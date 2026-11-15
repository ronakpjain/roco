#pragma once

#include "roco/isa.hpp"

#include <cstdint>
#include <string>
#include <vector>

/** @file object.hpp
 *  @brief In-memory relocatable object model shared by assembler and linker.
 */

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

/** @brief One RELA relocation attached to a section. */
struct Relocation {
  std::uint32_t offset = 0;         ///< Byte offset in the target section.
  isa::Reloc type = isa::Reloc::None; ///< ELF relocation kind.
  std::uint32_t symbol = 0;         ///< Index into Object::symbols.
  std::int64_t addend = 0;          ///< Explicit RELA addend.
};

/** @brief One output or input section and its relocation records. */
struct Section {
  std::string name;                 ///< ELF section name, such as `.text`.
  std::uint32_t type = kShtProgbits; ///< ELF section type.
  std::uint64_t flags = 0;          ///< ELF SHF_* flags.
  std::uint64_t align = 4;          ///< Required alignment in bytes.
  std::uint32_t address = 0;        ///< Runtime address for ET_EXEC output.
  std::uint64_t size = 0;           ///< Size; required for NOBITS sections.
  std::vector<std::uint8_t> data;   ///< File bytes for PROGBITS sections.
  std::vector<Relocation> relocations; ///< Relocations targeting this section.

  /** @brief Whether the section occupies no file bytes. */
  [[nodiscard]] bool is_bss() const { return type == kShtNobits; }
  /** @brief Number of bytes that appear in the file. */
  [[nodiscard]] std::uint64_t content_size() const {
    return is_bss() ? 0 : data.size();
  }
  /** @brief Number of bytes occupied in memory, including zero-filled bss. */
  [[nodiscard]] std::uint64_t total_size() const {
    return is_bss() ? size : data.size();
  }
};

/** @brief One ELF symbol table entry.
 *
 * `section` is an index into Object::sections, or one of the
 * kSymbolUndefined and kSymbolAbsolute sentinels.
 */
struct Symbol {
  std::string name;                 ///< Linker-visible name; empty for section symbols.
  std::int64_t section = kSymbolUndefined; ///< Defining section or sentinel.
  std::uint32_t value = 0;          ///< Offset in the section, or absolute value.
  std::uint32_t size = 0;           ///< Object size when known.
  std::uint8_t binding = kStbLocal; ///< STB_LOCAL, STB_GLOBAL, or STB_WEAK.
  std::uint8_t type = kSttNoType;   ///< STT_* symbol type.
};

/** @brief A complete relocatable object or linked image.
 *
 * The assembler, ELF reader, and linker exchange this representation.
 * `symbols[0]` must be the ELF null symbol in every serialized object.
 */
struct Object {
  std::vector<Section> sections; ///< Content sections in output order.
  std::vector<Symbol> symbols;   ///< ELF symbol table; index zero is null.
};

/** @brief Whether a symbol has a section or absolute definition. */
inline bool is_defined(const Symbol& symbol) {
  return symbol.section != kSymbolUndefined;
}

/** @brief Whether a symbol has an absolute value. */
inline bool is_absolute(const Symbol& symbol) {
  return symbol.section == kSymbolAbsolute;
}

/** @brief Whether a symbol has local binding. */
inline bool is_local(const Symbol& symbol) {
  return symbol.binding == kStbLocal;
}

}  // namespace roco
