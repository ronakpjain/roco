#pragma once

/// @file section.hpp
/// @brief Assembler section and symbol bookkeeping.

#include "roco/isa.hpp"
#include "roco/object.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace roco::cc_asm {

struct AsmSymbol {
  std::string name;
  std::int64_t section = kSymbolUndefined;
  std::uint32_t value = 0;
  std::uint32_t size = 0;
  bool global = false;
  bool defined = false;
  std::uint8_t type = kSttNoType;
};

struct PendingRelocation {
  std::uint32_t offset = 0;
  isa::Reloc type = isa::Reloc::None;
  std::string symbol;
  std::int64_t addend = 0;
};

struct AsmSection {
  std::string name;
  std::uint32_t type = kShtProgbits;
  std::uint64_t flags = 0;
  std::uint64_t align = 4;
  std::vector<std::uint8_t> data;
  std::uint64_t bss_size = 0;
  std::vector<PendingRelocation> relocations;

  [[nodiscard]] std::uint64_t offset() const {
    return type == kShtNobits ? bss_size : data.size();
  }
};


}  // namespace roco::cc_asm
