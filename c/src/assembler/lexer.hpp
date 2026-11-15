#pragma once

/// @file lexer.hpp
/// @brief Line-oriented assembly lexer.

#include "roco/diagnostic.hpp"

#include <cctype>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace roco::cc_asm {

enum class TokenKind {
  Identifier,
  Number,
  LocalRef,
  String,
  Punct,
  EndOfLine,
  End,
};

struct Token {
  TokenKind kind = TokenKind::End;
  std::string text;
  std::uint64_t number = 0;
  int line = 1;
  int column = 1;
};

inline bool is_identifier_start(char character) {
  return (character >= 'a' && character <= 'z') ||
         (character >= 'A' && character <= 'Z') || character == '_' ||
         character == '.' || character == '$';
}

inline bool is_identifier_character(char character) {
  return is_identifier_start(character) ||
         (character >= '0' && character <= '9');
}

inline bool ends_with(const std::string& text, std::string_view suffix) {
  return text.size() >= suffix.size() &&
         text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

inline char decode_escape(std::string_view source, std::size_t& index) {
  if (index >= source.size()) {
    return '\\';
  }
  const char character = source[index++];
  switch (character) {
    case 'n':
      return '\n';
    case 't':
      return '\t';
    case 'r':
      return '\r';
    case '0':
      return '\0';
    case '\\':
      return '\\';
    case '\'':
      return '\'';
    case '"':
      return '"';
    case 'x': {
      int value = 0;
      int digits = 0;
      while (digits < 2 && index < source.size()) {
        const char digit = source[index];
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
        ++index;
        ++digits;
      }
      return static_cast<char>(value);
    }
    default:
      return character;
  }
}

class Lexer {
 public:
  Lexer(std::string_view source, std::string filename)
      : source_(source), filename_(std::move(filename)) {}

  std::vector<Token> tokenize() {
    std::vector<Token> tokens;
    while (position_ < source_.size()) {
      const char character = source_[position_];
      if (character == ' ' || character == '\t' || character == '\r') {
        advance();
        continue;
      }
      if (character == '\n') {
        tokens.push_back(make_token(TokenKind::EndOfLine, "\n"));
        advance();
        line_ += 1;
        column_ = 1;
        continue;
      }
      if (character == '#') {
        skip_to_end_of_line();
        continue;
      }
      if (character == '/' && position_ + 1 < source_.size()) {
        if (source_[position_ + 1] == '/') {
          skip_to_end_of_line();
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
              line_ += 1;
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
      if (std::string_view(",:()+-~%@=*/!").find(character) !=
          std::string_view::npos) {
        Token token = make_token(TokenKind::Punct, std::string(1, character));
        advance();
        tokens.push_back(std::move(token));
        continue;
      }
      fail(line_, column_, std::string("unexpected character '") + character +
                               "'");
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

  void skip_to_end_of_line() {
    while (position_ < source_.size() && source_[position_] != '\n') {
      advance();
    }
  }

  Token lex_identifier() {
    const std::size_t start = position_;
    while (position_ < source_.size() &&
           is_identifier_character(source_[position_])) {
      advance();
    }
    return make_token(TokenKind::Identifier,
                      std::string(source_.substr(start, position_ - start)));
  }

  Token lex_number() {
    const std::size_t start = position_;
    std::uint64_t value = 0;
    bool decimal = true;

    if (source_[position_] == '0' && position_ + 1 < source_.size() &&
        (source_[position_ + 1] == 'x' ||
         source_[position_ + 1] == 'X')) {
      decimal = false;
      advance();
      advance();
      const std::size_t digits_start = position_;
      while (position_ < source_.size() &&
             std::isxdigit(static_cast<unsigned char>(source_[position_]))) {
        advance();
      }
      if (position_ == digits_start) {
        fail(line_, column_, "expected hexadecimal digits");
      }
      const std::string digits(
          source_.substr(digits_start, position_ - digits_start));
      const auto result =
          std::from_chars(digits.data(), digits.data() + digits.size(), value,
                          16);
      if (result.ec != std::errc{}) {
        fail(line_, column_, "hexadecimal literal is out of range");
      }
    } else if (source_[position_] == '0' && position_ + 1 < source_.size() &&
               (source_[position_ + 1] == 'b' ||
                source_[position_ + 1] == 'B')) {
      decimal = false;
      advance();
      advance();
      const std::size_t digits_start = position_;
      while (position_ < source_.size() &&
             (source_[position_] == '0' || source_[position_] == '1')) {
        value = value * 2 + static_cast<std::uint64_t>(source_[position_] - '0');
        advance();
      }
      if (position_ == digits_start) {
        fail(line_, column_, "expected binary digits");
      }
    } else {
      while (position_ < source_.size() && source_[position_] >= '0' &&
             source_[position_] <= '9') {
        value = value * 10 +
                static_cast<std::uint64_t>(source_[position_] - '0');
        advance();
      }
    }

    if (decimal && position_ < source_.size() &&
        (source_[position_] == 'f' || source_[position_] == 'b')) {
      const char direction = source_[position_];
      const bool boundary =
          position_ + 1 >= source_.size() ||
          !is_identifier_character(source_[position_ + 1]);
      if (boundary) {
        advance();
        Token token = make_token(TokenKind::LocalRef,
                                 std::string(source_.substr(
                                     start, position_ - start)));
        token.number = value;
        if (direction == 'b') {
          token.text = std::to_string(value) + "b";
        }
        return token;
      }
    }

    Token token = make_token(
        TokenKind::Number,
        std::string(source_.substr(start, position_ - start)));
    token.number = value;
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
      value = decode_escape(source_, position_);
    } else {
      value = source_[position_];
      advance();
    }
    if (position_ >= source_.size() || source_[position_] != '\'') {
      fail(line_, column_, "unterminated character literal");
    }
    advance();
    Token token = make_token(TokenKind::Number, "character");
    token.number = static_cast<unsigned char>(value);
    return token;
  }

  Token lex_string() {
    advance();
    std::string value;
    while (position_ < source_.size() && source_[position_] != '"') {
      if (source_[position_] == '\\') {
        advance();
        value.push_back(decode_escape(source_, position_));
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

  std::string_view source_;
  std::string filename_;
  std::size_t position_ = 0;
  int line_ = 1;
  int column_ = 1;
};


}  // namespace roco::cc_asm
