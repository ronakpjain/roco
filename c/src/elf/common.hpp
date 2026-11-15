#pragma once

/// @file common.hpp
/// @brief Shared ELF32 constants and bounded byte helpers.

#include "roco/diagnostic.hpp"
#include "roco/isa.hpp"
#include "roco/object.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>
#include <string>
#include <vector>

namespace roco::elf {

constexpr std::uint32_t kShnUndef = 0;
constexpr std::uint32_t kShnAbs = 0xfff1;
constexpr std::size_t kHeaderSize = 52;
constexpr std::size_t kSectionHeaderSize = 40;
constexpr std::size_t kProgramHeaderSize = 32;
constexpr std::size_t kSymbolSize = 16;
constexpr std::size_t kRelaSize = 12;

struct SectionHeader {
  std::uint32_t name = 0;
  std::uint32_t type = 0;
  std::uint32_t flags = 0;
  std::uint32_t address = 0;
  std::uint32_t offset = 0;
  std::uint32_t size = 0;
  std::uint32_t link = 0;
  std::uint32_t info = 0;
  std::uint32_t align = 0;
  std::uint32_t entsize = 0;
};

class Buffer {
 public:
  std::vector<std::uint8_t> bytes;

  void reserve(std::size_t size) { bytes.reserve(size); }

  void u8(std::uint8_t value) { bytes.push_back(value); }

  void u16(std::uint16_t value) {
    bytes.push_back(static_cast<std::uint8_t>(value));
    bytes.push_back(static_cast<std::uint8_t>(value >> 8));
  }

  void u32(std::uint32_t value) {
    bytes.push_back(static_cast<std::uint8_t>(value));
    bytes.push_back(static_cast<std::uint8_t>(value >> 8));
    bytes.push_back(static_cast<std::uint8_t>(value >> 16));
    bytes.push_back(static_cast<std::uint8_t>(value >> 24));
  }

  void append(const void* data, std::size_t size) {
    const auto* first = static_cast<const std::uint8_t*>(data);
    bytes.insert(bytes.end(), first, first + size);
  }

  void append(const std::vector<std::uint8_t>& data) {
    bytes.insert(bytes.end(), data.begin(), data.end());
  }

  void zeros(std::size_t count) { bytes.insert(bytes.end(), count, 0); }

  void align(std::size_t alignment) {
    if (alignment == 0) {
      alignment = 1;
    }
    const std::size_t remainder = bytes.size() % alignment;
    if (remainder != 0) {
      zeros(alignment - remainder);
    }
  }

  void patch_u16(std::size_t offset, std::uint16_t value) {
    if (offset + 2 > bytes.size()) {
      throw Error("internal error: ELF patch out of range");
    }
    bytes[offset] = static_cast<std::uint8_t>(value);
    bytes[offset + 1] = static_cast<std::uint8_t>(value >> 8);
  }

  void patch_u32(std::size_t offset, std::uint32_t value) {
    if (offset + 4 > bytes.size()) {
      throw Error("internal error: ELF patch out of range");
    }
    bytes[offset] = static_cast<std::uint8_t>(value);
    bytes[offset + 1] = static_cast<std::uint8_t>(value >> 8);
    bytes[offset + 2] = static_cast<std::uint8_t>(value >> 16);
    bytes[offset + 3] = static_cast<std::uint8_t>(value >> 24);
  }
};

class Reader {
 public:
  explicit Reader(std::span<const std::uint8_t> bytes) : bytes_(bytes) {}

  void require(std::size_t offset, std::size_t size,
               const char* what) const {
    if (offset > bytes_.size() || size > bytes_.size() - offset) {
      throw Error(std::string("malformed ELF: truncated ") + what);
    }
  }

  std::uint8_t u8(std::size_t offset, const char* what) const {
    require(offset, 1, what);
    return bytes_[offset];
  }

  std::uint16_t u16(std::size_t offset, const char* what) const {
    require(offset, 2, what);
    return static_cast<std::uint16_t>(bytes_[offset]) |
           static_cast<std::uint16_t>(bytes_[offset + 1] << 8);
  }

  std::uint32_t u32(std::size_t offset, const char* what) const {
    require(offset, 4, what);
    return static_cast<std::uint32_t>(bytes_[offset]) |
           (static_cast<std::uint32_t>(bytes_[offset + 1]) << 8) |
           (static_cast<std::uint32_t>(bytes_[offset + 2]) << 16) |
           (static_cast<std::uint32_t>(bytes_[offset + 3]) << 24);
  }

  std::int32_t i32(std::size_t offset, const char* what) const {
    const auto value = u32(offset, what);
    return static_cast<std::int32_t>(value);
  }

  const std::uint8_t* data(std::size_t offset) const {
    return bytes_.data() + offset;
  }

  [[nodiscard]] std::size_t size() const { return bytes_.size(); }

 private:
  std::span<const std::uint8_t> bytes_;
};

inline std::string read_string(std::span<const std::uint8_t> table,
                        std::uint32_t offset, const char* what) {
  if (offset >= table.size()) {
    throw Error(std::string("malformed ELF: ") + what + " string out of range");
  }
  const auto* first = table.data() + offset;
  const auto* last = std::find(first, table.data() + table.size(), 0);
  if (last == table.data() + table.size()) {
    throw Error(std::string("malformed ELF: unterminated ") + what +
                " string");
  }
  return std::string(reinterpret_cast<const char*>(first),
                     reinterpret_cast<const char*>(last));
}

inline std::vector<std::uint8_t> slice(std::span<const std::uint8_t> bytes,
                                std::uint32_t offset, std::uint32_t size) {
  if (offset > bytes.size() || size > bytes.size() - offset) {
    throw Error("malformed ELF: section data out of range");
  }
  return {bytes.begin() + offset, bytes.begin() + offset + size};
}

inline bool is_power_of_two(std::uint64_t value) {
  return value != 0 && (value & (value - 1)) == 0;
}


}  // namespace roco::elf
