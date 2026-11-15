#pragma once

#include "roco/object.hpp"

#include <string>
#include <string_view>

/** @file assembler.hpp
 *  @brief RV32IMA + roco vector subset source assembler.
 */

namespace roco {

/** @brief Assemble one source string into a relocatable object.
 *
 * The filename is used only for diagnostics. Throw roco::Error on
 * malformed syntax, unsupported instructions, invalid immediates, or
 * unresolved local labels.
 *
 * @param source Complete assembly source.
 * @param filename Display name for diagnostics.
 * @return Relocatable object ready for ELF serialization.
 * @throws roco::Error on invalid input.
 */
Object assemble(std::string_view source, std::string_view filename);

/** @brief Read and assemble one source file.
 *  @param path Filesystem path of the assembly source.
 *  @return Relocatable object ready for ELF serialization.
 *  @throws roco::Error if the file cannot be read or the source is invalid.
 */
Object assemble_file(const std::string& path);

}  // namespace roco
