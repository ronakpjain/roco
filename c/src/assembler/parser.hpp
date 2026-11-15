#pragma once

/// @file parser.hpp
/// @brief Assembly parser, encoder, and object builder.

#include "assembler/instruction.hpp"
#include "assembler/lexer.hpp"
#include "assembler/preprocessor.hpp"
#include "assembler/section.hpp"

#include "roco/diagnostic.hpp"
#include "roco/isa.hpp"
#include "roco/object.hpp"

#include <algorithm>
#include <cctype>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace roco::cc_asm {

class Assembler {
 public:
  Assembler(std::string_view source, std::string filename)
      : filename_(std::move(filename)),
        tokens_(tokenize(source, filename_)) {
    add_initial_sections();
  }

  Object run() {
    while (!at_end()) {
      parse_line();
    }
    finalize_symbols();
    return build_object();
  }

 private:
  static std::vector<Token> tokenize(std::string_view source,
                                         const std::string& filename) {
    const std::string expanded = MacroExpander(source, filename).run();
    return Lexer(expanded, filename).tokenize();
  }

  void add_initial_sections() {
    add_section(".text", kShtProgbits, kShfAlloc | kShfExecInstr);
    add_section(".rodata", kShtProgbits, kShfAlloc);
    add_section(".data", kShtProgbits, kShfAlloc | kShfWrite);
    add_section(".bss", kShtNobits, kShfAlloc | kShfWrite);
    current_section_ = 0;
  }

  std::size_t add_section(const std::string& name, std::uint32_t type,
                          std::uint64_t flags) {
    const auto existing = section_indices_.find(name);
    if (existing != section_indices_.end()) {
      return existing->second;
    }
    AsmSection section;
    section.name = name;
    section.type = type;
    section.flags = flags;
    const std::size_t index = sections_.size();
    sections_.push_back(std::move(section));
    section_indices_.emplace(name, index);
    return index;
  }

  [[noreturn]] void fail(const Token& token, const std::string& message) const {
    throw Error(filename_ + ":" + std::to_string(token.line) + ":" +
                std::to_string(token.column) + ": " + message);
  }

  [[noreturn]] void fail(const std::string& message) const {
    fail(peek(), message);
  }

  const Token& peek(std::size_t lookahead = 0) const {
    const std::size_t index = position_ + lookahead;
    if (index >= tokens_.size()) {
      return tokens_.back();
    }
    return tokens_[index];
  }

  const Token& advance() {
    const Token& token = peek();
    if (position_ + 1 < tokens_.size()) {
      ++position_;
    }
    return token;
  }

  bool at_end() const { return peek().kind == TokenKind::End; }

  bool at_end_of_line() const {
    return peek().kind == TokenKind::EndOfLine ||
           peek().kind == TokenKind::End;
  }

  bool is_punct(char character, std::size_t lookahead = 0) const {
    const Token& token = peek(lookahead);
    return token.kind == TokenKind::Punct && token.text.size() == 1 &&
           token.text[0] == character;
  }

  bool consume_punct(char character) {
    if (!is_punct(character)) {
      return false;
    }
    advance();
    return true;
  }

  void expect_punct(char character) {
    if (!consume_punct(character)) {
      fail(std::string("expected '") + character + "'");
    }
  }

  void expect_end_of_line() {
    if (!at_end_of_line()) {
      fail("unexpected token '" + peek().text + "' at end of line");
    }
    if (peek().kind == TokenKind::EndOfLine) {
      advance();
    }
  }

  std::string expect_identifier() {
    if (peek().kind != TokenKind::Identifier) {
      fail("expected an identifier");
    }
    return advance().text;
  }

  int parse_register_operand() {
    if (peek().kind != TokenKind::Identifier) {
      fail("expected a register");
    }
    const Token token = advance();
    const int number = isa::parse_register(token.text);
    if (number < 0) {
      fail(token, "unknown register '" + token.text + "'");
    }
    return number;
  }

  int parse_vector_register_operand() {
    if (peek().kind != TokenKind::Identifier) {
      fail("expected a vector register");
    }
    const Token token = advance();
    const int number = isa::parse_vector_register(token.text);
    if (number < 0) {
      fail(token, "unknown vector register '" + token.text + "'");
    }
    return number;
  }

  void parse_line() {
    while (!at_end() && !at_end_of_line()) {
      if ((peek().kind == TokenKind::Identifier ||
           peek().kind == TokenKind::Number) &&
          is_punct(':', 1)) {
        const Token label = advance();
        expect_punct(':');
        define_label(label);
        continue;
      }
      break;
    }

    if (at_end_of_line()) {
      expect_end_of_line();
      return;
    }

    if (peek().kind == TokenKind::Identifier &&
        !peek().text.empty() && peek().text[0] == '.') {
      parse_directive(advance().text);
    } else if (peek().kind == TokenKind::Identifier) {
      parse_instruction(advance().text);
    } else {
      fail("expected an instruction or directive");
    }
    expect_end_of_line();
  }

  void define_label(const Token& token) {
    if (token.kind == TokenKind::Number) {
      define_numeric_label(static_cast<int>(token.number), token);
      return;
    }
    if (token.kind != TokenKind::Identifier) {
      fail(token, "invalid label");
    }
    AsmSymbol& symbol = symbol_for(token.text);
    if (symbol.defined) {
      fail(token, "duplicate label '" + token.text + "'");
    }
    symbol.defined = true;
    symbol.section = static_cast<std::int64_t>(current_section_);
    symbol.value = static_cast<std::uint32_t>(current_offset());
  }

  void define_numeric_label(int number, const Token& token) {
    std::string name;
    const auto pending = pending_forward_.find(number);
    if (pending != pending_forward_.end()) {
      name = pending->second;
      pending_forward_.erase(pending);
    } else {
      name = ".Lnum." + std::to_string(number) + "." +
             std::to_string(numeric_label_sequence_++);
      symbol_for(name);
    }
    AsmSymbol& symbol = symbol_for(name);
    if (symbol.defined) {
      fail(token, "duplicate numeric label");
    }
    symbol.defined = true;
    symbol.section = static_cast<std::int64_t>(current_section_);
    symbol.value = static_cast<std::uint32_t>(current_offset());
    latest_numeric_[number] = name;
  }

  AsmSymbol& symbol_for(const std::string& name) {
    const auto existing = symbols_.find(name);
    if (existing != symbols_.end()) {
      return existing->second;
    }
    AsmSymbol symbol;
    symbol.name = name;
    const auto [iterator, inserted] =
        symbols_.emplace(name, std::move(symbol));
    (void)inserted;
    return iterator->second;
  }

  std::string symbol_name_for_local_ref(const Token& token, bool forward) {
    const int number = static_cast<int>(token.number);
    if (!forward) {
      const auto iterator = latest_numeric_.find(number);
      if (iterator == latest_numeric_.end()) {
        fail(token, "no previous definition of numeric label " +
                        std::to_string(number) + "b");
      }
      return iterator->second;
    }

    const auto pending = pending_forward_.find(number);
    if (pending != pending_forward_.end()) {
      return pending->second;
    }
    const std::string name = ".Lnum." + std::to_string(number) + "." +
                             std::to_string(numeric_label_sequence_++);
    symbol_for(name);
    pending_forward_[number] = name;
    return name;
  }

  Expr parse_expr() { return parse_additive(); }

  Expr parse_additive() {
    Expr left = parse_multiplicative();
    while (is_punct('+') || is_punct('-')) {
      const char operation = advance().text[0];
      Expr right = parse_multiplicative();
      if (!left.has_symbol && !right.has_symbol) {
        if (operation == '+') {
          left.value += right.value;
        } else {
          left.value -= right.value;
        }
        continue;
      }
      if (left.marker != Marker::None || right.marker != Marker::None) {
        fail("relocation markers cannot be combined in an expression");
      }
      if (!left.has_symbol && right.has_symbol && operation == '+') {
        right.value += left.value;
        left = std::move(right);
        continue;
      }
      if (left.has_symbol && !right.has_symbol) {
        left.value += operation == '+' ? right.value : -right.value;
        continue;
      }
      fail("unsupported symbol arithmetic");
    }
    return left;
  }

  Expr parse_multiplicative() {
    Expr left = parse_unary();
    while (is_punct('*') || is_punct('/') || is_punct('%')) {
      const char operation = advance().text[0];
      Expr right = parse_unary();
      if (left.has_symbol || right.has_symbol) {
        fail("symbols cannot be multiplied or divided");
      }
      if (operation == '*') {
        left.value *= right.value;
      } else if (right.value == 0) {
        fail("division by zero in expression");
      } else if (operation == '/') {
        left.value /= right.value;
      } else {
        left.value %= right.value;
      }
    }
    return left;
  }

  Expr parse_unary() {
    if (consume_punct('+')) {
      return parse_unary();
    }
    if (consume_punct('-')) {
      Expr value = parse_unary();
      if (value.has_symbol) {
        fail("cannot negate a symbol");
      }
      value.value = -value.value;
      return value;
    }
    if (consume_punct('~')) {
      Expr value = parse_unary();
      if (value.has_symbol) {
        fail("cannot complement a symbol");
      }
      value.value = ~value.value;
      return value;
    }
    return parse_primary();
  }

  Expr parse_primary() {
    if (is_punct('%')) {
      const Token marker_token = advance();
      const std::string marker = expect_identifier();
      Marker kind = Marker::None;
      if (marker == "hi") {
        kind = Marker::Hi;
      } else if (marker == "lo") {
        kind = Marker::Lo;
      } else if (marker == "pcrel_hi") {
        kind = Marker::PcrelHi;
      } else if (marker == "pcrel_lo") {
        kind = Marker::PcrelLo;
      } else {
        fail(marker_token, "unsupported relocation marker '%" + marker + "'");
      }
      expect_punct('(');
      Expr expression = parse_expr();
      expect_punct(')');
      if (expression.marker != Marker::None) {
        fail(marker_token, "nested relocation markers are not supported");
      }
      expression.marker = kind;
      return expression;
    }
    if (consume_punct('(')) {
      Expr expression = parse_expr();
      expect_punct(')');
      return expression;
    }
    if (peek().kind == TokenKind::Number) {
      Expr expression;
      expression.value = static_cast<std::int64_t>(advance().number);
      return expression;
    }
    if (peek().kind == TokenKind::LocalRef) {
      const Token token = advance();
      const bool forward = token.text.back() == 'f';
      Expr expression;
      expression.has_symbol = true;
      expression.symbol = symbol_name_for_local_ref(token, forward);
      return expression;
    }
    if (peek().kind == TokenKind::Identifier) {
      const Token token = advance();
      if (token.text == ".") {
        Expr expression;
        expression.has_symbol = true;
        expression.symbol = make_dot_symbol();
        return expression;
      }
      const auto iterator = symbols_.find(token.text);
      if (iterator != symbols_.end() && iterator->second.defined &&
          iterator->second.section == kSymbolAbsolute) {
        Expr expression;
        expression.value = iterator->second.value;
        return expression;
      }
      symbol_for(token.text);
      Expr expression;
      expression.has_symbol = true;
      expression.symbol = token.text;
      return expression;
    }
    fail("expected an expression");
  }

  std::string make_dot_symbol() {
    const std::string name =
        ".Ldot." + std::to_string(numeric_label_sequence_++);
    AsmSymbol& symbol = symbol_for(name);
    symbol.defined = true;
    symbol.section = static_cast<std::int64_t>(current_section_);
    symbol.value = static_cast<std::uint32_t>(current_offset());
    return name;
  }

  struct MemoryOperand {
    Expr offset;
    int base = 0;
  };

  MemoryOperand parse_memory_operand() {
    MemoryOperand operand;
    if (is_punct('(')) {
      operand.offset.value = 0;
    } else {
      operand.offset = parse_expr();
    }
    expect_punct('(');
    operand.base = parse_register_operand();
    expect_punct(')');
    return operand;
  }

  std::uint64_t current_offset() const {
    return sections_[current_section_].offset();
  }

  void set_section(std::size_t index) { current_section_ = index; }

  void align_current(std::uint64_t alignment, std::uint64_t fill = 0) {
    if (alignment == 0 || (alignment & (alignment - 1)) != 0) {
      fail("alignment must be a power of two");
    }
    AsmSection& section = sections_[current_section_];
    section.align = std::max(section.align, alignment);
    const std::uint64_t offset = section.offset();
    const std::uint64_t remainder = offset % alignment;
    if (remainder == 0) {
      return;
    }
    std::uint64_t padding = alignment - remainder;
    const bool executable = (section.flags & kShfExecInstr) != 0;
    if (fill == 0 && executable) {
      // Executable padding must be a legal instruction, not data zero.
      while (padding >= 4) {
        emit_u32(0x00000013U);
        padding -= 4;
      }
    }
    if (padding != 0) {
      emit_fill(padding, static_cast<std::uint8_t>(fill));
    }
  }

  void emit_fill(std::uint64_t count, std::uint8_t fill = 0) {
    AsmSection& section = sections_[current_section_];
    if (section.type == kShtNobits) {
      section.bss_size += count;
      return;
    }
    section.data.insert(section.data.end(), static_cast<std::size_t>(count),
                        fill);
  }

  void emit_u8(std::uint8_t value) {
    AsmSection& section = sections_[current_section_];
    if (section.type == kShtNobits) {
      fail("cannot emit initialized data in a bss section");
    }
    section.data.push_back(value);
  }

  void emit_u16(std::uint16_t value) {
    emit_u8(static_cast<std::uint8_t>(value));
    emit_u8(static_cast<std::uint8_t>(value >> 8));
  }

  void emit_u32(std::uint32_t value) {
    emit_u8(static_cast<std::uint8_t>(value));
    emit_u8(static_cast<std::uint8_t>(value >> 8));
    emit_u8(static_cast<std::uint8_t>(value >> 16));
    emit_u8(static_cast<std::uint8_t>(value >> 24));
  }

  std::uint32_t place_instruction(std::uint32_t word) {
    const auto offset = static_cast<std::uint32_t>(current_offset());
    emit_u32(word);
    return offset;
  }

  void add_relocation(std::uint32_t offset, isa::Reloc type,
                      const Expr& expression) {
    if (!expression.has_symbol) {
      fail("internal error: relocation without a symbol");
    }
    sections_[current_section_].relocations.push_back(
        {offset, type, expression.symbol, expression.value});
  }

  std::int64_t require_constant(const Expr& expression,
                                const std::string& what) {
    if (expression.has_symbol) {
      fail("expected a constant for " + what);
    }
    return expression.value;
  }

  std::uint32_t constant_to_32(std::int64_t value,
                               const std::string& what) {
    if (value < std::numeric_limits<std::int32_t>::min() ||
        value > 0xffffffffLL) {
      fail(what + " is outside the 32-bit range");
    }
    return static_cast<std::uint32_t>(value);
  }

  void parse_instruction(const std::string& name) {
    if (!name.empty() && name[0] == 'v') {
      parse_vector_instruction(name);
      return;
    }
    if (name.rfind("lr.", 0) == 0 || name.rfind("sc.", 0) == 0 ||
        name.rfind("amo", 0) == 0) {
      parse_atomic_instruction(name);
      return;
    }
    if (name == "nop") {
      emit_u32(isa::encode_i(isa::kOpcodeOpImm, 0, 0, 0, 0));
      return;
    }
    if (name == "mv") {
      const int rd = parse_register_operand();
      expect_punct(',');
      const int rs = parse_register_operand();
      emit_u32(isa::encode_i(isa::kOpcodeOpImm, static_cast<std::uint32_t>(rd),
                             0, static_cast<std::uint32_t>(rs), 0));
      return;
    }
    if (name == "not") {
      const int rd = parse_register_operand();
      expect_punct(',');
      const int rs = parse_register_operand();
      emit_u32(isa::encode_i(isa::kOpcodeOpImm, static_cast<std::uint32_t>(rd),
                             4, static_cast<std::uint32_t>(rs), 0xfff));
      return;
    }
    if (name == "neg") {
      const int rd = parse_register_operand();
      expect_punct(',');
      const int rs = parse_register_operand();
      emit_u32(isa::encode_r(isa::kOpcodeOp, static_cast<std::uint32_t>(rd), 0,
                             0, static_cast<std::uint32_t>(rs),
                             isa::kFunct7SubSra));
      return;
    }
    if (name == "seqz" || name == "snez" || name == "sltz" || name == "sgtz") {
      const int rd = parse_register_operand();
      expect_punct(',');
      const int rs = parse_register_operand();
      if (name == "seqz") {
        emit_u32(isa::encode_i(isa::kOpcodeOpImm,
                               static_cast<std::uint32_t>(rd), 3,
                               static_cast<std::uint32_t>(rs), 1));
      } else if (name == "snez") {
        emit_u32(isa::encode_r(isa::kOpcodeOp, static_cast<std::uint32_t>(rd),
                               3, 0, static_cast<std::uint32_t>(rs),
                               isa::kFunct7Base));
      } else if (name == "sltz") {
        emit_u32(isa::encode_r(isa::kOpcodeOp, static_cast<std::uint32_t>(rd),
                               2, static_cast<std::uint32_t>(rs), 0,
                               isa::kFunct7Base));
      } else {
        emit_u32(isa::encode_r(isa::kOpcodeOp, static_cast<std::uint32_t>(rd),
                               2, 0, static_cast<std::uint32_t>(rs),
                               isa::kFunct7Base));
      }
      return;
    }
    if (name == "li") {
      parse_li();
      return;
    }
    if (name == "la") {
      parse_la();
      return;
    }
    if (name == "j") {
      emit_jump(0, parse_expr());
      return;
    }
    if (name == "jr") {
      const int rs = parse_register_operand();
      emit_u32(isa::encode_i(isa::kOpcodeJalr, 0, 0,
                             static_cast<std::uint32_t>(rs), 0));
      return;
    }
    if (name == "ret") {
      emit_u32(isa::encode_i(isa::kOpcodeJalr, 0, 0, 1, 0));
      return;
    }
    if (name == "call" || name == "tail") {
      const Expr target = parse_expr();
      if (target.has_symbol) {
        if (target.marker != Marker::None) {
          fail("call and tail targets cannot carry a relocation marker");
        }
        const int temporary = name == "call" ? 1 : 6;
        const std::uint32_t offset = place_instruction(isa::encode_u(
            isa::kOpcodeAuipc, static_cast<std::uint32_t>(temporary), 0));
        place_instruction(isa::encode_i(
            isa::kOpcodeJalr, name == "call" ? 1U : 0U, 0,
            static_cast<std::uint32_t>(temporary), 0));
        add_relocation(offset, isa::Reloc::CallPlt, target);
      } else {
        emit_jump(name == "call" ? 1 : 0, target);
      }
      return;
    }
    if (name == "beqz" || name == "bnez" || name == "bltz" ||
        name == "bgez" || name == "blez" || name == "bgtz") {
      const int rs = parse_register_operand();
      expect_punct(',');
      const Expr target = parse_expr();
      if (name == "beqz") {
        emit_branch(0, rs, 0, target);
      } else if (name == "bnez") {
        emit_branch(1, rs, 0, target);
      } else if (name == "bltz") {
        emit_branch(4, rs, 0, target);
      } else if (name == "bgez") {
        emit_branch(5, rs, 0, target);
      } else if (name == "blez") {
        emit_branch(5, 0, rs, target);
      } else {
        emit_branch(4, 0, rs, target);
      }
      return;
    }
    if (name == "bgt" || name == "ble" || name == "bgtu" || name == "bleu") {
      const int rs = parse_register_operand();
      expect_punct(',');
      const int rt = parse_register_operand();
      expect_punct(',');
      const Expr target = parse_expr();
      if (name == "bgt") {
        emit_branch(4, rt, rs, target);
      } else if (name == "ble") {
        emit_branch(5, rt, rs, target);
      } else if (name == "bgtu") {
        emit_branch(6, rt, rs, target);
      } else {
        emit_branch(7, rt, rs, target);
      }
      return;
    }
    if (name == "csrr") {
      const int rd = parse_register_operand();
      expect_punct(',');
      const std::uint32_t csr = parse_csr_operand();
      emit_csr(2, rd, 0, csr);
      return;
    }
    if (name == "csrrw" || name == "csrrs" || name == "csrrc") {
      const int rd = parse_register_operand();
      expect_punct(',');
      const std::uint32_t csr = parse_csr_operand();
      expect_punct(',');
      const int rs = parse_register_operand();
      emit_csr(name == "csrrw" ? 1 : (name == "csrrs" ? 2 : 3), rd, rs, csr);
      return;
    }
    if (name == "csrrwi" || name == "csrrsi" || name == "csrrci") {
      const int rd = parse_register_operand();
      expect_punct(',');
      const std::uint32_t csr = parse_csr_operand();
      expect_punct(',');
      const std::int64_t immediate =
          require_constant(parse_expr(), "CSR immediate");
      if (immediate < 0 || immediate > 31) {
        fail("CSR immediate must be in the range 0..31");
      }
      emit_csr(name == "csrrwi" ? 5 : (name == "csrrsi" ? 6 : 7), rd,
               static_cast<int>(immediate), csr);
      return;
    }
    if (name == "csrw" || name == "csrs" || name == "csrc") {
      const std::uint32_t csr = parse_csr_operand();
      expect_punct(',');
      const int rs = parse_register_operand();
      emit_csr(name == "csrw" ? 1 : (name == "csrs" ? 2 : 3), 0, rs, csr);
      return;
    }
    if (name == "csrwi" || name == "csrsi" || name == "csrci") {
      const std::uint32_t csr = parse_csr_operand();
      expect_punct(',');
      const std::int64_t immediate =
          require_constant(parse_expr(), "CSR immediate");
      if (immediate < 0 || immediate > 31) {
        fail("CSR immediate must be in the range 0..31");
      }
      emit_csr(name == "csrwi" ? 5 : (name == "csrsi" ? 6 : 7), 0,
               static_cast<int>(immediate), csr);
      return;
    }
    if (name == "fence" || name == "fence.i" || name == "fence.tso") {
      parse_fence(name);
      return;
    }
    if (name == "sfence.vma") {
      parse_sfence_vma();
      return;
    }
    if (name == "ecall") {
      emit_u32(0x00000073);
      return;
    }
    if (name == "ebreak") {
      emit_u32(0x00100073);
      return;
    }
    if (name == "mret") {
      emit_u32(0x30200073);
      return;
    }
    if (name == "sret") {
      emit_u32(0x10200073);
      return;
    }
    if (name == "wfi") {
      emit_u32(0x10500073);
      return;
    }

    const auto iterator = instruction_specs().find(name);
    if (iterator == instruction_specs().end()) {
      fail("unknown instruction '" + name + "'");
    }
    emit_spec(iterator->second);
  }

  void parse_li() {
    const int rd = parse_register_operand();
    expect_punct(',');
    const Expr expression = parse_expr();
    if (expression.marker != Marker::None) {
      fail("li does not accept a relocation marker");
    }
    const std::int64_t raw = require_constant(expression, "li");
    const std::uint32_t value = constant_to_32(raw, "li immediate");
    const std::int32_t signed_value = static_cast<std::int32_t>(value);
    if (isa::fits_signed(signed_value, 12)) {
      emit_u32(isa::encode_i(isa::kOpcodeOpImm, static_cast<std::uint32_t>(rd),
                             0, 0,
                             static_cast<std::uint32_t>(signed_value) & 0xfffU));
      return;
    }
    const std::uint32_t high = ((value + 0x800U) >> 12) & 0xfffffU;
    const std::uint32_t low = value & 0xfffU;
    emit_u32(isa::encode_u(isa::kOpcodeLui, static_cast<std::uint32_t>(rd),
                           high));
    if (low != 0) {
      emit_u32(isa::encode_i(isa::kOpcodeOpImm, static_cast<std::uint32_t>(rd),
                             0, static_cast<std::uint32_t>(rd), low));
    }
  }

  void parse_la() {
    const int rd = parse_register_operand();
    expect_punct(',');
    Expr expression = parse_expr();
    if (expression.marker != Marker::None) {
      fail("la does not accept a relocation marker");
    }
    if (!expression.has_symbol) {
      const std::uint32_t value =
          constant_to_32(expression.value, "la address");
      const std::uint32_t high = ((value + 0x800U) >> 12) & 0xfffffU;
      const std::uint32_t low = value & 0xfffU;
      emit_u32(isa::encode_u(isa::kOpcodeLui, static_cast<std::uint32_t>(rd),
                             high));
      if (low != 0) {
        emit_u32(isa::encode_i(isa::kOpcodeOpImm,
                               static_cast<std::uint32_t>(rd), 0,
                               static_cast<std::uint32_t>(rd), low));
      }
      return;
    }
    // GNU's la is PC-relative, which also keeps code correct when it runs
    // through a virtual alias. The low relocation refers to the AUIPC site.
    const std::uint32_t high_offset = place_instruction(
        isa::encode_u(isa::kOpcodeAuipc, static_cast<std::uint32_t>(rd), 0));
    add_relocation(high_offset, isa::Reloc::PcrelHi20, expression);
    const std::string anchor_name =
        ".Lla." + std::to_string(numeric_label_sequence_++);
    AsmSymbol& anchor = symbol_for(anchor_name);
    anchor.defined = true;
    anchor.section = static_cast<std::int64_t>(current_section_);
    anchor.value = high_offset;
    Expr low_expression;
    low_expression.has_symbol = true;
    low_expression.symbol = anchor_name;
    const std::uint32_t low_offset = place_instruction(isa::encode_i(
        isa::kOpcodeOpImm, static_cast<std::uint32_t>(rd), 0,
        static_cast<std::uint32_t>(rd), 0));
    add_relocation(low_offset, isa::Reloc::PcrelLo12I, low_expression);
  }

  void emit_spec(const InstructionSpec& spec) {
    switch (spec.format) {
      case Format::R: {
        const int rd = parse_register_operand();
        expect_punct(',');
        const int rs1 = parse_register_operand();
        expect_punct(',');
        const int rs2 = parse_register_operand();
        emit_u32(isa::encode_r(
            spec.opcode, static_cast<std::uint32_t>(rd), spec.funct3,
            static_cast<std::uint32_t>(rs1), static_cast<std::uint32_t>(rs2),
            spec.funct7));
        return;
      }
      case Format::I: {
        const int rd = parse_register_operand();
        expect_punct(',');
        const int rs1 = parse_register_operand();
        expect_punct(',');
        const Expr immediate = parse_expr();
        emit_i_immediate(spec, rd, rs1, immediate);
        return;
      }
      case Format::Shift: {
        const int rd = parse_register_operand();
        expect_punct(',');
        const int rs1 = parse_register_operand();
        expect_punct(',');
        const Expr amount = parse_expr();
        if (amount.marker != Marker::None) {
          fail("shift amount cannot carry a relocation");
        }
        const std::int64_t value = require_constant(amount, "shift amount");
        if (value < 0 || value > 31) {
          fail("shift amount must be in the range 0..31");
        }
        emit_u32(isa::encode_i(
            spec.opcode, static_cast<std::uint32_t>(rd), spec.funct3,
            static_cast<std::uint32_t>(rs1),
            static_cast<std::uint32_t>(spec.funct7 << 5) | static_cast<std::uint32_t>(value)));
        return;
      }
      case Format::Load: {
        const int rd = parse_register_operand();
        expect_punct(',');
        const MemoryOperand memory = parse_memory_operand();
        emit_load(spec, rd, memory);
        return;
      }
      case Format::Store: {
        const int rs2 = parse_register_operand();
        expect_punct(',');
        const MemoryOperand memory = parse_memory_operand();
        emit_store(spec, rs2, memory);
        return;
      }
      case Format::Branch: {
        const int rs1 = parse_register_operand();
        expect_punct(',');
        const int rs2 = parse_register_operand();
        expect_punct(',');
        emit_branch(spec.funct3, rs1, rs2, parse_expr());
        return;
      }
      case Format::Upper: {
        const int rd = parse_register_operand();
        expect_punct(',');
        emit_upper(spec, rd, parse_expr());
        return;
      }
      case Format::Jump: {
        const int rd = parse_register_operand();
        expect_punct(',');
        emit_jump(rd, parse_expr());
        return;
      }
      case Format::Jalr: {
        const int rd = parse_register_operand();
        expect_punct(',');
        if (peek().kind == TokenKind::Identifier &&
            isa::parse_register(peek().text) >= 0 &&
            (peek(1).kind == TokenKind::EndOfLine ||
             peek(1).kind == TokenKind::End)) {
          const int rs1 = parse_register_operand();
          emit_u32(isa::encode_i(isa::kOpcodeJalr,
                                 static_cast<std::uint32_t>(rd), 0,
                                 static_cast<std::uint32_t>(rs1), 0));
          return;
        }
        const MemoryOperand memory = parse_memory_operand();
        emit_jalr(spec, rd, memory);
        return;
      }
    }
  }

  void emit_i_immediate(const InstructionSpec& spec, int rd, int rs1,
                        const Expr& immediate) {
    if (immediate.has_symbol) {
      if (immediate.marker == Marker::Hi ||
          immediate.marker == Marker::PcrelHi) {
        fail("this instruction requires a low relocation, not %hi");
      }
      const auto type = immediate.marker == Marker::PcrelLo
                            ? isa::Reloc::PcrelLo12I
                            : isa::Reloc::Lo12I;
      const std::uint32_t offset = place_instruction(isa::encode_i(
          spec.opcode, static_cast<std::uint32_t>(rd), spec.funct3,
          static_cast<std::uint32_t>(rs1), 0));
      add_relocation(offset, type, immediate);
      return;
    }
    std::int64_t value = immediate.value;
    if (immediate.marker == Marker::Lo ||
        immediate.marker == Marker::PcrelLo) {
      value = isa::sign_extend(static_cast<std::uint64_t>(value) & 0xfffU, 12);
    } else if (immediate.marker == Marker::Hi ||
               immediate.marker == Marker::PcrelHi) {
      fail("this instruction requires a low relocation, not %hi");
    }
    if (!isa::fits_signed(value, 12)) {
      fail("immediate does not fit in 12 signed bits");
    }
    emit_u32(isa::encode_i(
        spec.opcode, static_cast<std::uint32_t>(rd), spec.funct3,
        static_cast<std::uint32_t>(rs1),
        static_cast<std::uint32_t>(value) & 0xfffU));
  }

  void emit_load(const InstructionSpec& spec, int rd,
                 const MemoryOperand& memory) {
    if (memory.offset.has_symbol) {
      if (memory.offset.marker == Marker::Hi ||
          memory.offset.marker == Marker::PcrelHi) {
        fail("loads require a low relocation, not %hi");
      }
      const auto type = memory.offset.marker == Marker::PcrelLo
                            ? isa::Reloc::PcrelLo12I
                            : isa::Reloc::Lo12I;
      const std::uint32_t offset = place_instruction(isa::encode_i(
          spec.opcode, static_cast<std::uint32_t>(rd), spec.funct3,
          static_cast<std::uint32_t>(memory.base), 0));
      add_relocation(offset, type, memory.offset);
      return;
    }
    std::int64_t value = memory.offset.value;
    if (memory.offset.marker == Marker::Lo ||
        memory.offset.marker == Marker::PcrelLo) {
      value = isa::sign_extend(static_cast<std::uint64_t>(value) & 0xfffU, 12);
    } else if (memory.offset.marker == Marker::Hi ||
               memory.offset.marker == Marker::PcrelHi) {
      fail("loads require a low relocation, not %hi");
    }
    if (!isa::fits_signed(value, 12)) {
      fail("load offset does not fit in 12 signed bits");
    }
    emit_u32(isa::encode_i(
        spec.opcode, static_cast<std::uint32_t>(rd), spec.funct3,
        static_cast<std::uint32_t>(memory.base),
        static_cast<std::uint32_t>(value) & 0xfffU));
  }

  void emit_store(const InstructionSpec& spec, int rs2,
                  const MemoryOperand& memory) {
    if (memory.offset.has_symbol) {
      if (memory.offset.marker == Marker::Hi ||
          memory.offset.marker == Marker::PcrelHi) {
        fail("stores require a low relocation, not %hi");
      }
      const auto type = memory.offset.marker == Marker::PcrelLo
                            ? isa::Reloc::PcrelLo12S
                            : isa::Reloc::Lo12S;
      const std::uint32_t offset = place_instruction(isa::encode_s(
          spec.opcode, spec.funct3, static_cast<std::uint32_t>(memory.base),
          static_cast<std::uint32_t>(rs2), 0));
      add_relocation(offset, type, memory.offset);
      return;
    }
    std::int64_t value = memory.offset.value;
    if (memory.offset.marker == Marker::Lo ||
        memory.offset.marker == Marker::PcrelLo) {
      value = isa::sign_extend(static_cast<std::uint64_t>(value) & 0xfffU, 12);
    } else if (memory.offset.marker == Marker::Hi ||
               memory.offset.marker == Marker::PcrelHi) {
      fail("stores require a low relocation, not %hi");
    }
    if (!isa::fits_signed(value, 12)) {
      fail("store offset does not fit in 12 signed bits");
    }
    emit_u32(isa::encode_s(
        spec.opcode, spec.funct3, static_cast<std::uint32_t>(memory.base),
        static_cast<std::uint32_t>(rs2),
        static_cast<std::uint32_t>(value) & 0xfffU));
  }

  void emit_branch(std::uint32_t funct3, int rs1, int rs2,
                   const Expr& target) {
    if (target.has_symbol) {
      if (target.marker != Marker::None) {
        fail("branch targets cannot carry a relocation marker");
      }
      const std::uint32_t offset =
          place_instruction(isa::encode_b(funct3,
                                          static_cast<std::uint32_t>(rs1),
                                          static_cast<std::uint32_t>(rs2), 0));
      add_relocation(offset, isa::Reloc::Branch, target);
      return;
    }
    if ((target.value & 1) != 0) {
      fail("branch offset must be even");
    }
    if (!isa::fits_signed(target.value, 13)) {
      fail("branch offset is out of range");
    }
    emit_u32(isa::encode_b(
        funct3, static_cast<std::uint32_t>(rs1),
        static_cast<std::uint32_t>(rs2),
        static_cast<std::int32_t>(target.value)));
  }

  void emit_jump(int rd, const Expr& target) {
    if (target.has_symbol) {
      if (target.marker != Marker::None) {
        fail("jump targets cannot carry a relocation marker");
      }
      const std::uint32_t offset = place_instruction(
          isa::encode_j(static_cast<std::uint32_t>(rd), 0));
      add_relocation(offset, isa::Reloc::Jal, target);
      return;
    }
    if ((target.value & 1) != 0) {
      fail("jump offset must be even");
    }
    if (!isa::fits_signed(target.value, 21)) {
      fail("jump offset is out of range");
    }
    emit_u32(isa::encode_j(static_cast<std::uint32_t>(rd),
                           static_cast<std::int32_t>(target.value)));
  }

  void emit_upper(const InstructionSpec& spec, int rd, const Expr& value) {
    if (value.has_symbol) {
      isa::Reloc type = isa::Reloc::None;
      if (spec.opcode == isa::kOpcodeLui) {
        if (value.marker == Marker::Lo ||
            value.marker == Marker::PcrelLo) {
          fail("lui requires a high relocation, not %lo");
        }
        if (value.marker == Marker::PcrelHi) {
          fail("lui cannot use %pcrel_hi; use auipc");
        }
        type = isa::Reloc::Hi20;
      } else {
        if (value.marker == Marker::Lo ||
            value.marker == Marker::PcrelLo) {
          fail("auipc requires a high relocation, not %lo");
        }
        type = isa::Reloc::PcrelHi20;
      }
      const std::uint32_t offset = place_instruction(
          isa::encode_u(spec.opcode, static_cast<std::uint32_t>(rd), 0));
      add_relocation(offset, type, value);
      return;
    }

    std::uint32_t immediate = 0;
    if (value.marker == Marker::Hi) {
      immediate = static_cast<std::uint32_t>(
                      (static_cast<std::uint64_t>(value.value) + 0x800U) >> 12) &
                  0xfffffU;
    } else if (value.marker == Marker::Lo ||
               value.marker == Marker::PcrelLo) {
      fail("upper-immediate instruction cannot use %lo");
    } else {
      immediate =
          static_cast<std::uint32_t>(value.value) & 0xfffffU;
    }
    emit_u32(isa::encode_u(spec.opcode, static_cast<std::uint32_t>(rd),
                           immediate));
  }

  void emit_jalr(const InstructionSpec& spec, int rd,
                 const MemoryOperand& memory) {
    if (memory.offset.has_symbol) {
      if (memory.offset.marker == Marker::Hi ||
          memory.offset.marker == Marker::PcrelHi) {
        fail("jalr requires a low relocation, not %hi");
      }
      const auto type = memory.offset.marker == Marker::PcrelLo
                            ? isa::Reloc::PcrelLo12I
                            : isa::Reloc::Lo12I;
      const std::uint32_t offset = place_instruction(isa::encode_i(
          spec.opcode, static_cast<std::uint32_t>(rd), spec.funct3,
          static_cast<std::uint32_t>(memory.base), 0));
      add_relocation(offset, type, memory.offset);
      return;
    }
    std::int64_t value = memory.offset.value;
    if (memory.offset.marker == Marker::Lo ||
        memory.offset.marker == Marker::PcrelLo) {
      value = isa::sign_extend(static_cast<std::uint64_t>(value) & 0xfffU, 12);
    } else if (memory.offset.marker == Marker::Hi ||
               memory.offset.marker == Marker::PcrelHi) {
      fail("jalr requires a low relocation, not %hi");
    }
    if (!isa::fits_signed(value, 12)) {
      fail("jalr offset does not fit in 12 signed bits");
    }
    emit_u32(isa::encode_i(
        spec.opcode, static_cast<std::uint32_t>(rd), spec.funct3,
        static_cast<std::uint32_t>(memory.base),
        static_cast<std::uint32_t>(value) & 0xfffU));
  }

  std::uint32_t parse_csr_operand() {
    if (peek().kind == TokenKind::Number) {
      const std::uint64_t value = advance().number;
      if (value > 0xfff) {
        fail("CSR number is out of range");
      }
      return static_cast<std::uint32_t>(value);
    }
    if (peek().kind == TokenKind::Identifier) {
      const std::string name = advance().text;
      if (const auto value = isa::parse_csr(name)) {
        return *value;
      }
      fail("unknown CSR '" + name + "'");
    }
    fail("expected a CSR name or number");
  }

  void emit_csr(std::uint32_t funct3, int rd, int rs1, std::uint32_t csr) {
    emit_u32(isa::encode_i(isa::kOpcodeSystem,
                           static_cast<std::uint32_t>(rd), funct3,
                           static_cast<std::uint32_t>(rs1), csr));
  }

  std::uint32_t parse_fence_set() {
    if (peek().kind != TokenKind::Identifier) {
      fail("expected a fence set such as iorw");
    }
    const std::string text = advance().text;
    std::uint32_t value = 0;
    for (const char character : text) {
      if (character == 'i') {
        value |= 8;
      } else if (character == 'o') {
        value |= 4;
      } else if (character == 'r') {
        value |= 2;
      } else if (character == 'w') {
        value |= 1;
      } else {
        fail("invalid fence set '" + text + "'");
      }
    }
    return value;
  }

  void parse_fence(const std::string& name) {
    if (name == "fence.i") {
      emit_u32(0x0000100f);
      return;
    }
    if (name == "fence.tso") {
      emit_u32(0x8330000f);
      return;
    }
    std::uint32_t predecessor = 0xf;
    std::uint32_t successor = 0xf;
    if (!at_end_of_line()) {
      predecessor = parse_fence_set();
      expect_punct(',');
      successor = parse_fence_set();
    }
    emit_u32((predecessor << 24) | (successor << 20) | 0x0000000f);
  }

  void parse_sfence_vma() {
    if (at_end_of_line()) {
      emit_u32(0x12000073);
      return;
    }
    const int rs1 = parse_register_operand();
    int rs2 = 0;
    if (consume_punct(',')) {
      rs2 = parse_register_operand();
    }
    emit_u32(0x12000073 |
             (static_cast<std::uint32_t>(rs2) << 20) |
             (static_cast<std::uint32_t>(rs1) << 15));
  }

  std::uint32_t parse_vector_type() {
    std::uint32_t sew = 0;
    std::uint32_t vta = 0;
    std::uint32_t vma = 0;
    bool have_sew = false;
    bool have_lmul = false;
    bool have_tail = false;
    bool have_mask = false;

    if (at_end_of_line()) {
      fail("expected a vector type such as e32,m1,ta,ma");
    }
    while (true) {
      const Token token = peek();
      const std::string part = expect_identifier();
      if (part == "e8") {
        if (have_sew) fail(token, "duplicate vector element width");
        sew = 0;
        have_sew = true;
      } else if (part == "e16") {
        if (have_sew) fail(token, "duplicate vector element width");
        sew = 1;
        have_sew = true;
      } else if (part == "e32") {
        if (have_sew) fail(token, "duplicate vector element width");
        sew = 2;
        have_sew = true;
      } else if (part == "m1") {
        if (have_lmul) fail(token, "duplicate vector LMUL");
        have_lmul = true;
      } else if (part == "ta" || part == "tu") {
        if (have_tail) fail(token, "duplicate vector tail policy");
        vta = part == "ta" ? 1 : 0;
        have_tail = true;
      } else if (part == "ma" || part == "mu") {
        if (have_mask) fail(token, "duplicate vector mask policy");
        // Masking is not implemented by roco, but accepting ma keeps common
        // compiler output assembler-compatible.
        vma = part == "ma" ? 1 : 0;
        have_mask = true;
      } else if (part.size() > 1 && part[0] == 'm') {
        fail(token, "roco implements only LMUL=m1");
      } else {
        fail(token, "unknown vector type field '" + part + "'");
      }
      if (!consume_punct(',')) {
        break;
      }
    }
    if (!have_sew) {
      fail("vector type requires e8, e16 or e32");
    }
    return (vma << 7) | (vta << 6) | (sew << 3);
  }

  void parse_vector_instruction(const std::string& name) {
    if (name == "vsetvli") {
      const int rd = parse_register_operand();
      expect_punct(',');
      const int rs1 = parse_register_operand();
      expect_punct(',');
      const std::uint32_t vtype = parse_vector_type();
      emit_u32(isa::encode_i(0x57, static_cast<std::uint32_t>(rd), 7,
                             static_cast<std::uint32_t>(rs1), vtype));
      return;
    }
    if (name == "vsetivli") {
      const int rd = parse_register_operand();
      expect_punct(',');
      const Expr avl_expression = parse_expr();
      const std::int64_t avl =
          require_constant(avl_expression, "vsetivli AVL");
      if (avl < 0 || avl > 31) {
        fail("vsetivli AVL must be in the range 0..31");
      }
      expect_punct(',');
      const std::uint32_t vtype = parse_vector_type();
      emit_u32(isa::encode_i(0x57, static_cast<std::uint32_t>(rd), 7,
                             static_cast<std::uint32_t>(avl),
                             0xc00U | vtype));
      return;
    }
    if (name == "vsetvl") {
      const int rd = parse_register_operand();
      expect_punct(',');
      const int rs1 = parse_register_operand();
      expect_punct(',');
      const int rs2 = parse_register_operand();
      emit_u32(isa::encode_r(0x57, static_cast<std::uint32_t>(rd), 7,
                             static_cast<std::uint32_t>(rs1),
                             static_cast<std::uint32_t>(rs2), 0x40));
      return;
    }
    if (name == "vmv.v.v") {
      const int vd = parse_vector_register_operand();
      expect_punct(',');
      const int vs1 = parse_vector_register_operand();
      emit_u32(isa::encode_r(0x57, static_cast<std::uint32_t>(vd), 0,
                             static_cast<std::uint32_t>(vs1), 0,
                             (0x17U << 1) | 1U));
      return;
    }
    if (name == "vmv.v.x") {
      const int vd = parse_vector_register_operand();
      expect_punct(',');
      const int rs1 = parse_register_operand();
      emit_u32(isa::encode_r(0x57, static_cast<std::uint32_t>(vd), 4,
                             static_cast<std::uint32_t>(rs1), 0,
                             (0x17U << 1) | 1U));
      return;
    }
    if (name == "vmv.v.i") {
      const int vd = parse_vector_register_operand();
      expect_punct(',');
      const Expr immediate = parse_expr();
      const std::int64_t value =
          require_constant(immediate, "vector immediate");
      if (!isa::fits_signed(value, 5)) {
        fail("vector immediate must fit in 5 signed bits");
      }
      emit_u32(isa::encode_r(
          0x57, static_cast<std::uint32_t>(vd), 3,
          static_cast<std::uint32_t>(value) & 0x1fU, 0, (0x17U << 1) | 1U));
      return;
    }
    if (name == "vmv.x.s") {
      const int rd = parse_register_operand();
      expect_punct(',');
      const int vs2 = parse_vector_register_operand();
      emit_u32(isa::encode_r(0x57, static_cast<std::uint32_t>(rd), 2, 0,
                             static_cast<std::uint32_t>(vs2),
                             (0x10U << 1) | 1U));
      return;
    }
    if (name == "vmv.s.x") {
      const int vd = parse_vector_register_operand();
      expect_punct(',');
      const int rs1 = parse_register_operand();
      emit_u32(isa::encode_r(0x57, static_cast<std::uint32_t>(vd), 6,
                             static_cast<std::uint32_t>(rs1), 0,
                             (0x10U << 1) | 1U));
      return;
    }
    if (name == "vredsum.vs") {
      const int vd = parse_vector_register_operand();
      expect_punct(',');
      const int vs2 = parse_vector_register_operand();
      expect_punct(',');
      const int vs1 = parse_vector_register_operand();
      emit_u32(isa::encode_r(0x57, static_cast<std::uint32_t>(vd), 2,
                             static_cast<std::uint32_t>(vs1),
                             static_cast<std::uint32_t>(vs2), 1));
      return;
    }
    if (name == "vle8.v" || name == "vle16.v" || name == "vle32.v" ||
        name == "vse8.v" || name == "vse16.v" || name == "vse32.v") {
      const bool load = name.rfind("vle", 0) == 0;
      std::uint32_t width = 0;
      if (name.find("16") != std::string::npos) {
        width = 5;
      } else if (name.find("32") != std::string::npos) {
        width = 6;
      }
      const int vd = parse_vector_register_operand();
      expect_punct(',');
      expect_punct('(');
      const int rs1 = parse_register_operand();
      expect_punct(')');
      if (!at_end_of_line()) {
        fail("roco supports only unmasked unit-stride vector memory accesses");
      }
      emit_u32((1U << 25) | (static_cast<std::uint32_t>(rs1) << 15) |
               (width << 12) | (static_cast<std::uint32_t>(vd) << 7) |
               (load ? 0x07U : 0x27U));
      return;
    }

    static const std::unordered_map<std::string, std::uint32_t> operations = {
        {"vadd.vv", 0x00}, {"vadd.vx", 0x00}, {"vadd.vi", 0x00},
        {"vsub.vv", 0x02}, {"vsub.vx", 0x02}, {"vsub.vi", 0x02},
        {"vand.vv", 0x09}, {"vand.vx", 0x09}, {"vand.vi", 0x09},
        {"vor.vv", 0x0a},  {"vor.vx", 0x0a},  {"vor.vi", 0x0a},
        {"vxor.vv", 0x0b}, {"vxor.vx", 0x0b}, {"vxor.vi", 0x0b},
    };
    const auto operation = operations.find(name);
    if (operation == operations.end()) {
      fail("unsupported vector instruction '" + name +
           "'; roco implements only the Zve32x subset listed in the "
           "toolchain documentation");
    }
    if (name.size() < 2) {
      fail("invalid vector instruction");
    }
    const std::string suffix = name.substr(name.size() - 2);
    const int vd = parse_vector_register_operand();
    expect_punct(',');
    const int vs2 = parse_vector_register_operand();
    expect_punct(',');
    std::uint32_t source = 0;
    std::uint32_t funct3 = 0;
    if (suffix == "vv") {
      source = static_cast<std::uint32_t>(parse_vector_register_operand());
      funct3 = 0;
    } else if (suffix == "vx") {
      source = static_cast<std::uint32_t>(parse_register_operand());
      funct3 = 4;
    } else {
      const Expr immediate = parse_expr();
      const std::int64_t value =
          require_constant(immediate, "vector immediate");
      if (!isa::fits_signed(value, 5)) {
        fail("vector immediate must fit in 5 signed bits");
      }
      source = static_cast<std::uint32_t>(value) & 0x1fU;
      funct3 = 3;
    }
    emit_u32(isa::encode_r(0x57, static_cast<std::uint32_t>(vd), funct3,
                           source, static_cast<std::uint32_t>(vs2),
                           (operation->second << 1) | 1U));
  }

  void parse_atomic_instruction(const std::string& name) {
    std::string base = name;
    bool acquire = false;
    bool release = false;
    if (ends_with(base, ".aqrl")) {
      base.resize(base.size() - 5);
      acquire = true;
      release = true;
    } else if (ends_with(base, ".aq")) {
      base.resize(base.size() - 3);
      acquire = true;
    } else if (ends_with(base, ".rl")) {
      base.resize(base.size() - 3);
      release = true;
    }
    if (base.find(".d") != std::string::npos) {
      fail("roco implements only 32-bit (.w) atomics");
    }

    static const std::unordered_map<std::string, std::uint32_t> operations = {
        {"amoswap.w", 0x01}, {"amoadd.w", 0x00},  {"amoxor.w", 0x04},
        {"amoand.w", 0x0c},  {"amoor.w", 0x08},   {"amomin.w", 0x10},
        {"amomax.w", 0x14},  {"amominu.w", 0x18}, {"amomaxu.w", 0x1c},
    };

    std::uint32_t funct5 = 0;
    bool is_load_reserved = false;
    bool is_store_conditional = false;
    if (base == "lr.w") {
      funct5 = 0x02;
      is_load_reserved = true;
    } else if (base == "sc.w") {
      funct5 = 0x03;
      is_store_conditional = true;
    } else {
      const auto operation = operations.find(base);
      if (operation == operations.end()) {
        fail("unsupported atomic instruction '" + name + "'");
      }
      funct5 = operation->second;
    }

    const int rd = parse_register_operand();
    expect_punct(',');
    std::uint32_t rs2 = 0;
    if (!is_load_reserved) {
      rs2 = static_cast<std::uint32_t>(parse_register_operand());
      expect_punct(',');
    }
    const MemoryOperand memory = parse_memory_operand();
    if (memory.offset.has_symbol || memory.offset.marker != Marker::None ||
        memory.offset.value != 0) {
      fail("atomic addresses must use the form (rs1)");
    }
    std::uint32_t word = (funct5 << 27) | (rs2 << 20) |
                         (static_cast<std::uint32_t>(memory.base) << 15) |
                         (2U << 12) | (static_cast<std::uint32_t>(rd) << 7) |
                         isa::kOpcodeAmo;
    if (acquire) {
      word |= 1U << 26;
    }
    if (release) {
      word |= 1U << 25;
    }
    if (is_store_conditional && !acquire && !release) {
      // No special work; kept for readability of the encoding above.
    }
    emit_u32(word);
  }

  void parse_directive(const std::string& name) {
    if (name == ".text") {
      set_section(section_indices_.at(".text"));
      return;
    }
    if (name == ".data") {
      set_section(section_indices_.at(".data"));
      return;
    }
    if (name == ".rodata") {
      set_section(section_indices_.at(".rodata"));
      return;
    }
    if (name == ".bss") {
      set_section(section_indices_.at(".bss"));
      return;
    }
    if (name == ".section") {
      parse_section_directive();
      return;
    }
    if (name == ".globl" || name == ".global") {
      parse_global_directive();
      return;
    }
    if (name == ".local") {
      parse_local_directive();
      return;
    }
    if (name == ".type") {
      parse_type_directive();
      return;
    }
    if (name == ".size") {
      parse_size_directive();
      return;
    }
    if (name == ".align") {
      // GNU RISC-V treats .align as a byte alignment.
      parse_align_directive(false);
      return;
    }
    if (name == ".p2align") {
      parse_align_directive(true);
      return;
    }
    if (name == ".balign") {
      parse_align_directive(false);
      return;
    }
    if (name == ".byte") {
      parse_data_values(1);
      return;
    }
    if (name == ".half" || name == ".short" || name == ".2byte") {
      parse_data_values(2);
      return;
    }
    if (name == ".word" || name == ".long" || name == ".4byte") {
      parse_data_values(4);
      return;
    }
    if (name == ".ascii") {
      parse_strings(false);
      return;
    }
    if (name == ".asciz" || name == ".string") {
      parse_strings(true);
      return;
    }
    if (name == ".zero" || name == ".space" || name == ".skip") {
      parse_space_directive();
      return;
    }
    if (name == ".equ" || name == ".set") {
      parse_equ_directive();
      return;
    }
    if (name == ".file" || name == ".ident" || name == ".option" ||
        name == ".attribute") {
      skip_to_end_of_line();
      return;
    }
    if (name.rfind(".cfi_", 0) == 0) {
      skip_to_end_of_line();
      return;
    }
    fail("unsupported directive '" + name + "'");
  }

  void skip_to_end_of_line() {
    while (!at_end_of_line()) {
      advance();
    }
  }

  void parse_section_directive() {
    const std::string name = expect_identifier();
    std::uint64_t flags = 0;
    std::uint32_t type = kShtProgbits;
    bool have_flags = false;
    bool have_type = false;

    if (consume_punct(',')) {
      if (peek().kind == TokenKind::String) {
        const std::string flag_text = advance().text;
        have_flags = true;
        for (const char character : flag_text) {
          if (character == 'a') {
            flags |= kShfAlloc;
          } else if (character == 'w') {
            flags |= kShfWrite;
          } else if (character == 'x') {
            flags |= kShfExecInstr;
          } else if (character == 'M' || character == 'S' ||
                     character == 'T') {
            // Merge/string/tls flags are irrelevant to this toolchain.
          } else {
            fail("unsupported section flag '" + std::string(1, character) +
                 "'");
          }
        }
        if (consume_punct(',')) {
          // parsed below
        }
      }
      if (is_punct('@') || is_punct('%')) {
        advance();
        const std::string type_name = expect_identifier();
        have_type = true;
        if (type_name == "progbits") {
          type = kShtProgbits;
        } else if (type_name == "nobits") {
          type = kShtNobits;
        } else {
          fail("unsupported section type '" + type_name + "'");
        }
      }
    }

    if (!have_flags) {
      if (name.rfind(".text", 0) == 0) {
        flags = kShfAlloc | kShfExecInstr;
      } else if (name.rfind(".rodata", 0) == 0 ||
                 name.rfind(".srodata", 0) == 0) {
        flags = kShfAlloc;
      } else if (name.rfind(".bss", 0) == 0 ||
                 name.rfind(".sbss", 0) == 0) {
        flags = kShfAlloc | kShfWrite;
        type = kShtNobits;
      } else if (name.rfind(".data", 0) == 0 ||
                 name.rfind(".sdata", 0) == 0) {
        flags = kShfAlloc | kShfWrite;
      } else {
        flags = kShfAlloc;
      }
    }
    if (!have_type && (name.rfind(".bss", 0) == 0 ||
                       name.rfind(".sbss", 0) == 0)) {
      type = kShtNobits;
    }

    const std::size_t index = add_section(name, type, flags);
    AsmSection& section = sections_[index];
    if (have_flags) {
      section.flags = flags;
    }
    if (have_type) {
      section.type = type;
    }
    set_section(index);
  }

  void parse_global_directive() {
    do {
      AsmSymbol& symbol = symbol_for(expect_identifier());
      symbol.global = true;
    } while (consume_punct(','));
  }

  void parse_local_directive() {
    do {
      AsmSymbol& symbol = symbol_for(expect_identifier());
      symbol.global = false;
    } while (consume_punct(','));
  }

  void parse_type_directive() {
    AsmSymbol& symbol = symbol_for(expect_identifier());
    expect_punct(',');
    if (is_punct('@') || is_punct('%')) {
      advance();
    }
    const std::string type = expect_identifier();
    if (type == "function") {
      symbol.type = kSttFunc;
    } else if (type == "object") {
      symbol.type = kSttObject;
    } else if (type == "notype") {
      symbol.type = kSttNoType;
    } else {
      fail("unsupported symbol type '" + type + "'");
    }
  }

  void parse_size_directive() {
    symbol_for(expect_identifier());
    expect_punct(',');
    skip_to_end_of_line();
  }

  void parse_align_directive(bool exponent) {
    const Expr amount = parse_expr();
    const std::int64_t value = require_constant(amount, "alignment");
    const std::int64_t limit = exponent ? 20 : (std::int64_t{1} << 20);
    if (value < 0 || value > limit) {
      fail("alignment is out of range");
    }
    const std::uint64_t alignment =
        exponent ? (std::uint64_t{1} << value)
                 : static_cast<std::uint64_t>(value);
    align_current(alignment);
  }

  void parse_data_values(int width) {
    do {
      Expr expression = parse_expr();
      if (width == 4 && expression.has_symbol) {
        if (expression.marker != Marker::None) {
          fail("data relocations do not accept %hi or %lo");
        }
        const std::uint32_t offset =
            static_cast<std::uint32_t>(current_offset());
        emit_u32(0);
        add_relocation(offset, isa::Reloc::R32, expression);
        continue;
      }
      if (expression.marker != Marker::None) {
        fail("data relocations do not accept %hi or %lo");
      }
      const std::uint32_t value =
          constant_to_32(expression.value, "data value");
      if (width == 1) {
        emit_u8(static_cast<std::uint8_t>(value));
      } else if (width == 2) {
        emit_u16(static_cast<std::uint16_t>(value));
      } else {
        emit_u32(value);
      }
    } while (consume_punct(','));
  }

  void parse_strings(bool terminate) {
    do {
      if (peek().kind != TokenKind::String) {
        fail("expected a string literal");
      }
      const std::string value = advance().text;
      for (const char character : value) {
        emit_u8(static_cast<std::uint8_t>(character));
      }
      if (terminate) {
        emit_u8(0);
      }
    } while (consume_punct(','));
  }

  void parse_space_directive() {
    const Expr count_expression = parse_expr();
    const std::int64_t count =
        require_constant(count_expression, "space size");
    if (count < 0) {
      fail("space size cannot be negative");
    }
    std::uint8_t fill = 0;
    if (consume_punct(',')) {
      const Expr fill_expression = parse_expr();
      fill = static_cast<std::uint8_t>(
          require_constant(fill_expression, "space fill"));
    }
    emit_fill(static_cast<std::uint64_t>(count), fill);
  }

  void parse_equ_directive() {
    const std::string name = expect_identifier();
    expect_punct(',');
    const Expr expression = parse_expr();
    if (expression.marker != Marker::None) {
      fail("symbol values do not accept relocation markers");
    }
    const std::int64_t value = require_constant(expression, "symbol value");
    AsmSymbol& symbol = symbol_for(name);
    if (symbol.defined && symbol.section != kSymbolAbsolute) {
      fail("cannot redefine label '" + name + "' as an absolute symbol");
    }
    symbol.defined = true;
    symbol.section = kSymbolAbsolute;
    symbol.value = static_cast<std::uint32_t>(value);
  }

  void finalize_symbols() {
    for (const auto& [number, name] : pending_forward_) {
      (void)name;
      fail("undefined numeric label " + std::to_string(number) + "f");
    }
  }

  Object build_object() {
    Object object;
    std::unordered_map<std::string, std::uint32_t> symbol_indices;

    std::vector<const AsmSymbol*> locals;
    std::vector<const AsmSymbol*> globals;
    locals.reserve(symbols_.size());
    globals.reserve(symbols_.size());
    for (const auto& [name, symbol] : symbols_) {
      (void)name;
      if (!symbol.defined && !symbol.global &&
          symbol.name.rfind(".L", 0) != 0) {
        // An undefined external name is visible to the linker even without a
        // .globl directive. Internal .L labels must be defined.
        const_cast<AsmSymbol&>(symbol).global = true;
      }
      if (!symbol.defined && symbol.name.rfind(".L", 0) == 0) {
        fail("undefined local symbol '" + symbol.name + "'");
      }
      if (symbol.global) {
        globals.push_back(&symbol);
      } else {
        locals.push_back(&symbol);
      }
    }
    const auto sort_symbols = [](const AsmSymbol* left,
                                 const AsmSymbol* right) {
      return left->name < right->name;
    };
    std::sort(locals.begin(), locals.end(), sort_symbols);
    std::sort(globals.begin(), globals.end(), sort_symbols);

    object.symbols.push_back(Symbol{});  // ELF null symbol
    const auto append_symbol = [&](const AsmSymbol& source) {
      Symbol symbol;
      symbol.name = source.name;
      symbol.section = source.defined ? source.section : kSymbolUndefined;
      symbol.value = source.value;
      symbol.size = source.size;
      symbol.binding = source.global ? kStbGlobal : kStbLocal;
      symbol.type = source.type;
      symbol_indices.emplace(source.name,
                             static_cast<std::uint32_t>(object.symbols.size()));
      object.symbols.push_back(std::move(symbol));
    };
    for (const AsmSymbol* symbol : locals) {
      append_symbol(*symbol);
    }
    for (const AsmSymbol* symbol : globals) {
      append_symbol(*symbol);
    }

    object.sections.reserve(sections_.size());
    for (const AsmSection& source : sections_) {
      Section section;
      section.name = source.name;
      section.type = source.type;
      section.flags = source.flags;
      section.align = source.align;
      section.size = source.type == kShtNobits ? source.bss_size
                                               : source.data.size();
      section.data = source.data;
      for (const PendingRelocation& relocation : source.relocations) {
        const auto iterator = symbol_indices.find(relocation.symbol);
        if (iterator == symbol_indices.end()) {
          throw Error("internal error: missing relocation symbol " +
                      relocation.symbol);
        }
        Relocation output;
        output.offset = relocation.offset;
        output.type = relocation.type;
        output.symbol = iterator->second;
        output.addend = relocation.addend;
        section.relocations.push_back(output);
      }
      object.sections.push_back(std::move(section));
    }
    return object;
  }

  std::string filename_;
  std::vector<Token> tokens_;
  std::size_t position_ = 0;
  std::vector<AsmSection> sections_;
  std::unordered_map<std::string, std::size_t> section_indices_;
  std::size_t current_section_ = 0;
  std::unordered_map<std::string, AsmSymbol> symbols_;
  std::unordered_map<int, std::string> latest_numeric_;
  std::unordered_map<int, std::string> pending_forward_;
  std::uint64_t numeric_label_sequence_ = 0;
};


}  // namespace roco::cc_asm
