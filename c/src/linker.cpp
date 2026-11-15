/// @file linker.cpp
/// @brief Public linker entry points.

#include "roco/linker.hpp"

#include "linker/linker.hpp"

#include "roco/diagnostic.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

namespace roco {

LinkResult link(const std::vector<Object>& objects, const LinkOptions& options) {
  cc_link::Linker linker(objects, options);
  return linker.run();
}

std::vector<std::uint8_t> flatten(const LinkResult& result) {
  const std::uint32_t start = result.base;
  std::uint32_t end = start;
  for (const Section& section : result.image.sections) {
    if (section.is_bss()) {
      continue;
    }
    const std::uint32_t section_end =
        section.address + static_cast<std::uint32_t>(section.data.size());
    end = std::max(end, section_end);
  }
  if (end < start) {
    throw Error("linked image ends before its base address");
  }
  std::vector<std::uint8_t> image(end - start, 0);
  for (const Section& section : result.image.sections) {
    if (section.is_bss() || section.data.empty()) {
      continue;
    }
    if (section.address < start || section.address + section.data.size() > end) {
      throw Error("linked section lies outside the flat image");
    }
    const std::size_t offset = section.address - start;
    std::copy(section.data.begin(), section.data.end(),
              image.begin() + static_cast<std::ptrdiff_t>(offset));
  }
  return image;
}

}  // namespace roco
