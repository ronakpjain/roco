/// @file linker.cpp
/// @brief Static linker for roco ELF32 relocatable objects.

#include "roco/linker.hpp"

#include "roco/diagnostic.hpp"
#include "roco/isa.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace roco {
namespace {

enum class Group : std::size_t { Text = 0, Rodata = 1, Data = 2, Bss = 3 };

struct Contribution {
  std::size_t object = 0;
  std::size_t section = 0;
  Group group = Group::Text;
  std::uint32_t address = 0;
  std::uint64_t output_offset = 0;
  std::size_t order = 0;
};

struct GlobalDefinition {
  std::size_t object = 0;
  std::size_t symbol = 0;
  std::uint32_t address = 0;
  bool weak = false;
};

std::uint32_t align_up(std::uint32_t value, std::uint64_t alignment) {
  if (alignment == 0) {
    alignment = 1;
  }
  const std::uint64_t remainder = value % alignment;
  if (remainder == 0) {
    return value;
  }
  return static_cast<std::uint32_t>(value + alignment - remainder);
}

bool is_power_of_two(std::uint64_t value) {
  return value != 0 && (value & (value - 1)) == 0;
}

std::uint32_t read_u32(const Section& section, std::uint64_t offset) {
  if (offset + 4 > section.data.size()) {
    throw Error("relocation offset is outside section " + section.name);
  }
  return static_cast<std::uint32_t>(section.data[offset]) |
         (static_cast<std::uint32_t>(section.data[offset + 1]) << 8) |
         (static_cast<std::uint32_t>(section.data[offset + 2]) << 16) |
         (static_cast<std::uint32_t>(section.data[offset + 3]) << 24);
}

void write_u32(Section& section, std::uint64_t offset, std::uint32_t value) {
  if (offset + 4 > section.data.size()) {
    throw Error("relocation offset is outside section " + section.name);
  }
  section.data[offset] = static_cast<std::uint8_t>(value);
  section.data[offset + 1] = static_cast<std::uint8_t>(value >> 8);
  section.data[offset + 2] = static_cast<std::uint8_t>(value >> 16);
  section.data[offset + 3] = static_cast<std::uint8_t>(value >> 24);
}

Section make_output_section(std::string name, std::uint32_t type,
                            std::uint64_t flags) {
  Section section;
  section.name = std::move(name);
  section.type = type;
  section.flags = flags;
  section.align = 4;
  return section;
}

class Linker {
 public:
  Linker(const std::vector<Object>& objects, LinkOptions options)
      : objects_(objects), options_(std::move(options)) {}

  LinkResult run() {
    validate_options();
    collect_sections();
    layout_sections();
    assign_symbols();
    collect_globals();
    insert_builtins();
    apply_relocations();
    build_symbols();

    LinkResult result;
    result.base = options_.base_address;
    result.entry = resolve_entry();
    result.file_end = compute_file_end();
    result.image = std::move(output_);
    return result;
  }

 private:
  void validate_options() const {
    if ((options_.base_address & 3U) != 0) {
      throw Error("link base address must be 4-byte aligned");
    }
    if (options_.entry_symbol.empty()) {
      throw Error("entry symbol must not be empty");
    }
  }

  void collect_sections() {
    section_contribution_.resize(objects_.size());
    assigned_.resize(objects_.size());
    symbol_values_.resize(objects_.size());

    std::vector<Contribution> text;
    std::vector<Contribution> rodata;
    std::vector<Contribution> data;
    std::vector<Contribution> bss;
    std::size_t order = 0;

    for (std::size_t object_index = 0; object_index < objects_.size();
         ++object_index) {
      const Object& object = objects_[object_index];
      section_contribution_[object_index].assign(object.sections.size(), -1);
      assigned_[object_index].assign(object.sections.size(), 0);
      symbol_values_[object_index].assign(object.symbols.size(), 0);

      for (std::size_t section_index = 0;
           section_index < object.sections.size(); ++section_index) {
        const Section& section = object.sections[section_index];
        if ((section.flags & kShfAlloc) == 0) {
          continue;
        }
        if (section.type != kShtProgbits && section.type != kShtNobits) {
          throw Error("unsupported allocatable section type in " +
                      section.name);
        }
        if (!is_power_of_two(section.align)) {
          throw Error("section " + section.name + " has invalid alignment");
        }
        Contribution contribution;
        contribution.object = object_index;
        contribution.section = section_index;
        contribution.order = order++;
        if ((section.flags & kShfExecInstr) != 0) {
          contribution.group = Group::Text;
          text.push_back(contribution);
        } else if (section.type == kShtNobits) {
          contribution.group = Group::Bss;
          bss.push_back(contribution);
        } else if ((section.flags & kShfWrite) != 0) {
          contribution.group = Group::Data;
          data.push_back(contribution);
        } else {
          contribution.group = Group::Rodata;
          rodata.push_back(contribution);
        }
      }
    }

    const auto text_rank = [this](const Contribution& contribution) {
      const std::string& name =
          objects_[contribution.object].sections[contribution.section].name;
      if (name == ".text.init" || name.rfind(".text.init.", 0) == 0) {
        return 0;
      }
      if (name == ".text") {
        return 1;
      }
      return 2;
    };
    std::stable_sort(text.begin(), text.end(),
                     [&](const Contribution& left, const Contribution& right) {
                       const int left_rank = text_rank(left);
                       const int right_rank = text_rank(right);
                       if (left_rank != right_rank) {
                         return left_rank < right_rank;
                       }
                       return left.order < right.order;
                     });

    contributions_.reserve(text.size() + rodata.size() + data.size() +
                           bss.size());
    const auto append = [&](const std::vector<Contribution>& group) {
      for (const Contribution& contribution : group) {
        section_contribution_[contribution.object][contribution.section] =
            static_cast<std::int64_t>(contributions_.size());
        contributions_.push_back(contribution);
      }
    };
    append(text);
    append(rodata);
    append(data);
    append(bss);
  }

  void layout_sections() {
    output_.sections.push_back(make_output_section(
        ".text", kShtProgbits, kShfAlloc | kShfExecInstr));
    output_.sections.push_back(
        make_output_section(".rodata", kShtProgbits, kShfAlloc));
    output_.sections.push_back(
        make_output_section(".data", kShtProgbits, kShfAlloc | kShfWrite));
    output_.sections.push_back(make_output_section(
        ".bss", kShtNobits, kShfAlloc | kShfWrite));

    std::uint32_t cursor = options_.base_address;
    const std::array<Group, 4> groups = {Group::Text, Group::Rodata,
                                         Group::Data, Group::Bss};
    for (const Group group : groups) {
      const std::size_t group_index = static_cast<std::size_t>(group);
      std::uint64_t group_alignment = 4;
      for (const Contribution& contribution : contributions_) {
        if (contribution.group != group) {
          continue;
        }
        group_alignment =
            std::max(group_alignment,
                     objects_[contribution.object]
                         .sections[contribution.section]
                         .align);
      }
      cursor = align_up(cursor, group_alignment);
      Section& section = output_.sections[group_index];
      section.address = cursor;
      section.align = group_alignment;

      for (Contribution& contribution : contributions_) {
        if (contribution.group != group) {
          continue;
        }
        const Section& source =
            objects_[contribution.object].sections[contribution.section];
        const std::uint64_t alignment = std::max<std::uint64_t>(4, source.align);
        cursor = align_up(cursor, alignment);
        contribution.address = cursor;
        contribution.output_offset = cursor - section.address;
        assigned_[contribution.object][contribution.section] = cursor;
        cursor += static_cast<std::uint32_t>(source.total_size());
      }
      section.size = cursor - section.address;
      if (section.type != kShtNobits) {
        section.data.assign(static_cast<std::size_t>(section.size), 0);
      }
    }

    for (const Contribution& contribution : contributions_) {
      const Section& source =
          objects_[contribution.object].sections[contribution.section];
      if (source.type == kShtNobits) {
        continue;
      }
      Section& destination =
          output_.sections[static_cast<std::size_t>(contribution.group)];
      if (contribution.output_offset + source.data.size() >
          destination.data.size()) {
        throw Error("internal error: section layout overflow");
      }
      std::copy(source.data.begin(), source.data.end(),
                destination.data.begin() +
                    static_cast<std::ptrdiff_t>(contribution.output_offset));
    }
  }

  void assign_symbols() {
    for (std::size_t object_index = 0; object_index < objects_.size();
         ++object_index) {
      const Object& object = objects_[object_index];
      for (std::size_t symbol_index = 0;
           symbol_index < object.symbols.size(); ++symbol_index) {
        const Symbol& symbol = object.symbols[symbol_index];
        if (symbol.section == kSymbolAbsolute) {
          symbol_values_[object_index][symbol_index] = symbol.value;
        } else if (symbol.section >= 0 &&
                   static_cast<std::size_t>(symbol.section) <
                       object.sections.size()) {
          const std::size_t section_index =
              static_cast<std::size_t>(symbol.section);
          const Section& section = object.sections[section_index];
          if (symbol.value > section.total_size()) {
            throw Error("symbol " + symbol.name + " lies outside section " +
                        section.name);
          }
          symbol_values_[object_index][symbol_index] =
              assigned_[object_index][section_index] + symbol.value;
        }
      }
    }
  }

  void collect_globals() {
    for (std::size_t object_index = 0; object_index < objects_.size();
         ++object_index) {
      const Object& object = objects_[object_index];
      for (std::size_t symbol_index = 0;
           symbol_index < object.symbols.size(); ++symbol_index) {
        const Symbol& symbol = object.symbols[symbol_index];
        if (symbol.binding == kStbLocal || symbol.name.empty() ||
            !is_defined(symbol)) {
          continue;
        }
        GlobalDefinition definition;
        definition.object = object_index;
        definition.symbol = symbol_index;
        definition.address = symbol_values_[object_index][symbol_index];
        definition.weak = symbol.binding == kStbWeak;
        const auto existing = globals_.find(symbol.name);
        if (existing == globals_.end()) {
          globals_.emplace(symbol.name, definition);
          continue;
        }
        if (!existing->second.weak && !definition.weak) {
          throw Error("duplicate definition of symbol '" + symbol.name + "'");
        }
        if (existing->second.weak && !definition.weak) {
          existing->second = definition;
        }
        // A strong existing definition wins over a later weak one. Two weak
        // definitions keep the first definition in link order.
      }
    }
  }

  void insert_builtins() {
    const Section& text = output_.sections[0];
    const Section& rodata = output_.sections[1];
    const Section& data = output_.sections[2];
    const Section& bss = output_.sections[3];
    add_builtin("__text_start", text.address);
    add_builtin("__text_end", text.address + static_cast<std::uint32_t>(text.size));
    add_builtin("__rodata_start", rodata.address);
    add_builtin("__rodata_end",
                rodata.address + static_cast<std::uint32_t>(rodata.size));
    add_builtin("__data_start", data.address);
    add_builtin("__data_end",
                data.address + static_cast<std::uint32_t>(data.size));
    add_builtin("__bss_start", bss.address);
    add_builtin("__bss_end",
                bss.address + static_cast<std::uint32_t>(bss.size));
    add_builtin("_end", bss.address + static_cast<std::uint32_t>(bss.size));
    add_builtin("__global_pointer$", data.address + 0x800U);
  }

  void add_builtin(const std::string& name, std::uint32_t address) {
    builtins_.emplace(name, address);
  }

  std::uint32_t resolve_global_name(const std::string& name,
                                    bool weak) const {
    const auto global = globals_.find(name);
    if (global != globals_.end()) {
      return global->second.address;
    }
    const auto builtin = builtins_.find(name);
    if (builtin != builtins_.end()) {
      return builtin->second;
    }
    if (weak) {
      return 0;
    }
    throw Error("undefined symbol '" + name + "'");
  }

  std::uint32_t resolve_symbol(std::size_t object_index,
                               std::size_t symbol_index) const {
    const Symbol& symbol = objects_[object_index].symbols[symbol_index];
    if (is_defined(symbol)) {
      if (symbol.binding != kStbLocal && !symbol.name.empty()) {
        // A weak definition may be overridden by a definition in a later
        // object, so global references go through the winner.
        const auto global = globals_.find(symbol.name);
        if (global != globals_.end()) {
          return global->second.address;
        }
      }
      return symbol_values_[object_index][symbol_index];
    }
    if (symbol.name.empty()) {
      throw Error("relocation refers to an unnamed undefined symbol");
    }
    return resolve_global_name(symbol.name, symbol.binding == kStbWeak);
  }

  void apply_relocations() {
    for (const Contribution& contribution : contributions_) {
      const Section& source =
          objects_[contribution.object].sections[contribution.section];
      if (source.relocations.empty()) {
        continue;
      }
      if (source.type == kShtNobits) {
        throw Error("relocation in non-file-backed section " + source.name);
      }
      Section& destination =
          output_.sections[static_cast<std::size_t>(contribution.group)];
      for (const Relocation& relocation : source.relocations) {
        apply_relocation(contribution, source, destination, relocation);
      }
    }
  }

  void apply_relocation(const Contribution& contribution,
                        const Section& source, Section& destination,
                        const Relocation& relocation) {
    if (relocation.offset + 4 > source.data.size()) {
      throw Error("relocation offset is outside section " + source.name);
    }
    const std::uint64_t output_offset =
        contribution.output_offset + relocation.offset;
    const std::uint32_t place =
        contribution.address + relocation.offset;
    const std::uint32_t symbol =
        resolve_symbol(contribution.object, relocation.symbol);
    const std::int64_t value =
        static_cast<std::int64_t>(symbol) + relocation.addend;

    switch (relocation.type) {
      case isa::Reloc::None:
      case isa::Reloc::Align:
      case isa::Reloc::Relax:
        return;
      case isa::Reloc::R32: {
        if (value < std::numeric_limits<std::int32_t>::min() ||
            value > 0xffffffffLL) {
          throw Error("R_RISCV_32 value is outside the 32-bit range");
        }
        write_u32(destination, output_offset,
                  static_cast<std::uint32_t>(value));
        return;
      }
      case isa::Reloc::Hi20: {
        const std::uint32_t high =
            (static_cast<std::uint32_t>(value) + 0x800U) >> 12;
        write_u32(destination, output_offset,
                  isa::set_u_imm(read_u32(destination, output_offset), high));
        return;
      }
      case isa::Reloc::Lo12I: {
        write_u32(destination, output_offset,
                  isa::set_i_imm(read_u32(destination, output_offset),
                                 static_cast<std::uint32_t>(value) & 0xfffU));
        return;
      }
      case isa::Reloc::Lo12S: {
        write_u32(destination, output_offset,
                  isa::set_s_imm(read_u32(destination, output_offset),
                                 static_cast<std::uint32_t>(value) & 0xfffU));
        return;
      }
      case isa::Reloc::Branch: {
        const std::int64_t displacement =
            value - static_cast<std::int64_t>(place);
        if ((displacement & 1) != 0 || displacement < -4096 ||
            displacement > 4094) {
          throw Error("branch target is out of range in section " +
                      source.name);
        }
        write_u32(destination, output_offset,
                  isa::set_b_imm(read_u32(destination, output_offset),
                                 static_cast<std::int32_t>(displacement)));
        return;
      }
      case isa::Reloc::Jal: {
        const std::int64_t displacement =
            value - static_cast<std::int64_t>(place);
        if ((displacement & 1) != 0 || displacement < -1048576 ||
            displacement > 1048574) {
          throw Error("jump target is out of range in section " +
                      source.name);
        }
        write_u32(destination, output_offset,
                  isa::set_j_imm(read_u32(destination, output_offset),
                                 static_cast<std::int32_t>(displacement)));
        return;
      }
      case isa::Reloc::PcrelHi20: {
        const std::int64_t displacement =
            value - static_cast<std::int64_t>(place);
        const std::uint32_t high =
            (static_cast<std::uint32_t>(displacement) + 0x800U) >> 12;
        write_u32(destination, output_offset,
                  isa::set_u_imm(read_u32(destination, output_offset), high));
        return;
      }
      case isa::Reloc::PcrelLo12I:
      case isa::Reloc::PcrelLo12S: {
        const std::int64_t displacement =
            pcrel_lo_value(contribution, relocation) + relocation.addend;
        const std::uint32_t low =
            static_cast<std::uint32_t>(displacement) & 0xfffU;
        const std::uint32_t word = read_u32(destination, output_offset);
        write_u32(destination, output_offset,
                  relocation.type == isa::Reloc::PcrelLo12I
                      ? isa::set_i_imm(word, low)
                      : isa::set_s_imm(word, low));
        return;
      }
      case isa::Reloc::Call:
      case isa::Reloc::CallPlt: {
        const std::int64_t displacement =
            value - static_cast<std::int64_t>(place);
        if (output_offset + 8 > destination.data.size()) {
          throw Error("call relocation does not cover two instructions");
        }
        const std::uint32_t high =
            (static_cast<std::uint32_t>(displacement) + 0x800U) >> 12;
        const std::uint32_t low =
            static_cast<std::uint32_t>(displacement) -
            (high << 12);
        const std::uint32_t auipc = read_u32(destination, output_offset);
        const std::uint32_t jalr = read_u32(destination, output_offset + 4);
        if ((auipc & 0x7fU) != isa::kOpcodeAuipc ||
            (jalr & 0x7fU) != isa::kOpcodeJalr) {
          throw Error("call relocation is not on an auipc/jalr pair");
        }
        write_u32(destination, output_offset, isa::set_u_imm(auipc, high));
        write_u32(destination, output_offset + 4,
                  isa::set_i_imm(jalr, low));
        return;
      }
    }
    throw Error("unsupported relocation type " +
                std::to_string(static_cast<std::uint32_t>(relocation.type)));
  }

  std::int64_t pcrel_lo_value(const Contribution& contribution,
                              const Relocation& relocation) const {
    const Object& object = objects_[contribution.object];
    const Symbol& symbol = object.symbols[relocation.symbol];
    if (symbol.section < 0 ||
        static_cast<std::size_t>(symbol.section) >= object.sections.size()) {
      throw Error("PC-relative low relocation requires a section label");
    }
    const std::size_t section_index =
        static_cast<std::size_t>(symbol.section);
    const Section& section = object.sections[section_index];
    for (const Relocation& candidate : section.relocations) {
      if (candidate.type == isa::Reloc::PcrelHi20 &&
          candidate.offset == symbol.value) {
        const std::uint32_t target =
            resolve_symbol(contribution.object, candidate.symbol);
        const std::int64_t value =
            static_cast<std::int64_t>(target) + candidate.addend;
        const std::uint32_t place =
            assigned_[contribution.object][section_index] + candidate.offset;
        return value - static_cast<std::int64_t>(place);
      }
    }
    throw Error("PC-relative low relocation has no matching high relocation");
  }

  void build_symbols() {
    output_.symbols.push_back(Symbol{});  // ELF null symbol

    std::vector<Symbol> locals;
    std::vector<Symbol> globals;

    for (std::size_t object_index = 0; object_index < objects_.size();
         ++object_index) {
      const Object& object = objects_[object_index];
      for (std::size_t symbol_index = 0;
           symbol_index < object.symbols.size(); ++symbol_index) {
        const Symbol& source = object.symbols[symbol_index];
        if (symbol_index == 0 || source.name.empty()) {
          continue;
        }
        if (!is_defined(source)) {
          continue;
        }
        if (source.section >= 0 &&
            static_cast<std::size_t>(source.section) >=
                object.sections.size()) {
          continue;
        }
        if (source.section >= 0 && section_contribution_[object_index]
                                           [static_cast<std::size_t>(
                                               source.section)] < 0) {
          continue;
        }

        Symbol symbol;
        symbol.name = source.name;
        symbol.size = source.size;
        symbol.binding = source.binding;
        symbol.type = source.type;
        if (source.section == kSymbolAbsolute) {
          symbol.section = kSymbolAbsolute;
          symbol.value = source.value;
        } else {
          const std::size_t section_index =
              static_cast<std::size_t>(source.section);
          const std::int64_t contribution_index =
              section_contribution_[object_index][section_index];
          const Contribution& contribution =
              contributions_[static_cast<std::size_t>(contribution_index)];
          const Section& destination =
              output_.sections[static_cast<std::size_t>(contribution.group)];
          symbol.section = static_cast<std::int64_t>(contribution.group);
          symbol.value = symbol_values_[object_index][symbol_index] -
                         destination.address;
        }

        if (source.binding == kStbLocal) {
          locals.push_back(std::move(symbol));
        } else {
          const auto global = globals_.find(source.name);
          if (global != globals_.end() && global->second.object == object_index &&
              global->second.symbol == symbol_index) {
            globals.push_back(std::move(symbol));
          }
        }
      }
    }

    for (const auto& [name, address] : builtins_) {
      if (globals_.find(name) != globals_.end()) {
        continue;
      }
      Symbol symbol;
      symbol.name = name;
      symbol.section = kSymbolAbsolute;
      symbol.value = address;
      symbol.binding = kStbGlobal;
      globals.push_back(std::move(symbol));
    }
    std::sort(globals.begin(), globals.end(),
              [](const Symbol& left, const Symbol& right) {
                return left.name < right.name;
              });

    for (Symbol& symbol : locals) {
      output_.symbols.push_back(std::move(symbol));
    }
    for (Symbol& symbol : globals) {
      output_.symbols.push_back(std::move(symbol));
    }
  }

  std::uint32_t resolve_entry() const {
    const auto global = globals_.find(options_.entry_symbol);
    if (global != globals_.end()) {
      return global->second.address;
    }
    const auto builtin = builtins_.find(options_.entry_symbol);
    if (builtin != builtins_.end()) {
      return builtin->second;
    }
    throw Error("entry symbol '" + options_.entry_symbol + "' is not defined");
  }

  std::uint32_t compute_file_end() const {
    std::uint32_t end = options_.base_address;
    for (const Section& section : output_.sections) {
      if (section.is_bss()) {
        continue;
      }
      end = std::max(
          end, section.address + static_cast<std::uint32_t>(section.data.size()));
    }
    return end;
  }

  const std::vector<Object>& objects_;
  LinkOptions options_;
  std::vector<Contribution> contributions_;
  std::vector<std::vector<std::int64_t>> section_contribution_;
  std::vector<std::vector<std::uint32_t>> assigned_;
  std::vector<std::vector<std::uint32_t>> symbol_values_;
  Object output_;
  std::unordered_map<std::string, GlobalDefinition> globals_;
  std::unordered_map<std::string, std::uint32_t> builtins_;
};

}  // namespace

LinkResult link(const std::vector<Object>& objects, const LinkOptions& options) {
  Linker linker(objects, options);
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
