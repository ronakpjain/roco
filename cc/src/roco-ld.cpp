/// @file roco-ld.cpp
/// @brief Command-line driver for the roco static linker.

#include "roco/diagnostic.hpp"
#include "roco/elf.hpp"
#include "roco/linker.hpp"

#include <charconv>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <span>
#include <string>
#include <vector>

namespace {

void usage() {
  std::cerr << "usage: roco-ld [-o output.elf] [--binary output.bin] "
               "[--hex output.hex] [-e symbol] [--base address] "
               "[-Map map.txt] input.o...\n";
}

std::vector<std::uint8_t> read_file(const std::filesystem::path& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) {
    throw roco::Error("cannot open input file '" + path.string() + "'");
  }
  return {std::istreambuf_iterator<char>(stream),
          std::istreambuf_iterator<char>()};
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

std::uint32_t parse_address(const std::string& text) {
  const char* first = text.data();
  int base = 10;
  if (text.size() > 2 && text[0] == '0' &&
      (text[1] == 'x' || text[1] == 'X')) {
    first += 2;
    base = 16;
  }
  unsigned value = 0;
  const auto result =
      std::from_chars(first, text.data() + text.size(), value, base);
  if (result.ec != std::errc{} || result.ptr != text.data() + text.size()) {
    throw roco::Error("invalid address '" + text + "'");
  }
  return value;
}

void write_hex(const std::filesystem::path& path,
               const std::vector<std::uint8_t>& image) {
  std::ofstream stream(path);
  if (!stream) {
    throw roco::Error("cannot open hex output file '" + path.string() + "'");
  }
  const std::size_t words = (image.size() + 3) / 4;
  stream << std::hex << std::setfill('0');
  for (std::size_t i = 0; i < words; ++i) {
    std::uint32_t word = 0;
    for (std::size_t byte = 0; byte < 4; ++byte) {
      const std::size_t index = i * 4 + byte;
      if (index < image.size()) {
        word |= static_cast<std::uint32_t>(image[index]) << (8 * byte);
      }
    }
    stream << std::setw(8) << word << '\n';
  }
}

void write_map(const std::filesystem::path& path,
               const roco::LinkResult& result) {
  std::ofstream stream(path);
  if (!stream) {
    throw roco::Error("cannot open map file '" + path.string() + "'");
  }
  stream << std::hex << std::setfill('0');
  stream << "entry 0x" << std::setw(8) << result.entry << "\n\n";
  stream << "sections:\n";
  for (const roco::Section& section : result.image.sections) {
    stream << "  0x" << std::setw(8) << section.address << " 0x"
           << std::setw(8) << section.size << " " << section.name << "\n";
  }
  stream << "\nsymbols:\n";
  for (const roco::Symbol& symbol : result.image.symbols) {
    if (symbol.name.empty() || symbol.section == roco::kSymbolUndefined) {
      continue;
    }
    std::uint32_t address = symbol.value;
    if (symbol.section >= 0 &&
        static_cast<std::size_t>(symbol.section) <
            result.image.sections.size()) {
      address += result.image.sections[static_cast<std::size_t>(
                     symbol.section)]
                     .address;
    }
    stream << "  0x" << std::setw(8) << address << " " << symbol.name << "\n";
  }
}

}  // namespace

int main(int argc, char** argv) {
  std::filesystem::path output = "a.elf";
  std::filesystem::path binary;
  std::filesystem::path hex;
  std::filesystem::path map;
  roco::LinkOptions options;
  std::vector<std::filesystem::path> inputs;

  for (int i = 1; i < argc; ++i) {
    const std::string argument = argv[i];
    if (argument == "-h" || argument == "--help") {
      usage();
      return 0;
    }
    if (argument == "-o" || argument == "--binary" || argument == "--hex" ||
        argument == "-e" || argument == "--base" || argument == "-Map" ||
        argument == "--map") {
      if (i + 1 >= argc) {
        usage();
        return 2;
      }
      const std::string value = argv[++i];
      if (argument == "-o") {
        output = value;
      } else if (argument == "--binary") {
        binary = value;
      } else if (argument == "--hex") {
        hex = value;
      } else if (argument == "-e") {
        options.entry_symbol = value;
      } else if (argument == "--base") {
        options.base_address = parse_address(value);
      } else {
        map = value;
      }
      continue;
    }
    if (!argument.empty() && argument[0] == '-') {
      std::cerr << "roco-ld: unknown option '" << argument << "'\n";
      usage();
      return 2;
    }
    inputs.emplace_back(argument);
  }

  if (inputs.empty()) {
    usage();
    return 2;
  }

  try {
    std::vector<roco::Object> objects;
    objects.reserve(inputs.size());
    for (const auto& input : inputs) {
      const auto bytes = read_file(input);
      objects.push_back(
          roco::elf::decode(std::span<const std::uint8_t>(bytes)));
    }

    const roco::LinkResult result = roco::link(objects, options);
    write_file(output, roco::elf::encode_executable(result.image,
                                                     result.entry));
    const std::vector<std::uint8_t> image = roco::flatten(result);
    if (!binary.empty()) {
      write_file(binary, image);
    }
    if (!hex.empty()) {
      write_hex(hex, image);
    }
    if (!map.empty()) {
      write_map(map, result);
    }
    return 0;
  } catch (const roco::Error& error) {
    std::cerr << "roco-ld: " << error.what() << '\n';
    return 1;
  } catch (const std::exception& error) {
    std::cerr << "roco-ld: internal error: " << error.what() << '\n';
    return 1;
  }
}
