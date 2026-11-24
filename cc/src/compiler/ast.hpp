#pragma once

/// @file ast.hpp
/// @brief Declarations, statements, expressions, and translation-unit model.

#include "compiler/types.hpp"
#include "compiler/token.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace roco::cc {

// ---------------------------------------------------------------- AST

struct Decl;
struct Function;
struct GlobalVar;
struct Expr;
struct Stmt;

using ExprPtr = std::unique_ptr<Expr>;
using StmtPtr = std::unique_ptr<Stmt>;

enum class ExprKind {
  Int,
  String,
  Var,
  Unary,
  Binary,
  Assign,
  Conditional,
  Call,
  Index,
  Cast,
};

enum class UnaryOp {
  Plus,
  Negate,
  Not,
  BitNot,
  Dereference,
  Address,
  PreIncrement,
  PreDecrement,
  PostIncrement,
  PostDecrement,
};

enum class BinaryOp {
  Add,
  Sub,
  Mul,
  Div,
  Mod,
  Shl,
  Shr,
  Lt,
  Le,
  Gt,
  Ge,
  Eq,
  Ne,
  BitAnd,
  BitOr,
  BitXor,
  LogAnd,
  LogOr,
  Comma,
};

struct Expr {
  ExprKind kind = ExprKind::Int;
  TypePtr type;
  Token token;
  bool lvalue = false;
  std::int64_t value = 0;
  std::string name;
  Decl* local = nullptr;
  GlobalVar* global = nullptr;
  Function* function = nullptr;
  UnaryOp unary = UnaryOp::Plus;
  BinaryOp binary = BinaryOp::Add;
  bool compound = false;
  ExprPtr lhs;
  ExprPtr rhs;
  ExprPtr third;
  std::vector<ExprPtr> args;
};

struct Decl {
  std::string name;
  TypePtr type;
  Token token;
  bool is_static = false;
  bool is_extern = false;
  bool is_volatile = false;
  bool has_brace_init = false;
  ExprPtr init;
  std::vector<ExprPtr> init_list;
  int offset = 0;
};

struct GlobalVar {
  std::unique_ptr<Decl> decl;
  bool defined = false;
  bool is_static = false;
  bool is_extern = false;
};

enum class StmtKind {
  Empty,
  Expression,
  Return,
  Block,
  If,
  While,
  DoWhile,
  For,
  Break,
  Continue,
  Declaration,
};

struct Stmt {
  StmtKind kind = StmtKind::Empty;
  Token token;
  ExprPtr expr;
  ExprPtr inc;
  StmtPtr then_stmt;
  StmtPtr else_stmt;
  StmtPtr body;
  StmtPtr init;
  std::vector<StmtPtr> statements;
  std::vector<std::unique_ptr<Decl>> declarations;
};

struct Function {
  std::string name;
  TypePtr type;
  Token token;
  bool is_static = false;
  bool defined = false;
  std::vector<std::unique_ptr<Decl>> params;
  StmtPtr body;
  std::vector<Decl*> locals;
  int local_area = 0;
  int frame_size = 0;
};

struct StringLiteral {
  std::string label;
  std::string bytes;
};

struct Program {
  std::vector<std::unique_ptr<GlobalVar>> globals;
  std::vector<std::unique_ptr<Function>> functions;
  std::vector<StringLiteral> strings;
};


}  // namespace roco::cc
