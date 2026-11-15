/// \file elf.cpp
/// \brief ELF32 reader and writer for roco objects and executables.

#include "roco/elf.hpp"

#include "roco/diagnostic.hpp"
#include "roco/isa.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

namespace roco::elf {
namespace {

constexpr std::uint32_t kShnUndef = 0;
constexpr std::uint32_t kShnAbs = 0xfff1;
constexpr std::size_t kHeaderSize = 52;
constexpr std::size_t kSectionHeaderSize = 40;
constexpr std::size_t kProgramHeaderSize = 32;
constexpr std::size_t kSymbolSize = 16;
constexpr std::size_t kRelaSize = 12;

struct SectionHeader {
  std::uint32_t name = 0;
  std::uint32_t type = 0;
  std::uint32_t flags = 0;
  std::uint32_t address = 0;
  std::uint32_t offset = 0;
  std::uint32_t size = 0;
  std::uint32_t link = 0;
  std::uint32_t info = 0;
  std::uint32_t align = 0;
  std::uint32_t entsize = 0;
};

class Buffer {
 public:
  std::vector<std::uint8_t> bytes;

  void reserve(std::size_t size) { bytes.reserve(size); }

  void u8(std::uint8_t value) { bytes.push_back(value); }

  void u16(std::uint16_t value) {
    bytes.push_back(static_cast<std::uint8_t>(value));
    bytes.push_back(static_cast<std::uint8_t>(value >> 8));
  }

  void u32(std::uint32_t value) {
    bytes.push_back(static_cast<std::uint8_t>(value));
    bytes.push_back(static_cast<std::uint8_t>(value >> 8));
    bytes.push_back(static_cast<std::uint8_t>(value >> 16));
    bytes.push_back(static_cast<std::uint8_t>(value >> 24));
  }

  void append(const void* data, std::size_t size) {
    const auto* first = static_cast<const std::uint8_t*>(data);
    bytes.insert(bytes.end(), first, first + size);
  }

  void append(const std::vector<std::uint8_t>& data) {
    bytes.insert(bytes.end(), data.begin(), data.end());
  }

  void zeros(std::size_t count) { bytes.insert(bytes.end(), count, 0); }

  void align(std::size_t alignment) {
    if (alignment == 0) {
      alignment = 1;
    }
    const std::size_t remainder = bytes.size() % alignment;
    if (remainder != 0) {
      zeros(alignment - remainder);
    }
  }

  void patch_u16(std::size_t offset, std::uint16_t value) {
    if (offset + 2 > bytes.size()) {
      throw Error("internal error: ELF patch out of range");
    }
    bytes[offset] = static_cast<std::uint8_t>(value);
    bytes[offset + 1] = static_cast<std::uint8_t>(value >> 8);
  }

  void patch_u32(std::size_t offset, std::uint32_t value) {
    if (offset + 4 > bytes.size()) {
      throw Error("internal error: ELF patch out of range");
    }
    bytes[offset] = static_cast<std::uint8_t>(value);
    bytes[offset + 1] = static_cast<std::uint8_t>(value >> 8);
    bytes[offset + 2] = static_cast<std::uint8_t>(value >> 16);
    bytes[offset + 3] = static_cast<std::uint8_t>(value >> 24);
  }
};

class Reader {
 public:
  explicit Reader(std::span<const std::uint8_t> bytes) : bytes_(bytes) {}

  void require(std::size_t offset, std::size_t size,
               const char* what) const {
    if (offset > bytes_.size() || size > bytes_.size() - offset) {
      throw Error(std::string("malformed ELF: truncated ") + what);
    }
  }

  std::uint8_t u8(std::size_t offset, const char* what) const {
    require(offset, 1, what);
    return bytes_[offset];
  }

  std::uint16_t u16(std::size_t offset, const char* what) const {
    require(offset, 2, what);
    return static_cast<std::uint16_t>(bytes_[offset]) |
           static_cast<std::uint16_t>(bytes_[offset + 1] << 8);
  }

  std::uint32_t u32(std::size_t offset, const char* what) const {
    require(offset, 4, what);
    return static_cast<std::uint32_t>(bytes_[offset]) |
           (static_cast<std::uint32_t>(bytes_[offset + 1]) << 8) |
           (static_cast<std::uint32_t>(bytes_[offset + 2]) << 16) |
           (static_cast<std::uint32_t>(bytes_[offset + 3]) << 24);
  }

  std::int32_t i32(std::size_t offset, const char* what) const {
    const auto value = u32(offset, what);
    return static_cast<std::int32_t>(value);
  }

  const std::uint8_t* data(std::size_t offset) const {
    return bytes_.data() + offset;
  }

  [[nodiscard]] std::size_t size() const { return bytes_.size(); }

 private:
  std::span<const std::uint8_t> bytes_;
};

std::string read_string(std::span<const std::uint8_t> table,
                        std::uint32_t offset, const char* what) {
  if (offset >= table.size()) {
    throw Error(std::string("malformed ELF: ") + what + " string out of range");
  }
  const auto* first = table.data() + offset;
  const auto* last = std::find(first, table.data() + table.size(), 0);
  if (last == table.data() + table.size()) {
    throw Error(std::string("malformed ELF: unterminated ") + what +
                " string");
  }
  return std::string(reinterpret_cast<const char*>(first),
                     reinterpret_cast<const char*>(last));
}

std::vector<std::uint8_t> slice(std::span<const std::uint8_t> bytes,
                                std::uint32_t offset, std::uint32_t size) {
  if (offset > bytes.size() || size > bytes.size() - offset) {
    throw Error("malformed ELF: section data out of range");
  }
  return {bytes.begin() + offset, bytes.begin() + offset + size};
}

bool is_power_of_two(std::uint64_t value) {
  return value != 0 && (value & (value - 1)) == 0;
}

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
