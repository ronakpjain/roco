/// @file reader.cpp
/// @brief ELF32 RISC-V relocatable-object reader.

#include "roco/elf.hpp"

#include "elf/common.hpp"

#include "roco/diagnostic.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace roco::elf {

Object decode(std::span<const std::uint8_t> bytes) {
  Reader reader(bytes);
  reader.require(0, kHeaderSize, "ELF header");
  if (reader.u8(0, "ELF header") != 0x7f ||
      reader.u8(1, "ELF header") != 'E' ||
      reader.u8(2, "ELF header") != 'L' ||
      reader.u8(3, "ELF header") != 'F') {
    throw Error("not an ELF file");
  }
  if (reader.u8(4, "ELF header") != 1) {
    throw Error("only ELF32 files are supported");
  }
  if (reader.u8(5, "ELF header") != 1) {
    throw Error("only little-endian ELF files are supported");
  }
  const std::uint16_t type = reader.u16(16, "ELF header");
  if (type != kTypeRel && type != kTypeExec) {
    throw Error("unsupported ELF file type");
  }
  if (reader.u16(18, "ELF header") != kMachineRiscV) {
    throw Error("ELF file is not for RISC-V");
  }

  const std::uint32_t section_offset = reader.u32(32, "ELF header");
  const std::uint16_t section_entry_size =
      reader.u16(46, "ELF header");
  const std::uint16_t section_count = reader.u16(48, "ELF header");
  const std::uint16_t shstrtab_index = reader.u16(50, "ELF header");
  if (section_count == 0) {
    throw Error("ELF file has no sections");
  }
  if (section_entry_size < kSectionHeaderSize) {
    throw Error("ELF section header size is too small");
  }
  reader.require(section_offset,
                 static_cast<std::size_t>(section_count) *
                     section_entry_size,
                 "section headers");

  std::vector<SectionHeader> headers(section_count);
  for (std::uint16_t i = 0; i < section_count; ++i) {
    const std::size_t offset =
        section_offset + static_cast<std::size_t>(i) * section_entry_size;
    SectionHeader& header = headers[i];
    header.name = reader.u32(offset, "section header");
    header.type = reader.u32(offset + 4, "section header");
    header.flags = reader.u32(offset + 8, "section header");
    header.address = reader.u32(offset + 12, "section header");
    header.offset = reader.u32(offset + 16, "section header");
    header.size = reader.u32(offset + 20, "section header");
    header.link = reader.u32(offset + 24, "section header");
    header.info = reader.u32(offset + 28, "section header");
    header.align = reader.u32(offset + 32, "section header");
    header.entsize = reader.u32(offset + 36, "section header");
  }

  if (shstrtab_index >= section_count ||
      headers[shstrtab_index].type != kShtStrtab) {
    throw Error("ELF section name table is invalid");
  }
  const auto shstrtab = slice(bytes, headers[shstrtab_index].offset,
                              headers[shstrtab_index].size);

  auto name_of = [&](std::uint32_t section_index) {
    return read_string(shstrtab, headers[section_index].name,
                       "section name");
  };

  Object object;
  std::vector<std::int64_t> header_to_object(section_count, -1);

  for (std::uint16_t i = 1; i < section_count; ++i) {
    const SectionHeader& header = headers[i];
    if (header.type == kShtNull || header.type == kShtSymtab ||
        header.type == kShtStrtab || header.type == kShtRela) {
      continue;
    }
    Section section;
    section.name = name_of(i);
    section.type = header.type;
    section.flags = header.flags;
    section.align = header.align == 0 ? 1 : header.align;
    section.address = header.address;
    section.size = header.size;
    if (header.type != kShtNobits) {
      section.data = slice(bytes, header.offset, header.size);
      section.size = section.data.size();
    }
    header_to_object[i] = static_cast<std::int64_t>(object.sections.size());
    object.sections.push_back(std::move(section));
  }

  // Locate the (single) symbol table.
  int symbol_table_index = -1;
  for (std::uint16_t i = 0; i < section_count; ++i) {
    if (headers[i].type == kShtSymtab) {
      if (symbol_table_index >= 0) {
        throw Error("multiple symbol tables are not supported");
      }
      symbol_table_index = i;
    }
  }

  if (symbol_table_index >= 0) {
    const SectionHeader& symtab = headers[static_cast<std::size_t>(
        symbol_table_index)];
    if (symtab.link >= section_count ||
        headers[symtab.link].type != kShtStrtab) {
      throw Error("ELF symbol string table is invalid");
    }
    if (symtab.entsize != 0 && symtab.entsize < kSymbolSize) {
      throw Error("ELF symbol entry size is too small");
    }
    const auto strings = slice(bytes, headers[symtab.link].offset,
                               headers[symtab.link].size);
    const std::size_t count = symtab.size / kSymbolSize;
    for (std::size_t i = 0; i < count; ++i) {
      const std::size_t offset =
          symtab.offset + i * kSymbolSize;
      reader.require(offset, kSymbolSize, "symbol table");
      const std::uint32_t name_offset =
          reader.u32(offset, "symbol table");
      const std::uint32_t value = reader.u32(offset + 4, "symbol table");
      const std::uint32_t size = reader.u32(offset + 8, "symbol table");
      const std::uint8_t info = reader.u8(offset + 12, "symbol table");
      const std::uint16_t shndx = reader.u16(offset + 14, "symbol table");

      Symbol symbol;
      symbol.name = read_string(strings, name_offset, "symbol name");
      symbol.value = value;
      symbol.size = size;
      symbol.binding = static_cast<std::uint8_t>(info >> 4);
      symbol.type = static_cast<std::uint8_t>(info & 0x0f);
      if (shndx == kShnUndef) {
        symbol.section = kSymbolUndefined;
      } else if (shndx == kShnAbs) {
        symbol.section = kSymbolAbsolute;
      } else if (shndx < section_count &&
                 header_to_object[shndx] >= 0) {
        symbol.section = header_to_object[shndx];
      } else {
        // A symbol in a metadata section is irrelevant to linking.
        symbol.section = kSymbolUndefined;
      }
      object.symbols.push_back(std::move(symbol));
    }
  }

  // Attach relocation records to their target sections.
  for (std::uint16_t i = 0; i < section_count; ++i) {
    const SectionHeader& header = headers[i];
    if (header.type != kShtRela) {
      continue;
    }
    if (symbol_table_index < 0 ||
        header.link != static_cast<std::uint32_t>(symbol_table_index)) {
      throw Error("relocation section uses an unsupported symbol table");
    }
    if (header.info >= section_count ||
        header_to_object[header.info] < 0) {
      continue;
    }
    if (header.entsize != 0 && header.entsize < kRelaSize) {
      throw Error("ELF relocation entry size is too small");
    }
    Section& target =
        object.sections[static_cast<std::size_t>(
            header_to_object[header.info])];
    const std::size_t count = header.size / kRelaSize;
    for (std::size_t j = 0; j < count; ++j) {
      const std::size_t offset = header.offset + j * kRelaSize;
      reader.require(offset, kRelaSize, "relocation table");
      const std::uint32_t relocation_offset =
          reader.u32(offset, "relocation table");
      const std::uint32_t info = reader.u32(offset + 4, "relocation table");
      const std::int32_t addend = reader.i32(offset + 8, "relocation table");
      const std::uint32_t symbol = info >> 8;
      if (symbol >= object.symbols.size()) {
        throw Error("relocation refers to a missing symbol");
      }
      Relocation relocation;
      relocation.offset = relocation_offset;
      relocation.type = static_cast<isa::Reloc>(info & 0xff);
      relocation.symbol = symbol;
      relocation.addend = addend;
      target.relocations.push_back(relocation);
    }
  }

  return object;
}

}  // namespace roco::elf
