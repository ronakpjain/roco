#include "roco/assembler.hpp"

#include "roco/diagnostic.hpp"
#include "roco/object.hpp"

#include <cstdint>
#include <gtest/gtest.h>
#include <string>
#include <vector>

namespace {

std::vector<std::uint32_t> words(const roco::Section& section) {
  std::vector<std::uint32_t> result;
  for (std::size_t i = 0; i + 4 <= section.data.size(); i += 4) {
    result.push_back(static_cast<std::uint32_t>(section.data[i]) |
                     (static_cast<std::uint32_t>(section.data[i + 1]) << 8) |
                     (static_cast<std::uint32_t>(section.data[i + 2]) << 16) |
                     (static_cast<std::uint32_t>(section.data[i + 3]) << 24));
  }
  return result;
}

const roco::Section& section(const roco::Object& object,
                             const std::string& name) {
  for (const auto& candidate : object.sections) {
    if (candidate.name == name) {
      return candidate;
    }
  }
  throw std::runtime_error("missing section " + name);
}

const roco::Symbol& symbol(const roco::Object& object,
                           const std::string& name) {
  for (const auto& candidate : object.symbols) {
    if (candidate.name == name) {
      return candidate;
    }
  }
  throw std::runtime_error("missing symbol " + name);
}

TEST(AssemblerTest, EncodesIntegerInstructions) {
  const roco::Object object = roco::assemble(R"(
    .section .text
    addi a0, zero, 42
    add a1, a0, a0
    lw a2, 8(sp)
    sw a2, -4(sp)
    beq a0, a1, 0
    jal ra, 0
    ret
    not a3, a0
    neg a4, a0
    seqz a5, a0
    snez s0, a0
    sltz s1, a0
    sgtz s2, a0
    slli t0, a0, 31
    srli t0, a0, 3
    srai t0, a0, 3
  )",
                                       "test.S");
  const auto text = words(section(object, ".text"));
  ASSERT_EQ(text.size(), 16U);
  EXPECT_EQ(text[0], 0x02a00513U);
  EXPECT_EQ(text[1], 0x00a505b3U);
  EXPECT_EQ(text[2], 0x00812603U);
  EXPECT_EQ(text[3], 0xfec12e23U);
  EXPECT_EQ(text[4], 0x00b50063U);
  EXPECT_EQ(text[5], 0x000000efU);
  EXPECT_EQ(text[6], 0x00008067U);
  EXPECT_EQ(text[7], 0xfff54693U);
  EXPECT_EQ(text[8], 0x40a00733U);
  EXPECT_EQ(text[9], 0x00153793U);
  EXPECT_EQ(text[10], 0x00a03433U);
  EXPECT_EQ(text[11], 0x000524b3U);
  EXPECT_EQ(text[12], 0x00a02933U);
  EXPECT_EQ(text[13], 0x01f51293U);
  EXPECT_EQ(text[14], 0x00355293U);
  EXPECT_EQ(text[15], 0x02355293U);
}

TEST(AssemblerTest, ExpandsLoadImmediateAndAddressPseudoInstructions) {
  const roco::Object object = roco::assemble(R"(
    .text
    li a0, 0x12345678
    li a1, -1
    li a2, 0x800
    la a3, value
  )",
                                       "test.S");
  const auto text = words(section(object, ".text"));
  ASSERT_EQ(text.size(), 7U);
  EXPECT_EQ(text[0], 0x12345537U);
  EXPECT_EQ(text[1], 0x67850513U);
  EXPECT_EQ(text[2], 0xfff00593U);
  EXPECT_EQ(text[3], 0x00001637U);
  EXPECT_EQ(text[4], 0x80060613U);
  EXPECT_EQ(text[5], 0x000006b7U);
  EXPECT_EQ(text[6], 0x00068693U);

  const auto& text_section = section(object, ".text");
  ASSERT_EQ(text_section.relocations.size(), 2U);
  EXPECT_EQ(text_section.relocations[0].offset, 20U);
  EXPECT_EQ(text_section.relocations[0].type, roco::isa::Reloc::Hi20);
  EXPECT_EQ(object.symbols[text_section.relocations[0].symbol].name, "value");
  EXPECT_EQ(text_section.relocations[1].offset, 24U);
  EXPECT_EQ(text_section.relocations[1].type, roco::isa::Reloc::Lo12I);
}

TEST(AssemblerTest, ResolvesNamedAndNumericLabels) {
  const roco::Object object = roco::assemble(R"(
    .text
    .globl _start
  _start:
    li a0, 7
  1:
    addi a0, a0, -1
    bnez a0, 1b
    j done
    nop
  done:
    ret
  )",
                                       "test.S");
  const auto& text = section(object, ".text");
  const auto program = words(text);
  ASSERT_EQ(program.size(), 6U);
  EXPECT_EQ(program[0], 0x00700513U);
  EXPECT_EQ(program[1], 0xfff50513U);
  EXPECT_EQ(program[2], 0x00051063U);
  EXPECT_EQ(program[3], 0x0000006fU);
  EXPECT_EQ(program[4], 0x00000013U);
  EXPECT_EQ(program[5], 0x00008067U);
  ASSERT_EQ(text.relocations.size(), 2U);
  EXPECT_EQ(text.relocations[0].offset, 8U);
  EXPECT_EQ(text.relocations[0].type, roco::isa::Reloc::Branch);
  EXPECT_EQ(object.symbols[text.relocations[0].symbol].name, ".Lnum.1.0");
  EXPECT_EQ(text.relocations[1].offset, 12U);
  EXPECT_EQ(text.relocations[1].type, roco::isa::Reloc::Jal);
  EXPECT_EQ(object.symbols[text.relocations[1].symbol].name, "done");
  EXPECT_EQ(symbol(object, "_start").binding, roco::kStbGlobal);
  EXPECT_EQ(symbol(object, "done").binding, roco::kStbLocal);
}

TEST(AssemblerTest, EmitsDataRelocationsAndBss) {
  const roco::Object object = roco::assemble(R"(
    .data
    .globl value
  value:
    .word 0x11223344, target
    .byte 1, 2
    .half 0x5566
    .asciz "hi"
    .align 2
    .word 0x99
    .bss
  buffer:
    .zero 16
  )",
                                       "test.S");
  const auto& data = section(object, ".data");
  const auto data_words = words(data);
  ASSERT_EQ(data_words.size(), 5U);
  EXPECT_EQ(data_words[0], 0x11223344U);
  EXPECT_EQ(data_words[1], 0U);
  EXPECT_EQ(data.data.size(), 20U);
  ASSERT_EQ(data.relocations.size(), 1U);
  EXPECT_EQ(data.relocations[0].offset, 4U);
  EXPECT_EQ(data.relocations[0].type, roco::isa::Reloc::R32);
  EXPECT_EQ(object.symbols[data.relocations[0].symbol].name, "target");
  EXPECT_EQ(symbol(object, "target").binding, roco::kStbGlobal);

  const auto& bss = section(object, ".bss");
  EXPECT_EQ(bss.type, roco::kShtNobits);
  EXPECT_EQ(bss.size, 16U);
  EXPECT_EQ(symbol(object, "buffer").value, 0U);
}

TEST(AssemblerTest, HandlesCustomSectionsAndMetadataDirectives) {
  const roco::Object object = roco::assemble(R"(
    .section .text.init, "ax", @progbits
    .globl _start
  _start:
    nop
    .section .rodata.str, "a", @progbits
  message:
    .asciz "roco"
    .section .data, "aw", @progbits
    .word message
  )",
                                       "test.S");
  EXPECT_EQ(section(object, ".text.init").flags,
            roco::kShfAlloc | roco::kShfExecInstr);
  EXPECT_EQ(section(object, ".rodata.str").flags, roco::kShfAlloc);
  EXPECT_EQ(section(object, ".rodata.str").data,
            (std::vector<std::uint8_t>{'r', 'o', 'c', 'o', 0}));
  EXPECT_EQ(section(object, ".data").relocations.size(), 1U);
}

TEST(AssemblerTest, RejectsInvalidInput) {
  EXPECT_THROW(roco::assemble("addi a0, zero, 4096\n", "test.S"),
               roco::Error);
  EXPECT_THROW(roco::assemble("bogus a0, a1\n", "test.S"), roco::Error);
  EXPECT_THROW(roco::assemble("j .Lmissing\n", "test.S"), roco::Error);
  EXPECT_THROW(roco::assemble("foo:\nfoo:\n", "test.S"), roco::Error);
  EXPECT_THROW(roco::assemble("j 1f\n", "test.S"), roco::Error);
  EXPECT_THROW(roco::assemble("li a0, symbol\n", "test.S"), roco::Error);
  EXPECT_THROW(roco::assemble(".unsupported\n", "test.S"), roco::Error);
  EXPECT_THROW(roco::assemble("beq a0, a1, 3\n", "test.S"), roco::Error);
}

TEST(AssemblerTest, EncodesAtomicInstructions) {
  const roco::Object object = roco::assemble(R"(
    .text
    lr.w a0, (a1)
    lr.w.aq a0, (a1)
    sc.w a0, a2, (a1)
    sc.w.rl a0, a2, (a1)
    amoswap.w a0, a2, (a1)
    amoadd.w.aqrl a0, a2, (a1)
    amoxor.w a0, a2, (a1)
    amoand.w a0, a2, (a1)
    amoor.w a0, a2, (a1)
    amomin.w a0, a2, (a1)
    amomax.w a0, a2, (a1)
    amominu.w a0, a2, (a1)
    amomaxu.w a0, a2, (a1)
  )",
                                       "test.S");
  const auto text = words(section(object, ".text"));
  ASSERT_EQ(text.size(), 13U);
  EXPECT_EQ(text[0], 0x1005a52fU);
  EXPECT_EQ(text[1], 0x1405a52fU);
  EXPECT_EQ(text[2], 0x18c5a52fU);
  EXPECT_EQ(text[3], 0x1ac5a52fU);
  EXPECT_EQ(text[4], 0x08c5a52fU);
  EXPECT_EQ(text[5], 0x06c5a52fU);
  EXPECT_EQ(text[6], 0x20c5a52fU);
  EXPECT_EQ(text[7], 0x60c5a52fU);
  EXPECT_EQ(text[8], 0x40c5a52fU);
  EXPECT_EQ(text[9], 0x80c5a52fU);
  EXPECT_EQ(text[10], 0xa0c5a52fU);
  EXPECT_EQ(text[11], 0xc0c5a52fU);
  EXPECT_EQ(text[12], 0xe0c5a52fU);
}

TEST(AssemblerTest, EncodesRocoVectorSubset) {
  const roco::Object object = roco::assemble(R"(
    .text
    vsetvli t0, a0, e32, m1, ta, ma
    vsetivli t0, 4, e32, m1, ta, ma
    vsetvl t0, a0, a1
    vmv.x.s a0, v1
    vmv.s.x v1, a0
    vmv.v.v v1, v2
    vmv.v.x v1, a0
    vmv.v.i v1, 7
    vredsum.vs v1, v2, v3
    vadd.vv v1, v2, v3
    vadd.vx v1, v2, a0
    vadd.vi v1, v2, 7
    vsub.vv v1, v2, v3
    vand.vv v1, v2, v3
    vor.vv v1, v2, v3
    vxor.vv v1, v2, v3
    vle8.v v1, (a0)
    vle16.v v1, (a0)
    vle32.v v1, (a0)
    vse8.v v1, (a0)
    vse16.v v1, (a0)
    vse32.v v1, (a0)
  )",
                                       "test.S");
  const auto text = words(section(object, ".text"));
  ASSERT_EQ(text.size(), 22U);
  EXPECT_EQ(text[0], 0x0d0572d7U);
  EXPECT_EQ(text[1], 0xcd0272d7U);
  EXPECT_EQ(text[2], 0x80b572d7U);
  EXPECT_EQ(text[3], 0x42102557U);
  EXPECT_EQ(text[4], 0x420560d7U);
  EXPECT_EQ(text[5], 0x5e0100d7U);
  EXPECT_EQ(text[6], 0x5e0540d7U);
  EXPECT_EQ(text[7], 0x5e03b0d7U);
  EXPECT_EQ(text[8], 0x0221a0d7U);
  EXPECT_EQ(text[9], 0x022180d7U);
  EXPECT_EQ(text[10], 0x022540d7U);
  EXPECT_EQ(text[11], 0x0223b0d7U);
  EXPECT_EQ(text[12], 0x0a2180d7U);
  EXPECT_EQ(text[13], 0x262180d7U);
  EXPECT_EQ(text[14], 0x2a2180d7U);
  EXPECT_EQ(text[15], 0x2e2180d7U);
  EXPECT_EQ(text[16], 0x02050087U);
  EXPECT_EQ(text[17], 0x02055087U);
  EXPECT_EQ(text[18], 0x02056087U);
  EXPECT_EQ(text[19], 0x020500a7U);
  EXPECT_EQ(text[20], 0x020550a7U);
  EXPECT_EQ(text[21], 0x020560a7U);
}

TEST(AssemblerTest, RejectsUnsupportedRocoForms) {
  EXPECT_THROW(roco::assemble("vadd.vv v1, v2, v3, v0.t\n", "test.S"),
               roco::Error);
  EXPECT_THROW(roco::assemble("vsetvli t0, a0, e64, m1\n", "test.S"),
               roco::Error);
  EXPECT_THROW(roco::assemble("vsetvli t0, a0, e32, m2\n", "test.S"),
               roco::Error);
  EXPECT_THROW(roco::assemble("vmul.vv v1, v2, v3\n", "test.S"),
               roco::Error);
  EXPECT_THROW(roco::assemble("vle32.v v1, 4(a0)\n", "test.S"),
               roco::Error);
  EXPECT_THROW(roco::assemble("vse32.v v1, (a0), v0.t\n", "test.S"),
               roco::Error);
  EXPECT_THROW(roco::assemble("vadd.vv v1, v2, v3, v0.t\n", "test.S"),
               roco::Error);
  EXPECT_THROW(roco::assemble("lr.d a0, (a1)\n", "test.S"),
               roco::Error);
  EXPECT_THROW(roco::assemble("amoadd.w a0, a2, 4(a1)\n", "test.S"),
               roco::Error);
}

}  // namespace
