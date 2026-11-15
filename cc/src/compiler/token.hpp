#pragma once

/// @file token.hpp
/// @brief Lexical token representation and C keyword classification.

#include <cstdint>
#include <string>
#include <unordered_set>

namespace roco::cc {

enum class TokenKind {
  Identifier,
  Keyword,
  Number,
  String,
  Character,
  Punct,
  End,
};

struct Token {
  TokenKind kind = TokenKind::End;
  std::string text;
  std::uint64_t number = 0;
  bool unsigned_suffix = false;
  int line = 1;
  int column = 1;
};

const std::unordered_set<std::string>& keywords();

}  // namespace roco::cc
