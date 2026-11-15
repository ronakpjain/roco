#pragma once

/// @file codegen.hpp
/// @brief Stack-machine RV32 assembly generation for the supported C subset.

#include "compiler/ast.hpp"
#include "compiler/types.hpp"

#include "roco/diagnostic.hpp"

#include <cctype>
#include <cstddef>
#include <cstdint>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace roco::cc {

// ---------------------------------------------------------------- Codegen

class Codegen {
 public:
  explicit Codegen(Program program) : program_(std::move(program)) {}

  std::string generate() {
    emit(".section .text");
    for (const auto& function : program_.functions) {
      if (function->defined) {
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

  void push_a0() {
    emit("  addi s1, s1, -4");
    emit("  sw a0, 0(s1)");
    ++temp_depth_;
    if (temp_depth_ > 256) {
      throw Error("expression is too deeply nested for the compiler frame");
    }
  }

  void pop_to(const std::string& reg) {
    emit("  lw " + reg + ", 0(s1)");
    emit("  addi s1, s1, 4");
    --temp_depth_;
  }

  void generate_function(const Function& function) {
    temp_depth_ = 0;
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
             "roco-cc currently supports at most eight parameters");
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
    if (temp_depth_ != 0) {
      throw Error("internal error: unbalanced compiler expression stack");
    }
  }

  void generate_statement(const Stmt& statement, const Function& function) {
    switch (statement.kind) {
      case StmtKind::Empty:
        return;
      case StmtKind::Expression:
        generate_expression(*statement.expr, function);
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
        const std::string else_label = new_label();
        const std::string end_label = new_label();
        generate_expression(*statement.expr, function);
        emit("  beqz a0, " + (statement.else_stmt ? else_label : end_label));
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
        const std::string start = new_label();
        const std::string end = new_label();
        break_labels_.push_back(end);
        continue_labels_.push_back(start);
        emit(start + ":");
        generate_expression(*statement.expr, function);
        emit("  beqz a0, " + end);
        generate_statement(*statement.body, function);
        emit("  j " + start);
        emit(end + ":");
        continue_labels_.pop_back();
        break_labels_.pop_back();
        return;
      }
      case StmtKind::DoWhile: {
        const std::string start = new_label();
        const std::string condition = new_label();
        const std::string end = new_label();
        break_labels_.push_back(end);
        continue_labels_.push_back(condition);
        emit(start + ":");
        generate_statement(*statement.body, function);
        emit(condition + ":");
        generate_expression(*statement.expr, function);
        emit("  bnez a0, " + start);
        emit(end + ":");
        continue_labels_.pop_back();
        break_labels_.pop_back();
        return;
      }
      case StmtKind::For: {
        const std::string start = new_label();
        const std::string increment = new_label();
        const std::string end = new_label();
        break_labels_.push_back(end);
        continue_labels_.push_back(increment);
        if (statement.init) {
          generate_statement(*statement.init, function);
        }
        emit(start + ":");
        if (statement.expr) {
          generate_expression(*statement.expr, function);
          emit("  beqz a0, " + end);
        }
        generate_statement(*statement.body, function);
        emit(increment + ":");
        if (statement.inc) {
          generate_expression(*statement.inc, function);
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

  void generate_expression(const Expr& expression, const Function& function) {
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
        generate_address(expression, function);
        if (object_type->kind != TypeKind::Array) {
          load(expression.type);
        }
        return;
      }
      case ExprKind::Unary:
        generate_unary(expression, function);
        return;
      case ExprKind::Binary:
        generate_binary(expression, function);
        return;
      case ExprKind::Assign:
        generate_assignment(expression, function);
        return;
      case ExprKind::Conditional: {
        const std::string else_label = new_label();
        const std::string end_label = new_label();
        generate_expression(*expression.lhs, function);
        emit("  beqz a0, " + else_label);
        generate_expression(*expression.rhs, function);
        emit("  j " + end_label);
        emit(else_label + ":");
        generate_expression(*expression.third, function);
        emit(end_label + ":");
        return;
      }
      case ExprKind::Call:
        generate_call(expression, function);
        return;
      case ExprKind::Index:
        generate_address(expression, function);
        load(expression.type);
        return;
      case ExprKind::Cast:
        generate_expression(*expression.lhs, function);
        convert_value(expression.type);
        return;
    }
  }

  void generate_unary(const Expr& expression, const Function& function) {
    switch (expression.unary) {
      case UnaryOp::Plus:
        generate_expression(*expression.lhs, function);
        return;
      case UnaryOp::Negate:
        generate_expression(*expression.lhs, function);
        emit("  neg a0, a0");
        return;
      case UnaryOp::Not:
        generate_expression(*expression.lhs, function);
        emit("  seqz a0, a0");
        return;
      case UnaryOp::BitNot:
        generate_expression(*expression.lhs, function);
        emit("  not a0, a0");
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
        generate_increment(expression, function);
        return;
    }
  }

  void generate_increment(const Expr& expression, const Function& function) {
    generate_address(*expression.lhs, function);
    push_a0();
    load(expression.lhs->type);
    emit("  mv a2, a0");
    const bool increment = expression.unary == UnaryOp::PreIncrement ||
                           expression.unary == UnaryOp::PostIncrement;
    const std::int64_t delta = increment ? 1 : -1;
    if (is_pointer(expression.type)) {
      const std::int64_t step =
          static_cast<std::int64_t>(expression.type->base->size) * delta;
      emit("  li a1, " + std::to_string(step));
      emit("  add a0, a0, a1");
    } else {
      emit("  addi a0, a0, " + std::to_string(delta));
    }
    pop_to("a1");
    store(expression.lhs->type);
    convert_value(expression.lhs->type);
    if (expression.unary == UnaryOp::PostIncrement ||
        expression.unary == UnaryOp::PostDecrement) {
      emit("  mv a0, a2");
    }
  }

  void generate_assignment(const Expr& expression, const Function& function) {
    if (!expression.compound) {
      generate_address(*expression.lhs, function);
      push_a0();
      generate_expression(*expression.rhs, function);
      pop_to("a1");
      store(expression.lhs->type);
      convert_value(expression.lhs->type);
      return;
    }

    generate_address(*expression.lhs, function);
    push_a0();
    load(expression.lhs->type);
    push_a0();
    generate_expression(*expression.rhs, function);
    if (is_pointer(expression.lhs->type) &&
        is_integer(expression.rhs->type)) {
      const std::size_t scale = expression.lhs->type->base->size;
      if (scale > 1) {
        emit("  li a1, " + std::to_string(scale));
        emit("  mul a0, a0, a1");
      }
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
    convert_value(expression.lhs->type);
  }

  void generate_binary(const Expr& expression, const Function& function) {
    if (expression.binary == BinaryOp::LogAnd ||
        expression.binary == BinaryOp::LogOr) {
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
      generate_expression(*expression.lhs, function);
      generate_expression(*expression.rhs, function);
      return;
    }

    generate_expression(*expression.lhs, function);
    push_a0();
    generate_expression(*expression.rhs, function);

    const TypePtr left_type = expression.lhs->type;
    const TypePtr right_type = expression.rhs->type;
    const bool pointer_arith =
        (expression.binary == BinaryOp::Add ||
         expression.binary == BinaryOp::Sub) &&
        is_pointer(left_type);
    if (pointer_arith && is_integer(right_type)) {
      const std::size_t scale = left_type->base->size;
      if (scale > 1) {
        emit("  li a1, " + std::to_string(scale));
        emit("  mul a0, a0, a1");
      }
    }
    pop_to("a1");
    if (expression.binary == BinaryOp::Sub && is_pointer(left_type) &&
        is_pointer(right_type)) {
      emit("  sub a0, a1, a0");
      const std::size_t scale = left_type->base->size;
      if (scale > 1) {
        emit("  li a1, " + std::to_string(scale));
        emit("  div a0, a0, a1");
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
           "roco-cc currently supports at most eight call arguments");
    }
    for (const auto& argument : expression.args) {
      generate_expression(*argument, function);
      push_a0();
    }
    static const std::vector<std::string> arg_registers = {
        "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7"};
    for (std::size_t i = expression.args.size(); i > 0; --i) {
      pop_to(arg_registers[i - 1]);
    }
    emit("  call " + expression.function->name);
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
        generate_expression(*expression.lhs, function);
        push_a0();
        generate_expression(*expression.rhs, function);
        const std::size_t scale = expression.type->size;
        if (scale > 1) {
          emit("  li a1, " + std::to_string(scale));
          emit("  mul a0, a0, a1");
        }
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
    emit("  .align " + std::to_string(exponent));
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
  std::ostringstream output_;
  std::uint64_t label_counter_ = 0;
  std::string return_label_;
  int temp_depth_ = 0;
  std::vector<std::string> break_labels_;
  std::vector<std::string> continue_labels_;
};


}  // namespace roco::cc
