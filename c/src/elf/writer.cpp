/// @file writer.cpp
/// @brief ELF32 relocatable and executable serialization.

#include "roco/elf.hpp"

#include "elf/common.hpp"

#include "roco/diagnostic.hpp"
#include "roco/isa.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

namespace roco::elf {
namespace {

struct OutputSection {
  std::string name;
  std::uint32_t name_offset = 0;
  std::uint32_t type = 0;
  std::uint64_t flags = 0;
  std::uint32_t address = 0;
  std::uint64_t align = 1;
  std::uint64_t size = 0;
  std::uint32_t offset = 0;
  std::uint32_t link = 0;
  std::uint32_t info = 0;
  std::uint64_t entsize = 0;
  const std::vector<std::uint8_t>* data = nullptr;
};

void validate_object(const Object& object) {
  for (std::size_t i = 0; i < object.sections.size(); ++i) {
    const Section& section = object.sections[i];
    if (!is_power_of_two(section.align)) {
      throw Error("section " + section.name + " has invalid alignment");
    }
    if (section.is_bss()) {
      if (!section.data.empty()) {
        throw Error("bss section " + section.name + " has file data");
      }
    } else if (section.size != 0 && section.size != section.data.size()) {
      throw Error("section " + section.name +
                  " has inconsistent size and data");
    }
  }

  bool seen_global = false;
  for (std::size_t i = 1; i < object.symbols.size(); ++i) {
    const Symbol& symbol = object.symbols[i];
    if (symbol.binding == kStbLocal) {
      if (seen_global) {
        throw Error("ELF symbol table must place local symbols before globals");
      }
    } else {
      seen_global = true;
    }
    if (symbol.section >= 0 &&
        static_cast<std::size_t>(symbol.section) >= object.sections.size()) {
      throw Error("symbol " + symbol.name + " refers to a missing section");
    }
  }
}

std::uint32_t section_elf_index(const Symbol& symbol,
                                const Object& object) {
  if (symbol.section == kSymbolUndefined) {
    return kShnUndef;
  }
  if (symbol.section == kSymbolAbsolute) {
    return kShnAbs;
  }
  if (symbol.section < 0 ||
      static_cast<std::size_t>(symbol.section) >= object.sections.size()) {
    throw Error("symbol " + symbol.name + " refers to a missing section");
  }
  return static_cast<std::uint32_t>(symbol.section) + 1;
}

std::vector<std::uint8_t> encode(const Object& object, bool executable,
                                 std::uint32_t entry) {
  validate_object(object);

  if (object.symbols.empty()) {
    throw Error("object has no symbol table");
  }
  if (object.symbols[0].name.empty() == false ||
      object.symbols[0].section != kSymbolUndefined) {
    throw Error("symbol table entry zero must be the null symbol");
  }

  std::vector<OutputSection> sections;
  sections.reserve(object.sections.size() + object.symbols.size() / 4 + 4);

  // ELF section index zero is reserved for the null section.
  const std::uint32_t first_section_index = 1;

  for (std::size_t i = 0; i < object.sections.size(); ++i) {
    const Section& source = object.sections[i];
    OutputSection section;
    section.name = source.name;
    section.type = source.type;
    section.flags = source.flags;
    section.address = source.address;
    section.align = std::max<std::uint64_t>(1, source.align);
    section.size = source.total_size();
    if (!source.is_bss()) {
      section.data = &source.data;
    }
    sections.push_back(std::move(section));
  }

  // Build relocation section payloads first; they refer to symbol indices,
  // which are preserved exactly in the output symbol table.
  std::vector<std::vector<std::uint8_t>> relocation_data;
  struct PendingRelocation {
    std::size_t target_section;
    std::size_t payload;
  };
  std::vector<PendingRelocation> pending_relocations;

  for (std::size_t i = 0; i < object.sections.size(); ++i) {
    const Section& source = object.sections[i];
    if (source.relocations.empty()) {
      continue;
    }
    Buffer payload;
    payload.reserve(source.relocations.size() * kRelaSize);
    for (const Relocation& relocation : source.relocations) {
      if (relocation.symbol >= object.symbols.size()) {
        throw Error("relocation in " + source.name +
                    " refers to a missing symbol");
      }
      payload.u32(relocation.offset);
      payload.u32((relocation.symbol << 8) |
                  static_cast<std::uint32_t>(relocation.type));
      payload.u32(static_cast<std::uint32_t>(relocation.addend));
    }
    relocation_data.push_back(std::move(payload.bytes));
    pending_relocations.push_back({i, relocation_data.size() - 1});
  }

  const std::uint32_t symtab_index = static_cast<std::uint32_t>(
      first_section_index + sections.size() + pending_relocations.size());

  // Relocation section metadata.
  for (const PendingRelocation& pending : pending_relocations) {
    OutputSection section;
    const std::string& target = object.sections[pending.target_section].name;
    section.name = target.empty() ? ".rela" : ".rela" + target;
    section.type = kShtRela;
    section.align = 4;
    section.entsize = kRelaSize;
    section.size = relocation_data[pending.payload].size();
    section.data = &relocation_data[pending.payload];
    section.link = symtab_index;
    section.info = static_cast<std::uint32_t>(pending.target_section) + 1;
    sections.push_back(std::move(section));
  }

  const std::uint32_t strtab_index = symtab_index + 1;
  const std::uint32_t shstrtab_index = strtab_index + 1;

  // Symbol table and string table.
  std::vector<std::uint8_t> symbol_data;
  std::vector<std::uint8_t> string_data;
  string_data.push_back(0);
  symbol_data.reserve(object.symbols.size() * kSymbolSize);

  std::uint32_t first_global = static_cast<std::uint32_t>(object.symbols.size());
  bool seen_global = false;
  for (std::size_t i = 0; i < object.symbols.size(); ++i) {
    const Symbol& symbol = object.symbols[i];
    const bool local = symbol.binding == kStbLocal;
    if (!local && !seen_global) {
      first_global = static_cast<std::uint32_t>(i);
      seen_global = true;
    }
    if (local && seen_global) {
      throw Error("ELF symbol table must place local symbols before globals");
    }

    std::uint32_t name_offset = 0;
    if (!symbol.name.empty()) {
      name_offset = static_cast<std::uint32_t>(string_data.size());
      string_data.insert(string_data.end(), symbol.name.begin(),
                         symbol.name.end());
      string_data.push_back(0);
    }

    Buffer symbol_entry;
    symbol_entry.u32(name_offset);
    symbol_entry.u32(symbol.value);
    symbol_entry.u32(symbol.size);
    symbol_entry.u8(static_cast<std::uint8_t>((symbol.binding << 4) |
                                              (symbol.type & 0x0f)));
    symbol_entry.u8(0);
    symbol_entry.u16(static_cast<std::uint16_t>(
        section_elf_index(symbol, object)));
    symbol_data.insert(symbol_data.end(), symbol_entry.bytes.begin(),
                       symbol_entry.bytes.end());
  }

  OutputSection symtab;
  symtab.name = ".symtab";
  symtab.type = kShtSymtab;
  symtab.align = 4;
  symtab.entsize = kSymbolSize;
  symtab.size = symbol_data.size();
  symtab.data = &symbol_data;
  symtab.link = strtab_index;
  symtab.info = first_global;
  sections.push_back(std::move(symtab));

  OutputSection strtab;
  strtab.name = ".strtab";
  strtab.type = kShtStrtab;
  strtab.align = 1;
  strtab.size = string_data.size();
  strtab.data = &string_data;
  sections.push_back(std::move(strtab));

  // Section name table, including its own name.
  std::vector<std::uint8_t> shstrtab_data;
  shstrtab_data.push_back(0);
  for (OutputSection& section : sections) {
    section.name_offset = static_cast<std::uint32_t>(shstrtab_data.size());
    shstrtab_data.insert(shstrtab_data.end(), section.name.begin(),
                         section.name.end());
    shstrtab_data.push_back(0);
  }
  const std::uint32_t shstrtab_name_offset =
      static_cast<std::uint32_t>(shstrtab_data.size());
  for (const char character : std::string_view(".shstrtab")) {
    shstrtab_data.push_back(static_cast<std::uint8_t>(character));
  }
  shstrtab_data.push_back(0);

  OutputSection shstrtab;
  shstrtab.name = ".shstrtab";
  shstrtab.name_offset = shstrtab_name_offset;
  shstrtab.type = kShtStrtab;
  shstrtab.align = 1;
  shstrtab.size = shstrtab_data.size();
  shstrtab.data = &shstrtab_data;
  sections.push_back(std::move(shstrtab));

  Buffer out;
  out.reserve(4096);
  out.zeros(kHeaderSize);
  if (executable) {
    out.zeros(kProgramHeaderSize);
  }

  for (OutputSection& section : sections) {
    out.align(static_cast<std::size_t>(section.align));
    section.offset = static_cast<std::uint32_t>(out.bytes.size());
    if (section.data != nullptr) {
      out.append(*section.data);
    }
  }

  out.align(4);
  const std::uint32_t section_header_offset =
      static_cast<std::uint32_t>(out.bytes.size());
  out.zeros(kSectionHeaderSize);  // section header zero is reserved
  for (const OutputSection& section : sections) {
    out.u32(section.name_offset);
    out.u32(section.type);
    out.u32(static_cast<std::uint32_t>(section.flags));
    out.u32(section.address);
    out.u32(section.offset);
    out.u32(static_cast<std::uint32_t>(section.size));
    out.u32(section.link);
    out.u32(section.info);
    out.u32(static_cast<std::uint32_t>(section.align));
    out.u32(static_cast<std::uint32_t>(section.entsize));
  }

  // ELF header.
  out.bytes[0] = 0x7f;
  out.bytes[1] = 'E';
  out.bytes[2] = 'L';
  out.bytes[3] = 'F';
  out.bytes[4] = 1;  // ELFCLASS32
  out.bytes[5] = 1;  // ELFDATA2LSB
  out.bytes[6] = 1;  // EV_CURRENT
  out.bytes[7] = 0;  // ELFOSABI_SYSV
  out.patch_u16(16, executable ? kTypeExec : kTypeRel);
  out.patch_u16(18, kMachineRiscV);
  out.patch_u32(20, 1);
  out.patch_u32(24, entry);
  out.patch_u32(28, executable ? kHeaderSize : 0);
  out.patch_u32(32, section_header_offset);
  out.patch_u32(36, 0);  // e_flags: soft-float ILP32
  out.patch_u16(40, static_cast<std::uint16_t>(kHeaderSize));
  out.patch_u16(42, static_cast<std::uint16_t>(
                        executable ? kProgramHeaderSize : 0));
  out.patch_u16(44, executable ? 1 : 0);
  out.patch_u16(46, static_cast<std::uint16_t>(kSectionHeaderSize));
  out.patch_u16(48, static_cast<std::uint16_t>(sections.size() + 1));
  out.patch_u16(50, static_cast<std::uint16_t>(shstrtab_index));

  if (executable) {
    const OutputSection* first_alloc = nullptr;
    const OutputSection* last_alloc = nullptr;
    const OutputSection* last_file = nullptr;
    for (const OutputSection& section : sections) {
      if ((section.flags & kShfAlloc) == 0) {
        continue;
      }
      if (first_alloc == nullptr ||
          section.address < first_alloc->address) {
        first_alloc = &section;
      }
      if (last_alloc == nullptr ||
          section.address + section.size >
              last_alloc->address + last_alloc->size) {
        last_alloc = &section;
      }
      if (section.data != nullptr &&
          (last_file == nullptr ||
           section.address + section.size >
               last_file->address + last_file->size)) {
        last_file = &section;
      }
    }
    if (first_alloc != nullptr && last_alloc != nullptr) {
      const std::uint32_t file_end =
          last_file == nullptr
              ? first_alloc->address
              : last_file->address +
                    static_cast<std::uint32_t>(last_file->size);
      const std::uint32_t memory_end =
          last_alloc->address +
          static_cast<std::uint32_t>(last_alloc->size);
      out.patch_u32(kHeaderSize + 0, 1);  // PT_LOAD
      out.patch_u32(kHeaderSize + 4, first_alloc->offset);
      out.patch_u32(kHeaderSize + 8, first_alloc->address);
      out.patch_u32(kHeaderSize + 12, first_alloc->address);
      out.patch_u32(kHeaderSize + 16, file_end - first_alloc->address);
      out.patch_u32(kHeaderSize + 20, memory_end - first_alloc->address);
      out.patch_u32(kHeaderSize + 24, 7);  // PF_R | PF_W | PF_X
      out.patch_u32(kHeaderSize + 28, 4);
    }
  }

  return std::move(out.bytes);
}

}  // namespace

std::vector<std::uint8_t> encode_object(const Object& object) {
  return encode(object, false, 0);
}

std::vector<std::uint8_t> encode_executable(const Object& object,
                                            std::uint32_t entry) {
  return encode(object, true, entry);
}

}  // namespace roco::elf
