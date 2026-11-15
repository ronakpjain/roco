#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace roco::isa {

// ELF relocation types used by the assembler and linker.
enum class Reloc : std::uint32_t {
  None = 0,
  R32 = 1,
  Branch = 16,
  Jal = 17,
  Call = 18,
  CallPlt = 19,
  PcrelHi20 = 23,
  PcrelLo12I = 24,
  PcrelLo12S = 25,
  Hi20 = 26,
  Lo12I = 27,
  Lo12S = 28,
  Align = 43,
  Relax = 51,
};

// RISC-V base and M-extension opcodes.
inline constexpr std::uint32_t kOpcodeLoad = 0x03;
inline constexpr std::uint32_t kOpcodeMiscMem = 0x0f;
inline constexpr std::uint32_t kOpcodeOpImm = 0x13;
inline constexpr std::uint32_t kOpcodeAuipc = 0x17;
inline constexpr std::uint32_t kOpcodeStore = 0x23;
inline constexpr std::uint32_t kOpcodeAmo = 0x2f;
inline constexpr std::uint32_t kOpcodeOp = 0x33;
inline constexpr std::uint32_t kOpcodeLui = 0x37;
inline constexpr std::uint32_t kOpcodeBranch = 0x63;
inline constexpr std::uint32_t kOpcodeJalr = 0x67;
inline constexpr std::uint32_t kOpcodeJal = 0x6f;
inline constexpr std::uint32_t kOpcodeSystem = 0x73;

inline constexpr std::uint32_t kFunct7Base = 0x00;
inline constexpr std::uint32_t kFunct7Mul = 0x01;
inline constexpr std::uint32_t kFunct7SubSra = 0x20;

// Returns the scalar register number for an ABI name or an xN name, or -1.
int parse_register(std::string_view name);

// ABI name for x0..x31. The argument must be in range.
std::string_view register_name(int number);

// Returns the vector register number for v0..v31, or -1.
int parse_vector_register(std::string_view name);

// Name for v0..v31, or an empty view when the number is out of range.
std::string_view vector_register_name(int number);

// Returns the CSR number for a symbolic name or a decimal/hex number.
std::optional<std::uint32_t> parse_csr(std::string_view name);

// ABI name for a CSR, if one is known.
std::optional<std::string_view> csr_name(std::uint32_t address);

std::uint32_t encode_r(std::uint32_t opcode, std::uint32_t rd,
                       std::uint32_t funct3, std::uint32_t rs1,
                       std::uint32_t rs2, std::uint32_t funct7);
std::uint32_t encode_i(std::uint32_t opcode, std::uint32_t rd,
                       std::uint32_t funct3, std::uint32_t rs1,
                       std::uint32_t imm12);
std::uint32_t encode_s(std::uint32_t opcode, std::uint32_t funct3,
                       std::uint32_t rs1, std::uint32_t rs2,
                       std::uint32_t imm12);
std::uint32_t encode_b(std::uint32_t funct3, std::uint32_t rs1,
                       std::uint32_t rs2, std::int32_t imm13);
std::uint32_t encode_u(std::uint32_t opcode, std::uint32_t rd,
                       std::uint32_t imm20);
std::uint32_t encode_j(std::uint32_t rd, std::int32_t imm21);

// Replace an immediate field while preserving every other instruction bit.
std::uint32_t set_i_imm(std::uint32_t word, std::uint32_t imm12);
std::uint32_t set_s_imm(std::uint32_t word, std::uint32_t imm12);
std::uint32_t set_b_imm(std::uint32_t word, std::int32_t imm13);
std::uint32_t set_u_imm(std::uint32_t word, std::uint32_t imm20);
std::uint32_t set_j_imm(std::uint32_t word, std::int32_t imm21);

std::int64_t sign_extend(std::uint64_t value, unsigned bits);
bool fits_signed(std::int64_t value, unsigned bits);

}  // namespace roco::isa
