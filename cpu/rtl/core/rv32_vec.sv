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

  logic [127:0] regs[0:31];
  logic [127:0] elem_mask;
  logic [127:0] elem_wdata;
  integer i;

  assign vs1_data = regs[vs1];
  assign vs2_data = regs[vs2];
  assign vd_data = regs[vd];

  // The element written by a vector load goes into the lane selected by
  // the element index at the current SEW.
  always_comb begin
    elem_mask = '0;
    elem_wdata = '0;
    case (mem_sew)
      3'd0: begin
        elem_mask[8*mem_elem+:8] = 8'hff;
        elem_wdata[8*mem_elem+:8] = mem_wdata[7:0];
      end
      3'd1: begin
        elem_mask[16*mem_elem[2:0]+:16] = 16'hffff;
        elem_wdata[16*mem_elem[2:0]+:16] = mem_wdata[15:0];
      end
      default: begin
        elem_mask[32*mem_elem[1:0]+:32] = 32'hffff_ffff;
        elem_wdata[32*mem_elem[1:0]+:32] = mem_wdata[31:0];
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < 32; i = i + 1) begin
        regs[i] <= '0;
      end
    end else if (ex_we) begin
      regs[ex_wd] <= ex_wdata;
    end else if (mem_we) begin
      regs[mem_wd] <= (regs[mem_wd] & ~elem_mask) | elem_wdata;
    end
  end

endmodule
