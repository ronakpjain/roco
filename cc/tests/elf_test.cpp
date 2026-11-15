#include "roco/elf.hpp"

#include "roco/diagnostic.hpp"
#include "roco/object.hpp"

#include <cstdint>
#include <gtest/gtest.h>
#include <span>
#include <vector>

namespace {

using roco::Object;
using roco::Section;
using roco::Symbol;
using roco::kShfAlloc;
using roco::kShfExecInstr;
using roco::kShfWrite;
using roco::kShtNobits;
using roco::kShtProgbits;
using roco::kStbGlobal;
using roco::kStbLocal;
using roco::kSttFunc;
using roco::kSymbolAbsolute;
using roco::kSymbolUndefined;
using roco::isa::Reloc;

Section make_section(std::string name, std::uint32_t type,
                     std::uint64_t flags, std::uint32_t address,
                     std::vector<std::uint8_t> data,
                     std::uint64_t size = 0) {
  Section section;
  section.name = std::move(name);
  section.type = type;
  section.flags = flags;
  section.align = 4;
  section.address = address;
  section.data = std::move(data);
  section.size = section.data.size();
  if (type == kShtNobits) {
    section.size = size;
  }
  return section;
}

Symbol make_symbol(std::string name, std::int64_t section,
                   std::uint32_t value, std::uint8_t binding,
                   std::uint8_t type) {
  Symbol symbol;
  symbol.name = std::move(name);
  symbol.section = section;
  symbol.value = value;
  symbol.binding = binding;
  symbol.type = type;
  return symbol;
}

Object make_object() {
  Object object;
  object.sections.push_back(make_section(".text", kShtProgbits,
                                         kShfAlloc | kShfExecInstr,
                                         0x10000000,
                                         {0x13, 0x05, 0xa0, 0x02,
                                          0x67, 0x80, 0x00, 0x00}));
  object.sections.push_back(make_section(".data", kShtProgbits,
                                         kShfAlloc | kShfWrite,
                                         0x10000008, {1, 2, 3, 4}));
  object.sections.push_back(make_section(".bss", kShtNobits,
                                         kShfAlloc | kShfWrite,
                                         0x1000000c, {}, 16));

  object.symbols.push_back(Symbol{});
  object.symbols.push_back(
      make_symbol(".Llocal", 0, 4, kStbLocal, roco::kSttNoType));
  object.symbols.push_back(
      make_symbol("_start", 0, 0, kStbGlobal, kSttFunc));
  object.symbols.push_back(
      make_symbol("value", 1, 0, kStbGlobal, roco::kSttObject));
  object.symbols.push_back(
      make_symbol("absolute", kSymbolAbsolute, 0x1234, kStbGlobal,
                  roco::kSttNoType));
  object.symbols.push_back(
      make_symbol("external", kSymbolUndefined, 0, kStbGlobal,
                  roco::kSttNoType));

  object.sections[0].relocations.push_back(
      {0, Reloc::Hi20, 1, 0});
  object.sections[0].relocations.push_back(
      {4, Reloc::Lo12I, 3, 4});
  return object;
}

std::uint16_t read_u16(const std::vector<std::uint8_t>& bytes,
                       std::size_t offset) {
  return static_cast<std::uint16_t>(bytes[offset]) |
         static_cast<std::uint16_t>(bytes[offset + 1] << 8);
}

std::uint32_t read_u32(const std::vector<std::uint8_t>& bytes,
                       std::size_t offset) {
  return static_cast<std::uint32_t>(bytes[offset]) |
         (static_cast<std::uint32_t>(bytes[offset + 1]) << 8) |
         (static_cast<std::uint32_t>(bytes[offset + 2]) << 16) |
         (static_cast<std::uint32_t>(bytes[offset + 3]) << 24);
}

TEST(ElfTest, RoundTripsRelocatableObject) {
  const Object original = make_object();
  const std::vector<std::uint8_t> bytes = roco::elf::encode_object(original);
  ASSERT_GT(bytes.size(), 52U);
  EXPECT_EQ(read_u16(bytes, 16), roco::elf::kTypeRel);
  EXPECT_EQ(read_u16(bytes, 18), roco::elf::kMachineRiscV);

  const Object decoded =
      roco::elf::decode(std::span<const std::uint8_t>(bytes));
  ASSERT_EQ(decoded.sections.size(), original.sections.size());
  ASSERT_EQ(decoded.symbols.size(), original.symbols.size());

  for (std::size_t i = 0; i < original.sections.size(); ++i) {
    EXPECT_EQ(decoded.sections[i].name, original.sections[i].name);
    EXPECT_EQ(decoded.sections[i].type, original.sections[i].type);
    EXPECT_EQ(decoded.sections[i].flags, original.sections[i].flags);
    EXPECT_EQ(decoded.sections[i].address, original.sections[i].address);
    EXPECT_EQ(decoded.sections[i].data, original.sections[i].data);
    EXPECT_EQ(decoded.sections[i].size, original.sections[i].size);
  }

  for (std::size_t i = 0; i < original.symbols.size(); ++i) {
    EXPECT_EQ(decoded.symbols[i].name, original.symbols[i].name);
    EXPECT_EQ(decoded.symbols[i].section, original.symbols[i].section);
    EXPECT_EQ(decoded.symbols[i].value, original.symbols[i].value);
    EXPECT_EQ(decoded.symbols[i].binding, original.symbols[i].binding);
    EXPECT_EQ(decoded.symbols[i].type, original.symbols[i].type);
  }

  ASSERT_EQ(decoded.sections[0].relocations.size(), 2U);
  EXPECT_EQ(decoded.sections[0].relocations[0].offset, 0U);
  EXPECT_EQ(decoded.sections[0].relocations[0].type, Reloc::Hi20);
  EXPECT_EQ(decoded.sections[0].relocations[0].symbol, 1U);
  EXPECT_EQ(decoded.sections[1].relocations.size(), 0U);
}

TEST(ElfTest, EncodesExecutableProgramHeader) {
  Object object;
  object.sections.push_back(make_section(".text", kShtProgbits,
                                         kShfAlloc | kShfExecInstr,
                                         0x10000000,
                                         {0x13, 0x00, 0x00, 0x00}));
  object.sections.push_back(make_section(".data", kShtProgbits,
                                         kShfAlloc | kShfWrite,
                                         0x10000004, {1, 2, 3, 4}));
  object.sections.push_back(make_section(".bss", kShtNobits,
                                         kShfAlloc | kShfWrite,
                                         0x10000008, {}, 16));
  object.symbols.push_back(Symbol{});
  object.symbols.push_back(
      make_symbol("_start", 0, 0, kStbGlobal, kSttFunc));

  const std::vector<std::uint8_t> bytes =
      roco::elf::encode_executable(object, 0x10000000);
  ASSERT_GT(bytes.size(), 84U);
  EXPECT_EQ(read_u16(bytes, 16), roco::elf::kTypeExec);
  EXPECT_EQ(read_u32(bytes, 24), 0x10000000U);
  EXPECT_EQ(read_u32(bytes, 28), 52U);
  EXPECT_EQ(read_u16(bytes, 44), 1);
  EXPECT_EQ(read_u32(bytes, 52), 1);  // PT_LOAD
  EXPECT_EQ(read_u32(bytes, 60), 0x10000000U);
  EXPECT_EQ(read_u32(bytes, 68), 8U);   // four text + four data bytes
  EXPECT_EQ(read_u32(bytes, 72), 24U);  // includes bss

  const Object decoded =
      roco::elf::decode(std::span<const std::uint8_t>(bytes));
  ASSERT_EQ(decoded.sections.size(), 3U);
  EXPECT_EQ(decoded.sections[0].address, 0x10000000U);
  EXPECT_EQ(decoded.sections[1].address, 0x10000004U);
  EXPECT_EQ(decoded.sections[2].type, kShtNobits);
  EXPECT_EQ(decoded.sections[2].size, 16U);
}

TEST(ElfTest, RejectsMalformedInput) {
  EXPECT_THROW(roco::elf::decode(std::span<const std::uint8_t>()),
               roco::Error);
  const std::vector<std::uint8_t> not_elf(64, 0);
  EXPECT_THROW(roco::elf::decode(
                   std::span<const std::uint8_t>(not_elf)),
               roco::Error);
  const auto bytes = roco::elf::encode_object(make_object());
  const std::vector<std::uint8_t> truncated(bytes.begin(),
                                            bytes.begin() + 30);
  EXPECT_THROW(roco::elf::decode(
                   std::span<const std::uint8_t>(truncated)),
               roco::Error);
}

TEST(ElfTest, RejectsMisorderedSymbols) {
  Object object = make_object();
  object.symbols[1].binding = kStbGlobal;
  object.symbols[2].binding = kStbLocal;
  EXPECT_THROW(roco::elf::encode_object(object), roco::Error);
}

}  // namespace
