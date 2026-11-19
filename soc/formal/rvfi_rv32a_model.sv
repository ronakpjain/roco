`default_nettype none

// Companion to riscv-formal's RV32I model. The reservation is for one
// physical word on this uniprocessor, bare-address, no-DMA platform.
module rvfi_rv32a_model (
`ifdef ROCO_ATOMIC_STREAM_CHECKS
  output logic spec_reserved,
  output logic [29:0] spec_reserved_word,
`endif
  input logic clk,
  rst,
  input logic rvfi_valid,
  rvfi_trap,
  input logic [31:0] rvfi_insn,
  rvfi_pc_rdata,
  input logic [31:0] rvfi_rs1_rdata,
  rvfi_rs2_rdata,
  input logic [31:0] rvfi_mem_addr,
  rvfi_mem_rdata,
  input logic [3:0] rvfi_mem_wmask,
  output logic spec_valid,
  spec_trap,
  output logic [4:0] spec_rs1,
  spec_rs2,
  spec_rd,
  output logic [31:0] spec_rd_data,
  spec_pc,
  spec_addr,
  spec_wdata,
  output logic [3:0] spec_rmask,
  spec_wmask
);
  localparam logic [4:0] Lr = 5'b00010, Sc = 5'b00011;
  logic [4:0] funct5;
  logic lr, sc, sc_success, reserved;
  logic [29:0] reserved_word;
  logic [31:0] old_word, operand;
  assign funct5 = rvfi_insn[31:27];
  assign lr = funct5 == Lr;
  assign sc = funct5 == Sc;
  assign sc_success = reserved && reserved_word == rvfi_rs1_rdata[31:2];
`ifdef ROCO_ATOMIC_STREAM_CHECKS
  assign spec_reserved = reserved;
  assign spec_reserved_word = reserved_word;
`endif
  assign old_word = rvfi_mem_rdata;
  assign operand = rvfi_rs2_rdata;

  // The harness independently restricts the fetch input to supported
  // encodings. Illegal encodings must not be accepted as legal here.
  always_comb begin
    spec_valid = 0;
    if (rvfi_valid && rvfi_insn[6:0] == 7'h2f && rvfi_insn[14:12] == 3'd2) begin
      case (funct5)
        Lr: spec_valid = rvfi_insn[24:20] == 0;
        Sc, 0, 1, 4, 8, 12, 16, 20, 24, 28: spec_valid = 1;
        default: spec_valid = 0;
      endcase
    end
  end

  assign spec_trap = spec_valid && |rvfi_rs1_rdata[1:0];
  assign spec_rs1 = rvfi_insn[19:15];
  assign spec_rs2 = lr ? 5'd0 : rvfi_insn[24:20];
  assign spec_rd = rvfi_insn[11:7];
  assign spec_addr = {rvfi_rs1_rdata[31:2], 2'b00};
  assign spec_pc = rvfi_pc_rdata + 4;
  assign spec_rmask = sc ? 4'h0 : 4'hf;
  assign spec_wmask = lr || (sc && !sc_success) ? 4'h0 : 4'hf;
  assign spec_rd_data = spec_rd == 0 ? 32'd0 : sc ? {31'd0, !sc_success} : old_word;
  always_comb begin
    case (funct5)
      0: spec_wdata = old_word + operand;
      4: spec_wdata = old_word ^ operand;
      8: spec_wdata = old_word | operand;
      12: spec_wdata = old_word & operand;
      16: spec_wdata = $signed(old_word) < $signed(operand) ? old_word : operand;
      20: spec_wdata = $signed(old_word) > $signed(operand) ? old_word : operand;
      24: spec_wdata = old_word < operand ? old_word : operand;
      28: spec_wdata = old_word > operand ? old_word : operand;
      default: spec_wdata = operand;  // SC and AMOSWAP
    endcase
  end

  always @(posedge clk) begin
    if (rst) begin
      reserved <= 0;
      reserved_word <= 0;
    end else if (rvfi_valid) begin
      if (rvfi_trap) reserved <= 0;
      else if (spec_valid && lr) begin
        reserved <= 1;
        reserved_word <= spec_addr[31:2];
      end else if ((spec_valid && sc) ||
                   ((|rvfi_mem_wmask) && rvfi_mem_addr[31:2] == reserved_word))
        reserved <= 0;

      cover (spec_valid && !rvfi_trap && sc && sc_success);
      cover (spec_valid && !rvfi_trap && sc && !sc_success);
      cover (spec_valid && !rvfi_trap && !sc && !lr && |rvfi_mem_wmask);
      cover (spec_valid && rvfi_trap);
    end
  end
endmodule
