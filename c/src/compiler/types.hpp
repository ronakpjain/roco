#pragma once

/// @file types.hpp
/// @brief C type representation used by the compiler frontend and backend.

#include <algorithm>
#include <cstddef>
#include <memory>
#include <vector>

namespace roco::cc {

// ---------------------------------------------------------------- Types

enum class TypeKind { Void, Char, Short, Int, Long, Pointer, Array, Function };

struct Type;
using TypePtr = std::shared_ptr<Type>;

struct Type {
  TypeKind kind = TypeKind::Int;
  bool is_unsigned = false;
  std::size_t size = 4;
  std::size_t align = 4;
  TypePtr base;
  std::size_t length = 0;
  std::vector<TypePtr> params;
  bool variadic = false;
};

TypePtr make_primitive(TypeKind kind, bool is_unsigned, std::size_t size) {
  auto type = std::make_shared<Type>();
  type->kind = kind;
  type->is_unsigned = is_unsigned;
  type->size = size;
  type->align = size;
  return type;
}

TypePtr type_void() {
  static TypePtr type = [] {
    auto value = std::make_shared<Type>();
    value->kind = TypeKind::Void;
    value->size = 0;
    value->align = 1;
    return value;
  }();
  return type;
}

TypePtr type_int() {
  static TypePtr type = make_primitive(TypeKind::Int, false, 4);
  return type;
}

TypePtr type_uint() {
  static TypePtr type = make_primitive(TypeKind::Int, true, 4);
  return type;
}

TypePtr type_char(bool is_unsigned = false) {
  static TypePtr signed_char = make_primitive(TypeKind::Char, false, 1);
  static TypePtr unsigned_char = make_primitive(TypeKind::Char, true, 1);
  return is_unsigned ? unsigned_char : signed_char;
}

TypePtr type_short(bool is_unsigned = false) {
  static TypePtr signed_short = make_primitive(TypeKind::Short, false, 2);
  static TypePtr unsigned_short = make_primitive(TypeKind::Short, true, 2);
  return is_unsigned ? unsigned_short : signed_short;
}

TypePtr type_long(bool is_unsigned = false) {
  static TypePtr signed_long = make_primitive(TypeKind::Long, false, 4);
  static TypePtr unsigned_long = make_primitive(TypeKind::Long, true, 4);
  return is_unsigned ? unsigned_long : signed_long;
}

TypePtr pointer_to(TypePtr base) {
  auto type = std::make_shared<Type>();
  type->kind = TypeKind::Pointer;
  type->size = 4;
  type->align = 4;
  type->base = std::move(base);
  return type;
}

TypePtr array_of(TypePtr base, std::size_t length) {
  auto type = std::make_shared<Type>();
  type->kind = TypeKind::Array;
  type->size = base->size * length;
  type->align = std::max<std::size_t>(1, base->align);
  type->base = std::move(base);
  type->length = length;
  return type;
}

TypePtr function_of(TypePtr result, std::vector<TypePtr> params,
                    bool variadic) {
  auto type = std::make_shared<Type>();
  type->kind = TypeKind::Function;
  type->size = 0;
  type->align = 1;
  type->base = std::move(result);
  type->params = std::move(params);
  type->variadic = variadic;
  return type;
}

TypePtr decay(TypePtr type) {
  if (type->kind == TypeKind::Array) {
    return pointer_to(type->base);
  }
  return type;
}

bool is_integer(const TypePtr& type) {
  return type->kind == TypeKind::Char || type->kind == TypeKind::Short ||
         type->kind == TypeKind::Int || type->kind == TypeKind::Long;
}

bool is_pointer(const TypePtr& type) {
  return type->kind == TypeKind::Pointer;
}

bool is_scalar(const TypePtr& type) { return is_integer(type) || is_pointer(type); }

TypePtr promote(const TypePtr& type) {
  if (type->kind == TypeKind::Char || type->kind == TypeKind::Short) {
    return type->is_unsigned ? type_uint() : type_int();
  }
  return type;
}

TypePtr usual_integer_type(const TypePtr& left, const TypePtr& right) {
  if (left->is_unsigned || right->is_unsigned) {
    return type_uint();
  }
  return type_int();
}


}  // namespace roco::cc
