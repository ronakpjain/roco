`default_nettype none
`include "rv32_defs.svh"

// MEM stage: combine the partial products and select the low or high
// word. MULH treats both operands as signed, MULHSU only the first, and
// MULHU neither.
module rv32_mul_finish (
  input logic [31:0] p0,
  input logic [31:0] p1,
  input logic [31:0] p2,
  input logic [31:0] p3,
  input logic [31:0] sub_a,
  input logic [31:0] sub_b,
  input logic [2:0] variant,
  output logic [31:0] result
);

  logic [32:0] middle;
  logic [63:0] product;
  logic sub_signed_a;
  logic sub_signed_b;

  assign middle = {1'b0, p1} + {1'b0, p2};
  assign product = ({32'd0, p3} << 32) + {15'd0, middle, 16'd0} + {32'd0, p0};
  assign sub_signed_a = (variant == `RV32_MD_MULH) || (variant == `RV32_MD_MULHSU);
  assign sub_signed_b = (variant == `RV32_MD_MULH);
  assign result = (variant == `RV32_MD_MUL) ? product[31:0] :
                  product[63:32] - (sub_signed_a ? sub_a : 32'd0) -
                  (sub_signed_b ? sub_b : 32'd0);

endmodule
