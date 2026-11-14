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

  logic [127:0] elem_mask;
  logic [127:0] elem_wdata;

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

  // Byte banks have a single write port and no data reset, allowing
  // distributed RAM. Reset validity separately so unread bytes still
  // return zero, including bytes untouched by a partial vector load.
  wire [4:0] write_reg = ex_we ? ex_wd : mem_wd;
  for (genvar b = 0; b < 16; b = b + 1) begin : g_byte
    logic [7:0] data[0:31];
    logic [31:0] valid_bytes;
    wire write_byte = ex_we || (mem_we && elem_mask[8*b]);
    wire [7:0] write_data = ex_we ? ex_wdata[8*b+:8] : elem_wdata[8*b+:8];

    assign vs1_data[8*b+:8] = valid_bytes[vs1] ? data[vs1] : 8'd0;
    assign vs2_data[8*b+:8] = valid_bytes[vs2] ? data[vs2] : 8'd0;
    assign vd_data[8*b+:8] = valid_bytes[vd] ? data[vd] : 8'd0;

    always_ff @(posedge clk) begin
      if (!rst && write_byte) begin
        data[write_reg] <= write_data;
      end
      if (rst) begin
        valid_bytes <= '0;
      end else if (write_byte) begin
        valid_bytes[write_reg] <= 1'b1;
      end
    end
  end

endmodule
