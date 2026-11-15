#include "roco/assembler.hpp"
#include "roco/diagnostic.hpp"
#include "roco/isa.hpp"
#include "roco/linker.hpp"

#include <cstdint>
#include <gtest/gtest.h>
#include <string>
#include <vector>

namespace {

using roco::LinkOptions;
using roco::LinkResult;
using roco::Object;
using roco::Section;
using roco::Symbol;

const Section& section(const LinkResult& result, const std::string& name) {
  for (const Section& candidate : result.image.sections) {
    if (candidate.name == name) {
      return candidate;
    }
  }
  throw std::runtime_error("missing section " + name);
}

const Symbol& symbol(const LinkResult& result, const std::string& name) {
  for (const Symbol& candidate : result.image.symbols) {
    if (candidate.name == name) {
      return candidate;
    }
  }
  throw std::runtime_error("missing symbol " + name);
}

std::uint32_t word_at(const Section& section, std::uint32_t address) {
  const std::uint64_t offset = address - section.address;
  if (offset + 4 > section.data.size()) {
    throw std::runtime_error("read outside section " + section.name);
  }
  return static_cast<std::uint32_t>(section.data[offset]) |
         (static_cast<std::uint32_t>(section.data[offset + 1]) << 8) |
         (static_cast<std::uint32_t>(section.data[offset + 2]) << 16) |
         (static_cast<std::uint32_t>(section.data[offset + 3]) << 24);
}

std::uint32_t word_at_offset(const Section& section, std::size_t offset) {
  return static_cast<std::uint32_t>(section.data[offset]) |
         (static_cast<std::uint32_t>(section.data[offset + 1]) << 8) |
         (static_cast<std::uint32_t>(section.data[offset + 2]) << 16) |
         (static_cast<std::uint32_t>(section.data[offset + 3]) << 24);
}

TEST(LinkerTest, LinksCrossObjectReferences) {
  const Object startup = roco::assemble(R"(
    .section .text.init
    .globl _start
  _start:
    la a0, message
    call puts
    j done
  done:
    ret
  )",
                                        "startup.S");
  const Object library = roco::assemble(R"(
    .section .text
    .globl puts
  puts:
    ret
    .section .rodata
    .globl message
  message:
    .asciz "roco"
  )",
                                        "library.S");

  LinkOptions options;
  const LinkResult result = roco::link({startup, library}, options);
  EXPECT_EQ(result.entry, 0x10000000U);
  EXPECT_EQ(result.base, 0x10000000U);

  const Section& text = section(result, ".text");
  const Section& rodata = section(result, ".rodata");
  EXPECT_EQ(text.address, 0x10000000U);
  EXPECT_EQ(text.data.size(), 28U);
  EXPECT_EQ(rodata.address, 0x1000001cU);
  EXPECT_EQ(rodata.data,
            (std::vector<std::uint8_t>{'r', 'o', 'c', 'o', 0}));

  EXPECT_EQ(symbol(result, "_start").section, 0);
  EXPECT_EQ(symbol(result, "_start").value, 0U);
  EXPECT_EQ(symbol(result, "puts").section, 0);
  EXPECT_EQ(symbol(result, "puts").value, 24U);
  EXPECT_EQ(symbol(result, "message").section, 1);
  EXPECT_EQ(symbol(result, "message").value, 0U);

  EXPECT_EQ(word_at_offset(text, 0),
            roco::isa::encode_u(roco::isa::kOpcodeLui, 10, 0x10000));
  EXPECT_EQ(word_at_offset(text, 4),
            roco::isa::encode_i(roco::isa::kOpcodeOpImm, 10, 0, 10, 0x01c));
  EXPECT_EQ(word_at_offset(text, 8),
            roco::isa::encode_u(roco::isa::kOpcodeAuipc, 1, 0));
  EXPECT_EQ(word_at_offset(text, 12),
            roco::isa::encode_i(roco::isa::kOpcodeJalr, 1, 0, 1, 0x010));
  EXPECT_EQ(word_at_offset(text, 16), roco::isa::encode_j(0, 4));
  EXPECT_EQ(word_at_offset(text, 20), 0x00008067U);
  EXPECT_EQ(word_at_offset(text, 24), 0x00008067U);

  const auto flat = roco::flatten(result);
  ASSERT_GE(flat.size(), 28U);
  EXPECT_EQ(flat[0], 0x37U);
  EXPECT_EQ(flat[text.data.size()], 'r');
}

TEST(LinkerTest, AppliesAbsoluteAndPcRelativeRelocations) {
  const Object object = roco::assemble(R"(
    .text
    .globl _start
  _start:
  1:
    auipc a0, %pcrel_hi(message)
    addi a0, a0, %pcrel_lo(1b)
    la a1, message
    .word message
    .data
    .globl message
  message:
    .word 0x12345678
  )",
                                       "relocs.S");
  LinkOptions options;
  const LinkResult result = roco::link({object}, options);
  const Section& text = section(result, ".text");
  const Section& data = section(result, ".data");
  EXPECT_EQ(data.address, 0x10000014U);
  EXPECT_EQ(word_at_offset(text, 0), 0x00000517U);  // auipc a0, 0
  EXPECT_EQ(word_at_offset(text, 4), 0x01450513U);  // addi a0, a0, 20
  EXPECT_EQ(word_at_offset(text, 8),
            roco::isa::encode_u(roco::isa::kOpcodeLui, 11, 0x10000));
  EXPECT_EQ(word_at_offset(text, 12),
            roco::isa::encode_i(roco::isa::kOpcodeOpImm, 11, 0, 11, 0x014));
  EXPECT_EQ(word_at_offset(text, 16), 0x10000014U);
  EXPECT_EQ(word_at(data, 0x10000014U), 0x12345678U);
}

TEST(LinkerTest, DefinesBssBoundsAndKeepsBssOutOfFlatImage) {
  const Object object = roco::assemble(R"(
    .text
    .globl _start
  _start:
    la t0, __bss_start
    la t1, __bss_end
    ret
    .bss
    .globl buffer
  buffer:
    .zero 16
  )",
                                       "bss.S");
  LinkOptions options;
  const LinkResult result = roco::link({object}, options);
  const Section& text = section(result, ".text");
  const Section& bss = section(result, ".bss");
  EXPECT_EQ(bss.address, 0x10000014U);
  EXPECT_EQ(bss.size, 16U);
  EXPECT_EQ(bss.data.size(), 0U);
  EXPECT_EQ(word_at_offset(text, 0),
            roco::isa::encode_u(roco::isa::kOpcodeLui, 5, 0x10000));
  EXPECT_EQ(word_at_offset(text, 4),
            roco::isa::encode_i(roco::isa::kOpcodeOpImm, 5, 0, 5, 0x014));
  EXPECT_EQ(word_at_offset(text, 8),
            roco::isa::encode_u(roco::isa::kOpcodeLui, 6, 0x10000));
  EXPECT_EQ(word_at_offset(text, 12),
            roco::isa::encode_i(roco::isa::kOpcodeOpImm, 6, 0, 6, 0x024));

  const Symbol& bss_start = symbol(result, "__bss_start");
  const Symbol& bss_end = symbol(result, "__bss_end");
  EXPECT_EQ(bss_start.section, roco::kSymbolAbsolute);
  EXPECT_EQ(bss_start.value, 0x10000014U);
  EXPECT_EQ(bss_end.section, roco::kSymbolAbsolute);
  EXPECT_EQ(bss_end.value, 0x10000024U);
  EXPECT_EQ(symbol(result, "buffer").section, 3);
  EXPECT_EQ(symbol(result, "buffer").value, 0U);
  EXPECT_EQ(symbol(result, "_end").value, 0x10000024U);

  const auto flat = roco::flatten(result);
  EXPECT_EQ(flat.size(), 20U);
}

TEST(LinkerTest, PatchesCallRelocationPairs) {
  Object object;
  Section text;
  text.name = ".text";
  text.type = roco::kShtProgbits;
  text.flags = roco::kShfAlloc | roco::kShfExecInstr;
  text.align = 4;
  text.data = {
      0x97U, 0x00, 0x00, 0x00,  // auipc ra, 0
      0xe7U, 0x80, 0x00, 0x00,  // jalr ra, 0(ra)
      0x67U, 0x80, 0x00, 0x00,  // ret
  };
  text.size = text.data.size();
  roco::Relocation call;
  call.offset = 0;
  call.type = roco::isa::Reloc::Call;
  call.symbol = 2;
  text.relocations.push_back(call);
  object.sections.push_back(std::move(text));

  object.symbols.push_back(Symbol{});
  Symbol start;
  start.name = "_start";
  start.section = 0;
  start.binding = roco::kStbGlobal;
  object.symbols.push_back(start);
  Symbol target;
  target.name = "target";
  target.section = 0;
  target.value = 8;
  target.binding = roco::kStbGlobal;
  object.symbols.push_back(target);

  LinkOptions options;
  const LinkResult result = roco::link({object}, options);
  const Section& linked = section(result, ".text");
  EXPECT_EQ(word_at_offset(linked, 0),
            roco::isa::encode_u(roco::isa::kOpcodeAuipc, 1, 0));
  EXPECT_EQ(word_at_offset(linked, 4),
            roco::isa::encode_i(roco::isa::kOpcodeJalr, 1, 0, 1, 8));
}

TEST(LinkerTest, RejectsDuplicateMissingAndEntrySymbols) {
  const Object first = roco::assemble(R"(
    .text
    .globl foo
  foo:
    ret
  )",
                                      "first.S");
  const Object second = roco::assemble(R"(
    .text
    .globl foo
  foo:
    ret
  )",
                                       "second.S");
  LinkOptions options;
  EXPECT_THROW(roco::link({first, second}, options), roco::Error);

  const Object missing = roco::assemble(R"(
    .globl _start
  _start:
    call nowhere
  )",
                                        "missing.S");
  EXPECT_THROW(roco::link({missing}, options), roco::Error);

  const Object no_entry = roco::assemble(R"(
    .globl main
  main:
    ret
  )",
                                         "no-entry.S");
  EXPECT_THROW(roco::link({no_entry}, options), roco::Error);
}

}  // namespace
