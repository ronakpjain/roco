#pragma once

#include "roco/target.hpp"

#include <string>
#include <string_view>

/** @file compiler.hpp
 *  @brief C frontend and RV32 assembly backend for the roco toolchain.
 */

namespace roco {

/** @brief Compile a freestanding C translation unit to roco assembly.
 *
 * The supported language is a practical C subset: `int`, `char`, `short`,
 * `long`, signed/unsigned variants, pointers, arrays, functions,
 * declarations, compound statements, `if`/`else`, `while`, `do`, `for`,
 * `break`, `continue`, `return`, and the usual expression operators.
 *
 * Unsupported constructs fail with a source-located diagnostic rather than
 * producing incorrect code.
 *
 * @param source Complete C source text.
 * @param filename Display name used in diagnostics.
 * @param options Optimization level and target instruction costs.
 * @return GNU-style RISC-V assembly accepted by roco_as.
 * @throws roco::Error on invalid input or unsupported C constructs.
 */
std::string compile_to_assembly(
    std::string_view source, std::string_view filename,
    const CompilerOptions& options = CompilerOptions{});

/** @brief Read and compile one C source file.
 *  @param path Filesystem path of the C source.
 *  @param options Optimization level and target instruction costs.
 *  @return Assembly text.
 *  @throws roco::Error if the file cannot be read or compilation fails.
 */
std::string compile_file(const std::string& path,
                         const CompilerOptions& options = CompilerOptions{});

/** @brief Run only the C preprocessor on one source file.
 *  @param path Filesystem path of the C source.
 *  @return Preprocessed C source.
 *  @throws roco::Error if the file or an include cannot be read.
 */
std::string preprocess_file(const std::string& path);

}  // namespace roco
