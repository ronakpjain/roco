#pragma once

#include "roco/object.hpp"

#include <cstdint>
#include <span>
#include <vector>

namespace roco::elf {

inline constexpr std::uint16_t kMachineRiscV = 243;
inline constexpr std::uint16_t kTypeRel = 1;
inline constexpr std::uint16_t kTypeExec = 2;

// Serialize a relocatable object (ET_REL).
std::vector<std::uint8_t> encode_object(const Object& object);

// Serialize a linked executable (ET_EXEC) with one PT_LOAD segment.
std::vector<std::uint8_t> encode_executable(const Object& object,
                                            std::uint32_t entry);

// Parse an ELF32 little-endian RISC-V file. Throws roco::Error on malformed
// input. Metadata sections are skipped; allocatable content sections and their
// relocation records are preserved.
Object decode(std::span<const std::uint8_t> bytes);

}  // namespace roco::elf
