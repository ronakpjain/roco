#pragma once

/// @file preprocessor.hpp
/// @brief Macro and repetition expansion for the assembler.

#include "roco/diagnostic.hpp"

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace roco::cc_asm {

/// Expand `.macro`/`.endm`, `.rept`/`.endr`, `\argument`, and `\@`.
///
/// Expansion happens before lexing, matching the line-oriented syntax the
/// assembler accepts. Macro-local `\@` counters keep generated labels
/// unique across repeated invocations.
class MacroExpander {
 public:
  MacroExpander(std::string_view source, std::string filename)
      : filename_(std::move(filename)) {
    std::istringstream input{std::string(source)};
    std::string line;
    while (std::getline(input, line)) {
      lines_.push_back(line);
    }
  }

  std::string run() {
    std::vector<std::string> output;
    expand(lines_, output, 0);
    std::string result;
    for (const std::string& line : output) {
      result += line;
      result += '\n';
    }
    return result;
  }

 private:
  struct Macro {
    std::vector<std::string> parameters;
    std::vector<std::string> body;
  };

  [[noreturn]] void fail(std::size_t line, const std::string& message) const {
    throw Error(filename_ + ":" + std::to_string(line + 1) + ": " + message);
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

  static std::string strip_comment(std::string_view text) {
    bool quoted = false;
    for (std::size_t i = 0; i < text.size(); ++i) {
      if (text[i] == '"' && (i == 0 || text[i - 1] != '\\')) {
        quoted = !quoted;
      }
      if (!quoted && text[i] == '#') {
        return std::string(text.substr(0, i));
      }
    }
    return std::string(text);
  }

  static bool starts_with_word(const std::string& text, std::string_view word) {
    if (text.size() < word.size() || text.compare(0, word.size(), word) != 0) {
      return false;
    }
    return text.size() == word.size() ||
           std::isspace(static_cast<unsigned char>(text[word.size()])) != 0;
  }

  static std::vector<std::string> split_arguments(const std::string& text) {
    std::vector<std::string> arguments;
    if (trim(text).empty()) {
      return arguments;
    }
    if (text.find(',') != std::string::npos) {
      std::size_t begin = 0;
      while (begin <= text.size()) {
        const std::size_t comma = text.find(',', begin);
        const std::size_t end = comma == std::string::npos ? text.size() : comma;
        arguments.push_back(trim(std::string_view(text).substr(begin, end - begin)));
        if (comma == std::string::npos) {
          break;
        }
        begin = comma + 1;
      }
    } else {
      std::istringstream input(text);
      std::string word;
      while (input >> word) {
        arguments.push_back(word);
      }
    }
    return arguments;
  }

  static void replace_all(std::string& text, const std::string& from,
                          const std::string& to) {
    if (from.empty()) {
      return;
    }
    std::size_t position = 0;
    while ((position = text.find(from, position)) != std::string::npos) {
      text.replace(position, from.size(), to);
      position += to.size();
    }
  }

  void expand(const std::vector<std::string>& input,
              std::vector<std::string>& output, int depth) {
    if (depth > 64) {
      fail(0, "macro expansion is nested too deeply");
    }
    for (std::size_t i = 0; i < input.size();) {
      const std::string code = strip_comment(input[i]);
      const std::string line = trim(code);

      if (starts_with_word(line, ".macro")) {
        const std::string header = trim(std::string_view(line).substr(6));
        const std::size_t name_end = header.find_first_of(" \t");
        if (header.empty() || name_end == 0) {
          fail(i, ".macro requires a name");
        }
        const std::string name = header.substr(0, name_end);
        const std::vector<std::string> parameters =
            name_end == std::string::npos
                ? std::vector<std::string>{}
                : split_arguments(header.substr(name_end));
        Macro macro;
        macro.parameters = parameters;
        ++i;
        bool closed = false;
        while (i < input.size()) {
          const std::string body_line = trim(strip_comment(input[i]));
          if (body_line == ".endm") {
            closed = true;
            ++i;
            break;
          }
          if (starts_with_word(body_line, ".macro")) {
            fail(i, "nested .macro definitions are not supported");
          }
          macro.body.push_back(input[i]);
          ++i;
        }
        if (!closed) {
          fail(i, ".macro without matching .endm");
        }
        macros_.insert_or_assign(name, std::move(macro));
        continue;
      }

      if (starts_with_word(line, ".rept")) {
        const std::string count_text =
            trim(std::string_view(line).substr(5));
        std::size_t consumed = 0;
        long long count = 0;
        try {
          count = std::stoll(count_text, &consumed, 0);
        } catch (const std::exception&) {
          fail(i, ".rept requires a constant repeat count");
        }
        if (consumed != count_text.size() || count < 0 || count > 1000000) {
          fail(i, "repeat count must be in the range 0..1000000");
        }
        std::vector<std::string> body;
        ++i;
        int nesting = 0;
        bool closed = false;
        while (i < input.size()) {
          const std::string body_line = trim(strip_comment(input[i]));
          if (starts_with_word(body_line, ".rept")) {
            ++nesting;
          } else if (body_line == ".endr") {
            if (nesting == 0) {
              closed = true;
              ++i;
              break;
            }
            --nesting;
          }
          body.push_back(input[i]);
          ++i;
        }
        if (!closed) {
          fail(i, ".rept without matching .endr");
        }
        for (long long repetition = 0; repetition < count; ++repetition) {
          expand(body, output, depth + 1);
        }
        continue;
      }

      if (line == ".endm" || line == ".endr") {
        fail(i, "unexpected " + line);
      }

      const std::size_t word_end = line.find_first_of(" \t");
      const std::string mnemonic =
          word_end == std::string::npos ? line : line.substr(0, word_end);
      const auto macro = macros_.find(mnemonic);
      if (macro != macros_.end()) {
        const std::string argument_text =
            word_end == std::string::npos ? std::string() : line.substr(word_end);
        const std::vector<std::string> arguments =
            split_arguments(argument_text);
        if (arguments.size() != macro->second.parameters.size()) {
          fail(i, "macro '" + mnemonic + "' expects " +
                      std::to_string(macro->second.parameters.size()) +
                      " arguments");
        }
        const std::string unique = std::to_string(unique_++);
        std::vector<std::string> expanded;
        for (std::string body_line : macro->second.body) {
          replace_all(body_line, "\\@", unique);
          for (std::size_t parameter = 0;
               parameter < macro->second.parameters.size(); ++parameter) {
            replace_all(body_line, "\\" + macro->second.parameters[parameter],
                        arguments[parameter]);
          }
          expanded.push_back(std::move(body_line));
        }
        expand(expanded, output, depth + 1);
        ++i;
        continue;
      }

      output.push_back(input[i]);
      ++i;
    }
  }

  std::string filename_;
  std::vector<std::string> lines_;
  std::unordered_map<std::string, Macro> macros_;
  std::uint64_t unique_ = 0;
};

}  // namespace roco::cc_asm
