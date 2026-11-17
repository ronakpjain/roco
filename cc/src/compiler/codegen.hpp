#pragma once

/// @file codegen.hpp
/// @brief Stack-machine RV32 assembly generation for the supported C subset.

#include "compiler/ast.hpp"
#include "compiler/types.hpp"

#include "roco/diagnostic.hpp"
#include "roco/target.hpp"

#include <cctype>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <sstream>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

namespace roco::cc {

// ---------------------------------------------------------------- Codegen

class Codegen {
 public:
  explicit Codegen(Program program, CompilerOptions options = {})
      : program_(std::move(program)), options_(options) {}

  std::string generate() {
    mark_reachable_functions();
    emit(".section .text");
    for (const auto& function : program_.functions) {
      if (function->defined && reachable_.count(function.get()) != 0) {
        generate_function(*function);
      }
    }
    emit_strings();
    emit_globals();
    return output_.str();
  }

 private:
  [[noreturn]] void fail(const Token& token, const std::string& message) const {
    throw Error("codegen:" + std::to_string(token.line) + ":" +
                std::to_string(token.column) + ": " + message);
  }

  void emit(const std::string& line) { output_ << line << '\n'; }

  std::string new_label() { return ".L" + std::to_string(label_counter_++); }

  struct TempValue {
    bool in_register = false;
    std::string reg;
  };

  void push_a0() {
    if (temp_stack_.size() < 7) {
      const std::string reg = "t" + std::to_string(temp_stack_.size());
      emit("  mv " + reg + ", a0");
      temp_stack_.push_back({true, reg});
      return;
    }
    emit("  addi s1, s1, -4");
    emit("  sw a0, 0(s1)");
    temp_stack_.push_back({false, std::string()});
    if (temp_stack_.size() > 256) {
      throw Error("expression is too deeply nested for the compiler frame");
    }
  }

  void pop_to(const std::string& reg) {
    const TempValue value = temp_stack_.back();
    temp_stack_.pop_back();
    if (value.in_register) {
      emit("  mv " + reg + ", " + value.reg);
    } else {
      emit("  lw " + reg + ", 0(s1)");
      emit("  addi s1, s1, 4");
    }
  }

  void spill_temporaries() {
    for (const TempValue& value : temp_stack_) {
      if (value.in_register) {
        emit("  addi s1, s1, -4");
        emit("  sw " + value.reg + ", 0(s1)");
      }
    }
  }

  void reload_temporaries() {
    for (auto iterator = temp_stack_.rbegin(); iterator != temp_stack_.rend();
         ++iterator) {
      if (iterator->in_register) {
        emit("  lw " + iterator->reg + ", 0(s1)");
        emit("  addi s1, s1, 4");
      }
    }
  }

  void mark_reachable_functions() {
    std::vector<Function*> worklist;
    for (const auto& function : program_.functions) {
      if (function->defined && !function->is_static) {
        worklist.push_back(function.get());
      }
    }
    while (!worklist.empty()) {
      Function* function = worklist.back();
      worklist.pop_back();
      if (!function->defined || function->body == nullptr) {
        continue;
      }
      if (!reachable_.insert(function).second) {
        continue;
      }
      collect_calls(*function->body, worklist);
    }
  }

  void collect_calls(const Stmt& statement, std::vector<Function*>& worklist) {
    if (statement.expr) collect_calls(*statement.expr, worklist);
    if (statement.inc) collect_calls(*statement.inc, worklist);
    if (statement.init) collect_calls(*statement.init, worklist);
    if (statement.then_stmt) collect_calls(*statement.then_stmt, worklist);
    if (statement.else_stmt) collect_calls(*statement.else_stmt, worklist);
    if (statement.body) collect_calls(*statement.body, worklist);
    for (const auto& child : statement.statements) {
      collect_calls(*child, worklist);
    }
    for (const auto& declaration : statement.declarations) {
      if (declaration->init) collect_calls(*declaration->init, worklist);
      for (const auto& element : declaration->init_list) {
        collect_calls(*element, worklist);
      }
    }
  }

  void collect_calls(const Expr& expression, std::vector<Function*>& worklist) {
    if (expression.function != nullptr && expression.kind == ExprKind::Call &&
        expression.function->defined) {
      worklist.push_back(expression.function);
    }
    if (expression.lhs) collect_calls(*expression.lhs, worklist);
    if (expression.rhs) collect_calls(*expression.rhs, worklist);
    if (expression.third) collect_calls(*expression.third, worklist);
    for (const auto& argument : expression.args) {
      collect_calls(*argument, worklist);
    }
  }

  void generate_function(const Function& function) {
    temp_stack_.clear();
    return_label_ = new_label();
    if (!function.is_static) {
      emit("  .globl " + function.name);
    }
    emit("  .type " + function.name + ", @function");
    emit(function.name + ":");
    emit("  addi sp, sp, -16");
    emit("  sw ra, 12(sp)");
    emit("  sw s0, 8(sp)");
    emit("  sw s1, 4(sp)");
    emit("  mv s0, sp");
    emit("  addi sp, sp, -" + std::to_string(function.frame_size));
    emit("  addi s1, s0, -" + std::to_string(function.local_area));

    static const std::vector<std::string> arg_registers = {
        "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7"};
    for (std::size_t i = 0; i < function.params.size(); ++i) {
      if (i >= arg_registers.size()) {
        fail(function.params[i]->token,
             "roco_cc currently supports at most eight parameters");
      }
      emit("  sw " + arg_registers[i] + ", " +
           std::to_string(function.params[i]->offset) + "(s0)");
    }

    generate_statement(*function.body, function);
    if (function.name == "main" && function.type->base->kind != TypeKind::Void) {
      emit("  li a0, 0");
    }
    emit(return_label_ + ":");
    emit("  mv sp, s0");
    emit("  lw ra, 12(sp)");
    emit("  lw s0, 8(sp)");
    emit("  lw s1, 4(sp)");
    emit("  addi sp, sp, 16");
    emit("  ret");
    if (!temp_stack_.empty()) {
      throw Error("internal error: unbalanced compiler expression stack");
    }
  }

  bool optimizing(OptimizationLevel level) const {
    return options_.optimization >= level;
  }

  static bool is_comparison(BinaryOp operation) {
    switch (operation) {
      case BinaryOp::Lt:
      case BinaryOp::Le:
      case BinaryOp::Gt:
      case BinaryOp::Ge:
      case BinaryOp::Eq:
      case BinaryOp::Ne:
        return true;
      default:
        return false;
    }
  }

  void emit_compare_branch_impl(BinaryOp operation, bool when_true,
                                const std::string& left_reg,
                                const std::string& right_reg, bool is_unsigned,
                                const std::string& target) {
    BinaryOp branch_operation = operation;
    if (!when_true) {
      switch (operation) {
        case BinaryOp::Eq:
          branch_operation = BinaryOp::Ne;
          break;
        case BinaryOp::Ne:
          branch_operation = BinaryOp::Eq;
          break;
        case BinaryOp::Lt:
          branch_operation = BinaryOp::Ge;
          break;
        case BinaryOp::Le:
          branch_operation = BinaryOp::Gt;
          break;
        case BinaryOp::Gt:
          branch_operation = BinaryOp::Le;
          break;
        case BinaryOp::Ge:
          branch_operation = BinaryOp::Lt;
          break;
        default:
          break;
      }
    }
    std::string mnemonic;
    std::string first = left_reg;
    std::string second = right_reg;
    switch (branch_operation) {
      case BinaryOp::Eq:
        mnemonic = "beq";
        break;
      case BinaryOp::Ne:
        mnemonic = "bne";
        break;
      case BinaryOp::Lt:
        mnemonic = is_unsigned ? "bltu" : "blt";
        break;
      case BinaryOp::Le:
        mnemonic = is_unsigned ? "bgeu" : "bge";
        first = right_reg;
        second = left_reg;
        break;
      case BinaryOp::Gt:
        mnemonic = is_unsigned ? "bltu" : "blt";
        first = right_reg;
        second = left_reg;
        break;
      case BinaryOp::Ge:
        mnemonic = is_unsigned ? "bgeu" : "bge";
        break;
      default:
        return;
    }
    emit("  " + mnemonic + " " + first + ", " + second + ", " + target);
  }

  void emit_comparison_condition(const Expr& expression,
                                 const Function& function,
                                 const std::string& target, bool when_true) {
    const TypePtr left_type = expression.lhs->type;
    const TypePtr right_type = expression.rhs->type;
    const bool is_unsigned =
        left_type->is_unsigned || right_type->is_unsigned ||
        is_pointer(left_type) || is_pointer(right_type);
    std::int64_t constant = 0;
    if (constant_int(*expression.rhs, constant)) {
      generate_expression(*expression.lhs, function);
      std::string right_reg = "zero";
      if (constant != 0) {
        right_reg = "a1";
        emit("  li a1, " + std::to_string(constant));
      }
      emit_compare_branch_impl(expression.binary, when_true, "a0", right_reg,
                               is_unsigned, target);
      return;
    }
    generate_expression(*expression.lhs, function);
    push_a0();
    generate_expression(*expression.rhs, function);
    pop_to("a1");
    emit_compare_branch_impl(expression.binary, when_true, "a1", "a0",
                             is_unsigned, target);
  }

  void emit_branch_condition(const Expr& expression, const Function& function,
                             const std::string& target, bool when_true) {
    if (expression.kind == ExprKind::Unary &&
        expression.unary == UnaryOp::Not) {
      emit_branch_condition(*expression.lhs, function, target, !when_true);
      return;
    }
    if (expression.kind == ExprKind::Binary) {
      if (expression.binary == BinaryOp::LogAnd) {
        if (!when_true) {
          emit_branch_condition(*expression.lhs, function, target, false);
          emit_branch_condition(*expression.rhs, function, target, false);
        } else {
          const std::string skip = new_label();
          emit_branch_condition(*expression.lhs, function, skip, false);
          emit_branch_condition(*expression.rhs, function, skip, false);
          emit("  j " + target);
          emit(skip + ":");
        }
        return;
      }
      if (expression.binary == BinaryOp::LogOr) {
        if (when_true) {
          emit_branch_condition(*expression.lhs, function, target, true);
          emit_branch_condition(*expression.rhs, function, target, true);
        } else {
          const std::string skip = new_label();
          emit_branch_condition(*expression.lhs, function, skip, true);
          emit_branch_condition(*expression.rhs, function, skip, true);
          emit("  j " + target);
          emit(skip + ":");
        }
        return;
      }
      if (is_comparison(expression.binary)) {
        emit_comparison_condition(expression, function, target, when_true);
        return;
      }
    }
    generate_expression(expression, function);
    emit(std::string(when_true ? "  bnez a0, " : "  beqz a0, ") + target);
  }

  void generate_statement(const Stmt& statement, const Function& function) {
    switch (statement.kind) {
      case StmtKind::Empty:
        return;
      case StmtKind::Expression:
        generate_expression(*statement.expr, function,
                            !optimizing(OptimizationLevel::O1));
        return;
      case StmtKind::Return: {
        if (statement.expr) {
          generate_expression(*statement.expr, function);
          convert_value(function.type->base);
        } else if (function.type->base->kind != TypeKind::Void) {
          emit("  li a0, 0");
        }
        emit("  j " + return_label_);
        return;
      }
      case StmtKind::Block:
        for (const auto& child : statement.statements) {
          generate_statement(*child, function);
        }
        return;
      case StmtKind::If: {
        std::int64_t condition = 0;
        if (optimizing(OptimizationLevel::O1) &&
            constant_int(*statement.expr, condition)) {
          if (condition != 0) {
            generate_statement(*statement.then_stmt, function);
          } else if (statement.else_stmt) {
            generate_statement(*statement.else_stmt, function);
          }
          return;
        }
        const std::string else_label = new_label();
        const std::string end_label = new_label();
        if (optimizing(OptimizationLevel::O1)) {
          emit_branch_condition(*statement.expr, function,
                                statement.else_stmt ? else_label : end_label,
                                false);
        } else {
          generate_expression(*statement.expr, function);
          emit("  beqz a0, " +
               (statement.else_stmt ? else_label : end_label));
        }
        generate_statement(*statement.then_stmt, function);
        if (statement.else_stmt) {
          emit("  j " + end_label);
          emit(else_label + ":");
          generate_statement(*statement.else_stmt, function);
        }
        emit(end_label + ":");
        return;
      }
      case StmtKind::While: {
        std::int64_t condition = 0;
        const bool constant =
            optimizing(OptimizationLevel::O1) &&
            constant_int(*statement.expr, condition);
        if (constant && condition == 0) {
          return;
        }
        const std::string start = new_label();
        const std::string end = new_label();
        break_labels_.push_back(end);
        continue_labels_.push_back(start);
        emit(start + ":");
        if (!(constant && condition != 0)) {
          if (optimizing(OptimizationLevel::O1)) {
            emit_branch_condition(*statement.expr, function, end, false);
          } else {
            generate_expression(*statement.expr, function);
            emit("  beqz a0, " + end);
          }
        }
        generate_statement(*statement.body, function);
        emit("  j " + start);
        emit(end + ":");
        continue_labels_.pop_back();
        break_labels_.pop_back();
        return;
      }
      case StmtKind::DoWhile: {
        std::int64_t condition = 0;
        if (optimizing(OptimizationLevel::O1) &&
            constant_int(*statement.expr, condition)) {
          const std::string end = new_label();
          break_labels_.push_back(end);
          if (condition != 0) {
            const std::string start = new_label();
            continue_labels_.push_back(start);
            emit(start + ":");
            generate_statement(*statement.body, function);
            emit("  j " + start);
          } else {
            continue_labels_.push_back(end);
            generate_statement(*statement.body, function);
          }
          emit(end + ":");
          continue_labels_.pop_back();
          break_labels_.pop_back();
          return;
        }
        const std::string start = new_label();
        const std::string condition_label = new_label();
        const std::string end = new_label();
        break_labels_.push_back(end);
        continue_labels_.push_back(condition_label);
        emit(start + ":");
        generate_statement(*statement.body, function);
        emit(condition_label + ":");
        if (optimizing(OptimizationLevel::O1)) {
          emit_branch_condition(*statement.expr, function, start, true);
        } else {
          generate_expression(*statement.expr, function);
          emit("  bnez a0, " + start);
        }
        emit(end + ":");
        continue_labels_.pop_back();
        break_labels_.pop_back();
        return;
      }
      case StmtKind::For: {
        std::int64_t condition = 0;
        const bool constant =
            optimizing(OptimizationLevel::O1) && statement.expr != nullptr &&
            constant_int(*statement.expr, condition);
        if (constant && condition == 0) {
          if (statement.init) {
            generate_statement(*statement.init, function);
          }
          return;
        }
        const std::string start = new_label();
        const std::string increment = new_label();
        const std::string end = new_label();
        break_labels_.push_back(end);
        continue_labels_.push_back(increment);
        if (statement.init) {
          generate_statement(*statement.init, function);
        }
        emit(start + ":");
        if (statement.expr && !(constant && condition != 0)) {
          if (optimizing(OptimizationLevel::O1)) {
            emit_branch_condition(*statement.expr, function, end, false);
          } else {
            generate_expression(*statement.expr, function);
            emit("  beqz a0, " + end);
          }
        }
        generate_statement(*statement.body, function);
        emit(increment + ":");
        if (statement.inc) {
          generate_expression(*statement.inc, function,
                              !optimizing(OptimizationLevel::O1));
        }
        emit("  j " + start);
        emit(end + ":");
        continue_labels_.pop_back();
        break_labels_.pop_back();
        return;
      }
      case StmtKind::Break:
        if (break_labels_.empty()) {
          fail(statement.token, "'break' outside a loop");
        }
        emit("  j " + break_labels_.back());
        return;
      case StmtKind::Continue:
        if (continue_labels_.empty()) {
          fail(statement.token, "'continue' outside a loop");
        }
        emit("  j " + continue_labels_.back());
        return;
      case StmtKind::Declaration:
        for (const auto& declaration : statement.declarations) {
          if (declaration->init) {
            generate_expression(*declaration->init, function);
            convert_value(declaration->type);
            emit("  sw a0, " + std::to_string(declaration->offset) + "(s0)");
          }
        }
        return;
    }
  }

  void generate_expression(const Expr& expression, const Function& function,
                           bool need_value = true) {
    if (!need_value && optimizing(OptimizationLevel::O1) &&
        (expression.kind == ExprKind::Int ||
         expression.kind == ExprKind::String)) {
      return;
    }
    switch (expression.kind) {
      case ExprKind::Int:
        emit("  li a0, " + std::to_string(expression.value));
        return;
      case ExprKind::String:
        emit("  la a0, " + expression.name);
        return;
      case ExprKind::Var: {
        TypePtr object_type = expression.type;
        if (expression.local != nullptr) {
          object_type = expression.local->type;
        } else if (expression.global != nullptr) {
          object_type = expression.global->decl->type;
        }
        if (object_type->kind != TypeKind::Array && expression.local != nullptr) {
          load_from(expression.type, "s0", expression.local->offset);
          return;
        }
        generate_address(expression, function);
        if (object_type->kind != TypeKind::Array) {
          load(expression.type);
        }
        return;
      }
      case ExprKind::Unary:
        generate_unary(expression, function, need_value);
        return;
      case ExprKind::Binary:
        generate_binary(expression, function, need_value);
        return;
      case ExprKind::Assign:
        generate_assignment(expression, function, need_value);
        return;
      case ExprKind::Conditional: {
        const std::string else_label = new_label();
        const std::string end_label = new_label();
        if (optimizing(OptimizationLevel::O1)) {
          emit_branch_condition(*expression.lhs, function, else_label, false);
        } else {
          generate_expression(*expression.lhs, function);
          emit("  beqz a0, " + else_label);
        }
        generate_expression(*expression.rhs, function, need_value);
        emit("  j " + end_label);
        emit(else_label + ":");
        generate_expression(*expression.third, function, need_value);
        emit(end_label + ":");
        return;
      }
      case ExprKind::Call:
        generate_call(expression, function);
        return;
      case ExprKind::Index:
        if (try_constant_index_load(expression)) {
          return;
        }
        if (optimizing(OptimizationLevel::O1) && is_scalar(expression.type)) {
          std::int64_t offset = 0;
          if (constant_byte_offset(*expression.rhs, expression.type->size,
                                   offset)) {
            generate_expression(*expression.lhs, function);
            if (fits_signed_12(offset)) {
              load_into(expression.type, "a0", "a0",
                        static_cast<int>(offset));
            } else {
              emit_add_to_a0(offset);
              load(expression.type);
            }
            return;
          }
        }
        generate_address(expression, function);
        load(expression.type);
        return;
      case ExprKind::Cast:
        generate_expression(*expression.lhs, function, need_value);
        if (need_value || !optimizing(OptimizationLevel::O1)) {
          convert_value(expression.type);
        }
        return;
    }
  }

  void generate_unary(const Expr& expression, const Function& function,
                      bool need_value = true) {
    switch (expression.unary) {
      case UnaryOp::Plus:
        generate_expression(*expression.lhs, function, need_value);
        return;
      case UnaryOp::Negate:
        generate_expression(*expression.lhs, function, need_value);
        if (need_value || !optimizing(OptimizationLevel::O1)) {
          emit("  neg a0, a0");
        }
        return;
      case UnaryOp::Not:
        generate_expression(*expression.lhs, function, need_value);
        if (need_value || !optimizing(OptimizationLevel::O1)) {
          emit("  seqz a0, a0");
        }
        return;
      case UnaryOp::BitNot:
        generate_expression(*expression.lhs, function, need_value);
        if (need_value || !optimizing(OptimizationLevel::O1)) {
          emit("  not a0, a0");
        }
        return;
      case UnaryOp::Dereference:
        generate_expression(*expression.lhs, function);
        load(expression.type);
        return;
      case UnaryOp::Address:
        generate_address(*expression.lhs, function);
        return;
      case UnaryOp::PreIncrement:
      case UnaryOp::PreDecrement:
      case UnaryOp::PostIncrement:
      case UnaryOp::PostDecrement:
        generate_increment(expression, function, need_value);
        return;
    }
  }

  void generate_increment(const Expr& expression, const Function& function,
                          bool need_value = true) {
    if (expression.lhs->kind == ExprKind::Var &&
        expression.lhs->local != nullptr &&
        expression.lhs->local->type->kind != TypeKind::Array) {
      const int offset = expression.lhs->local->offset;
      load_from(expression.lhs->type, "s0", offset);
      const bool increment = expression.unary == UnaryOp::PreIncrement ||
                             expression.unary == UnaryOp::PostIncrement;
      const bool post = expression.unary == UnaryOp::PostIncrement ||
                        expression.unary == UnaryOp::PostDecrement;
      if (post && need_value) {
        emit("  mv a2, a0");
      }
      const std::int64_t delta = increment ? 1 : -1;
      if (is_pointer(expression.type)) {
        const std::int64_t step =
            static_cast<std::int64_t>(expression.type->base->size) * delta;
        emit("  addi a0, a0, " + std::to_string(step));
      } else {
        emit("  addi a0, a0, " + std::to_string(delta));
      }
      store_to(expression.lhs->type, "s0", offset);
      if (optimizing(OptimizationLevel::O1)) {
        if (need_value) {
          if (post) {
            emit("  mv a0, a2");
          } else {
            convert_value(expression.lhs->type);
          }
        }
      } else {
        convert_value(expression.lhs->type);
        if (post) {
          emit("  mv a0, a2");
        }
      }
      return;
    }
    generate_address(*expression.lhs, function);
    push_a0();
    load(expression.lhs->type);
    const bool increment = expression.unary == UnaryOp::PreIncrement ||
                           expression.unary == UnaryOp::PostIncrement;
    const bool post = expression.unary == UnaryOp::PostIncrement ||
                      expression.unary == UnaryOp::PostDecrement;
    if (post && need_value) {
      emit("  mv a2, a0");
    }
    const std::int64_t delta = increment ? 1 : -1;
    if (is_pointer(expression.type)) {
      const std::int64_t step =
          static_cast<std::int64_t>(expression.type->base->size) * delta;
      if (optimizing(OptimizationLevel::O1)) {
        emit_add_to_a0(step);
      } else {
        emit("  li a1, " + std::to_string(step));
        emit("  add a0, a0, a1");
      }
    } else {
      emit("  addi a0, a0, " + std::to_string(delta));
    }
    pop_to("a1");
    store(expression.lhs->type);
    if (optimizing(OptimizationLevel::O1)) {
      if (need_value) {
        if (post) {
          emit("  mv a0, a2");
        } else {
          convert_value(expression.lhs->type);
        }
      }
    } else {
      convert_value(expression.lhs->type);
      if (post) {
        emit("  mv a0, a2");
      }
    }
  }

  void generate_assignment(const Expr& expression, const Function& function,
                           bool need_value = true) {
    if (!expression.compound) {
      if (expression.lhs->kind == ExprKind::Var &&
          expression.lhs->local != nullptr &&
          expression.lhs->local->type->kind != TypeKind::Array) {
        generate_expression(*expression.rhs, function);
        store_to(expression.lhs->type, "s0", expression.lhs->local->offset);
        convert_result(expression.lhs->type, need_value);
        return;
      }
      if (expression.lhs->kind == ExprKind::Var &&
          expression.lhs->global != nullptr &&
          expression.lhs->global->decl->type->kind != TypeKind::Array) {
        generate_expression(*expression.rhs, function);
        emit("  la a1, " + expression.lhs->global->decl->name);
        store(expression.lhs->type);
        convert_result(expression.lhs->type, need_value);
        return;
      }
      if (try_constant_index_store(expression, function, need_value)) {
        return;
      }
      generate_address(*expression.lhs, function);
      push_a0();
      generate_expression(*expression.rhs, function);
      pop_to("a1");
      store(expression.lhs->type);
      convert_result(expression.lhs->type, need_value);
      return;
    }

    const bool local_compound =
        expression.lhs->kind == ExprKind::Var &&
        expression.lhs->local != nullptr &&
        expression.lhs->local->type->kind != TypeKind::Array;
    std::int64_t immediate = 0;
    const bool pointer_compound =
        is_pointer(expression.lhs->type) &&
        (expression.binary == BinaryOp::Add ||
         expression.binary == BinaryOp::Sub) &&
        is_integer(expression.rhs->type);
    bool immediate_compound =
        optimizing(OptimizationLevel::O1) &&
        constant_int(*expression.rhs, immediate) &&
        (is_integer(expression.lhs->type) || pointer_compound);
    if (immediate_compound && pointer_compound) {
      const std::int64_t signed_scale =
          static_cast<std::int64_t>(expression.lhs->type->base->size);
      if (immediate >
              std::numeric_limits<std::int32_t>::max() / signed_scale ||
          immediate <
              std::numeric_limits<std::int32_t>::min() / signed_scale) {
        immediate_compound = false;
      } else {
        immediate *= signed_scale;
      }
    }
    if (immediate_compound) {
      bool is_unsigned = expression.lhs->type->is_unsigned ||
                         expression.rhs->type->is_unsigned;
      if (expression.binary == BinaryOp::Shr) {
        is_unsigned = expression.lhs->type->is_unsigned;
      }
      if (local_compound) {
        load_into(expression.lhs->type, "a0", "s0",
                  expression.lhs->local->offset);
        if (emit_immediate(expression.binary, immediate,
                           expression.lhs->type, expression.rhs->type)) {
          store_to(expression.lhs->type, "s0",
                   expression.lhs->local->offset);
          convert_result(expression.lhs->type, need_value);
          return;
        }
        push_a0();
        generate_expression(*expression.rhs, function);
        if (pointer_compound) {
          emit_scale_a0(expression.lhs->type->base->size);
        }
        pop_to("a1");
        apply_binary(expression.binary, expression.lhs->type,
                     expression.rhs->type, is_unsigned);
        store_to(expression.lhs->type, "s0",
                 expression.lhs->local->offset);
        convert_result(expression.lhs->type, need_value);
        return;
      }
      generate_address(*expression.lhs, function);
      push_a0();
      load(expression.lhs->type);
      if (emit_immediate(expression.binary, immediate,
                         expression.lhs->type, expression.rhs->type)) {
        pop_to("a1");
        store(expression.lhs->type);
        convert_result(expression.lhs->type, need_value);
        return;
      }
      push_a0();
      generate_expression(*expression.rhs, function);
      if (pointer_compound) {
        emit_scale_a0(expression.lhs->type->base->size);
      }
      pop_to("a1");
      apply_binary(expression.binary, expression.lhs->type,
                   expression.rhs->type, is_unsigned);
      pop_to("a1");
      store(expression.lhs->type);
      convert_result(expression.lhs->type, need_value);
      return;
    }
    if (local_compound) {
      generate_expression(*expression.rhs, function);
      if (is_pointer(expression.lhs->type) &&
          is_integer(expression.rhs->type)) {
        emit_scale_a0(expression.lhs->type->base->size);
      }
      emit("  mv a2, a0");
      load_into(expression.lhs->type, "a1", "s0",
                expression.lhs->local->offset);
      emit("  mv a0, a2");
      bool is_unsigned = expression.lhs->type->is_unsigned ||
                         expression.rhs->type->is_unsigned;
      if (expression.binary == BinaryOp::Shr) {
        is_unsigned = expression.lhs->type->is_unsigned;
      }
      apply_binary(expression.binary, expression.lhs->type,
                   expression.rhs->type, is_unsigned);
      store_to(expression.lhs->type, "s0", expression.lhs->local->offset);
      convert_result(expression.lhs->type, need_value);
      return;
    }
    generate_address(*expression.lhs, function);
    push_a0();
    load(expression.lhs->type);
    push_a0();
    generate_expression(*expression.rhs, function);
    if (is_pointer(expression.lhs->type) &&
        is_integer(expression.rhs->type)) {
      emit_scale_a0(expression.lhs->type->base->size);
    }
    pop_to("a1");
    bool is_unsigned = expression.lhs->type->is_unsigned ||
                       expression.rhs->type->is_unsigned;
    if (expression.binary == BinaryOp::Shr) {
      is_unsigned = expression.lhs->type->is_unsigned;
    }
    apply_binary(expression.binary, expression.lhs->type, expression.rhs->type,
                 is_unsigned);
    pop_to("a1");
    store(expression.lhs->type);
    convert_result(expression.lhs->type, need_value);
  }

  static bool constant_int(const Expr& expression, std::int64_t& value) {
    if (expression.kind == ExprKind::Int) {
      value = expression.value;
      return true;
    }
    if (expression.kind == ExprKind::Unary &&
        expression.unary == UnaryOp::Negate && expression.lhs &&
        constant_int(*expression.lhs, value)) {
      value = -value;
      return true;
    }
    return false;
  }

  static bool fits_signed_12(std::int64_t value) {
    return value >= -2048 && value <= 2047;
  }

  static bool is_power_of_two(std::size_t value) {
    return value != 0 && (value & (value - 1)) == 0;
  }

  static unsigned power_of_two_shift(std::size_t value) {
    unsigned shift = 0;
    while ((std::size_t{1} << shift) < value) {
      ++shift;
    }
    return shift;
  }

  void emit_scale_a0(std::size_t scale) {
    if (scale <= 1) {
      return;
    }
    if (optimizing(OptimizationLevel::O1) && is_power_of_two(scale)) {
      emit("  slli a0, a0, " +
           std::to_string(power_of_two_shift(scale)));
      return;
    }
    emit("  li a1, " + std::to_string(scale));
    emit("  mul a0, a0, a1");
  }

  void emit_add_to_a0(std::int64_t offset) {
    if (offset == 0) {
      return;
    }
    if (fits_signed_12(offset)) {
      emit("  addi a0, a0, " + std::to_string(offset));
      return;
    }
    emit("  li a1, " + std::to_string(offset));
    emit("  add a0, a0, a1");
  }

  static bool constant_byte_offset(const Expr& index, std::size_t scale,
                                   std::int64_t& offset) {
    std::int64_t value = 0;
    if (!constant_int(index, value)) {
      return false;
    }
    if (scale == 0) {
      return false;
    }
    const std::int64_t signed_scale = static_cast<std::int64_t>(scale);
    if (value > static_cast<std::int64_t>(std::numeric_limits<std::int32_t>::max()) /
                    signed_scale ||
        value < static_cast<std::int64_t>(std::numeric_limits<std::int32_t>::min()) /
                    signed_scale) {
      return false;
    }
    offset = value * signed_scale;
    return true;
  }

  int sequence_cost(int instructions, int latency) const {
    const int issue = options_.costs.issue > 0 ? options_.costs.issue : 1;
    return instructions * issue + std::max(0, latency - issue);
  }

  static int highest_bit(std::uint32_t value) {
    int bit = -1;
    while (value != 0) {
      ++bit;
      value >>= 1;
    }
    return bit;
  }

  static int count_bits(std::uint32_t value) {
    int count = 0;
    while (value != 0) {
      count += static_cast<int>(value & 1u);
      value >>= 1;
    }
    return count;
  }

  static int immediate_instruction_count(std::int64_t value) {
    if (fits_signed_12(value)) {
      return 1;
    }
    const std::uint32_t bits = static_cast<std::uint32_t>(value);
    return (bits & 0xfffu) == 0 ? 1 : 2;
  }

  int temporary_push_cost() const {
    return temp_stack_.size() < 7 ? 1 : 2;
  }

  int temporary_pop_cost() const {
    return temp_stack_.size() < 7 ? 1 : 2;
  }

  int latency_of_sequence(const std::vector<std::string>& sequence) const {
    if (sequence.empty()) {
      return options_.costs.arithmetic;
    }
    const std::string& last = sequence.back();
    if (last.find("slli") != std::string::npos ||
        last.find("srli") != std::string::npos ||
        last.find("srai") != std::string::npos ||
        last.find("andi") != std::string::npos ||
        last.find("ori") != std::string::npos ||
        last.find("xori") != std::string::npos) {
      return options_.costs.shift;
    }
    return options_.costs.arithmetic;
  }

  void consider_sequence(std::vector<std::string>& best, int& best_cost,
                         std::vector<std::string> candidate) const {
    const int cost =
        sequence_cost(static_cast<int>(candidate.size()),
                      latency_of_sequence(candidate));
    if (cost < best_cost) {
      best_cost = cost;
      best = std::move(candidate);
    }
  }

  bool emit_constant_multiply(std::int32_t value) {
    std::vector<std::string> best;
    int best_cost = std::numeric_limits<int>::max();
    if (value == 0) {
      consider_sequence(best, best_cost, {"li a0, 0"});
    } else if (value == 1) {
      consider_sequence(best, best_cost, {});
    } else if (value == -1) {
      consider_sequence(best, best_cost, {"neg a0, a0"});
    } else {
      const bool negative = value < 0;
      const std::uint32_t magnitude =
          negative ? 0u - static_cast<std::uint32_t>(value)
                   : static_cast<std::uint32_t>(value);
      const auto with_sign = [&](std::vector<std::string> sequence) {
        if (negative) {
          sequence.push_back("neg a0, a0");
        }
        return sequence;
      };

      if (is_power_of_two(static_cast<std::size_t>(magnitude))) {
        const unsigned shift = power_of_two_shift(magnitude);
        consider_sequence(best, best_cost,
                          with_sign({"slli a0, a0, " +
                                     std::to_string(shift)}));
      }

      const int bits = count_bits(magnitude);
      if (bits == 2) {
        const int high = highest_bit(magnitude);
        int low = 0;
        while ((magnitude & (1u << low)) == 0) {
          ++low;
        }
        if (low == 0) {
          consider_sequence(
              best, best_cost,
              with_sign({"slli a1, a0, " + std::to_string(high),
                         "add a0, a0, a1"}));
        } else {
          consider_sequence(
              best, best_cost,
              with_sign({"slli a1, a0, " + std::to_string(high),
                         "slli a0, a0, " + std::to_string(low),
                         "add a0, a0, a1"}));
        }
      }
      if (bits == 3) {
        const int high = highest_bit(magnitude);
        int middle = high - 1;
        while (middle >= 0 && (magnitude & (1u << middle)) == 0) {
          --middle;
        }
        int low = 0;
        while ((magnitude & (1u << low)) == 0) {
          ++low;
        }
        std::vector<std::string> sequence = {
            "slli a1, a0, " + std::to_string(high),
            "slli a2, a0, " + std::to_string(middle),
            "add a1, a1, a2"};
        if (low == 0) {
          sequence.push_back("add a0, a1, a0");
        } else {
          sequence.push_back("slli a0, a0, " + std::to_string(low));
          sequence.push_back("add a0, a1, a0");
        }
        consider_sequence(best, best_cost, with_sign(std::move(sequence)));
      }

      for (int low = 0; low < 31; ++low) {
        const std::uint64_t power = std::uint64_t{1} << low;
        const std::uint64_t sum = static_cast<std::uint64_t>(magnitude) + power;
        if (sum > 0x80000000ULL ||
            !is_power_of_two(static_cast<std::size_t>(sum))) {
          continue;
        }
        const int high = static_cast<int>(power_of_two_shift(sum));
        if (high <= low || high > 31) {
          continue;
        }
        if (low == 0) {
          consider_sequence(
              best, best_cost,
              with_sign({"slli a1, a0, " + std::to_string(high),
                         "sub a0, a1, a0"}));
        } else {
          consider_sequence(
              best, best_cost,
              with_sign({"slli a1, a0, " + std::to_string(high),
                         "slli a0, a0, " + std::to_string(low),
                         "sub a0, a1, a0"}));
        }
      }

      if (magnitude != 1) {
        std::vector<std::string> sequence = {"mv a1, a0"};
        const int high = highest_bit(magnitude);
        for (int bit = high - 1; bit >= 0; --bit) {
          sequence.push_back("slli a0, a0, 1");
          if ((magnitude & (1u << bit)) != 0) {
            sequence.push_back("add a0, a0, a1");
          }
        }
        consider_sequence(best, best_cost, with_sign(std::move(sequence)));
      }
    }

    const int fallback_cost = sequence_cost(
        temporary_push_cost() + immediate_instruction_count(value) +
            temporary_pop_cost() + 1,
        options_.costs.multiply);
    if (best_cost < fallback_cost) {
      for (const std::string& line : best) {
        emit("  " + line);
      }
      return true;
    }
    return false;
  }

  bool emit_constant_divmod(BinaryOp operation, std::int32_t value,
                            bool is_unsigned) {
    std::vector<std::string> best;
    int best_cost = std::numeric_limits<int>::max();
    const auto consider = [&](std::vector<std::string> candidate) {
      consider_sequence(best, best_cost, std::move(candidate));
    };
    const bool is_mod = operation == BinaryOp::Mod;
    const std::uint32_t bits = static_cast<std::uint32_t>(value);
    if (is_unsigned) {
      if (bits == 0) {
        return false;
      }
      if (bits == 1) {
        consider(is_mod ? std::vector<std::string>{"li a0, 0"}
                        : std::vector<std::string>{});
      } else if (is_power_of_two(static_cast<std::size_t>(bits))) {
        const unsigned shift = power_of_two_shift(bits);
        if (is_mod) {
          const std::uint32_t mask = bits - 1u;
          if (mask <= 2047u) {
            consider({"andi a0, a0, " + std::to_string(mask)});
          } else {
            consider({"li a1, " + std::to_string(mask),
                      "and a0, a0, a1"});
          }
        } else {
          consider({"srli a0, a0, " + std::to_string(shift)});
        }
      } else {
        return false;
      }
    } else {
      if (value == 0) {
        return false;
      }
      if (value == 1 || value == -1) {
        if (is_mod) {
          consider({"li a0, 0"});
        } else if (value == 1) {
          consider({});
        } else {
          consider({"neg a0, a0"});
        }
      } else {
        const bool negative = value < 0;
        const std::uint32_t magnitude =
            negative ? 0u - static_cast<std::uint32_t>(value)
                     : static_cast<std::uint32_t>(value);
        if (!is_power_of_two(static_cast<std::size_t>(magnitude))) {
          return false;
        }
        const unsigned shift = power_of_two_shift(magnitude);
        if (!is_mod) {
          std::vector<std::string> sequence = {
              "srai a1, a0, 31",
              "srli a1, a1, " + std::to_string(32u - shift),
              "add a0, a0, a1",
              "srai a0, a0, " + std::to_string(shift)};
          if (negative) {
            sequence.push_back("neg a0, a0");
          }
          consider(std::move(sequence));
        } else {
          std::vector<std::string> sequence = {
              "srai a1, a0, 31",
              "srli a1, a1, " + std::to_string(32u - shift),
              "add a0, a0, a1"};
          const std::uint32_t mask = magnitude - 1u;
          if (mask <= 2047u) {
            sequence.push_back("andi a0, a0, " + std::to_string(mask));
          } else {
            sequence.push_back("li a2, " + std::to_string(mask));
            sequence.push_back("and a0, a0, a2");
          }
          sequence.push_back("sub a0, a0, a1");
          consider(std::move(sequence));
        }
      }
    }

    const int fallback_cost = sequence_cost(
        temporary_push_cost() + immediate_instruction_count(value) +
            temporary_pop_cost() + 1,
        options_.costs.divide);
    if (best_cost < fallback_cost) {
      for (const std::string& line : best) {
        emit("  " + line);
      }
      return true;
    }
    return false;
  }

  bool emit_immediate(BinaryOp operation, std::int64_t value,
                      const TypePtr& left_type, const TypePtr& right_type) {
    const bool is_unsigned = left_type->is_unsigned ||
                             right_type->is_unsigned ||
                             is_pointer(left_type) || is_pointer(right_type);
    if (optimizing(OptimizationLevel::O2) &&
        (operation == BinaryOp::Mul || operation == BinaryOp::Div ||
         operation == BinaryOp::Mod)) {
      if (value < std::numeric_limits<std::int32_t>::min() ||
          value > std::numeric_limits<std::int32_t>::max()) {
        return false;
      }
      const std::int32_t constant = static_cast<std::int32_t>(value);
      if (operation == BinaryOp::Mul) {
        return emit_constant_multiply(constant);
      }
      return emit_constant_divmod(operation, constant, is_unsigned);
    }
    if (!fits_signed_12(value)) {
      return false;
    }
    switch (operation) {
      case BinaryOp::Add:
        if (value != 0) emit("  addi a0, a0, " + std::to_string(value));
        return true;
      case BinaryOp::Sub:
        if (!fits_signed_12(-value)) return false;
        if (value != 0) emit("  addi a0, a0, " + std::to_string(-value));
        return true;
      case BinaryOp::BitAnd:
        emit("  andi a0, a0, " + std::to_string(value));
        return true;
      case BinaryOp::BitOr:
        emit("  ori a0, a0, " + std::to_string(value));
        return true;
      case BinaryOp::BitXor:
        emit("  xori a0, a0, " + std::to_string(value));
        return true;
      case BinaryOp::Shl:
        if (value < 0 || value > 31) return false;
        emit("  slli a0, a0, " + std::to_string(value));
        return true;
      case BinaryOp::Shr:
        if (value < 0 || value > 31) return false;
        emit(std::string(left_type->is_unsigned ? "  srli a0, a0, "
                                                : "  srai a0, a0, ") +
             std::to_string(value));
        return true;
      case BinaryOp::Eq:
        emit("  xori a0, a0, " + std::to_string(value));
        emit("  seqz a0, a0");
        return true;
      case BinaryOp::Ne:
        emit("  xori a0, a0, " + std::to_string(value));
        emit("  snez a0, a0");
        return true;
      case BinaryOp::Lt:
        emit(std::string(is_unsigned ? "  sltiu a0, a0, "
                                     : "  slti a0, a0, ") +
             std::to_string(value));
        return true;
      case BinaryOp::Ge:
        emit(std::string(is_unsigned ? "  sltiu a0, a0, "
                                     : "  slti a0, a0, ") +
             std::to_string(value));
        emit("  xori a0, a0, 1");
        return true;
      case BinaryOp::Le:
        if (!fits_signed_12(value + 1)) return false;
        emit(std::string(is_unsigned ? "  sltiu a0, a0, "
                                     : "  slti a0, a0, ") +
             std::to_string(value + 1));
        return true;
      case BinaryOp::Gt:
        if (!fits_signed_12(value + 1)) return false;
        emit(std::string(is_unsigned ? "  sltiu a0, a0, "
                                     : "  slti a0, a0, ") +
             std::to_string(value + 1));
        emit("  xori a0, a0, 1");
        return true;
      default:
        return false;
    }
  }

  void load_into(const TypePtr& type, const std::string& reg,
                 const std::string& base, int offset) {
    switch (type->kind) {
      case TypeKind::Char:
        emit(std::string(type->is_unsigned ? "  lbu " : "  lb ") + reg + ", " +
             std::to_string(offset) + "(" + base + ")");
        return;
      case TypeKind::Short:
        emit(std::string(type->is_unsigned ? "  lhu " : "  lh ") + reg + ", " +
             std::to_string(offset) + "(" + base + ")");
        return;
      case TypeKind::Int:
      case TypeKind::Long:
      case TypeKind::Pointer:
        emit("  lw " + reg + ", " + std::to_string(offset) + "(" + base + ")");
        return;
      default:
        break;
    }
    throw Error("cannot load a value of this type");
  }

  void load_from(const TypePtr& type, const std::string& base, int offset) {
    load_into(type, "a0", base, offset);
  }

  void store_to(const TypePtr& type, const std::string& base, int offset) {
    switch (type->kind) {
      case TypeKind::Char:
        emit("  sb a0, " + std::to_string(offset) + "(" + base + ")");
        return;
      case TypeKind::Short:
        emit("  sh a0, " + std::to_string(offset) + "(" + base + ")");
        return;
      case TypeKind::Int:
      case TypeKind::Long:
      case TypeKind::Pointer:
        emit("  sw a0, " + std::to_string(offset) + "(" + base + ")");
        return;
      default:
        break;
    }
    throw Error("cannot store a value of this type");
  }

  bool try_constant_index_load(const Expr& expression) {
    if (!optimizing(OptimizationLevel::O1) ||
        expression.kind != ExprKind::Index || expression.lhs->kind != ExprKind::Var ||
        !is_scalar(expression.type)) {
      return false;
    }
    std::int64_t offset = 0;
    if (!constant_byte_offset(*expression.rhs, expression.type->size, offset)) {
      return false;
    }
    const Expr& base = *expression.lhs;
    if (base.local != nullptr && base.local->type->kind == TypeKind::Array) {
      const std::int64_t total =
          static_cast<std::int64_t>(base.local->offset) + offset;
      if (total < std::numeric_limits<int>::min() ||
          total > std::numeric_limits<int>::max() ||
          !fits_signed_12(total)) {
        return false;
      }
      load_from(expression.type, "s0", static_cast<int>(total));
      return true;
    }
    if (base.global != nullptr &&
        base.global->decl->type->kind == TypeKind::Array &&
        fits_signed_12(offset)) {
      emit("  la a0, " + base.global->decl->name);
      load_into(expression.type, "a0", "a0", static_cast<int>(offset));
      return true;
    }
    return false;
  }

  bool try_constant_index_store(const Expr& expression,
                                const Function& function, bool need_value) {
    if (!optimizing(OptimizationLevel::O1) || expression.compound ||
        expression.lhs->kind != ExprKind::Index ||
        expression.lhs->lhs->kind != ExprKind::Var ||
        !is_scalar(expression.lhs->type)) {
      return false;
    }
    std::int64_t offset = 0;
    if (!constant_byte_offset(*expression.lhs->rhs, expression.lhs->type->size,
                              offset)) {
      return false;
    }
    const Expr& base = *expression.lhs->lhs;
    if (base.local != nullptr && base.local->type->kind == TypeKind::Array) {
      const std::int64_t total =
          static_cast<std::int64_t>(base.local->offset) + offset;
      if (total < std::numeric_limits<int>::min() ||
          total > std::numeric_limits<int>::max() ||
          !fits_signed_12(total)) {
        return false;
      }
      generate_expression(*expression.rhs, function);
      if (!optimizing(OptimizationLevel::O1)) {
        convert_value(expression.lhs->type);
      }
      store_to(expression.lhs->type, "s0", static_cast<int>(total));
      convert_result(expression.lhs->type, need_value);
      return true;
    }
    if (base.global != nullptr &&
        base.global->decl->type->kind == TypeKind::Array &&
        fits_signed_12(offset)) {
      generate_expression(*expression.rhs, function);
      if (!optimizing(OptimizationLevel::O1)) {
        convert_value(expression.lhs->type);
      }
      emit("  la a1, " + base.global->decl->name);
      store_to(expression.lhs->type, "a1", static_cast<int>(offset));
      convert_result(expression.lhs->type, need_value);
      return true;
    }
    return false;
  }

  void generate_binary(const Expr& expression, const Function& function,
                       bool need_value = true) {
    if (expression.binary == BinaryOp::LogAnd ||
        expression.binary == BinaryOp::LogOr) {
      if (!need_value && optimizing(OptimizationLevel::O1)) {
        const std::string end = new_label();
        emit_branch_condition(expression, function, end, false);
        emit(end + ":");
        return;
      }
      const std::string short_label = new_label();
      const std::string end_label = new_label();
      generate_expression(*expression.lhs, function);
      if (expression.binary == BinaryOp::LogAnd) {
        emit("  beqz a0, " + short_label);
      } else {
        emit("  bnez a0, " + short_label);
      }
      generate_expression(*expression.rhs, function);
      emit("  snez a0, a0");
      emit("  j " + end_label);
      emit(short_label + ":");
      emit(expression.binary == BinaryOp::LogAnd ? "  li a0, 0"
                                                 : "  li a0, 1");
      emit(end_label + ":");
      return;
    }
    if (expression.binary == BinaryOp::Comma) {
      generate_expression(*expression.lhs, function, false);
      generate_expression(*expression.rhs, function, need_value);
      return;
    }
    if (!need_value && optimizing(OptimizationLevel::O1)) {
      generate_expression(*expression.lhs, function, false);
      generate_expression(*expression.rhs, function, false);
      return;
    }

    const TypePtr left_type = expression.lhs->type;
    const TypePtr right_type = expression.rhs->type;
    const bool pointer_arith =
        (expression.binary == BinaryOp::Add ||
         expression.binary == BinaryOp::Sub) &&
        is_pointer(left_type);
    std::int64_t immediate = 0;
    if (constant_int(*expression.rhs, immediate)) {
      if (pointer_arith && is_integer(right_type)) {
        immediate *= static_cast<std::int64_t>(left_type->base->size);
      }
      generate_expression(*expression.lhs, function);
      if (emit_immediate(expression.binary, immediate, left_type,
                         right_type)) {
        return;
      }
      push_a0();
      emit("  li a0, " + std::to_string(immediate));
      pop_to("a1");
    } else {
      generate_expression(*expression.lhs, function);
      push_a0();
      generate_expression(*expression.rhs, function);
      if (pointer_arith && is_integer(right_type)) {
        emit_scale_a0(left_type->base->size);
      }
      pop_to("a1");
    }
    if (expression.binary == BinaryOp::Sub && is_pointer(left_type) &&
        is_pointer(right_type)) {
      emit("  sub a0, a1, a0");
      const std::size_t scale = left_type->base->size;
      if (scale > 1) {
        if (optimizing(OptimizationLevel::O1) && is_power_of_two(scale)) {
          emit("  srai a0, a0, " +
               std::to_string(power_of_two_shift(scale)));
        } else {
          emit("  li a1, " + std::to_string(scale));
          emit("  div a0, a0, a1");
        }
      }
      return;
    }
    bool is_unsigned = left_type->is_unsigned || right_type->is_unsigned;
    if (is_pointer(left_type) || is_pointer(right_type)) {
      is_unsigned = true;
    }
    if (expression.binary == BinaryOp::Shr) {
      is_unsigned = left_type->is_unsigned;
    }
    apply_binary(expression.binary, left_type, right_type, is_unsigned);
  }

  void apply_binary(BinaryOp operation, const TypePtr& left_type,
                    const TypePtr& right_type, bool is_unsigned) {
    (void)left_type;
    (void)right_type;
    switch (operation) {
      case BinaryOp::Add:
        emit("  add a0, a1, a0");
        return;
      case BinaryOp::Sub:
        emit("  sub a0, a1, a0");
        return;
      case BinaryOp::Mul:
        emit("  mul a0, a1, a0");
        return;
      case BinaryOp::Div:
        emit(is_unsigned ? "  divu a0, a1, a0" : "  div a0, a1, a0");
        return;
      case BinaryOp::Mod:
        emit(is_unsigned ? "  remu a0, a1, a0" : "  rem a0, a1, a0");
        return;
      case BinaryOp::Shl:
        emit("  sll a0, a1, a0");
        return;
      case BinaryOp::Shr:
        emit(is_unsigned ? "  srl a0, a1, a0" : "  sra a0, a1, a0");
        return;
      case BinaryOp::Lt:
        emit(is_unsigned ? "  sltu a0, a1, a0" : "  slt a0, a1, a0");
        return;
      case BinaryOp::Le:
        emit(is_unsigned ? "  sltu a0, a0, a1" : "  slt a0, a0, a1");
        emit("  xori a0, a0, 1");
        return;
      case BinaryOp::Gt:
        emit(is_unsigned ? "  sltu a0, a0, a1" : "  slt a0, a0, a1");
        return;
      case BinaryOp::Ge:
        emit(is_unsigned ? "  sltu a0, a1, a0" : "  slt a0, a1, a0");
        emit("  xori a0, a0, 1");
        return;
      case BinaryOp::Eq:
        emit("  sub a0, a1, a0");
        emit("  seqz a0, a0");
        return;
      case BinaryOp::Ne:
        emit("  sub a0, a1, a0");
        emit("  snez a0, a0");
        return;
      case BinaryOp::BitAnd:
        emit("  and a0, a1, a0");
        return;
      case BinaryOp::BitOr:
        emit("  or a0, a1, a0");
        return;
      case BinaryOp::BitXor:
        emit("  xor a0, a1, a0");
        return;
      case BinaryOp::LogAnd:
      case BinaryOp::LogOr:
      case BinaryOp::Comma:
        break;
    }
    throw Error("internal error: invalid binary operator");
  }

  void generate_call(const Expr& expression, const Function& function) {
    if (expression.args.size() > 8) {
      fail(expression.token,
           "roco_cc currently supports at most eight call arguments");
    }
    if (expression.args.size() == 1) {
      generate_expression(*expression.args[0], function);
    } else {
      static const std::vector<std::string> arg_registers = {
          "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7"};
      const bool direct_constants = optimizing(OptimizationLevel::O1);
      for (const auto& argument : expression.args) {
        std::int64_t value = 0;
        if (direct_constants && constant_int(*argument, value)) {
          continue;
        }
        generate_expression(*argument, function);
        push_a0();
      }
      for (std::size_t i = expression.args.size(); i > 0; --i) {
        std::int64_t value = 0;
        if (direct_constants &&
            constant_int(*expression.args[i - 1], value)) {
          emit("  li " + arg_registers[i - 1] + ", " +
               std::to_string(value));
        } else {
          pop_to(arg_registers[i - 1]);
        }
      }
    }
    spill_temporaries();
    emit("  call " + expression.function->name);
    reload_temporaries();
  }

  void generate_address(const Expr& expression, const Function& function) {
    switch (expression.kind) {
      case ExprKind::Var:
        if (expression.local != nullptr) {
          emit("  addi a0, s0, " + std::to_string(expression.local->offset));
        } else if (expression.global != nullptr) {
          emit("  la a0, " + expression.global->decl->name);
        } else {
          fail(expression.token, "internal error: unresolved variable");
        }
        return;
      case ExprKind::Unary:
        if (expression.unary == UnaryOp::Dereference) {
          generate_expression(*expression.lhs, function);
          return;
        }
        break;
      case ExprKind::Index: {
        std::int64_t offset = 0;
        if (optimizing(OptimizationLevel::O1) &&
            constant_byte_offset(*expression.rhs, expression.type->size,
                                 offset)) {
          generate_expression(*expression.lhs, function);
          emit_add_to_a0(offset);
          return;
        }
        generate_expression(*expression.lhs, function);
        push_a0();
        generate_expression(*expression.rhs, function);
        emit_scale_a0(expression.type->size);
        pop_to("a1");
        emit("  add a0, a1, a0");
        return;
      }
      default:
        break;
    }
    fail(expression.token, "expression is not an lvalue");
  }

  void load(const TypePtr& type) {
    switch (type->kind) {
      case TypeKind::Char:
        emit(type->is_unsigned ? "  lbu a0, 0(a0)" : "  lb a0, 0(a0)");
        return;
      case TypeKind::Short:
        emit(type->is_unsigned ? "  lhu a0, 0(a0)" : "  lh a0, 0(a0)");
        return;
      case TypeKind::Int:
      case TypeKind::Long:
      case TypeKind::Pointer:
        emit("  lw a0, 0(a0)");
        return;
      case TypeKind::Void:
      case TypeKind::Array:
      case TypeKind::Function:
        break;
    }
    throw Error("cannot load a value of this type");
  }

  void store(const TypePtr& type) {
    switch (type->kind) {
      case TypeKind::Char:
        emit("  sb a0, 0(a1)");
        return;
      case TypeKind::Short:
        emit("  sh a0, 0(a1)");
        return;
      case TypeKind::Int:
      case TypeKind::Long:
      case TypeKind::Pointer:
        emit("  sw a0, 0(a1)");
        return;
      case TypeKind::Void:
      case TypeKind::Array:
      case TypeKind::Function:
        break;
    }
    throw Error("cannot store a value of this type");
  }

  void convert_value(const TypePtr& type) {
    if (type->kind == TypeKind::Char) {
      if (type->is_unsigned) {
        emit("  andi a0, a0, 255");
      } else {
        emit("  slli a0, a0, 24");
        emit("  srai a0, a0, 24");
      }
    } else if (type->kind == TypeKind::Short) {
      if (type->is_unsigned) {
        emit("  slli a0, a0, 16");
        emit("  srli a0, a0, 16");
      } else {
        emit("  slli a0, a0, 16");
        emit("  srai a0, a0, 16");
      }
    }
  }

  void convert_result(const TypePtr& type, bool need_value) {
    if (need_value || !optimizing(OptimizationLevel::O1)) {
      convert_value(type);
    }
  }

  void emit_strings() {
    if (program_.strings.empty()) {
      return;
    }
    emit("  .section .rodata");
    for (const StringLiteral& literal : program_.strings) {
      emit(literal.label + ":");
      std::string line = "  .byte ";
      std::size_t count = 0;
      for (const char character : literal.bytes) {
        const auto byte = static_cast<unsigned char>(character);
        if (count != 0) {
          line += ", ";
        }
        line += std::to_string(static_cast<unsigned int>(byte));
        ++count;
        if (count == 16) {
          emit(line);
          line = "  .byte ";
          count = 0;
        }
      }
      if (count != 0) {
        emit(line);
      }
      emit("  .byte 0");
    }
  }

  std::string static_expression(const Expr& expression) {
    if (expression.kind == ExprKind::Int) {
      return std::to_string(expression.value);
    }
    if (expression.kind == ExprKind::String) {
      return expression.name;
    }
    if (expression.kind == ExprKind::Unary &&
        expression.unary == UnaryOp::Address) {
      const Expr& operand = *expression.lhs;
      if (operand.kind == ExprKind::Var && operand.global != nullptr) {
        return operand.global->decl->name;
      }
      throw Error("unsupported address constant in global initializer");
    }
    if (expression.kind == ExprKind::Cast) {
      return static_expression(*expression.lhs);
    }
    if (expression.kind == ExprKind::Var && expression.global != nullptr) {
      if (expression.global->decl->type->kind == TypeKind::Array) {
        return expression.global->decl->name;
      }
      throw Error("global scalar value is not a link-time constant");
    }
    if (expression.kind == ExprKind::Binary &&
        (expression.binary == BinaryOp::Add ||
         expression.binary == BinaryOp::Sub)) {
      const std::string left = static_expression(*expression.lhs);
      const std::string right = static_expression(*expression.rhs);
      const bool left_symbol = !is_number(left);
      const bool right_symbol = !is_number(right);
      if (left_symbol && !right_symbol) {
        return left + (expression.binary == BinaryOp::Add ? "+" : "-") + right;
      }
      if (!left_symbol && right_symbol &&
          expression.binary == BinaryOp::Add) {
        return right + "+" + left;
      }
      throw Error("unsupported symbol arithmetic in global initializer");
    }
    if (expression.kind == ExprKind::Unary &&
        expression.unary == UnaryOp::Negate &&
        expression.lhs->kind == ExprKind::Int) {
      return std::to_string(-expression.lhs->value);
    }
    throw Error("global initializer is not a link-time constant");
  }

  static bool is_number(const std::string& text) {
    if (text.empty()) {
      return false;
    }
    std::size_t index = 0;
    if (text[0] == '-' || text[0] == '+') {
      index = 1;
    }
    if (index >= text.size()) {
      return false;
    }
    for (; index < text.size(); ++index) {
      if (!std::isdigit(static_cast<unsigned char>(text[index]))) {
        return false;
      }
    }
    return true;
  }

  void emit_globals() {
    for (const auto& global : program_.globals) {
      if (!global->defined || global->decl->type->kind == TypeKind::Function) {
        continue;
      }
      const Decl& declaration = *global->decl;
      const TypePtr& type = declaration.type;
      const bool has_initializer =
          declaration.init != nullptr || !declaration.init_list.empty() ||
          declaration.has_brace_init;
      if (!has_initializer) {
        emit("  .section .bss");
        emit_alignment(type->align);
        if (!global->is_static && !global->is_extern) {
          emit("  .globl " + declaration.name);
        }
        emit(declaration.name + ":");
        emit("  .zero " + std::to_string(type->size));
        continue;
      }

      emit("  .section .data");
      emit_alignment(type->align);
      if (!global->is_static && !global->is_extern) {
        emit("  .globl " + declaration.name);
      }
      emit(declaration.name + ":");

      if (type->kind == TypeKind::Array) {
        if (declaration.init != nullptr) {
          if (declaration.init->kind != ExprKind::String ||
              type->base->kind != TypeKind::Char) {
            throw Error("unsupported array initializer");
          }
          emit_string_array(*declaration.init, type);
        } else {
          emit_array_initializer(declaration, type);
        }
        continue;
      }

      if (declaration.init == nullptr) {
        emit("  .zero " + std::to_string(type->size));
        continue;
      }
      const std::string value = static_expression(*declaration.init);
      emit_value(type, value);
    }
  }

  void emit_alignment(std::size_t alignment) {
    std::size_t exponent = 0;
    std::size_t value = 1;
    while (value < alignment) {
      value *= 2;
      ++exponent;
    }
    emit("  .p2align " + std::to_string(exponent));
  }

  void emit_value(const TypePtr& type, const std::string& value) {
    switch (type->kind) {
      case TypeKind::Char:
        emit("  .byte " + value);
        return;
      case TypeKind::Short:
        emit("  .half " + value);
        return;
      case TypeKind::Int:
      case TypeKind::Long:
      case TypeKind::Pointer:
        emit("  .word " + value);
        return;
      default:
        break;
    }
    throw Error("unsupported global initializer type");
  }

  void emit_string_array(const Expr& string, const TypePtr& type) {
    std::size_t written = 0;
    // The string bytes live in Program::strings under the literal label.
    const StringLiteral* literal = nullptr;
    for (const StringLiteral& candidate : program_.strings) {
      if (candidate.label == string.name) {
        literal = &candidate;
        break;
      }
    }
    if (literal == nullptr) {
      throw Error("internal error: missing string literal");
    }
    for (const char character : literal->bytes) {
      if (written >= type->length) {
        throw Error("initializer string is too long");
      }
      const auto byte = static_cast<unsigned char>(character);
      emit("  .byte " + std::to_string(static_cast<unsigned int>(byte)));
      ++written;
    }
    while (written < type->length) {
      emit("  .byte 0");
      ++written;
    }
  }

  void emit_array_initializer(const Decl& declaration, const TypePtr& type) {
    std::size_t written = 0;
    for (const auto& element : declaration.init_list) {
      if (written >= type->length) {
        throw Error("too many array initializers");
      }
      emit_value(type->base, static_expression(*element));
      ++written;
    }
    while (written < type->length) {
      const std::string zero = "0";
      emit_value(type->base, zero);
      ++written;
    }
  }

  Program program_;
  CompilerOptions options_;
  std::ostringstream output_;
  std::unordered_set<Function*> reachable_;
  std::vector<TempValue> temp_stack_;
  std::uint64_t label_counter_ = 0;
  std::string return_label_;
  std::vector<std::string> break_labels_;
  std::vector<std::string> continue_labels_;
};


}  // namespace roco::cc
