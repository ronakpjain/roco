#pragma once

/// @file instruction.hpp
/// @brief RV32 mnemonic table and operand formats.

#include "roco/isa.hpp"

#include <cstdint>
#include <string>
#include <unordered_map>

namespace roco::cc_asm {

enum class Marker { None, Hi, Lo, PcrelHi, PcrelLo };

struct Expr {
  bool has_symbol = false;
  std::string symbol;
  std::int64_t value = 0;
  Marker marker = Marker::None;
};

enum class Format {
  R,
  I,
  Shift,
  Load,
  Store,
  Branch,
  Upper,
  Jump,
  Jalr,
};

struct InstructionSpec {
  Format format;
  std::uint32_t opcode;
  std::uint32_t funct3;
  std::uint32_t funct7;
};

inline const std::unordered_map<std::string, InstructionSpec>& instruction_specs() {
  static const std::unordered_map<std::string, InstructionSpec> specs = {
      // Integer register-register.
      {"add", {Format::R, isa::kOpcodeOp, 0, isa::kFunct7Base}},
      {"sub", {Format::R, isa::kOpcodeOp, 0, isa::kFunct7SubSra}},
      {"sll", {Format::R, isa::kOpcodeOp, 1, isa::kFunct7Base}},
      {"slt", {Format::R, isa::kOpcodeOp, 2, isa::kFunct7Base}},
      {"sltu", {Format::R, isa::kOpcodeOp, 3, isa::kFunct7Base}},
      {"xor", {Format::R, isa::kOpcodeOp, 4, isa::kFunct7Base}},
      {"srl", {Format::R, isa::kOpcodeOp, 5, isa::kFunct7Base}},
      {"sra", {Format::R, isa::kOpcodeOp, 5, isa::kFunct7SubSra}},
      {"or", {Format::R, isa::kOpcodeOp, 6, isa::kFunct7Base}},
      {"and", {Format::R, isa::kOpcodeOp, 7, isa::kFunct7Base}},

      // M extension.
      {"mul", {Format::R, isa::kOpcodeOp, 0, isa::kFunct7Mul}},
      {"mulh", {Format::R, isa::kOpcodeOp, 1, isa::kFunct7Mul}},
      {"mulhsu", {Format::R, isa::kOpcodeOp, 2, isa::kFunct7Mul}},
      {"mulhu", {Format::R, isa::kOpcodeOp, 3, isa::kFunct7Mul}},
      {"div", {Format::R, isa::kOpcodeOp, 4, isa::kFunct7Mul}},
      {"divu", {Format::R, isa::kOpcodeOp, 5, isa::kFunct7Mul}},
      {"rem", {Format::R, isa::kOpcodeOp, 6, isa::kFunct7Mul}},
      {"remu", {Format::R, isa::kOpcodeOp, 7, isa::kFunct7Mul}},

      // Integer immediate.
      {"addi", {Format::I, isa::kOpcodeOpImm, 0, 0}},
      {"slti", {Format::I, isa::kOpcodeOpImm, 2, 0}},
      {"sltiu", {Format::I, isa::kOpcodeOpImm, 3, 0}},
      {"xori", {Format::I, isa::kOpcodeOpImm, 4, 0}},
      {"ori", {Format::I, isa::kOpcodeOpImm, 6, 0}},
      {"andi", {Format::I, isa::kOpcodeOpImm, 7, 0}},
      {"slli", {Format::Shift, isa::kOpcodeOpImm, 1, 0}},
      {"srli", {Format::Shift, isa::kOpcodeOpImm, 5, 0}},
      {"srai", {Format::Shift, isa::kOpcodeOpImm, 5, isa::kFunct7SubSra}},

      // Loads.
      {"lb", {Format::Load, isa::kOpcodeLoad, 0, 0}},
      {"lh", {Format::Load, isa::kOpcodeLoad, 1, 0}},
      {"lw", {Format::Load, isa::kOpcodeLoad, 2, 0}},
      {"lbu", {Format::Load, isa::kOpcodeLoad, 4, 0}},
      {"lhu", {Format::Load, isa::kOpcodeLoad, 5, 0}},

      // Stores.
      {"sb", {Format::Store, isa::kOpcodeStore, 0, 0}},
      {"sh", {Format::Store, isa::kOpcodeStore, 1, 0}},
      {"sw", {Format::Store, isa::kOpcodeStore, 2, 0}},

      // Branches.
      {"beq", {Format::Branch, isa::kOpcodeBranch, 0, 0}},
      {"bne", {Format::Branch, isa::kOpcodeBranch, 1, 0}},
      {"blt", {Format::Branch, isa::kOpcodeBranch, 4, 0}},
      {"bge", {Format::Branch, isa::kOpcodeBranch, 5, 0}},
      {"bltu", {Format::Branch, isa::kOpcodeBranch, 6, 0}},
      {"bgeu", {Format::Branch, isa::kOpcodeBranch, 7, 0}},

      {"lui", {Format::Upper, isa::kOpcodeLui, 0, 0}},
      {"auipc", {Format::Upper, isa::kOpcodeAuipc, 0, 0}},
      {"jal", {Format::Jump, isa::kOpcodeJal, 0, 0}},
      {"jalr", {Format::Jalr, isa::kOpcodeJalr, 0, 0}},
  };
  return specs;
}


}  // namespace roco::cc_asm
