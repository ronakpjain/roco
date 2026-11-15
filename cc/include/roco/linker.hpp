#pragma once

#include "roco/object.hpp"

#include <cstdint>
#include <string>
#include <vector>

/** @file linker.hpp
 *  @brief Static linker for roco ELF32 objects.
 */

namespace roco {

/** @brief Placement and symbol options for a linked roco image. */
struct LinkOptions {
  std::uint32_t base_address = 0x10000000; ///< First load address in SDRAM.
  std::string entry_symbol = "_start";     ///< Executable entry symbol.
};

/** @brief A linked image and its entry address.
 *
 * `image` contains the output `.text`, `.rodata`, `.data`, and `.bss`
 * sections with final addresses and a resolved symbol table. It can be
 * serialized with `elf::encode_executable` or flattened for the bootloader.
 */
struct LinkResult {
  Object image;        ///< Linked sections and symbols.
  std::uint32_t entry = 0; ///< Resolved entry address.
  std::uint32_t base = 0;  ///< Load address.
  std::uint32_t file_end = 0; ///< End of the last file-backed byte.
};

/** @brief Link relocatable objects into a roco executable image.
 *
 * Only allocatable `SHT_PROGBITS` and `SHT_NOBITS` sections are linked.
 * Weak definitions follow the usual strong-over-weak rule. Undefined weak
 * references resolve to zero; undefined strong references are errors.
 *
 * @param objects Input objects in link order.
 * @param options Placement and entry options.
 * @return Linked image and metadata.
 * @throws roco::Error on duplicate strong definitions, unresolved symbols,
 *         unsupported relocations, or out-of-range relocation results.
 */
LinkResult link(const std::vector<Object>& objects, const LinkOptions& options);

/** @brief Flatten the file-backed parts of a linked image.
 *
 * The result starts at `result.base`; gaps between sections and alignment
 * padding are zero-filled. `.bss` is excluded because startup code must
 * clear it.
 *
 * @param result Linked image.
 * @return Flat load image for the roco bootloader or simulation.
 * @throws roco::Error if the image contains an invalid address range.
 */
std::vector<std::uint8_t> flatten(const LinkResult& result);

}  // namespace roco
