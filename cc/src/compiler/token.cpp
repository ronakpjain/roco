/// @file token.cpp
/// @brief C keyword classification.

#include "compiler/token.hpp"

namespace roco::cc {

const std::unordered_set<std::string>& keywords() {
  static const std::unordered_set<std::string> values = {
      "auto",     "break",    "case",     "char",      "const",
      "continue", "default",  "do",       "double",    "else",
      "enum",     "extern",   "float",    "for",       "goto",
      "if",       "inline",   "int",      "long",      "register",
      "restrict", "return",   "short",    "signed",    "sizeof",
      "static",   "struct",   "switch",   "typedef",   "union",
      "unsigned", "void",     "volatile", "while",     "_Bool",
  };
  return values;
}

}  // namespace roco::cc
