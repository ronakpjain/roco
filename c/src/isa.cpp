/// \file isa.cpp
/// \brief RV32 instruction encoding and register/CSR tables.

#include "roco/isa.hpp"

#include <array>
#include <charconv>
#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>

namespace roco::isa {
namespace {

constexpr std::array<std::string_view, 32> kRegisters = {
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0",   "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6",   "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8",   "s9", "s10", "s11", "t3", "t4", "t5", "t6",
};

constexpr std::array<std::string_view, 32> kAlternateNames = {
    "", "", "", "", "", "", "", "",
    "fp", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
};

const std::unordered_map<std::string_view, std::uint32_t> kCsrs = {
    {"ustatus", 0x000},   {"uie", 0x004},       {"utvec", 0x005},
    {"uscratch", 0x040},  {"uepc", 0x041},      {"ucause", 0x042},
    {"utval", 0x043},     {"uip", 0x044},       {"fflags", 0x001},
    {"frm", 0x002},       {"fcsr", 0x003},      {"cycle", 0xc00},
    {"time", 0xc01},      {"instret", 0xc02},   {"cycleh", 0xc80},
    {"timeh", 0xc81},     {"instreth", 0xc82},  {"sstatus", 0x100},
    {"sie", 0x104},       {"stvec", 0x105},     {"scounteren", 0x106},
    {"sscratch", 0x140},  {"sepc", 0x141},      {"scause", 0x142},
    {"stval", 0x143},     {"sip", 0x144},       {"satp", 0x180},
    {"mstatus", 0x300},   {"misa", 0x301},      {"medeleg", 0x302},
    {"mideleg", 0x303},   {"mie", 0x304},       {"mtvec", 0x305},
    {"mcounteren", 0x306}, {"mstatush", 0x310}, {"mscratch", 0x340},
    {"mepc", 0x341},      {"mcause", 0x342},    {"mtval", 0x343},
    {"mip", 0x344},       {"mcycle", 0xb00},    {"minstret", 0xb02},
    {"mcycleh", 0xb80},   {"minstreth", 0xb82}, {"mhartid", 0xf14},
    {"pmpcfg0", 0x3a0},   {"pmpcfg1", 0x3a1},   {"pmpcfg2", 0x3a2},
    {"pmpcfg3", 0x3a3},   {"pmpaddr0", 0x3b0},  {"pmpaddr1", 0x3b1},
    {"pmpaddr2", 0x3b2},  {"pmpaddr3", 0x3b3},  {"pmpaddr4", 0x3b4},
    {"pmpaddr5", 0x3b5},  {"pmpaddr6", 0x3b6},  {"pmpaddr7", 0x3b7},
    {"vstart", 0x008},    {"vl", 0xc20},        {"vtype", 0xc21},
    {"vlenb", 0xc22},
};

}  // namespace

int parse_register(std::string_view name) {
  for (std::size_t i = 0; i < kRegisters.size(); ++i) {
    if (kRegisters[i] == name) {
      return static_cast<int>(i);
    }
  }
  for (std::size_t i = 0; i < kAlternateNames.size(); ++i) {
    if (!kAlternateNames[i].empty() && kAlternateNames[i] == name) {
      return static_cast<int>(i);
    }
  }
  if (name.size() >= 2 && name[0] == 'x') {
    unsigned value = 0;
    const auto* first = name.data() + 1;
    const auto* last = name.data() + name.size();
    const auto result = std::from_chars(first, last, value, 10);
    if (result.ec == std::errc{} && result.ptr == last && value < 32) {
      return static_cast<int>(value);
    }
  }
  return -1;
}

std::string_view register_name(int number) {
  if (number < 0 || number >= static_cast<int>(kRegisters.size())) {
    return "";
  }
  return kRegisters[static_cast<std::size_t>(number)];
}

int parse_vector_register(std::string_view name) {
  if (name.size() < 2 || name[0] != 'v') {
    return -1;
  }
  unsigned value = 0;
  const auto* first = name.data() + 1;
  const auto* last = name.data() + name.size();
  const auto result = std::from_chars(first, last, value, 10);
  if (result.ec == std::errc{} && result.ptr == last && value < 32) {
    return static_cast<int>(value);
  }
  return -1;
}

std::string_view vector_register_name(int number) {
  static constexpr std::array<std::string_view, 32> names = {
      "v0",  "v1",  "v2",  "v3",  "v4",  "v5",  "v6",  "v7",
      "v8",  "v9",  "v10", "v11", "v12", "v13", "v14", "v15",
      "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
      "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31",
  };
  if (number < 0 || number >= 32) {
    return "";
  }
  return names[static_cast<std::size_t>(number)];
}

std::optional<std::uint32_t> parse_csr(std::string_view name) {
  if (const auto it = kCsrs.find(name); it != kCsrs.end()) {
    return it->second;
  }
  unsigned value = 0;
  const char* first = name.data();
  int base = 10;
  if (name.size() > 2 && name[0] == '0' &&
      (name[1] == 'x' || name[1] == 'X')) {
    first += 2;
    base = 16;
  }
  const auto result = std::from_chars(first, name.data() + name.size(), value,
                                      base);
  if (result.ec == std::errc{} && result.ptr == name.data() + name.size() &&
      value < 4096) {
    return value;
  }
  return std::nullopt;
}

std::optional<std::string_view> csr_name(std::uint32_t address) {
  for (const auto& [name, value] : kCsrs) {
    if (value == address) {
      return name;
    }
  }
  return std::nullopt;
}

std::uint32_t encode_r(std::uint32_t opcode, std::uint32_t rd,
                       std::uint32_t funct3, std::uint32_t rs1,
                       std::uint32_t rs2, std::uint32_t funct7) {
  return ((funct7 & 0x7fU) << 25) | ((rs2 & 0x1fU) << 20) |
         ((rs1 & 0x1fU) << 15) | ((funct3 & 0x7U) << 12) |
         ((rd & 0x1fU) << 7) | (opcode & 0x7fU);
}

std::uint32_t encode_i(std::uint32_t opcode, std::uint32_t rd,
                       std::uint32_t funct3, std::uint32_t rs1,
                       std::uint32_t imm12) {
  return ((imm12 & 0xfffU) << 20) | ((rs1 & 0x1fU) << 15) |
         ((funct3 & 0x7U) << 12) | ((rd & 0x1fU) << 7) | (opcode & 0x7fU);
}

std::uint32_t encode_s(std::uint32_t opcode, std::uint32_t funct3,
                       std::uint32_t rs1, std::uint32_t rs2,
                       std::uint32_t imm12) {
  return (((imm12 >> 5) & 0x7fU) << 25) | ((rs2 & 0x1fU) << 20) |
         ((rs1 & 0x1fU) << 15) | ((funct3 & 0x7U) << 12) |
         ((imm12 & 0x1fU) << 7) | (opcode & 0x7fU);
}

std::uint32_t encode_b(std::uint32_t funct3, std::uint32_t rs1,
                       std::uint32_t rs2, std::int32_t imm13) {
  const auto imm = static_cast<std::uint32_t>(imm13);
  const std::uint32_t imm_12 = (imm >> 12) & 0x1U;
  const std::uint32_t imm_11 = (imm >> 11) & 0x1U;
  const std::uint32_t imm_10_5 = (imm >> 5) & 0x3fU;
  const std::uint32_t imm_4_1 = (imm >> 1) & 0xfU;
  return (imm_12 << 31) | (imm_10_5 << 25) | ((rs2 & 0x1fU) << 20) |
         ((rs1 & 0x1fU) << 15) | ((funct3 & 0x7U) << 12) |
         (imm_4_1 << 8) | (imm_11 << 7) | kOpcodeBranch;
}

std::uint32_t encode_u(std::uint32_t opcode, std::uint32_t rd,
                       std::uint32_t imm20) {
  return ((imm20 & 0xfffffU) << 12) | ((rd & 0x1fU) << 7) |
         (opcode & 0x7fU);
}

std::uint32_t encode_j(std::uint32_t rd, std::int32_t imm21) {
  const auto imm = static_cast<std::uint32_t>(imm21);
  const std::uint32_t imm_20 = (imm >> 20) & 0x1U;
  const std::uint32_t imm_19_12 = (imm >> 12) & 0xffU;
  const std::uint32_t imm_11 = (imm >> 11) & 0x1U;
  const std::uint32_t imm_10_1 = (imm >> 1) & 0x3ffU;
  return (imm_20 << 31) | (imm_10_1 << 21) | (imm_11 << 20) |
         (imm_19_12 << 12) | ((rd & 0x1fU) << 7) | kOpcodeJal;
}

std::uint32_t set_i_imm(std::uint32_t word, std::uint32_t imm12) {
  return (word & 0x000fffffU) | ((imm12 & 0xfffU) << 20);
}

std::uint32_t set_s_imm(std::uint32_t word, std::uint32_t imm12) {
  return (word & 0x01fff07fU) | (((imm12 >> 5) & 0x7fU) << 25) |
         ((imm12 & 0x1fU) << 7);
}

std::uint32_t set_b_imm(std::uint32_t word, std::int32_t imm13) {
  const auto imm = static_cast<std::uint32_t>(imm13);
  return (word & 0x01fff07fU) | (((imm >> 12) & 0x1U) << 31) |
         (((imm >> 5) & 0x3fU) << 25) | (((imm >> 1) & 0xfU) << 8) |
         (((imm >> 11) & 0x1U) << 7);
}

std::uint32_t set_u_imm(std::uint32_t word, std::uint32_t imm20) {
  return (word & 0x00000fffU) | ((imm20 & 0xfffffU) << 12);
}

std::uint32_t set_j_imm(std::uint32_t word, std::int32_t imm21) {
  const auto imm = static_cast<std::uint32_t>(imm21);
  return (word & 0x00000fffU) | (((imm >> 20) & 0x1U) << 31) |
         (((imm >> 1) & 0x3ffU) << 21) | (((imm >> 11) & 0x1U) << 20) |
         (((imm >> 12) & 0xffU) << 12);
}

std::int64_t sign_extend(std::uint64_t value, unsigned bits) {
  const std::uint64_t sign = std::uint64_t{1} << (bits - 1);
  return static_cast<std::int64_t>((value ^ sign) - sign);
}

bool fits_signed(std::int64_t value, unsigned bits) {
  const std::int64_t minimum = -(std::int64_t{1} << (bits - 1));
  const std::int64_t maximum = (std::int64_t{1} << (bits - 1)) - 1;
  return value >= minimum && value <= maximum;
}

}  // namespace roco::isa
