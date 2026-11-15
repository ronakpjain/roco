#pragma once

#include "roco/object.hpp"

#include <string>
#include <string_view>

namespace roco {

// Assemble RV32IMA source into an ELF-ready relocatable object.
Object assemble(std::string_view source, std::string_view filename);

Object assemble_file(const std::string& path);

}  // namespace roco
