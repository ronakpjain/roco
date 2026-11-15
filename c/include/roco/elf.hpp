#pragma once

#include "roco/object.hpp"

#include <cstdint>
#include <span>
#include <vector>

/** @file elf.hpp
 *  @brief ELF32 little-endian RISC-V object serialization.
 */

namespace roco::elf {

inline constexpr std::uint16_t kMachineRiscV = 243; ///< EM_RISCV.
inline constexpr std::uint16_t kTypeRel = 1;        ///< ET_REL.
inline constexpr std::uint16_t kTypeExec = 2;       ///< ET_EXEC.

/** @brief Serialize a relocatable object (ET_REL).
 *  @param object In-memory object with section and symbol indices resolved.
 *  @return ELF32 little-endian file bytes.
 *  @throws roco::Error if the object is malformed or cannot be represented.
 */
std::vector<std::uint8_t> encode_object(const Object& object);

/** @brief Serialize a linked executable (ET_EXEC) with one PT_LOAD segment.
 *  @param object Linked object; section `address` fields must be populated.
 *  @param entry Executable entry address.
 *  @return ELF32 little-endian file bytes.
 *  @throws roco::Error if the image is malformed or cannot be represented.
 */
std::vector<std::uint8_t> encode_executable(const Object& object,
                                            std::uint32_t entry);

/** @brief Parse an ELF32 little-endian RISC-V file.
 *
 * Metadata sections are skipped. Allocatable content sections and their
 * relocation records are preserved, with section and symbol references
 * translated to in-memory indices.
 *
 * @param bytes Complete ELF file image.
 * @return Parsed object.
 * @throws roco::Error on malformed input or an unsupported ELF shape.
 */
Object decode(std::span<const std::uint8_t> bytes);

}  // namespace roco::elf
