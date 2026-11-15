#pragma once

/// @file lexer.hpp
/// @brief Tokenizer for the supported C subset.

#include "compiler/token.hpp"

#include "roco/diagnostic.hpp"

#include <cctype>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace roco::cc {

// ---------------------------------------------------------------- Lexer

inline bool is_identifier_start(char character) {
  return (character >= 'a' && character <= 'z') ||
         (character >= 'A' && character <= 'Z') || character == '_';
}

inline bool is_identifier_character(char character) {
  return is_identifier_start(character) ||
         (character >= '0' && character <= '9');
}

class Lexer {
 public:
  Lexer(std::string_view source, std::string filename)
      : source_(source), filename_(std::move(filename)) {}

  std::vector<Token> tokenize() {
    std::vector<Token> tokens;
    while (position_ < source_.size()) {
      const char character = source_[position_];
      if (character == ' ' || character == '\t' || character == '\r' ||
          character == '\n') {
        if (character == '\n') {
          ++line_;
          column_ = 1;
          ++position_;
        } else {
          advance();
        }
        continue;
      }
      if (character == '/' && position_ + 1 < source_.size()) {
        if (source_[position_ + 1] == '/') {
          while (position_ < source_.size() && source_[position_] != '\n') {
            advance();
          }
          continue;
        }
        if (source_[position_ + 1] == '*') {
          const int start_line = line_;
          advance();
          advance();
          bool closed = false;
          while (position_ < source_.size()) {
            if (source_[position_] == '*' && position_ + 1 < source_.size() &&
                source_[position_ + 1] == '/') {
              advance();
              advance();
              closed = true;
              break;
            }
            if (source_[position_] == '\n') {
              ++line_;
              column_ = 1;
              ++position_;
            } else {
              advance();
            }
          }
          if (!closed) {
            fail(start_line, 1, "unterminated block comment");
          }
          continue;
        }
      }
      if (character == '#') {
        fail(line_, column_, "preprocessor directives are not supported yet");
      }
      if (is_identifier_start(character)) {
        tokens.push_back(lex_identifier());
        continue;
      }
      if (character >= '0' && character <= '9') {
        tokens.push_back(lex_number());
        continue;
      }
      if (character == '\'') {
        tokens.push_back(lex_character());
        continue;
      }
      if (character == '"') {
        tokens.push_back(lex_string());
        continue;
      }
      tokens.push_back(lex_punct());
    }
    tokens.push_back(make_token(TokenKind::End, ""));
    return tokens;
  }

 private:
  Token make_token(TokenKind kind, std::string text) const {
    Token token;
    token.kind = kind;
    token.text = std::move(text);
    token.line = line_;
    token.column = column_;
    return token;
  }

  [[noreturn]] void fail(int line, int column,
                         const std::string& message) const {
    throw Error(filename_ + ":" + std::to_string(line) + ":" +
                std::to_string(column) + ": " + message);
  }

  void advance() {
    ++position_;
    ++column_;
  }

  char decode_escape() {
    if (position_ >= source_.size()) {
      return '\\';
    }
    const char character = source_[position_++];
    ++column_;
    switch (character) {
      case 'n':
        return '\n';
      case 't':
        return '\t';
      case 'r':
        return '\r';
      case '0':
        return '\0';
      case 'a':
        return '\a';
      case 'b':
        return '\b';
      case 'f':
        return '\f';
      case 'v':
        return '\v';
      case '\\':
        return '\\';
      case '\'':
        return '\'';
      case '"':
        return '"';
      case 'x': {
        int value = 0;
        int digits = 0;
        while (digits < 2 && position_ < source_.size()) {
          const char digit = source_[position_];
          int digit_value = -1;
          if (digit >= '0' && digit <= '9') {
            digit_value = digit - '0';
          } else if (digit >= 'a' && digit <= 'f') {
            digit_value = digit - 'a' + 10;
          } else if (digit >= 'A' && digit <= 'F') {
            digit_value = digit - 'A' + 10;
          }
          if (digit_value < 0) {
            break;
          }
          value = value * 16 + digit_value;
          ++position_;
          ++column_;
          ++digits;
        }
        return static_cast<char>(value);
      }
      default:
        return character;
    }
  }

  Token lex_identifier() {
    const std::size_t start = position_;
    while (position_ < source_.size() &&
           is_identifier_character(source_[position_])) {
      advance();
    }
    std::string text(source_.substr(start, position_ - start));
    TokenKind kind = keywords().count(text) != 0 ? TokenKind::Keyword
                                                 : TokenKind::Identifier;
    return make_token(kind, std::move(text));
  }

  Token lex_number() {
    const std::size_t start = position_;
    std::uint64_t value = 0;
    int base = 10;
    if (source_[position_] == '0' && position_ + 1 < source_.size()) {
      if (source_[position_ + 1] == 'x' || source_[position_ + 1] == 'X') {
        base = 16;
        advance();
        advance();
      } else if (source_[position_ + 1] == 'b' ||
                 source_[position_ + 1] == 'B') {
        base = 2;
        advance();
        advance();
      } else {
        base = 8;
      }
    }
    const std::size_t digits_start = position_;
    while (position_ < source_.size()) {
      const char character = source_[position_];
      int digit = -1;
      if (character >= '0' && character <= '9') {
        digit = character - '0';
      } else if (character >= 'a' && character <= 'f') {
        digit = character - 'a' + 10;
      } else if (character >= 'A' && character <= 'F') {
        digit = character - 'A' + 10;
      }
      if (digit < 0 || digit >= base) {
        break;
      }
      value = value * static_cast<std::uint64_t>(base) +
              static_cast<std::uint64_t>(digit);
      advance();
    }
    if (position_ == digits_start) {
      fail(line_, column_, "invalid numeric literal");
    }
    bool unsigned_suffix = false;
    while (position_ < source_.size()) {
      const char character = static_cast<char>(
          std::tolower(static_cast<unsigned char>(source_[position_])));
      if (character == 'u') {
        unsigned_suffix = true;
      } else if (character != 'l') {
        break;
      }
      advance();
    }
    Token token = make_token(
        TokenKind::Number,
        std::string(source_.substr(start, position_ - start)));
    token.number = value;
    token.unsigned_suffix = unsigned_suffix;
    return token;
  }

  Token lex_character() {
    advance();
    char value = '\0';
    if (position_ >= source_.size()) {
      fail(line_, column_, "unterminated character literal");
    }
    if (source_[position_] == '\\') {
      advance();
      value = decode_escape();
    } else {
      value = source_[position_];
      advance();
    }
    if (position_ >= source_.size() || source_[position_] != '\'') {
      fail(line_, column_, "unterminated character literal");
    }
    advance();
    Token token = make_token(TokenKind::Character, "character");
    token.number = static_cast<unsigned char>(value);
    return token;
  }

  Token lex_string() {
    advance();
    std::string value;
    while (position_ < source_.size() && source_[position_] != '"') {
      if (source_[position_] == '\\') {
        advance();
        value.push_back(decode_escape());
      } else if (source_[position_] == '\n') {
        fail(line_, column_, "unterminated string literal");
      } else {
        value.push_back(source_[position_]);
        advance();
      }
    }
    if (position_ >= source_.size()) {
      fail(line_, column_, "unterminated string literal");
    }
    advance();
    return make_token(TokenKind::String, std::move(value));
  }

  Token lex_punct() {
    static const std::vector<std::string> puncts = {
        "<<=", ">>=", "...", "==", "!=", "<=", ">=", "&&", "||", "++",
        "--",  "+=",  "-=",  "*=", "/=", "%=", "&=", "|=", "^=", "->",
        "<<",  ">>",
    };
    for (const std::string& punct : puncts) {
      if (source_.compare(position_, punct.size(), punct) == 0) {
        Token token = make_token(TokenKind::Punct, punct);
        for (std::size_t i = 0; i < punct.size(); ++i) {
          advance();
        }
        return token;
      }
    }
    const char character = source_[position_];
    if (std::string_view("{}[]();:,.?+-*/%&|^!~<>=#").find(character) ==
        std::string_view::npos) {
      fail(line_, column_, std::string("unexpected character '") + character +
                               "'");
    }
    Token token = make_token(TokenKind::Punct, std::string(1, character));
    advance();
    return token;
  }

  std::string_view source_;
  std::string filename_;
  std::size_t position_ = 0;
  int line_ = 1;
  int column_ = 1;
};


}  // namespace roco::cc
