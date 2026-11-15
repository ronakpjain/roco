#pragma once

/// @file parser.hpp
/// @brief Recursive-descent parser and semantic checks for the C subset.

#include "compiler/ast.hpp"
#include "compiler/lexer.hpp"
#include "compiler/types.hpp"

#include "roco/diagnostic.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace roco::cc {

// ---------------------------------------------------------------- Parser

struct Declarator {
  std::string name;
  Token token;
  TypePtr type;
  bool is_function = false;
  std::vector<std::unique_ptr<Decl>> params;
  bool variadic = false;
};

class Parser {
 public:
  Parser(std::string_view source, std::string filename)
      : filename_(std::move(filename)),
        tokens_(Lexer(source, filename_).tokenize()) {}

  Program parse() {
    while (!at_end()) {
      parse_external_declaration();
    }
    for (auto& function : program_.functions) {
      if (function->defined) {
        assign_frame(function.get());
      }
    }
    return std::move(program_);
  }

 private:
  [[noreturn]] void fail(const Token& token, const std::string& message) const {
    throw Error(filename_ + ":" + std::to_string(token.line) + ":" +
                std::to_string(token.column) + ": " + message);
  }

  [[noreturn]] void fail(const std::string& message) const {
    fail(peek(), message);
  }

  const Token& peek(std::size_t lookahead = 0) const {
    const std::size_t index = position_ + lookahead;
    if (index >= tokens_.size()) {
      return tokens_.back();
    }
    return tokens_[index];
  }

  const Token& advance() {
    const Token& token = peek();
    if (position_ + 1 < tokens_.size()) {
      ++position_;
    }
    return token;
  }

  bool at_end() const { return peek().kind == TokenKind::End; }

  bool is_punct(std::string_view text, std::size_t lookahead = 0) const {
    const Token& token = peek(lookahead);
    return token.kind == TokenKind::Punct && token.text == text;
  }

  bool consume_punct(std::string_view text) {
    if (!is_punct(text)) {
      return false;
    }
    advance();
    return true;
  }

  void expect_punct(std::string_view text) {
    if (!consume_punct(text)) {
      fail("expected '" + std::string(text) + "'");
    }
  }

  bool is_keyword(std::string_view text, std::size_t lookahead = 0) const {
    const Token& token = peek(lookahead);
    return token.kind == TokenKind::Keyword && token.text == text;
  }

  bool consume_keyword(std::string_view text) {
    if (!is_keyword(text)) {
      return false;
    }
    advance();
    return true;
  }

  std::string expect_identifier() {
    if (peek().kind != TokenKind::Identifier) {
      fail("expected an identifier");
    }
    return advance().text;
  }

  bool is_declaration_start() const {
    if (peek().kind != TokenKind::Keyword) {
      return false;
    }
    static const std::unordered_set<std::string> starters = {
        "void",   "char",   "short",  "int",     "long",
        "signed", "unsigned", "const", "volatile", "static",
        "extern", "register", "typedef", "struct", "union",
        "enum",   "_Bool",
    };
    return starters.count(peek().text) != 0;
  }

  void parse_external_declaration() {
    bool is_static = false;
    bool is_extern = false;
    while (true) {
      if (consume_keyword("static")) {
        is_static = true;
        continue;
      }
      if (consume_keyword("extern")) {
        is_extern = true;
        continue;
      }
      if (consume_keyword("inline") || consume_keyword("register")) {
        continue;
      }
      break;
    }
    if (consume_punct(";")) {
      return;
    }
    const TypePtr base = parse_declspec();
    if (consume_punct(";")) {
      return;
    }
    Declarator first = parse_declarator(base, true, false);
    if (first.is_function) {
      parse_function_declaration(std::move(first), is_static, is_extern);
      return;
    }
    parse_global_variable(std::move(first), is_static, is_extern);
  }

  TypePtr parse_declspec() {
    bool is_unsigned = false;
    bool is_signed = false;
    bool saw_char = false;
    bool saw_short = false;
    bool saw_int = false;
    bool saw_long = false;
    bool saw_void = false;
    bool saw_other = false;

    while (true) {
      if (consume_keyword("const") || consume_keyword("volatile") ||
          consume_keyword("restrict")) {
        continue;
      }
      if (consume_keyword("unsigned")) {
        is_unsigned = true;
        continue;
      }
      if (consume_keyword("signed")) {
        is_signed = true;
        continue;
      }
      if (consume_keyword("void")) {
        saw_void = true;
        continue;
      }
      if (consume_keyword("char")) {
        saw_char = true;
        continue;
      }
      if (consume_keyword("short")) {
        saw_short = true;
        continue;
      }
      if (consume_keyword("int")) {
        saw_int = true;
        continue;
      }
      if (consume_keyword("long")) {
        saw_long = true;
        continue;
      }
      if (is_keyword("struct") || is_keyword("union") || is_keyword("enum") ||
          is_keyword("_Bool") || is_keyword("float") || is_keyword("double")) {
        fail("this C type is not supported yet");
      }
      break;
    }

    int base_count = 0;
    base_count += saw_void ? 1 : 0;
    base_count += saw_char ? 1 : 0;
    base_count += saw_short ? 1 : 0;
    base_count += saw_int ? 1 : 0;
    base_count += saw_long ? 1 : 0;
    base_count += saw_other ? 1 : 0;
    if (base_count == 0) {
      if (is_unsigned || is_signed) {
        return is_unsigned ? type_uint() : type_int();
      }
      fail("expected a type specifier");
    }
    if (base_count > 1) {
      if (saw_long && saw_int) {
        return is_unsigned ? type_long(true) : type_long(false);
      }
      fail("conflicting type specifiers");
    }
    if (saw_void) {
      return type_void();
    }
    if (saw_char) {
      return type_char(is_unsigned);
    }
    if (saw_short) {
      return type_short(is_unsigned);
    }
    if (saw_long) {
      return type_long(is_unsigned);
    }
    return is_unsigned ? type_uint() : type_int();
  }

  Declarator parse_declarator(TypePtr base, bool allow_function,
                              bool allow_abstract) {
    while (true) {
      if (!consume_punct("*")) {
        break;
      }
      while (consume_keyword("const") || consume_keyword("volatile") ||
             consume_keyword("restrict")) {
      }
      base = pointer_to(base);
    }

    if (is_punct("(")) {
      fail("parenthesized declarators and function pointers are not supported");
    }

    Declarator result;
    result.token = peek();
    if (peek().kind == TokenKind::Identifier) {
      result.name = advance().text;
    } else if (!allow_abstract) {
      fail("expected a declarator name");
    }

    if (allow_function && consume_punct("(")) {
      result.is_function = true;
      bool variadic = false;
      std::vector<std::unique_ptr<Decl>> params;
      if (!is_punct(")")) {
        if (is_keyword("void") && is_punct(")", 1)) {
          advance();
        } else {
          while (true) {
            if (consume_punct("...")) {
              variadic = true;
              break;
            }
            const TypePtr parameter_base = parse_declspec();
            Declarator parameter =
                parse_declarator(parameter_base, false, true);
            TypePtr parameter_type = parameter.type;
            if (parameter_type->kind == TypeKind::Array) {
              parameter_type = pointer_to(parameter_type->base);
            }
            auto declaration = std::make_unique<Decl>();
            declaration->name = parameter.name;
            declaration->type = parameter_type;
            declaration->token = parameter.token;
            params.push_back(std::move(declaration));
            if (!consume_punct(",")) {
              break;
            }
          }
        }
      }
      expect_punct(")");
      std::vector<TypePtr> parameter_types;
      parameter_types.reserve(params.size());
      for (const auto& parameter : params) {
        parameter_types.push_back(parameter->type);
      }
      result.params = std::move(params);
      result.variadic = variadic;
      result.type = function_of(base, std::move(parameter_types), variadic);
      return result;
    }

    std::vector<std::size_t> dimensions;
    while (consume_punct("[")) {
      if (consume_punct("]")) {
        dimensions.push_back(0);
        continue;
      }
      ExprPtr expression = parse_assignment();
      std::int64_t length = 0;
      if (!evaluate_constant(expression.get(), length) || length < 0) {
        fail(expression->token, "array length must be a non-negative constant");
      }
      dimensions.push_back(static_cast<std::size_t>(length));
      expect_punct("]");
    }
    for (auto it = dimensions.rbegin(); it != dimensions.rend(); ++it) {
      base = array_of(base, *it);
    }
    result.type = base;
    return result;
  }

  void parse_function_declaration(Declarator declarator, bool is_static,
                                  bool is_extern) {
    (void)is_extern;
    Function* function = nullptr;
    const auto existing = functions_.find(declarator.name);
    if (existing != functions_.end()) {
      function = existing->second;
      if (function->defined && is_punct("{")) {
        fail(declarator.token,
             "duplicate definition of function '" + declarator.name + "'");
      }
      function->type = declarator.type;
    } else {
      auto owned = std::make_unique<Function>();
      owned->name = declarator.name;
      owned->type = declarator.type;
      owned->token = declarator.token;
      owned->is_static = is_static;
      function = owned.get();
      functions_.emplace(declarator.name, function);
      program_.functions.push_back(std::move(owned));
    }
    function->is_static = is_static;
    if (!is_punct("{")) {
      expect_punct(";");
      return;
    }
    function->defined = true;
    function->params = std::move(declarator.params);
    function->locals.clear();
    for (auto& parameter : function->params) {
      if (parameter->name.empty()) {
        fail(parameter->token,
             "function definition parameters must have names");
      }
      function->locals.push_back(parameter.get());
    }
    current_function_ = function;
    scopes_.clear();
    push_scope();
    for (auto& parameter : function->params) {
      declare_local(parameter.get());
    }
    function->body = parse_compound_statement();
    pop_scope();
    current_function_ = nullptr;
  }

  void parse_global_variable(Declarator first, bool is_static,
                             bool is_extern) {
    Declarator declarator = std::move(first);
    while (true) {
      if (declarator.type->kind == TypeKind::Function) {
        fail(declarator.token, "functions cannot be declared as variables");
      }
      auto declaration = std::make_unique<Decl>();
      declaration->name = declarator.name;
      declaration->type = declarator.type;
      declaration->token = declarator.token;
      declaration->is_static = is_static;
      declaration->is_extern = is_extern;

      if (consume_punct("=")) {
        parse_initializer(*declaration);
        if (declaration->type->kind == TypeKind::Array &&
            declaration->type->length == 0) {
          if (!declaration->init ||
              declaration->init->kind != ExprKind::String) {
            fail(declaration->token,
                 "unsized arrays need a string or brace initializer");
          }
          const std::size_t length = declaration->init->name.size() + 1;
          declaration->type = array_of(declaration->type->base, length);
        }
      }
      if (declaration->type->kind == TypeKind::Array &&
          declaration->type->length == 0) {
        fail(declaration->token, "array has no size");
      }

      const auto existing = globals_.find(declaration->name);
      GlobalVar* variable = nullptr;
      if (existing != globals_.end()) {
        variable = existing->second;
        if (variable->defined && !is_extern) {
          fail(declaration->token,
               "duplicate definition of variable '" + declaration->name + "'");
        }
        variable->decl = std::move(declaration);
        variable->defined = variable->defined || !is_extern;
      } else {
        auto owned = std::make_unique<GlobalVar>();
        owned->decl = std::move(declaration);
        owned->defined = !is_extern;
        owned->is_static = is_static;
        owned->is_extern = is_extern;
        variable = owned.get();
        globals_.emplace(variable->decl->name, variable);
        program_.globals.push_back(std::move(owned));
      }
      variable->is_static = is_static || variable->is_static;
      variable->is_extern = is_extern || variable->is_extern;

      if (!consume_punct(",")) {
        break;
      }
      declarator = parse_declarator(parse_declspec(), true, false);
    }
    expect_punct(";");
  }

  void parse_initializer(Decl& declaration) {
    if (consume_punct("{")) {
      declaration.has_brace_init = true;
      if (!is_punct("}")) {
        while (true) {
          declaration.init_list.push_back(parse_assignment());
          if (!consume_punct(",")) {
            break;
          }
          if (is_punct("}")) {
            break;
          }
        }
      }
      expect_punct("}");
      if (declaration.type->kind == TypeKind::Array &&
          declaration.type->length == 0) {
        declaration.type =
            array_of(declaration.type->base, declaration.init_list.size());
      }
      return;
    }
    if (peek().kind == TokenKind::String &&
        declaration.type->kind == TypeKind::Array &&
        declaration.type->base->kind == TypeKind::Char) {
      ExprPtr string = parse_primary();
      declaration.init = std::move(string);
      if (declaration.type->length == 0) {
        declaration.type = array_of(declaration.type->base,
                                    declaration.init->name.size() + 1);
      }
      return;
    }
    declaration.init = parse_assignment();
  }

  StmtPtr parse_statement() {
    if (is_punct("{")) {
      return parse_compound_statement();
    }
    if (consume_keyword("return")) {
      auto statement = std::make_unique<Stmt>();
      statement->kind = StmtKind::Return;
      statement->token = peek();
      if (!consume_punct(";")) {
        statement->expr = parse_expression();
        expect_punct(";");
      }
      return statement;
    }
    if (consume_keyword("if")) {
      auto statement = std::make_unique<Stmt>();
      statement->kind = StmtKind::If;
      statement->token = peek();
      expect_punct("(");
      statement->expr = parse_expression();
      expect_punct(")");
      statement->then_stmt = parse_statement();
      if (consume_keyword("else")) {
        statement->else_stmt = parse_statement();
      }
      return statement;
    }
    if (consume_keyword("while")) {
      auto statement = std::make_unique<Stmt>();
      statement->kind = StmtKind::While;
      statement->token = peek();
      expect_punct("(");
      statement->expr = parse_expression();
      expect_punct(")");
      statement->body = parse_statement();
      return statement;
    }
    if (consume_keyword("do")) {
      auto statement = std::make_unique<Stmt>();
      statement->kind = StmtKind::DoWhile;
      statement->token = peek();
      statement->body = parse_statement();
      if (!consume_keyword("while")) {
        fail("expected 'while' after do body");
      }
      expect_punct("(");
      statement->expr = parse_expression();
      expect_punct(")");
      expect_punct(";");
      return statement;
    }
    if (consume_keyword("for")) {
      return parse_for_statement();
    }
    if (consume_keyword("break")) {
      auto statement = std::make_unique<Stmt>();
      statement->kind = StmtKind::Break;
      statement->token = peek();
      expect_punct(";");
      return statement;
    }
    if (consume_keyword("continue")) {
      auto statement = std::make_unique<Stmt>();
      statement->kind = StmtKind::Continue;
      statement->token = peek();
      expect_punct(";");
      return statement;
    }
    if (consume_punct(";")) {
      auto statement = std::make_unique<Stmt>();
      statement->kind = StmtKind::Empty;
      return statement;
    }
    if (is_declaration_start()) {
      return parse_local_declaration();
    }
    auto statement = std::make_unique<Stmt>();
    statement->kind = StmtKind::Expression;
    statement->token = peek();
    statement->expr = parse_expression();
    expect_punct(";");
    return statement;
  }

  StmtPtr parse_compound_statement() {
    expect_punct("{");
    push_scope();
    auto statement = std::make_unique<Stmt>();
    statement->kind = StmtKind::Block;
    statement->token = peek();
    while (!consume_punct("}")) {
      if (at_end()) {
        fail("unterminated compound statement");
      }
      statement->statements.push_back(parse_statement());
    }
    pop_scope();
    return statement;
  }

  StmtPtr parse_for_statement() {
    auto statement = std::make_unique<Stmt>();
    statement->kind = StmtKind::For;
    statement->token = peek();
    expect_punct("(");
    push_scope();
    if (consume_punct(";")) {
      statement->init = nullptr;
    } else if (is_declaration_start()) {
      statement->init = parse_local_declaration();
    } else {
      auto init = std::make_unique<Stmt>();
      init->kind = StmtKind::Expression;
      init->expr = parse_expression();
      expect_punct(";");
      statement->init = std::move(init);
    }
    if (!consume_punct(";")) {
      statement->expr = parse_expression();
      expect_punct(";");
    }
    if (!consume_punct(")")) {
      statement->inc = parse_expression();
      expect_punct(")");
    }
    statement->body = parse_statement();
    pop_scope();
    return statement;
  }

  StmtPtr parse_local_declaration() {
    while (consume_keyword("static")) {
      fail("local static variables are not supported yet");
    }
    while (consume_keyword("extern") || consume_keyword("register")) {
      fail("local storage classes are not supported yet");
    }
    const TypePtr base = parse_declspec();
    auto statement = std::make_unique<Stmt>();
    statement->kind = StmtKind::Declaration;
    statement->token = peek();
    while (true) {
      Declarator declarator = parse_declarator(base, false, false);
      auto declaration = std::make_unique<Decl>();
      declaration->name = declarator.name;
      declaration->type = declarator.type;
      declaration->token = declarator.token;
      if (consume_punct("=")) {
        if (consume_punct("{")) {
          fail(declaration->token,
               "local brace initializers are not supported yet");
        }
        declaration->init = parse_assignment();
      }
      if (declaration->type->kind == TypeKind::Array &&
          declaration->type->length == 0) {
        fail(declaration->token, "local arrays must have a size");
      }
      declare_local(declaration.get());
      current_function_->locals.push_back(declaration.get());
      statement->declarations.push_back(std::move(declaration));
      if (!consume_punct(",")) {
        break;
      }
    }
    expect_punct(";");
    return statement;
  }

  void push_scope() { scopes_.emplace_back(); }

  void pop_scope() { scopes_.pop_back(); }

  void declare_local(Decl* declaration) {
    if (declaration->name.empty()) {
      return;
    }
    scopes_.back()[declaration->name] = declaration;
  }

  Decl* find_local(const std::string& name) {
    for (auto it = scopes_.rbegin(); it != scopes_.rend(); ++it) {
      const auto found = it->find(name);
      if (found != it->end()) {
        return found->second;
      }
    }
    return nullptr;
  }

  GlobalVar* find_global(const std::string& name) {
    const auto found = globals_.find(name);
    return found == globals_.end() ? nullptr : found->second;
  }

  Function* find_function(const std::string& name) {
    const auto found = functions_.find(name);
    return found == functions_.end() ? nullptr : found->second;
  }

  ExprPtr make_int(std::int64_t value, TypePtr type, const Token& token) {
    auto expression = std::make_unique<Expr>();
    expression->kind = ExprKind::Int;
    expression->type = std::move(type);
    expression->value = value;
    expression->token = token;
    return expression;
  }

  ExprPtr parse_expression() {
    ExprPtr left = parse_assignment();
    while (consume_punct(",")) {
      ExprPtr right = parse_assignment();
      auto expression = std::make_unique<Expr>();
      expression->kind = ExprKind::Binary;
      expression->binary = BinaryOp::Comma;
      expression->token = left->token;
      expression->lhs = std::move(left);
      expression->rhs = std::move(right);
      expression->type = expression->rhs->type;
      left = std::move(expression);
    }
    return left;
  }

  ExprPtr parse_assignment() {
    ExprPtr left = parse_conditional();
    static const std::unordered_map<std::string, BinaryOp> compound_ops = {
        {"+=", BinaryOp::Add},  {"-=", BinaryOp::Sub},
        {"*=", BinaryOp::Mul},  {"/=", BinaryOp::Div},
        {"%=", BinaryOp::Mod},  {"&=", BinaryOp::BitAnd},
        {"|=", BinaryOp::BitOr}, {"^=", BinaryOp::BitXor},
        {"<<=", BinaryOp::Shl}, {">>=", BinaryOp::Shr},
    };
    if (consume_punct("=")) {
      if (!left->lvalue) {
        fail(left->token, "assignment requires an lvalue");
      }
      ExprPtr right = parse_assignment();
      right = decay_expression(std::move(right));
      auto expression = std::make_unique<Expr>();
      expression->kind = ExprKind::Assign;
      expression->token = left->token;
      expression->type = left->type;
      expression->lhs = std::move(left);
      expression->rhs = std::move(right);
      return expression;
    }
    if (peek().kind == TokenKind::Punct) {
      const auto operation = compound_ops.find(peek().text);
      if (operation != compound_ops.end()) {
        const Token token = advance();
        if (!left->lvalue) {
          fail(left->token, "compound assignment requires an lvalue");
        }
        ExprPtr right = parse_assignment();
        auto expression = std::make_unique<Expr>();
        expression->kind = ExprKind::Assign;
        expression->token = token;
        expression->type = left->type;
        expression->compound = true;
        expression->binary = operation->second;
        expression->lhs = std::move(left);
        expression->rhs = decay_expression(std::move(right));
        return expression;
      }
    }
    return left;
  }

  ExprPtr parse_conditional() {
    ExprPtr condition = parse_logical_or();
    if (!consume_punct("?")) {
      return condition;
    }
    ExprPtr yes = parse_expression();
    expect_punct(":");
    ExprPtr no = parse_conditional();
    auto expression = std::make_unique<Expr>();
    expression->kind = ExprKind::Conditional;
    expression->token = condition->token;
    expression->lhs = decay_expression(std::move(condition));
    expression->rhs = decay_expression(std::move(yes));
    expression->third = decay_expression(std::move(no));
    expression->type = expression->rhs->type->kind == TypeKind::Void
                           ? expression->third->type
                           : expression->rhs->type;
    return expression;
  }

  ExprPtr parse_logical_or() {
    ExprPtr left = parse_logical_and();
    while (consume_punct("||")) {
      ExprPtr right = parse_logical_and();
      left = make_binary(BinaryOp::LogOr, std::move(left), std::move(right));
    }
    return left;
  }

  ExprPtr parse_logical_and() {
    ExprPtr left = parse_bitwise_or();
    while (consume_punct("&&")) {
      ExprPtr right = parse_bitwise_or();
      left = make_binary(BinaryOp::LogAnd, std::move(left), std::move(right));
    }
    return left;
  }

  ExprPtr parse_bitwise_or() {
    ExprPtr left = parse_bitwise_xor();
    while (consume_punct("|")) {
      ExprPtr right = parse_bitwise_xor();
      left = make_binary(BinaryOp::BitOr, std::move(left), std::move(right));
    }
    return left;
  }

  ExprPtr parse_bitwise_xor() {
    ExprPtr left = parse_bitwise_and();
    while (consume_punct("^")) {
      ExprPtr right = parse_bitwise_and();
      left = make_binary(BinaryOp::BitXor, std::move(left), std::move(right));
    }
    return left;
  }

  ExprPtr parse_bitwise_and() {
    ExprPtr left = parse_equality();
    while (consume_punct("&")) {
      ExprPtr right = parse_equality();
      left = make_binary(BinaryOp::BitAnd, std::move(left), std::move(right));
    }
    return left;
  }

  ExprPtr parse_equality() {
    ExprPtr left = parse_relational();
    while (true) {
      if (consume_punct("==")) {
        left = make_binary(BinaryOp::Eq, std::move(left), parse_relational());
      } else if (consume_punct("!=")) {
        left = make_binary(BinaryOp::Ne, std::move(left), parse_relational());
      } else {
        return left;
      }
    }
  }

  ExprPtr parse_relational() {
    ExprPtr left = parse_shift();
    while (true) {
      if (consume_punct("<")) {
        left = make_binary(BinaryOp::Lt, std::move(left), parse_shift());
      } else if (consume_punct("<=")) {
        left = make_binary(BinaryOp::Le, std::move(left), parse_shift());
      } else if (consume_punct(">")) {
        left = make_binary(BinaryOp::Gt, std::move(left), parse_shift());
      } else if (consume_punct(">=")) {
        left = make_binary(BinaryOp::Ge, std::move(left), parse_shift());
      } else {
        return left;
      }
    }
  }

  ExprPtr parse_shift() {
    ExprPtr left = parse_additive();
    while (true) {
      if (consume_punct("<<")) {
        left = make_binary(BinaryOp::Shl, std::move(left), parse_additive());
      } else if (consume_punct(">>")) {
        left = make_binary(BinaryOp::Shr, std::move(left), parse_additive());
      } else {
        return left;
      }
    }
  }

  ExprPtr parse_additive() {
    ExprPtr left = parse_multiplicative();
    while (true) {
      if (consume_punct("+")) {
        left = make_binary(BinaryOp::Add, std::move(left),
                           parse_multiplicative());
      } else if (consume_punct("-")) {
        left = make_binary(BinaryOp::Sub, std::move(left),
                           parse_multiplicative());
      } else {
        return left;
      }
    }
  }

  ExprPtr parse_multiplicative() {
    ExprPtr left = parse_unary();
    while (true) {
      if (consume_punct("*")) {
        left = make_binary(BinaryOp::Mul, std::move(left), parse_unary());
      } else if (consume_punct("/")) {
        left = make_binary(BinaryOp::Div, std::move(left), parse_unary());
      } else if (consume_punct("%")) {
        left = make_binary(BinaryOp::Mod, std::move(left), parse_unary());
      } else {
        return left;
      }
    }
  }

  ExprPtr parse_unary() {
    if (consume_punct("+")) {
      ExprPtr operand = parse_unary();
      auto expression = std::make_unique<Expr>();
      expression->kind = ExprKind::Unary;
      expression->unary = UnaryOp::Plus;
      expression->token = operand->token;
      expression->type = promote(decay_expression(std::move(operand))->type);
      expression->lhs = std::move(operand);
      return expression;
    }
    if (consume_punct("-")) {
      ExprPtr operand = decay_expression(parse_unary());
      if (!is_integer(operand->type)) {
        fail(operand->token, "unary '-' requires an integer");
      }
      auto expression = std::make_unique<Expr>();
      expression->kind = ExprKind::Unary;
      expression->unary = UnaryOp::Negate;
      expression->token = operand->token;
      expression->type = promote(operand->type);
      expression->lhs = std::move(operand);
      return expression;
    }
    if (consume_punct("!")) {
      ExprPtr operand = decay_expression(parse_unary());
      auto expression = std::make_unique<Expr>();
      expression->kind = ExprKind::Unary;
      expression->unary = UnaryOp::Not;
      expression->token = operand->token;
      expression->type = type_int();
      expression->lhs = std::move(operand);
      return expression;
    }
    if (consume_punct("~")) {
      ExprPtr operand = decay_expression(parse_unary());
      if (!is_integer(operand->type)) {
        fail(operand->token, "unary '~' requires an integer");
      }
      auto expression = std::make_unique<Expr>();
      expression->kind = ExprKind::Unary;
      expression->unary = UnaryOp::BitNot;
      expression->token = operand->token;
      expression->type = promote(operand->type);
      expression->lhs = std::move(operand);
      return expression;
    }
    if (consume_punct("&")) {
      ExprPtr operand = parse_unary();
      if (!operand->lvalue) {
        fail(operand->token, "address-of requires an lvalue");
      }
      auto expression = std::make_unique<Expr>();
      expression->kind = ExprKind::Unary;
      expression->unary = UnaryOp::Address;
      expression->token = operand->token;
      expression->type = pointer_to(operand->type);
      expression->lhs = std::move(operand);
      return expression;
    }
    if (consume_punct("*")) {
      ExprPtr operand = decay_expression(parse_unary());
      if (!is_pointer(operand->type)) {
        fail(operand->token, "dereference requires a pointer");
      }
      auto expression = std::make_unique<Expr>();
      expression->kind = ExprKind::Unary;
      expression->unary = UnaryOp::Dereference;
      expression->token = operand->token;
      expression->type = operand->type->base;
      expression->lvalue = true;
      expression->lhs = std::move(operand);
      return expression;
    }
    if (consume_punct("++")) {
      return parse_increment(true, true);
    }
    if (consume_punct("--")) {
      return parse_increment(true, false);
    }
    if (consume_keyword("sizeof")) {
      const Token token = peek();
      if (is_punct("(") && is_declaration_start(1)) {
        advance();
        const TypePtr type = parse_declspec();
        TypePtr full = parse_declarator(type, false, true).type;
        expect_punct(")");
        return make_int(static_cast<std::int64_t>(full->size), type_uint(),
                        token);
      }
      ExprPtr operand = parse_unary();
      if (operand->type->kind == TypeKind::Void) {
        fail(operand->token, "sizeof void is invalid");
      }
      return make_int(static_cast<std::int64_t>(operand->type->size),
                      type_uint(), token);
    }
    return parse_postfix();
  }

  bool is_declaration_start(std::size_t lookahead) const {
    if (peek(lookahead).kind != TokenKind::Keyword) {
      return false;
    }
    static const std::unordered_set<std::string> starters = {
        "void",   "char",   "short",  "int",     "long",
        "signed", "unsigned", "const", "volatile", "struct",
        "union",  "enum",   "_Bool",
    };
    return starters.count(peek(lookahead).text) != 0;
  }

  ExprPtr parse_increment(bool prefix, bool increment) {
    ExprPtr operand = parse_unary();
    if (!operand->lvalue || !is_scalar(operand->type)) {
      fail(operand->token, "increment requires a scalar lvalue");
    }
    auto expression = std::make_unique<Expr>();
    expression->kind = ExprKind::Unary;
    expression->unary =
        prefix ? (increment ? UnaryOp::PreIncrement : UnaryOp::PreDecrement)
               : (increment ? UnaryOp::PostIncrement : UnaryOp::PostDecrement);
    expression->token = operand->token;
    expression->type = operand->type;
    expression->lhs = std::move(operand);
    return expression;
  }

  ExprPtr parse_postfix() {
    ExprPtr expression = parse_primary();
    while (true) {
      if (consume_punct("[")) {
        ExprPtr index = parse_expression();
        expect_punct("]");
        expression = make_index(std::move(expression), std::move(index));
        continue;
      }
      if (consume_punct("++")) {
        if (!expression->lvalue || !is_scalar(expression->type)) {
          fail(expression->token, "increment requires a scalar lvalue");
        }
        auto node = std::make_unique<Expr>();
        node->kind = ExprKind::Unary;
        node->unary = UnaryOp::PostIncrement;
        node->token = expression->token;
        node->type = expression->type;
        node->lhs = std::move(expression);
        expression = std::move(node);
        continue;
      }
      if (consume_punct("--")) {
        if (!expression->lvalue || !is_scalar(expression->type)) {
          fail(expression->token, "decrement requires a scalar lvalue");
        }
        auto node = std::make_unique<Expr>();
        node->kind = ExprKind::Unary;
        node->unary = UnaryOp::PostDecrement;
        node->token = expression->token;
        node->type = expression->type;
        node->lhs = std::move(expression);
        expression = std::move(node);
        continue;
      }
      if (is_punct(".") || is_punct("->")) {
        fail("struct and union member access is not supported yet");
      }
      if (is_punct("(")) {
        fail(expression->token,
             "only direct function calls are supported; function pointers are "
             "not implemented");
      }
      return expression;
    }
  }

  ExprPtr parse_primary() {
    if (peek().kind == TokenKind::Number) {
      const Token token = advance();
      TypePtr type = token.unsigned_suffix ? type_uint() : type_int();
      return make_int(static_cast<std::int64_t>(token.number), type, token);
    }
    if (peek().kind == TokenKind::Character) {
      const Token token = advance();
      return make_int(static_cast<std::int64_t>(token.number), type_int(),
                      token);
    }
    if (peek().kind == TokenKind::String) {
      std::string bytes;
      Token token = peek();
      while (peek().kind == TokenKind::String) {
        bytes += advance().text;
      }
      StringLiteral literal;
      literal.label = ".LC" + std::to_string(string_counter_++);
      literal.bytes = bytes;
      program_.strings.push_back(literal);
      auto expression = std::make_unique<Expr>();
      expression->kind = ExprKind::String;
      expression->type = pointer_to(type_char());
      expression->name = literal.label;
      expression->token = token;
      return expression;
    }
    if (peek().kind == TokenKind::Identifier) {
      const Token token = advance();
      if (is_punct("(")) {
        Function* function = find_function(token.text);
        if (function == nullptr) {
          fail(token, "call to undeclared function '" + token.text + "'");
        }
        expect_punct("(");
        std::vector<ExprPtr> args;
        if (!is_punct(")")) {
          while (true) {
            args.push_back(decay_expression(parse_assignment()));
            if (!consume_punct(",")) {
              break;
            }
          }
        }
        expect_punct(")");
        const std::size_t fixed = function->type->params.size();
        if (!function->type->variadic && args.size() != fixed) {
          fail(token, "function '" + token.text + "' expects " +
                          std::to_string(fixed) + " arguments");
        }
        if (function->type->variadic && args.size() < fixed) {
          fail(token, "function '" + token.text + "' expects at least " +
                          std::to_string(fixed) + " arguments");
        }
        auto expression = std::make_unique<Expr>();
        expression->kind = ExprKind::Call;
        expression->type = function->type->base;
        expression->function = function;
        expression->token = token;
        expression->args = std::move(args);
        return expression;
      }
      if (Decl* local = find_local(token.text)) {
        auto expression = std::make_unique<Expr>();
        expression->kind = ExprKind::Var;
        expression->type = local->type;
        expression->local = local;
        expression->lvalue = local->type->kind != TypeKind::Array;
        expression->token = token;
        return expression;
      }
      if (GlobalVar* global = find_global(token.text)) {
        auto expression = std::make_unique<Expr>();
        expression->kind = ExprKind::Var;
        expression->type = global->decl->type;
        expression->global = global;
        expression->lvalue = global->decl->type->kind != TypeKind::Array;
        expression->token = token;
        return expression;
      }
      if (find_function(token.text) != nullptr) {
        fail(token, "function '" + token.text + "' used without a call");
      }
      fail(token, "undeclared identifier '" + token.text + "'");
    }
    if (consume_punct("(")) {
      ExprPtr expression = parse_expression();
      expect_punct(")");
      return expression;
    }
    fail("expected an expression");
  }

  ExprPtr decay_expression(ExprPtr expression) {
    if (expression->type->kind == TypeKind::Array) {
      expression->type = pointer_to(expression->type->base);
      expression->lvalue = false;
    }
    return expression;
  }

  ExprPtr make_binary(BinaryOp operation, ExprPtr left, ExprPtr right) {
    left = decay_expression(std::move(left));
    right = decay_expression(std::move(right));
    auto expression = std::make_unique<Expr>();
    expression->kind = ExprKind::Binary;
    expression->binary = operation;
    expression->token = left->token;
    expression->lhs = std::move(left);
    expression->rhs = std::move(right);

    TypePtr left_type = expression->lhs->type;
    TypePtr right_type = expression->rhs->type;

    switch (operation) {
      case BinaryOp::Add:
      case BinaryOp::Sub:
        if (is_pointer(left_type) && is_integer(right_type)) {
          expression->type = left_type;
          return expression;
        }
        if (operation == BinaryOp::Add && is_integer(left_type) &&
            is_pointer(right_type)) {
          std::swap(expression->lhs, expression->rhs);
          expression->type = expression->rhs->type;
          return expression;
        }
        if (operation == BinaryOp::Sub && is_pointer(left_type) &&
            is_pointer(right_type)) {
          if (left_type->base->size != right_type->base->size) {
            fail(expression->token, "pointer subtraction requires matching types");
          }
          expression->type = type_int();
          return expression;
        }
        if (!is_integer(left_type) || !is_integer(right_type)) {
          fail(expression->token, "arithmetic requires integer operands");
        }
        expression->type = usual_integer_type(promote(left_type),
                                              promote(right_type));
        return expression;
      case BinaryOp::Mul:
      case BinaryOp::Div:
      case BinaryOp::Mod:
      case BinaryOp::BitAnd:
      case BinaryOp::BitOr:
      case BinaryOp::BitXor:
        if (!is_integer(left_type) || !is_integer(right_type)) {
          fail(expression->token, "operator requires integer operands");
        }
        expression->type = usual_integer_type(promote(left_type),
                                              promote(right_type));
        return expression;
      case BinaryOp::Shl:
      case BinaryOp::Shr:
        if (!is_integer(left_type) || !is_integer(right_type)) {
          fail(expression->token, "shift requires integer operands");
        }
        expression->type = promote(left_type);
        return expression;
      case BinaryOp::Lt:
      case BinaryOp::Le:
      case BinaryOp::Gt:
      case BinaryOp::Ge:
      case BinaryOp::Eq:
      case BinaryOp::Ne:
      case BinaryOp::LogAnd:
      case BinaryOp::LogOr:
        if (!is_scalar(left_type) || !is_scalar(right_type)) {
          fail(expression->token, "comparison requires scalar operands");
        }
        expression->type = type_int();
        return expression;
      case BinaryOp::Comma:
        expression->type = expression->rhs->type;
        return expression;
    }
    fail(expression->token, "unsupported binary operator");
  }

  ExprPtr make_index(ExprPtr base, ExprPtr index) {
    base = decay_expression(std::move(base));
    index = decay_expression(std::move(index));
    if (!is_pointer(base->type) || !is_integer(index->type)) {
      fail(base->token, "subscript requires a pointer and an integer");
    }
    auto expression = std::make_unique<Expr>();
    expression->kind = ExprKind::Index;
    expression->token = base->token;
    expression->type = base->type->base;
    expression->lvalue = true;
    expression->lhs = std::move(base);
    expression->rhs = std::move(index);
    return expression;
  }

  bool evaluate_constant(const Expr* expression, std::int64_t& value) const {
    if (expression == nullptr) {
      return false;
    }
    switch (expression->kind) {
      case ExprKind::Int:
        value = expression->value;
        return true;
      case ExprKind::Unary: {
        std::int64_t operand = 0;
        if (!evaluate_constant(expression->lhs.get(), operand)) {
          return false;
        }
        switch (expression->unary) {
          case UnaryOp::Plus:
            value = operand;
            return true;
          case UnaryOp::Negate:
            value = -operand;
            return true;
          case UnaryOp::Not:
            value = operand == 0 ? 1 : 0;
            return true;
          case UnaryOp::BitNot:
            value = ~operand;
            return true;
          default:
            return false;
        }
      }
      case ExprKind::Binary: {
        std::int64_t left = 0;
        std::int64_t right = 0;
        if (!evaluate_constant(expression->lhs.get(), left) ||
            !evaluate_constant(expression->rhs.get(), right)) {
          return false;
        }
        switch (expression->binary) {
          case BinaryOp::Add:
            value = left + right;
            return true;
          case BinaryOp::Sub:
            value = left - right;
            return true;
          case BinaryOp::Mul:
            value = left * right;
            return true;
          case BinaryOp::Div:
            if (right == 0) return false;
            value = left / right;
            return true;
          case BinaryOp::Mod:
            if (right == 0) return false;
            value = left % right;
            return true;
          case BinaryOp::Shl:
            value = left << right;
            return true;
          case BinaryOp::Shr:
            value = left >> right;
            return true;
          case BinaryOp::Lt:
            value = left < right;
            return true;
          case BinaryOp::Le:
            value = left <= right;
            return true;
          case BinaryOp::Gt:
            value = left > right;
            return true;
          case BinaryOp::Ge:
            value = left >= right;
            return true;
          case BinaryOp::Eq:
            value = left == right;
            return true;
          case BinaryOp::Ne:
            value = left != right;
            return true;
          case BinaryOp::BitAnd:
            value = left & right;
            return true;
          case BinaryOp::BitOr:
            value = left | right;
            return true;
          case BinaryOp::BitXor:
            value = left ^ right;
            return true;
          case BinaryOp::LogAnd:
            value = left && right;
            return true;
          case BinaryOp::LogOr:
            value = left || right;
            return true;
          case BinaryOp::Comma:
            value = right;
            return true;
        }
        return false;
      }
      case ExprKind::Conditional: {
        std::int64_t condition = 0;
        if (!evaluate_constant(expression->lhs.get(), condition)) {
          return false;
        }
        return evaluate_constant(
            condition ? expression->rhs.get() : expression->third.get(), value);
      }
      default:
        return false;
    }
  }

  void assign_frame(Function* function) {
    int cursor = 0;
    for (Decl* declaration : function->locals) {
      const std::size_t size =
          declaration->type->kind == TypeKind::Array
              ? declaration->type->size
              : std::max<std::size_t>(4, declaration->type->size);
      cursor = static_cast<int>((cursor + 3) & ~3);
      cursor += static_cast<int>((size + 3U) & ~std::size_t{3});
      declaration->offset = -cursor;
    }
    function->local_area = (cursor + 15) & ~15;
    function->frame_size = (function->local_area + 1024 + 15) & ~15;
  }

  std::string filename_;
  std::vector<Token> tokens_;
  std::size_t position_ = 0;
  Program program_;
  std::unordered_map<std::string, GlobalVar*> globals_;
  std::unordered_map<std::string, Function*> functions_;
  std::vector<std::unordered_map<std::string, Decl*>> scopes_;
  Function* current_function_ = nullptr;
  std::uint64_t string_counter_ = 0;
};


}  // namespace roco::cc
