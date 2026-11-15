/// @file roco-cc.cpp
/// @brief Command-line driver for the roco-cc compiler.

#include "roco/assembler.hpp"
#include "roco/compiler.hpp"
#include "roco/diagnostic.hpp"
#include "roco/elf.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

void usage() {
  std::cerr << "usage: roco-cc [-S|-c|-E] [-o output] input.c\n";
}

void write_text(const std::filesystem::path& path, const std::string& text) {
  std::ofstream stream(path, std::ios::binary);
  if (!stream) {
    throw roco::Error("cannot open output file '" + path.string() + "'");
  }
  stream.write(text.data(), static_cast<std::streamsize>(text.size()));
  if (!stream) {
    throw roco::Error("failed to write output file '" + path.string() + "'");
  }
}

void write_bytes(const std::filesystem::path& path,
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
  bool emit_object = false;
  bool emit_preprocessed = false;
  std::filesystem::path output;
  std::filesystem::path input;

  for (int i = 1; i < argc; ++i) {
    const std::string argument = argv[i];
    if (argument == "-h" || argument == "--help") {
      usage();
      return 0;
    }
    if (argument == "-S") {
      emit_object = false;
      continue;
    }
    if (argument == "-c") {
      emit_object = true;
      continue;
    }
    if (argument == "-E") {
      emit_preprocessed = true;
      continue;
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
      std::cerr << "roco-cc: unknown option '" << argument << "'\n";
      usage();
      return 2;
    }
    if (!input.empty()) {
      std::cerr << "roco-cc: multiple input files are not supported\n";
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
    output.replace_extension(emit_preprocessed ? ".i" : (emit_object ? ".o" : ".s"));
  }

  try {
    if (emit_preprocessed) {
      write_text(output, roco::preprocess_file(input.string()));
      return 0;
    }
    if (!emit_object) {
      write_text(output, roco::compile_file(input.string()));
      return 0;
    }
    const std::string assembly = roco::compile_file(input.string());
    const roco::Object object = roco::assemble(assembly, input.string());
    write_bytes(output, roco::elf::encode_object(object));
    return 0;
  } catch (const roco::Error& error) {
    std::cerr << "roco-cc: " << error.what() << '\n';
    return 1;
  } catch (const std::exception& error) {
    std::cerr << "roco-cc: internal error: " << error.what() << '\n';
    return 1;
  }
}
