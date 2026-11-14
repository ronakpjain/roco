// EX stage: four parallel DSP products with signed high halves. Moving
// sign handling into DSP inputs avoids serial high-word corrections in MEM.
`default_nettype none
`include "rv32_defs.svh"

module rv32_mul_prod (
  input logic [31:0] a,
  input logic [31:0] b,
  input logic [2:0] variant,
  output logic [31:0] p0,
  output logic [33:0] p1,
  output logic [33:0] p2,
  output logic [33:0] p3
);
  logic signed [16:0] a_lo, b_lo, a_hi, b_hi;
  logic signed_a, signed_b;
  assign signed_a = (variant == `RV32_MD_MULH) || (variant == `RV32_MD_MULHSU);
  assign signed_b = (variant == `RV32_MD_MULH);
  assign a_lo = {1'b0, a[15:0]};
  assign b_lo = {1'b0, b[15:0]};
  assign a_hi = {signed_a && a[31], a[31:16]};
  assign b_hi = {signed_b && b[31], b[31:16]};
  assign p0 = a_lo * b_lo;
  assign p1 = a_lo * b_hi;
  assign p2 = a_hi * b_lo;
  assign p3 = a_hi * b_hi;
endmodule
