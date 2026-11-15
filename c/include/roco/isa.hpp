#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

/** @file isa.hpp
 *  @brief RV32 instruction encoding, register names, and relocation constants.
 */

namespace roco::isa {

/** @brief ELF relocation types used by the assembler and linker. */
enum class Reloc : std::uint32_t {
  None = 0,      ///< R_RISCV_NONE.
  R32 = 1,       ///< R_RISCV_32.
  Branch = 16,   ///< R_RISCV_BRANCH.
  Jal = 17,      ///< R_RISCV_JAL.
  Call = 18,     ///< R_RISCV_CALL relocation pair.
  CallPlt = 19,  ///< R_RISCV_CALL_PLT relocation pair.
  PcrelHi20 = 23, ///< R_RISCV_PCREL_HI20.
  PcrelLo12I = 24, ///< R_RISCV_PCREL_LO12_I.
  PcrelLo12S = 25, ///< R_RISCV_PCREL_LO12_S.
  Hi20 = 26,     ///< R_RISCV_HI20.
  Lo12I = 27,    ///< R_RISCV_LO12_I.
  Lo12S = 28,    ///< R_RISCV_LO12_S.
  Align = 43,    ///< R_RISCV_ALIGN.
  Relax = 51,    ///< R_RISCV_RELAX.
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

/** @brief Parse a scalar register name.
 *  @param name ABI name (`a0`) or numeric name (`x10`).
 *  @return Register number 0..31, or -1 if the name is invalid.
 */
int parse_register(std::string_view name);

/** @brief Get the ABI name for a scalar register.
 *  @param number Register number.
 *  @return Name such as `a0`, or an empty view when out of range.
 */
std::string_view register_name(int number);

/** @brief Parse a vector register name.
 *  @param name Numeric vector register name (`v0`..`v31`).
 *  @return Register number 0..31, or -1 if the name is invalid.
 */
int parse_vector_register(std::string_view name);

/** @brief Get the name for a vector register.
 *  @param number Register number.
 *  @return Name such as `v3`, or an empty view when out of range.
 */
std::string_view vector_register_name(int number);

/** @brief Parse a CSR name or number.
 *  @param name Symbolic CSR name or decimal/hex address.
 *  @return 12-bit CSR address, or std::nullopt if unknown.
 */
std::optional<std::uint32_t> parse_csr(std::string_view name);

/** @brief Find the canonical name for a CSR address.
 *  @param address 12-bit CSR address.
 *  @return Known name, or std::nullopt for an unnamed CSR.
 */
std::optional<std::string_view> csr_name(std::uint32_t address);

/** @brief Encode an R-type instruction.
 *  @param opcode 7-bit opcode.
 *  @param rd Destination register.
 *  @param funct3 3-bit function field.
 *  @param rs1 First source register.
 *  @param rs2 Second source register.
 *  @param funct7 7-bit function field.
 *  @return Encoded 32-bit instruction word.
 */
std::uint32_t encode_r(std::uint32_t opcode, std::uint32_t rd,
                       std::uint32_t funct3, std::uint32_t rs1,
                       std::uint32_t rs2, std::uint32_t funct7);

/** @brief Encode an I-type instruction.
 *  @param opcode 7-bit opcode.
 *  @param rd Destination register.
 *  @param funct3 3-bit function field.
 *  @param rs1 Source register.
 *  @param imm12 Low 12 bits of the immediate.
 *  @return Encoded 32-bit instruction word.
 */
std::uint32_t encode_i(std::uint32_t opcode, std::uint32_t rd,
                       std::uint32_t funct3, std::uint32_t rs1,
                       std::uint32_t imm12);

/** @brief Encode an S-type store instruction.
 *  @param opcode 7-bit opcode.
 *  @param funct3 3-bit function field.
 *  @param rs1 Base register.
 *  @param rs2 Source data register.
 *  @param imm12 Low 12 bits of the immediate.
 *  @return Encoded 32-bit instruction word.
 */
std::uint32_t encode_s(std::uint32_t opcode, std::uint32_t funct3,
                       std::uint32_t rs1, std::uint32_t rs2,
                       std::uint32_t imm12);

/** @brief Encode a B-type branch instruction.
 *  @param funct3 Branch condition field.
 *  @param rs1 First source register.
 *  @param rs2 Second source register.
 *  @param imm13 Signed PC-relative byte offset.
 *  @return Encoded 32-bit instruction word.
 */
std::uint32_t encode_b(std::uint32_t funct3, std::uint32_t rs1,
                       std::uint32_t rs2, std::int32_t imm13);

/** @brief Encode an U-type instruction.
 *  @param opcode 7-bit opcode.
 *  @param rd Destination register.
 *  @param imm20 20-bit upper immediate.
 *  @return Encoded 32-bit instruction word.
 */
std::uint32_t encode_u(std::uint32_t opcode, std::uint32_t rd,
                       std::uint32_t imm20);

/** @brief Encode a J-type jump instruction.
 *  @param rd Link register.
 *  @param imm21 Signed PC-relative byte offset.
 *  @return Encoded 32-bit instruction word.
 */
std::uint32_t encode_j(std::uint32_t rd, std::int32_t imm21);

/** @brief Replace an I-type immediate field.
 *  @param word Original instruction word.
 *  @param imm12 New low 12 immediate bits.
 *  @return Instruction with only the immediate field changed.
 */
std::uint32_t set_i_imm(std::uint32_t word, std::uint32_t imm12);

/** @brief Replace an S-type immediate field.
 *  @param word Original instruction word.
 *  @param imm12 New low 12 immediate bits.
 *  @return Instruction with only the immediate field changed.
 */
std::uint32_t set_s_imm(std::uint32_t word, std::uint32_t imm12);

/** @brief Replace a B-type immediate field.
 *  @param word Original instruction word.
 *  @param imm13 New signed PC-relative offset.
 *  @return Instruction with only the immediate field changed.
 */
std::uint32_t set_b_imm(std::uint32_t word, std::int32_t imm13);

/** @brief Replace a U-type immediate field.
 *  @param word Original instruction word.
 *  @param imm20 New 20-bit upper immediate.
 *  @return Instruction with only the immediate field changed.
 */
std::uint32_t set_u_imm(std::uint32_t word, std::uint32_t imm20);

/** @brief Replace a J-type immediate field.
 *  @param word Original instruction word.
 *  @param imm21 New signed PC-relative offset.
 *  @return Instruction with only the immediate field changed.
 */
std::uint32_t set_j_imm(std::uint32_t word, std::int32_t imm21);

/** @brief Sign-extend the low bits of a value.
 *  @param value Source bit pattern.
 *  @param bits Width of the signed field.
 *  @return Sign-extended 64-bit value.
 */
std::int64_t sign_extend(std::uint64_t value, unsigned bits);

/** @brief Test whether a value fits in a signed field.
 *  @param value Value to test.
 *  @param bits Field width in bits.
 *  @return True when the value is representable.
 */
bool fits_signed(std::int64_t value, unsigned bits);

}  // namespace roco::isa
