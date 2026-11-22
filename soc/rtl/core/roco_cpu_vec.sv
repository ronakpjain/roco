// Vector register file and element ALU for Zve32x.
//
// VLEN is fixed at 128 bits and only LMUL=m1 is implemented, which is
// what the compiler selects by default. Element-wise operations cover
// the whole register in one cycle at the current SEW, using a separate
// datapath per element width selected by vtype.
//
// Two logical write ports share one physical write port: complete
// register results and loaded elements both commit in MEM. The pipeline
// supplies at most one kind of write per cycle.

`default_nettype none
`include "roco_cpu_defs.svh"

module roco_cpu_vec (
`ifdef ROCO_VECTOR_REG_STATE
  input logic [4:0] formal_vec_reg,
  input logic [3:0] formal_vec_byte,
  output logic [7:0] formal_vec_stored,
`endif
  input logic clk,
  input logic rst,
  /* Operand read ports (EX). */
  input logic [4:0] vs1,
  input logic [4:0] vs2,
  input logic [4:0] vd,
  output logic [127:0] vs1_data,
  output logic [127:0] vs2_data,
  output logic [127:0] vd_data,
  /* Whole-register write port (MEM; ex_* names retain the unit interface). */
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

  // Stage the physical write while bypassing the pending packet to all
  // read ports. This preserves the interface's write visibility and keeps
  // MEM data/control routing out of the distributed RAM write ports.
  logic full_we_q, elem_we_q;
  logic [4:0] full_wd_q, elem_wd_q;
  logic [127:0] full_data_q;
  logic [31:0] elem_data_q;
  logic [3:0] elem_index_q;
  logic [2:0] elem_sew_q;
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      full_we_q <= 1'b0;
      elem_we_q <= 1'b0;
    end else begin
      full_we_q <= ex_we;
      elem_we_q <= !ex_we && mem_we;
    end
  end
  always_ff @(posedge clk) begin
    full_wd_q <= ex_wd;
    elem_wd_q <= mem_wd;
    full_data_q <= ex_wdata;
    elem_data_q <= mem_wdata;
    elem_index_q <= mem_elem;
    elem_sew_q <= mem_sew;
  end

  logic [15:0] elem_byte_mask;
  logic [127:0] elem_wdata;
  logic [31:0] valid_regs;

  // The element written by a vector load goes into the lane selected by
  // the element index at the current SEW.
  always_comb begin
    elem_byte_mask = '0;
    elem_wdata = '0;
    case (elem_sew_q)
      3'd0: begin
        elem_byte_mask[elem_index_q] = 1'b1;
        elem_wdata[8*elem_index_q+:8] = elem_data_q[7:0];
      end
      3'd1: begin
        elem_byte_mask[2*elem_index_q[2:0]+:2] = 2'b11;
        elem_wdata[16*elem_index_q[2:0]+:16] = elem_data_q[15:0];
      end
      default: begin
        elem_byte_mask[4*elem_index_q[1:0]+:4] = 4'b1111;
        elem_wdata[32*elem_index_q[1:0]+:32] = elem_data_q[31:0];
      end
    endcase
  end

  // Byte banks have one write port and no data reset. The first partial
  // load to an invalid register clears its untouched bytes, allowing one
  // validity bit per register while preserving reset-to-zero behavior.
  logic [4:0] write_reg;
  logic initialize_reg;
  assign write_reg = full_we_q ? full_wd_q : elem_wd_q;
  assign initialize_reg = !valid_regs[elem_wd_q];
  for (genvar r = 0; r < 32; r = r + 1) begin : g_valid
    // Decode both addresses before the late execute write enable.
    logic ex_select, mem_select;
    assign ex_select = (full_wd_q == 5'(r));
    assign mem_select = (elem_wd_q == 5'(r));
    always_ff @(posedge clk or posedge rst) begin
      if (rst) begin
        valid_regs[r] <= 1'b0;
      end else if (full_we_q) begin
        if (ex_select) valid_regs[r] <= 1'b1;
      end else if (elem_we_q && mem_select) begin
        valid_regs[r] <= 1'b1;
      end
    end
  end
`ifdef ROCO_VECTOR_REG_STATE
  logic [127:0] formal_vec_row;
  assign formal_vec_stored = formal_vec_row[8*formal_vec_byte+:8];
  always @(posedge clk) begin
    if (!rst) begin
      assert (full_we_q == (!$past(rst) && $past(ex_we)));
      assert (elem_we_q == (!$past(rst) && $past(!ex_we && mem_we)));
      if (full_we_q) assert ({full_wd_q, full_data_q} == $past({ex_wd, ex_wdata}));
      if (elem_we_q)
        assert ({elem_wd_q, elem_index_q, elem_sew_q, elem_data_q} == $past(
            {mem_wd, mem_elem, mem_sew, mem_wdata}
        ));
    end
  end
`endif
  for (genvar b = 0; b < 16; b = b + 1) begin : g_byte
    logic [7:0] data[0:31];
    logic write_byte;
    logic [7:0] write_data;
    assign write_byte = full_we_q || (elem_we_q && (initialize_reg || elem_byte_mask[b]));
    assign write_data = full_we_q ? full_data_q[8*b+:8] : elem_wdata[8*b+:8];

`ifdef ROCO_VECTOR_REG_STATE
    assign formal_vec_row[8*b+:8] = valid_regs[formal_vec_reg] ? data[formal_vec_reg] : 8'd0;
`endif

    assign vs1_data[8*b+:8] = (full_we_q && full_wd_q == vs1) ? full_data_q[8*b+:8] :
                                    (elem_we_q && elem_wd_q == vs1 && elem_byte_mask[b]) ? elem_wdata[8*b+:8] :
                                    valid_regs[vs1] ? data[vs1] : 8'd0;
    assign vs2_data[8*b+:8] = (full_we_q && full_wd_q == vs2) ? full_data_q[8*b+:8] :
                                    (elem_we_q && elem_wd_q == vs2 && elem_byte_mask[b]) ? elem_wdata[8*b+:8] :
                                    valid_regs[vs2] ? data[vs2] : 8'd0;
    assign vd_data[8*b+:8] = (full_we_q && full_wd_q == vd) ? full_data_q[8*b+:8] :
                                    (elem_we_q && elem_wd_q == vd && elem_byte_mask[b]) ? elem_wdata[8*b+:8] :
                                    valid_regs[vd] ? data[vd] : 8'd0;

    // Distributed RAM cannot be asynchronously cleared, and the write
    // enables are already held low during reset by the pipeline registers
    // that produce them.
    always_ff @(posedge clk) begin
      if (write_byte) begin
        data[write_reg] <= write_data;
      end
    end
  end

endmodule
