/// @file compiler.cpp
/// @brief Public C compilation entry points.

#include "roco/compiler.hpp"

#include "compiler/codegen.hpp"
#include "compiler/parser.hpp"
#include "compiler/preprocessor.hpp"

#include "roco/diagnostic.hpp"

#include <fstream>
#include <iterator>
#include <string>
#include <string_view>
#include <utility>

namespace roco {

namespace {

std::string read_source(const std::string& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) {
    throw Error("cannot open C source file '" + path + "'");
  }
  return std::string((std::istreambuf_iterator<char>(stream)),
                     std::istreambuf_iterator<char>());
}

std::vector<std::string> include_dirs() {
  std::vector<std::string> result;
#ifdef ROCO_INCLUDE_DIR
  result.emplace_back(ROCO_INCLUDE_DIR);
#endif
  return result;
}

}  // namespace

std::string compile_to_assembly(std::string_view source,
                                std::string_view filename) {
  cc::Preprocessor preprocessor(source, std::string(filename), include_dirs());
  cc::Parser parser(preprocessor.run(), std::string(filename));
  cc::Program program = parser.parse();
  cc::Codegen codegen(std::move(program));
  return codegen.generate();
}

std::string compile_file(const std::string& path) {
  return compile_to_assembly(read_source(path), path);
}

std::string preprocess_file(const std::string& path) {
  cc::Preprocessor preprocessor(read_source(path), path, include_dirs());
  return preprocessor.run();
}

}  // namespace roco
