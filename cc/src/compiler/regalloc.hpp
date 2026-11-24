#pragma once

/// @file regalloc.hpp
/// @brief Local scalar register allocation for the roco backend.

#include "compiler/ast.hpp"
#include "compiler/types.hpp"

#include "roco/target.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace roco::cc {

/// Number of callee-saved registers available for local variables.
inline constexpr int kLocalRegisterCount = 10;

/** @brief Mapping from local declarations to callee-saved registers.
 *
 * Slots 0 through 9 name `s2` through `s11`. A declaration without a slot
 * stays in its stack frame slot.
 */
struct LocalRegisterPlan {
  std::unordered_map<const Decl*, int> slots;
  int used = 0;

  int slot_for(const Decl* declaration) const {
    const auto found = slots.find(declaration);
    return found == slots.end() ? -1 : found->second;
  }

  static std::string register_name(int slot) {
    return "s" + std::to_string(slot + 2);
  }
};

namespace detail {

struct LocalRegisterUse {
  std::int64_t reads = 0;
  std::int64_t writes = 0;
  bool address_taken = false;
};

/// Count local accesses, weighting loop bodies more heavily than straight-line
/// code. The result feeds a static profitability estimate, not a full liveness
/// analysis: every selected local keeps its register for the whole function.
class LocalRegisterUseCollector {
 public:
  explicit LocalRegisterUseCollector(const Function& function)
      : function_(function) {
    for (const Decl* declaration : function.locals) {
      uses_[declaration] = LocalRegisterUse{};
    }
  }

  void run() {
    if (function_.body) {
      visit_statement(*function_.body, 0);
    }
  }

  const LocalRegisterUse& use_of(const Decl* declaration) const {
    static const LocalRegisterUse empty{};
    const auto found = uses_.find(declaration);
    return found == uses_.end() ? empty : found->second;
  }

 private:
  static std::int64_t access_weight(int loop_depth) {
    if (loop_depth <= 0) {
      return 1;
    }
    const int shift = std::min(loop_depth - 1, 4);
    return std::int64_t{8} << shift;
  }

  void touch(const Expr& expression, bool read, bool write, int loop_depth) {
    if (expression.local == nullptr) {
      return;
    }
    const auto found = uses_.find(expression.local);
    if (found == uses_.end()) {
      return;
    }
    const std::int64_t weight = access_weight(loop_depth);
    if (read) {
      found->second.reads += weight;
    }
    if (write) {
      found->second.writes += weight;
    }
  }

  void visit_lvalue(const Expr& expression, bool read, bool write,
                    int loop_depth) {
    if (expression.kind == ExprKind::Var) {
      touch(expression, read, write, loop_depth);
      return;
    }
    if (expression.kind == ExprKind::Unary &&
        expression.unary == UnaryOp::Dereference) {
      visit_expression(*expression.lhs, loop_depth);
      return;
    }
    if (expression.kind == ExprKind::Index) {
      visit_expression(*expression.lhs, loop_depth);
      visit_expression(*expression.rhs, loop_depth);
      return;
    }
    visit_expression(expression, loop_depth);
  }

  void visit_address(const Expr& expression, int loop_depth) {
    const Expr& target = *expression.lhs;
    if (target.kind == ExprKind::Var && target.local != nullptr) {
      const auto found = uses_.find(target.local);
      if (found != uses_.end()) {
        found->second.address_taken = true;
      }
    }
    visit_lvalue(target, false, false, loop_depth);
  }

  void visit_expression(const Expr& expression, int loop_depth) {
    switch (expression.kind) {
      case ExprKind::Int:
      case ExprKind::String:
        return;
      case ExprKind::Var:
        touch(expression, true, false, loop_depth);
        return;
      case ExprKind::Unary:
        if (expression.unary == UnaryOp::Address) {
          visit_address(expression, loop_depth);
          return;
        }
        if (expression.unary == UnaryOp::PreIncrement ||
            expression.unary == UnaryOp::PreDecrement ||
            expression.unary == UnaryOp::PostIncrement ||
            expression.unary == UnaryOp::PostDecrement) {
          visit_lvalue(*expression.lhs, true, true, loop_depth);
          return;
        }
        visit_expression(*expression.lhs, loop_depth);
        return;
      case ExprKind::Binary:
        visit_expression(*expression.lhs, loop_depth);
        visit_expression(*expression.rhs, loop_depth);
        return;
      case ExprKind::Assign:
        visit_lvalue(*expression.lhs, expression.compound, true, loop_depth);
        visit_expression(*expression.rhs, loop_depth);
        return;
      case ExprKind::Conditional:
        visit_expression(*expression.lhs, loop_depth);
        visit_expression(*expression.rhs, loop_depth);
        visit_expression(*expression.third, loop_depth);
        return;
      case ExprKind::Call:
        for (const auto& argument : expression.args) {
          visit_expression(*argument, loop_depth);
        }
        return;
      case ExprKind::Index:
        visit_expression(*expression.lhs, loop_depth);
        visit_expression(*expression.rhs, loop_depth);
        return;
      case ExprKind::Cast:
        visit_expression(*expression.lhs, loop_depth);
        return;
    }
  }

  void visit_statement(const Stmt& statement, int loop_depth) {
    switch (statement.kind) {
      case StmtKind::Empty:
      case StmtKind::Break:
      case StmtKind::Continue:
        return;
      case StmtKind::Expression:
        visit_expression(*statement.expr, loop_depth);
        return;
      case StmtKind::Return:
        if (statement.expr) {
          visit_expression(*statement.expr, loop_depth);
        }
        return;
      case StmtKind::Block:
        for (const auto& child : statement.statements) {
          visit_statement(*child, loop_depth);
        }
        return;
      case StmtKind::If:
        visit_expression(*statement.expr, loop_depth);
        visit_statement(*statement.then_stmt, loop_depth);
        if (statement.else_stmt) {
          visit_statement(*statement.else_stmt, loop_depth);
        }
        return;
      case StmtKind::While:
        visit_expression(*statement.expr, loop_depth + 1);
        visit_statement(*statement.body, loop_depth + 1);
        return;
      case StmtKind::DoWhile:
        visit_statement(*statement.body, loop_depth + 1);
        visit_expression(*statement.expr, loop_depth + 1);
        return;
      case StmtKind::For:
        if (statement.init) {
          visit_statement(*statement.init, loop_depth);
        }
        if (statement.expr) {
          visit_expression(*statement.expr, loop_depth + 1);
        }
        visit_statement(*statement.body, loop_depth + 1);
        if (statement.inc) {
          visit_expression(*statement.inc, loop_depth + 1);
        }
        return;
      case StmtKind::Declaration:
        for (const auto& declaration : statement.declarations) {
          if (declaration->init) {
            visit_expression(*declaration->init, loop_depth);
          }
        }
        return;
    }
  }

  const Function& function_;
  std::unordered_map<const Decl*, LocalRegisterUse> uses_;
};

}  // namespace detail

/** @brief Choose stack or register storage for each local in a function.
 *
 * Arrays and address-taken locals must stay in memory. Other scalars are
 * ranked by estimated cycle savings: each read avoids the difference between
 * the load latency and an ALU move, weighted by loop nesting, while the
 * function pays one store and one load to preserve the register.
 */
inline LocalRegisterPlan allocate_local_registers(const Function& function,
                                                  const CostModel& costs) {
  LocalRegisterPlan plan;
  detail::LocalRegisterUseCollector collector(function);
  collector.run();

  const std::int64_t read_saving =
      std::max(0, costs.load - costs.arithmetic);
  const std::int64_t write_saving =
      std::max(0, costs.store - costs.arithmetic);
  const std::int64_t overhead = 2 * std::max(1, costs.issue);

  struct Candidate {
    const Decl* declaration = nullptr;
    std::int64_t score = 0;
    std::int64_t accesses = 0;
  };
  std::vector<Candidate> candidates;
  for (const Decl* declaration : function.locals) {
    if (declaration == nullptr || declaration->type == nullptr ||
        declaration->type->kind == TypeKind::Array ||
        declaration->is_volatile) {
      continue;
    }
    const detail::LocalRegisterUse& use = collector.use_of(declaration);
    if (use.address_taken) {
      continue;
    }
    const std::int64_t benefit =
        use.reads * read_saving + use.writes * write_saving;
    const std::int64_t score = benefit - overhead;
    if (score > 0) {
      candidates.push_back(
          Candidate{declaration, score, use.reads + use.writes});
    }
  }
  std::stable_sort(candidates.begin(), candidates.end(),
                   [](const Candidate& left, const Candidate& right) {
                     if (left.score != right.score) {
                       return left.score > right.score;
                     }
                     return left.accesses > right.accesses;
                   });
  const std::size_t count = std::min<std::size_t>(
      candidates.size(), kLocalRegisterCount);
  for (std::size_t index = 0; index < count; ++index) {
    plan.slots.emplace(candidates[index].declaration,
                       static_cast<int>(index));
  }
  plan.used = static_cast<int>(count);
  return plan;
}

}  // namespace roco::cc
