// Vector register file and element ALU for Zve32x.
//
// VLEN is fixed at 128 bits and only LMUL=m1 is implemented, which is
// what the compiler selects by default. Element-wise operations cover
// the whole register in one cycle at the current SEW, using a separate
// datapath per element width selected by vtype.
//
// Two write ports are provided: the execute stage writes complete
// register results, while the memory stage inserts one loaded element.
// A vector memory sequence holds the pipeline for its whole length, so
// the two ports are never asked to write in the same cycle.

`default_nettype none
`include "rv32_defs.svh"

module rv32_vec (
  input logic clk,
  input logic rst,
  /* Operand read ports (EX). */
  input logic [4:0] vs1,
  input logic [4:0] vs2,
  input logic [4:0] vd,
  output logic [127:0] vs1_data,
  output logic [127:0] vs2_data,
  output logic [127:0] vd_data,
  /* Whole-register write port (EX). */
  input logic ex_we,
  input logic [4:0] ex_wd,
  input logic [127:0] ex_wdata,
  /* Element write port (MEM, vector load). */
  input logic mem_we,
  input logic [4:0] mem_wd,
  input logic [3:0] mem_elem,
  input logic [2:0] mem_sew,
  input logic [31:0] mem_wdata
);

  logic [15:0] elem_byte_mask;
  logic [127:0] elem_wdata;
  logic [31:0] valid_regs;

  // The element written by a vector load goes into the lane selected by
  // the element index at the current SEW.
  always_comb begin
    elem_byte_mask = '0;
    elem_wdata = '0;
    case (mem_sew)
      3'd0: begin
        elem_byte_mask[mem_elem] = 1'b1;
        elem_wdata[8*mem_elem+:8] = mem_wdata[7:0];
      end
      3'd1: begin
        elem_byte_mask[2*mem_elem[2:0]+:2] = 2'b11;
        elem_wdata[16*mem_elem[2:0]+:16] = mem_wdata[15:0];
      end
      default: begin
        elem_byte_mask[4*mem_elem[1:0]+:4] = 4'b1111;
        elem_wdata[32*mem_elem[1:0]+:32] = mem_wdata[31:0];
      end
    endcase
  end

  // Byte banks have one write port and no data reset. The first partial
  // load to an invalid register clears its untouched bytes, allowing one
  // validity bit per register while preserving reset-to-zero behavior.
  logic [4:0] write_reg;
  logic initialize_reg;
  assign write_reg = ex_we ? ex_wd : mem_wd;
  assign initialize_reg = !valid_regs[mem_wd];
  for (genvar r = 0; r < 32; r = r + 1) begin : g_valid
    // Decode both addresses before the late execute write enable.
    logic ex_select, mem_select;
    assign ex_select = (ex_wd == 5'(r));
    assign mem_select = (mem_wd == 5'(r));
    always_ff @(posedge clk) begin
      if (rst) begin
        valid_regs[r] <= 1'b0;
      end else if (ex_we) begin
        if (ex_select) valid_regs[r] <= 1'b1;
      end else if (mem_we && mem_select) begin
        valid_regs[r] <= 1'b1;
      end
    end
  end
  for (genvar b = 0; b < 16; b = b + 1) begin : g_byte
    logic [7:0] data[0:31];
    logic write_byte;
    logic [7:0] write_data;
    assign write_byte = ex_we || (mem_we && (initialize_reg || elem_byte_mask[b]));
    assign write_data = ex_we ? ex_wdata[8*b+:8] : elem_wdata[8*b+:8];

    assign vs1_data[8*b+:8] = valid_regs[vs1] ? data[vs1] : 8'd0;
    assign vs2_data[8*b+:8] = valid_regs[vs2] ? data[vs2] : 8'd0;
    assign vd_data[8*b+:8] = valid_regs[vd] ? data[vd] : 8'd0;

    always_ff @(posedge clk) begin
      if (!rst && write_byte) begin
        data[write_reg] <= write_data;
      end
    end
  end

endmodule
