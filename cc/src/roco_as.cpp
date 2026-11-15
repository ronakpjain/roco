/// @file roco_as.cpp
/// @brief Command-line driver for the roco RISC-V assembler.

#include "roco/assembler.hpp"
#include "roco/diagnostic.hpp"
#include "roco/elf.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

void usage() {
  std::cerr << "usage: roco_as [-o output.o] input.S\n";
}

void write_file(const std::filesystem::path& path,
                const std::vector<std::uint8_t>& bytes) {
  std::ofstream stream(path, std::ios::binary);
  if (!stream) {
    throw roco::Error("cannot open output file '" + path.string() + "'");
  }
  stream.write(reinterpret_cast<const char*>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  if (!stream) {
    throw roco::Error("failed to write output file '" + path.string() + "'");
  }
}

}  // namespace

int main(int argc, char** argv) {
  std::filesystem::path output;
  std::filesystem::path input;

  for (int i = 1; i < argc; ++i) {
    const std::string argument = argv[i];
    if (argument == "-h" || argument == "--help") {
      usage();
      return 0;
    }
    if (argument == "-o") {
      if (i + 1 >= argc) {
        usage();
        return 2;
      }
      output = argv[++i];
      continue;
    }
    if (!argument.empty() && argument[0] == '-') {
      std::cerr << "roco_as: unknown option '" << argument << "'\n";
      usage();
      return 2;
    }
    if (!input.empty()) {
      std::cerr << "roco_as: multiple input files are not supported\n";
      return 2;
    }
    input = argument;
  }

  if (input.empty()) {
    usage();
    return 2;
  }
  if (output.empty()) {
    output = input;
    output.replace_extension(".o");
  }

  try {
    const roco::Object object = roco::assemble_file(input.string());
    const auto bytes = roco::elf::encode_object(object);
    write_file(output, bytes);
    return 0;
  } catch (const roco::Error& error) {
    std::cerr << "roco_as: " << error.what() << '\n';
    return 1;
  } catch (const std::exception& error) {
    std::cerr << "roco_as: internal error: " << error.what() << '\n';
    return 1;
  }
}
