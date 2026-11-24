/// @file target.cpp
/// @brief Target cost model parsing and defaults.

#include "roco/target.hpp"

#include "roco/diagnostic.hpp"

#include <cctype>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <string_view>

namespace roco {

namespace {

std::string_view trim(std::string_view text) {
  while (!text.empty() &&
         std::isspace(static_cast<unsigned char>(text.front())) != 0) {
    text.remove_prefix(1);
  }
  while (!text.empty() &&
         std::isspace(static_cast<unsigned char>(text.back())) != 0) {
    text.remove_suffix(1);
  }
  return text;
}

bool parse_non_negative(std::string_view text, int& value) {
  text = trim(text);
  if (text.empty()) {
    return false;
  }
  long long parsed = 0;
  for (const char character : text) {
    if (std::isdigit(static_cast<unsigned char>(character)) == 0) {
      return false;
    }
    parsed = parsed * 10 + (character - '0');
    if (parsed > 1000000) {
      return false;
    }
  }
  value = static_cast<int>(parsed);
  return true;
}

}  // namespace

CostModel default_cost_model() { return CostModel{}; }

bool set_cost(CostModel& costs, std::string_view name, int value) {
  if (value < 0) {
    return false;
  }
  if (name == "issue") {
    if (value == 0) {
      return false;
    }
    costs.issue = value;
    return true;
  }
  if (name == "arithmetic") {
    costs.arithmetic = value;
    return true;
  }
  if (name == "shift") {
    costs.shift = value;
    return true;
  }
  if (name == "compare") {
    costs.compare = value;
    return true;
  }
  if (name == "multiply") {
    costs.multiply = value;
    return true;
  }
  if (name == "divide") {
    costs.divide = value;
    return true;
  }
  if (name == "load") {
    costs.load = value;
    return true;
  }
  if (name == "store") {
    costs.store = value;
    return true;
  }
  if (name == "branch") {
    costs.branch = value;
    return true;
  }
  if (name == "jump") {
    costs.jump = value;
    return true;
  }
  return false;
}

CostModel parse_cost_model(std::string_view text,
                           const std::string& source_name) {
  CostModel costs = default_cost_model();
  std::size_t line_number = 0;
  std::size_t position = 0;
  while (position <= text.size()) {
    const std::size_t newline = text.find('\n', position);
    const std::string_view line =
        text.substr(position, newline == std::string_view::npos
                                  ? std::string_view::npos
                                  : newline - position);
    ++line_number;
    std::string_view content = trim(line);
    if (!content.empty() && content.front() != '#') {
      const std::size_t equals = content.find('=');
      if (equals == std::string_view::npos) {
        throw Error(source_name + ":" + std::to_string(line_number) +
                    ": expected key=value");
      }
      const std::string_view key = trim(content.substr(0, equals));
      int value = 0;
      if (!parse_non_negative(content.substr(equals + 1), value)) {
        throw Error(source_name + ":" + std::to_string(line_number) +
                    ": expected a non-negative integer cost");
      }
      if (!set_cost(costs, key, value)) {
        throw Error(source_name + ":" + std::to_string(line_number) +
                    ": unknown cost key '" + std::string(key) + "'");
      }
    }
    if (newline == std::string_view::npos) {
      break;
    }
    position = newline + 1;
  }
  return costs;
}

CostModel load_cost_model(const std::string& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) {
    throw Error("cannot open cost model file '" + path + "'");
  }
  const std::string text((std::istreambuf_iterator<char>(stream)),
                         std::istreambuf_iterator<char>());
  return parse_cost_model(text, path);
}

const char* optimization_name(OptimizationLevel level) {
  switch (level) {
    case OptimizationLevel::O0:
      return "-O0";
    case OptimizationLevel::O1:
      return "-O1";
    case OptimizationLevel::O2:
      return "-O2";
  }
  return "-O?";
}

}  // namespace roco
