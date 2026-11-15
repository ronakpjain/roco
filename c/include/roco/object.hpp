#pragma once

#include "roco/isa.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace roco {

// ELF section types and flags used by the toolchain.
inline constexpr std::uint32_t kShtNull = 0;
inline constexpr std::uint32_t kShtProgbits = 1;
inline constexpr std::uint32_t kShtSymtab = 2;
inline constexpr std::uint32_t kShtStrtab = 3;
inline constexpr std::uint32_t kShtRela = 4;
inline constexpr std::uint32_t kShtNobits = 8;

inline constexpr std::uint64_t kShfWrite = 1;
inline constexpr std::uint64_t kShfAlloc = 2;
inline constexpr std::uint64_t kShfExecInstr = 4;

inline constexpr std::uint8_t kStbLocal = 0;
inline constexpr std::uint8_t kStbGlobal = 1;
inline constexpr std::uint8_t kStbWeak = 2;

inline constexpr std::uint8_t kSttNoType = 0;
inline constexpr std::uint8_t kSttObject = 1;
inline constexpr std::uint8_t kSttFunc = 2;
inline constexpr std::uint8_t kSttSection = 3;
inline constexpr std::uint8_t kSttFile = 4;

inline constexpr std::int64_t kSymbolUndefined = -1;
inline constexpr std::int64_t kSymbolAbsolute = -2;

struct Relocation {
  std::uint32_t offset = 0;
  isa::Reloc type = isa::Reloc::None;
  std::uint32_t symbol = 0;
  std::int64_t addend = 0;
};

struct Section {
  std::string name;
  std::uint32_t type = kShtProgbits;
  std::uint64_t flags = 0;
  std::uint64_t align = 4;
  std::uint32_t address = 0;
  std::uint64_t size = 0;
  std::vector<std::uint8_t> data;
  std::vector<Relocation> relocations;

  [[nodiscard]] bool is_bss() const { return type == kShtNobits; }
  [[nodiscard]] std::uint64_t content_size() const {
    return is_bss() ? 0 : data.size();
  }
  [[nodiscard]] std::uint64_t total_size() const {
    return is_bss() ? size : data.size();
  }
};

struct Symbol {
  std::string name;
  // Index into Object::sections, kSymbolUndefined, or kSymbolAbsolute.
  std::int64_t section = kSymbolUndefined;
  std::uint32_t value = 0;
  std::uint32_t size = 0;
  std::uint8_t binding = kStbLocal;
  std::uint8_t type = kSttNoType;
};

struct Object {
  std::vector<Section> sections;
  // symbols[0] is the ELF null symbol.
  std::vector<Symbol> symbols;
};

inline bool is_defined(const Symbol& symbol) {
  return symbol.section != kSymbolUndefined;
}

inline bool is_absolute(const Symbol& symbol) {
  return symbol.section == kSymbolAbsolute;
}

inline bool is_local(const Symbol& symbol) {
  return symbol.binding == kStbLocal;
}

}  // namespace roco
