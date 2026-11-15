#pragma once

#include <stdexcept>
#include <string>

/** @file diagnostic.hpp
 *  @brief Toolchain-wide exception type for user-facing diagnostics.
 */

namespace roco {

/** @brief A recoverable input or toolchain error with a human-readable message.
 *
 * Command-line drivers catch this type, print `what()`, and return a
 * non-zero exit status. Internal invariant failures use the same type so
 * they are not mistaken for successful output.
 */
class Error : public std::runtime_error {
 public:
  /** @brief Construct an error with a complete diagnostic message.
   *  @param message Text printed by the command-line driver.
   */
  explicit Error(const std::string& message) : std::runtime_error(message) {}
};

}  // namespace roco
