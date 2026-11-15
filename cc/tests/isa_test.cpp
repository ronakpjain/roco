#include "roco/isa.hpp"

#include <cstdint>
#include <gtest/gtest.h>

namespace {

using roco::isa::encode_b;
using roco::isa::encode_i;
using roco::isa::encode_j;
using roco::isa::encode_r;
using roco::isa::encode_s;
using roco::isa::encode_u;

TEST(RegisterTest, ParsesAbiNames) {
  EXPECT_EQ(roco::isa::parse_register("zero"), 0);
  EXPECT_EQ(roco::isa::parse_register("ra"), 1);
  EXPECT_EQ(roco::isa::parse_register("sp"), 2);
  EXPECT_EQ(roco::isa::parse_register("a0"), 10);
  EXPECT_EQ(roco::isa::parse_register("s11"), 27);
  EXPECT_EQ(roco::isa::parse_register("t6"), 31);
  EXPECT_EQ(roco::isa::parse_register("fp"), 8);
}

TEST(RegisterTest, ParsesNumericNames) {
  EXPECT_EQ(roco::isa::parse_register("x0"), 0);
  EXPECT_EQ(roco::isa::parse_register("x31"), 31);
  EXPECT_EQ(roco::isa::parse_register("x32"), -1);
  EXPECT_EQ(roco::isa::parse_register("x-1"), -1);
  EXPECT_EQ(roco::isa::parse_register("bogus"), -1);
}

TEST(RegisterTest, ParsesVectorRegisters) {
  EXPECT_EQ(roco::isa::parse_vector_register("v0"), 0);
  EXPECT_EQ(roco::isa::parse_vector_register("v31"), 31);
  EXPECT_EQ(roco::isa::parse_vector_register("v32"), -1);
  EXPECT_EQ(roco::isa::parse_vector_register("v-1"), -1);
  EXPECT_EQ(roco::isa::parse_vector_register("a0"), -1);
  EXPECT_EQ(roco::isa::vector_register_name(10), "v10");
  EXPECT_EQ(roco::isa::vector_register_name(32), "");
}

TEST(RegisterTest, FormatsNames) {
  EXPECT_EQ(roco::isa::register_name(0), "zero");
  EXPECT_EQ(roco::isa::register_name(10), "a0");
  EXPECT_EQ(roco::isa::register_name(31), "t6");
  EXPECT_EQ(roco::isa::register_name(32), "");
}

TEST(EncodingTest, MatchesKnownInstructions) {
  // addi a0, zero, 42
  EXPECT_EQ(encode_i(roco::isa::kOpcodeOpImm, 10, 0, 0, 42), 0x02a00513U);
  // add a0, a1, a2
  EXPECT_EQ(encode_r(roco::isa::kOpcodeOp, 10, 0, 11, 12,
                     roco::isa::kFunct7Base),
            0x00c58533U);
  // lw a1, 8(sp)
  EXPECT_EQ(encode_i(roco::isa::kOpcodeLoad, 11, 2, 2, 8), 0x00812583U);
  // sw a1, -4(sp)
  EXPECT_EQ(encode_s(roco::isa::kOpcodeStore, 2, 2, 11, 0xffcU), 0xfeb12e23U);
  // beq a0, a1, -8
  EXPECT_EQ(encode_b(0, 10, 11, -8), 0xfeb50ce3U);
  // jal ra, 16
  EXPECT_EQ(encode_j(1, 16), 0x010000efU);
  // lui a0, 0x12345
  EXPECT_EQ(encode_u(roco::isa::kOpcodeLui, 10, 0x12345), 0x12345537U);
  // auipc a0, 1
  EXPECT_EQ(encode_u(roco::isa::kOpcodeAuipc, 10, 1), 0x00001517U);
  // jalr ra, 4(a0)
  EXPECT_EQ(encode_i(roco::isa::kOpcodeJalr, 1, 0, 10, 4), 0x004500e7U);
  // csrrw a0, mstatus, a1
  EXPECT_EQ(encode_i(roco::isa::kOpcodeSystem, 10, 1, 11, 0x300), 0x30059573U);
}

TEST(EncodingTest, PatchesImmediatesWithoutChangingOtherFields) {
  const std::uint32_t addi = encode_i(roco::isa::kOpcodeOpImm, 10, 0, 11, 0);
  EXPECT_EQ(roco::isa::set_i_imm(addi, 0x7ff), 0x7ff58513U);

  const std::uint32_t sw = encode_s(roco::isa::kOpcodeStore, 2, 2, 11, 0);
  EXPECT_EQ(roco::isa::set_s_imm(sw, 0xffc), 0xfeb12e23U);

  const std::uint32_t beq = encode_b(0, 10, 11, 0);
  EXPECT_EQ(roco::isa::set_b_imm(beq, -8), 0xfeb50ce3U);

  const std::uint32_t jal = encode_j(1, 0);
  EXPECT_EQ(roco::isa::set_j_imm(jal, 16), 0x010000efU);

  const std::uint32_t lui = encode_u(roco::isa::kOpcodeLui, 10, 0);
  EXPECT_EQ(roco::isa::set_u_imm(lui, 0x12345), 0x12345537U);
}

TEST(EncodingTest, SignExtendsAndChecksRanges) {
  EXPECT_EQ(roco::isa::sign_extend(0xfff, 12), -1);
  EXPECT_EQ(roco::isa::sign_extend(0x800, 12), -2048);
  EXPECT_EQ(roco::isa::sign_extend(0x7ff, 12), 2047);
  EXPECT_TRUE(roco::isa::fits_signed(-2048, 12));
  EXPECT_TRUE(roco::isa::fits_signed(2047, 12));
  EXPECT_FALSE(roco::isa::fits_signed(-2049, 12));
  EXPECT_FALSE(roco::isa::fits_signed(2048, 12));
}

TEST(CsrTest, ParsesNamesAndNumbers) {
  EXPECT_EQ(roco::isa::parse_csr("mstatus"), 0x300);
  EXPECT_EQ(roco::isa::parse_csr("satp"), 0x180);
  EXPECT_EQ(roco::isa::parse_csr("vtype"), 0xc21);
  EXPECT_EQ(roco::isa::parse_csr("vlenb"), 0xc22);
  EXPECT_EQ(roco::isa::parse_csr("0x300"), 0x300);
  EXPECT_EQ(roco::isa::parse_csr("4095"), 4095);
  EXPECT_FALSE(roco::isa::parse_csr("4096"));
  EXPECT_FALSE(roco::isa::parse_csr("not_a_csr"));
  EXPECT_EQ(roco::isa::csr_name(0x341), "mepc");
}

}  // namespace
