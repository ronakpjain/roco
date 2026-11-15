#pragma once

/// @file preprocessor.hpp
/// @brief Minimal C preprocessor for freestanding roco sources.

#include "roco/diagnostic.hpp"

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace roco::cc {

/// Expand includes, object/function macros, and conditional directives.
///
/// The subset is deliberately small: it covers freestanding headers and
/// ordinary `#define`/`#ifdef` use, without token pasting or variadic macros.
class Preprocessor {
 public:
  Preprocessor(std::string_view source, std::string filename,
               std::vector<std::string> include_dirs = {})
      : filename_(std::move(filename)),
        include_dirs_(std::move(include_dirs)) {
    current_directory_ = std::filesystem::path(filename_).parent_path();
    result_ = process_source(std::string(source), filename_, 0);
  }

  std::string run() const { return result_; }

 private:
  struct Macro {
    bool function_like = false;
    std::vector<std::string> parameters;
    std::string body;
  };

  struct Conditional {
    bool parent_active = true;
    bool active = true;
    bool taken = false;
  };

  [[noreturn]] void fail(const std::string& file, int line,
                         const std::string& message) const {
    throw Error(file + ":" + std::to_string(line) + ": " + message);
  }

  static std::string trim(std::string_view text) {
    std::size_t begin = 0;
    while (begin < text.size() &&
           std::isspace(static_cast<unsigned char>(text[begin]))) {
      ++begin;
    }
    std::size_t end = text.size();
    while (end > begin &&
           std::isspace(static_cast<unsigned char>(text[end - 1]))) {
      --end;
    }
    return std::string(text.substr(begin, end - begin));
  }

  static bool is_identifier_start(char character) {
    return std::isalpha(static_cast<unsigned char>(character)) != 0 ||
           character == '_';
  }

  static bool is_identifier_character(char character) {
    return std::isalnum(static_cast<unsigned char>(character)) != 0 ||
           character == '_';
  }

  static std::string strip_comments(std::string_view source) {
    std::string result;
    result.reserve(source.size());
    bool line_comment = false;
    bool block_comment = false;
    bool string_literal = false;
    bool character_literal = false;
    for (std::size_t i = 0; i < source.size(); ++i) {
      const char character = source[i];
      const char next = i + 1 < source.size() ? source[i + 1] : '\0';
      if (line_comment) {
        if (character == '\n') {
          line_comment = false;
          result += character;
        }
        continue;
      }
      if (block_comment) {
        if (character == '*' && next == '/') {
          block_comment = false;
          ++i;
        } else if (character == '\n') {
          result += character;
        }
        continue;
      }
      if (string_literal || character_literal) {
        result += character;
        if (character == '\\' && i + 1 < source.size()) {
          result += source[++i];
        } else if ((string_literal && character == '"') ||
                   (character_literal && character == '\'')) {
          string_literal = false;
          character_literal = false;
        }
        continue;
      }
      if (character == '/' && next == '/') {
        line_comment = true;
        ++i;
        continue;
      }
      if (character == '/' && next == '*') {
        block_comment = true;
        ++i;
        continue;
      }
      if (character == '"') {
        string_literal = true;
      } else if (character == '\'') {
        character_literal = true;
      }
      result += character;
    }
    return result;
  }

  static std::vector<std::string> split_lines(const std::string& text) {
    std::vector<std::string> lines;
    std::istringstream input(text);
    std::string line;
    while (std::getline(input, line)) {
      lines.push_back(line);
    }
    return lines;
  }

  static std::string join_continuations(const std::vector<std::string>& lines) {
    std::string result;
    for (std::size_t i = 0; i < lines.size(); ++i) {
      std::string line = lines[i];
      while (!line.empty() && line.back() == '\\' && i + 1 < lines.size()) {
        line.pop_back();
        line += lines[++i];
      }
      result += line;
      result += '\n';
    }
    return result;
  }

  std::string process_source(const std::string& text,
                             const std::string& path, int depth) {
    if (depth > 32) {
      fail(path, 0, "include nesting is too deep");
    }
    const std::string clean = strip_comments(text);
    const std::vector<std::string> lines =
        split_lines(join_continuations(split_lines(clean)));
    std::string output;
    std::vector<Conditional> conditionals;

    auto active = [&]() {
      return conditionals.empty() || conditionals.back().active;
    };

    for (std::size_t index = 0; index < lines.size(); ++index) {
      const std::string line = lines[index];
      const std::string trimmed = trim(line);
      if (trimmed.empty() || trimmed[0] != '#') {
        if (active()) {
          output += strip_attributes(expand_line(line, 0));
          output += '\n';
        }
        continue;
      }

      std::size_t cursor = 1;
      while (cursor < trimmed.size() &&
             std::isspace(static_cast<unsigned char>(trimmed[cursor]))) {
        ++cursor;
      }
      std::size_t name_end = cursor;
      while (name_end < trimmed.size() &&
             std::isalpha(static_cast<unsigned char>(trimmed[name_end]))) {
        ++name_end;
      }
      const std::string directive = trimmed.substr(cursor, name_end - cursor);
      const std::string rest = trim(std::string_view(trimmed).substr(name_end));

      if (directive == "ifdef" || directive == "ifndef") {
        const bool defined = macros_.find(first_word(rest)) != macros_.end();
        const bool condition = directive == "ifdef" ? defined : !defined;
        Conditional state;
        state.parent_active = active();
        state.active = state.parent_active && condition;
        state.taken = state.active;
        conditionals.push_back(state);
        continue;
      }
      if (directive == "if") {
        const bool condition = active() && evaluate_condition(rest, path, static_cast<int>(index + 1));
        Conditional state;
        state.parent_active = active();
        state.active = state.parent_active && condition;
        state.taken = state.active;
        conditionals.push_back(state);
        continue;
      }
      if (directive == "elif") {
        if (conditionals.empty()) {
          fail(path, static_cast<int>(index + 1), "#elif without #if");
        }
        Conditional& state = conditionals.back();
        state.active = state.parent_active && !state.taken &&
                       evaluate_condition(rest, path, static_cast<int>(index + 1));
        state.taken = state.taken || state.active;
        continue;
      }
      if (directive == "else") {
        if (conditionals.empty()) {
          fail(path, static_cast<int>(index + 1), "#else without #if");
        }
        Conditional& state = conditionals.back();
        state.active = state.parent_active && !state.taken;
        state.taken = true;
        continue;
      }
      if (directive == "endif") {
        if (conditionals.empty()) {
          fail(path, static_cast<int>(index + 1), "#endif without #if");
        }
        conditionals.pop_back();
        continue;
      }
      if (!active()) {
        continue;
      }

      if (directive == "include") {
        const std::string target = parse_include_target(rest, path, static_cast<int>(index + 1));
        const std::string included_path = resolve_include(target, path, static_cast<int>(index + 1));
        std::ifstream stream(included_path, std::ios::binary);
        if (!stream) {
          fail(path, static_cast<int>(index + 1),
               "cannot open include '" + included_path + "'");
        }
        const std::string included((std::istreambuf_iterator<char>(stream)),
                                   std::istreambuf_iterator<char>());
        output += process_source(included, included_path, depth + 1);
        continue;
      }
      if (directive == "define") {
        define_macro(rest, path, static_cast<int>(index + 1));
        continue;
      }
      if (directive == "undef") {
        macros_.erase(first_word(rest));
        continue;
      }
      if (directive == "pragma") {
        continue;
      }
      if (directive == "error") {
        fail(path, static_cast<int>(index + 1), "#error " + rest);
      }
      fail(path, static_cast<int>(index + 1),
           "unsupported preprocessor directive '#" + directive + "'");
    }
    if (!conditionals.empty()) {
      fail(path, static_cast<int>(lines.size()), "unterminated #if");
    }
    return output;
  }

  static std::string first_word(const std::string& text) {
    std::size_t end = 0;
    while (end < text.size() &&
           is_identifier_character(text[end])) {
      ++end;
    }
    return text.substr(0, end);
  }

  void define_macro(const std::string& text, const std::string& path,
                    int line) {
    const std::string name = first_word(text);
    if (name.empty()) {
      fail(path, line, "#define requires a name");
    }
    Macro macro;
    std::size_t cursor = name.size();
    if (cursor < text.size() && text[cursor] == '(') {
      macro.function_like = true;
      ++cursor;
      std::size_t begin = cursor;
      while (cursor < text.size() && text[cursor] != ')') {
        if (text[cursor] == ',') {
          macro.parameters.push_back(trim(std::string_view(text).substr(
              begin, cursor - begin)));
          begin = ++cursor;
        } else {
          ++cursor;
        }
      }
      if (cursor >= text.size()) {
        fail(path, line, "unterminated macro parameter list");
      }
      const std::string final_parameter =
          trim(std::string_view(text).substr(begin, cursor - begin));
      if (!final_parameter.empty()) {
        macro.parameters.push_back(final_parameter);
      }
      ++cursor;
    }
    macro.body = trim(std::string_view(text).substr(cursor));
    macros_[name] = std::move(macro);
  }

  static std::string strip_attributes(std::string text) {
    const std::string attribute = "__attribute__";
    std::size_t position = 0;
    while ((position = text.find(attribute, position)) != std::string::npos) {
      if ((position != 0 && is_identifier_character(text[position - 1])) ||
          (position + attribute.size() < text.size() &&
           is_identifier_character(text[position + attribute.size()]))) {
        position += attribute.size();
        continue;
      }
      std::size_t end = position + attribute.size();
      while (end < text.size() &&
             std::isspace(static_cast<unsigned char>(text[end]))) {
        ++end;
      }
      if (end < text.size() && text[end] == '(') {
        int nesting = 1;
        ++end;
        while (end < text.size() && nesting != 0) {
          if (text[end] == '(') {
            ++nesting;
          } else if (text[end] == ')') {
            --nesting;
          }
          ++end;
        }
      }
      text.erase(position, end - position);
    }
    for (const auto& [from, to] :
         std::vector<std::pair<std::string, std::string>>{
             {"__restrict__", "restrict"},
             {"__restrict", "restrict"},
             {"__inline__", "inline"},
             {"__volatile__", "volatile"}}) {
      std::size_t offset = 0;
      while ((offset = text.find(from, offset)) != std::string::npos) {
        text.replace(offset, from.size(), to);
        offset += to.size();
      }
    }
    return text;
  }

  std::string expand_line(const std::string& line, int depth) {
    if (depth > 64) {
      return line;
    }
    std::string output;
    for (std::size_t i = 0; i < line.size();) {
      if (line[i] == '"' || line[i] == '\'') {
        const char quote = line[i];
        output += line[i++];
        while (i < line.size()) {
          output += line[i];
          if (line[i] == '\\' && i + 1 < line.size()) {
            output += line[++i];
          } else if (line[i] == quote) {
            ++i;
            break;
          }
          ++i;
        }
        continue;
      }
      if (!is_identifier_start(line[i])) {
        output += line[i++];
        continue;
      }
      const std::size_t begin = i;
      while (i < line.size() && is_identifier_character(line[i])) {
        ++i;
      }
      const std::string name = line.substr(begin, i - begin);
      const auto macro = macros_.find(name);
      if (macro == macros_.end()) {
        output += name;
        continue;
      }
      if (macro->second.function_like) {
        std::size_t lookahead = i;
        while (lookahead < line.size() &&
               std::isspace(static_cast<unsigned char>(line[lookahead]))) {
          ++lookahead;
        }
        if (lookahead >= line.size() || line[lookahead] != '(') {
          output += name;
          continue;
        }
        std::vector<std::string> arguments;
        std::size_t cursor = lookahead + 1;
        std::size_t argument_begin = cursor;
        int nesting = 0;
        while (cursor < line.size()) {
          if (line[cursor] == '(') {
            ++nesting;
          } else if (line[cursor] == ')') {
            if (nesting == 0) {
              arguments.push_back(trim(std::string_view(line).substr(
                  argument_begin, cursor - argument_begin)));
              ++cursor;
              break;
            }
            --nesting;
          } else if (line[cursor] == ',' && nesting == 0) {
            arguments.push_back(trim(std::string_view(line).substr(
                argument_begin, cursor - argument_begin)));
            argument_begin = cursor + 1;
          }
          ++cursor;
        }
        if (cursor > line.size()) {
          output += name;
          continue;
        }
        output += expand_macro_body(macro->second, arguments, depth + 1);
        i = cursor;
        continue;
      }
      output += expand_line(macro->second.body, depth + 1);
    }
    return output;
  }

  std::string expand_macro_body(const Macro& macro,
                                const std::vector<std::string>& arguments,
                                int depth) {
    std::string body = macro.body;
    for (std::size_t parameter = 0; parameter < macro.parameters.size();
         ++parameter) {
      const std::string replacement =
          parameter < arguments.size() ? arguments[parameter] : std::string();
      body = substitute_identifier(body, macro.parameters[parameter], replacement);
    }
    return expand_line(body, depth);
  }

  static std::string substitute_identifier(const std::string& text,
                                           const std::string& name,
                                           const std::string& replacement) {
    std::string output;
    for (std::size_t i = 0; i < text.size();) {
      if (!is_identifier_start(text[i])) {
        output += text[i++];
        continue;
      }
      const std::size_t begin = i;
      while (i < text.size() && is_identifier_character(text[i])) {
        ++i;
      }
      const std::string identifier = text.substr(begin, i - begin);
      output += identifier == name ? replacement : identifier;
    }
    return output;
  }

  std::string parse_include_target(const std::string& text,
                                   const std::string& path, int line) {
    if (text.empty() || (text.front() != '"' && text.front() != '<')) {
      fail(path, line, "#include requires \"file\" or <file>");
    }
    const char closing = text.front() == '"' ? '"' : '>';
    const std::size_t end = text.find(closing, 1);
    if (end == std::string::npos) {
      fail(path, line, "unterminated #include");
    }
    return text.substr(1, end - 1);
  }

  std::string resolve_include(const std::string& target,
                              const std::string& including_file,
                              int line) const {
    const bool quoted = target.find('"') == std::string::npos;
    (void)quoted;
    std::vector<std::filesystem::path> candidates;
    const std::filesystem::path including(including_file);
    if (!including.parent_path().empty()) {
      candidates.push_back(including.parent_path() / target);
    }
    for (const std::string& directory : include_dirs_) {
      candidates.push_back(std::filesystem::path(directory) / target);
    }
    for (const std::filesystem::path& candidate : candidates) {
      if (std::filesystem::exists(candidate)) {
        return candidate.string();
      }
    }
    fail(including_file, line, "include not found: " + target);
  }

  bool evaluate_condition(const std::string& expression,
                          const std::string& path, int line) {
    std::string expanded = expression;
    replace_defined(expanded);
    expanded = expand_line(expanded, 0);
    std::size_t cursor = 0;
    const std::int64_t value = parse_condition(expanded, cursor, path, line);
    return value != 0;
  }

  void replace_defined(std::string& text) {
    std::string output;
    for (std::size_t i = 0; i < text.size();) {
      if (text.compare(i, 7, "defined") == 0 &&
          (i == 0 || !is_identifier_character(text[i - 1])) &&
          (i + 7 >= text.size() ||
           !is_identifier_character(text[i + 7]))) {
        i += 7;
        while (i < text.size() &&
               std::isspace(static_cast<unsigned char>(text[i]))) {
          ++i;
        }
        bool parenthesized = false;
        if (i < text.size() && text[i] == '(') {
          parenthesized = true;
          ++i;
        }
        while (i < text.size() &&
               std::isspace(static_cast<unsigned char>(text[i]))) {
          ++i;
        }
        const std::size_t begin = i;
        while (i < text.size() && is_identifier_character(text[i])) {
          ++i;
        }
        const std::string name = text.substr(begin, i - begin);
        if (parenthesized) {
          while (i < text.size() && text[i] != ')') {
            ++i;
          }
          if (i < text.size()) {
            ++i;
          }
        }
        output += macros_.find(name) != macros_.end() ? "1" : "0";
        continue;
      }
      output += text[i++];
    }
    text = std::move(output);
  }

  std::int64_t parse_condition(const std::string& text, std::size_t& cursor,
                               const std::string& path, int line) {
    std::int64_t value = parse_condition_or(text, cursor, path, line);
    return value;
  }

  std::int64_t parse_condition_or(const std::string& text,
                                  std::size_t& cursor,
                                  const std::string& path, int line) {
    std::int64_t value = parse_condition_and(text, cursor, path, line);
    while (true) {
      skip_space(text, cursor);
      if (cursor + 1 < text.size() && text[cursor] == '|' &&
          text[cursor + 1] == '|') {
        cursor += 2;
        const std::int64_t right = parse_condition_and(text, cursor, path, line);
        value = (value != 0 || right != 0) ? 1 : 0;
      } else {
        return value;
      }
    }
  }

  std::int64_t parse_condition_and(const std::string& text,
                                   std::size_t& cursor,
                                   const std::string& path, int line) {
    std::int64_t value = parse_condition_equality(text, cursor, path, line);
    while (true) {
      skip_space(text, cursor);
      if (cursor + 1 < text.size() && text[cursor] == '&' &&
          text[cursor + 1] == '&') {
        cursor += 2;
        const std::int64_t right =
            parse_condition_equality(text, cursor, path, line);
        value = (value != 0 && right != 0) ? 1 : 0;
      } else {
        return value;
      }
    }
  }

  std::int64_t parse_condition_equality(const std::string& text,
                                        std::size_t& cursor,
                                        const std::string& path, int line) {
    std::int64_t value = parse_condition_relational(text, cursor, path, line);
    while (true) {
      skip_space(text, cursor);
      if (cursor + 1 < text.size() && text[cursor] == '=' &&
          text[cursor + 1] == '=') {
        cursor += 2;
        value = value == parse_condition_relational(text, cursor, path, line) ? 1 : 0;
      } else if (cursor + 1 < text.size() && text[cursor] == '!' &&
                 text[cursor + 1] == '=') {
        cursor += 2;
        value = value != parse_condition_relational(text, cursor, path, line) ? 1 : 0;
      } else {
        return value;
      }
    }
  }

  std::int64_t parse_condition_relational(const std::string& text,
                                          std::size_t& cursor,
                                          const std::string& path, int line) {
    std::int64_t value = parse_condition_unary(text, cursor, path, line);
    while (true) {
      skip_space(text, cursor);
      if (cursor < text.size() && text[cursor] == '<') {
        ++cursor;
        const bool equal = cursor < text.size() && text[cursor] == '=';
        if (equal) ++cursor;
        const std::int64_t right = parse_condition_unary(text, cursor, path, line);
        value = equal ? (value <= right) : (value < right);
      } else if (cursor < text.size() && text[cursor] == '>') {
        ++cursor;
        const bool equal = cursor < text.size() && text[cursor] == '=';
        if (equal) ++cursor;
        const std::int64_t right = parse_condition_unary(text, cursor, path, line);
        value = equal ? (value >= right) : (value > right);
      } else {
        return value;
      }
    }
  }

  std::int64_t parse_condition_unary(const std::string& text,
                                     std::size_t& cursor,
                                     const std::string& path, int line) {
    skip_space(text, cursor);
    if (cursor < text.size() && text[cursor] == '!') {
      ++cursor;
      return parse_condition_unary(text, cursor, path, line) == 0 ? 1 : 0;
    }
    if (cursor < text.size() && text[cursor] == '(') {
      ++cursor;
      const std::int64_t value =
          parse_condition_or(text, cursor, path, line);
      skip_space(text, cursor);
      if (cursor >= text.size() || text[cursor] != ')') {
        fail(path, line, "missing ')' in #if expression");
      }
      ++cursor;
      return value;
    }
    if (cursor < text.size() &&
        std::isdigit(static_cast<unsigned char>(text[cursor]))) {
      std::size_t end = cursor;
      while (end < text.size() &&
             (std::isalnum(static_cast<unsigned char>(text[end])) != 0)) {
        ++end;
      }
      const std::string literal = text.substr(cursor, end - cursor);
      cursor = end;
      try {
        return std::stoll(literal, nullptr, 0);
      } catch (const std::exception&) {
        fail(path, line, "invalid integer in #if expression");
      }
    }
    if (cursor < text.size() && is_identifier_start(text[cursor])) {
      const std::size_t begin = cursor;
      while (cursor < text.size() && is_identifier_character(text[cursor])) {
        ++cursor;
      }
      (void)begin;
      return 0;
    }
    fail(path, line, "invalid #if expression");
  }

  static void skip_space(const std::string& text, std::size_t& cursor) {
    while (cursor < text.size() &&
           std::isspace(static_cast<unsigned char>(text[cursor]))) {
      ++cursor;
    }
  }

  std::string filename_;
  std::vector<std::string> include_dirs_;
  std::filesystem::path current_directory_;
  std::unordered_map<std::string, Macro> macros_;
  std::string result_;
};

}  // namespace roco::cc
