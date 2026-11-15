/// @file compiler.cpp
/// @brief Public C compilation entry points.

#include "roco/compiler.hpp"

#include "compiler/codegen.hpp"
#include "compiler/parser.hpp"

#include "roco/diagnostic.hpp"

#include <fstream>
#include <iterator>
#include <string>
#include <string_view>
#include <utility>

namespace roco {

std::string compile_to_assembly(std::string_view source,
                                std::string_view filename) {
  cc::Parser parser(source, std::string(filename));
  cc::Program program = parser.parse();
  cc::Codegen codegen(std::move(program));
  return codegen.generate();
}

std::string compile_file(const std::string& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) {
    throw Error("cannot open C source file '" + path + "'");
  }
  const std::string source((std::istreambuf_iterator<char>(stream)),
                           std::istreambuf_iterator<char>());
  return compile_to_assembly(source, path);
}

}  // namespace roco
