/// @file assembler.cpp
/// @brief Public assembly entry points.

#include "roco/assembler.hpp"

#include "assembler/parser.hpp"

#include "roco/diagnostic.hpp"

#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

namespace roco {

Object assemble(std::string_view source, std::string_view filename) {
  cc_asm::Assembler assembler(source, std::string(filename));
  return assembler.run();
}

Object assemble_file(const std::string& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) {
    throw Error("cannot open assembly file '" + path + "'");
  }
  const std::string source((std::istreambuf_iterator<char>(stream)),
                           std::istreambuf_iterator<char>());
  return assemble(source, path);
}

}  // namespace roco
