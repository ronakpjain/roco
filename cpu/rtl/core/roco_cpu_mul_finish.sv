// EX completion: compress the four signed partial products to two terms, then
// use one carry-propagating sum. All arithmetic is modulo 2^64.
`default_nettype none
`include "roco_cpu_defs.svh"

module roco_cpu_mul_finish (
  input logic [31:0] p0,
  input logic [33:0] p1,
  input logic [33:0] p2,
  input logic [31:0] p3,
  input logic [2:0] variant,
  output logic [31:0] result
);
  logic [63:0] term0, term1, term2, term3;
  logic [63:0] sum0, carry0, sum1, carry1, product;
  assign term0 = {32'd0, p0};
  assign term1 = {{14{p1[33]}}, p1, 16'd0};
  assign term2 = {{14{p2[33]}}, p2, 16'd0};
  assign term3 = {p3, 32'd0};
  assign sum0 = term0 ^ term1 ^ term2;
  assign carry0 = ((term0 & term1) | (term0 & term2) | (term1 & term2)) << 1;
  assign sum1 = sum0 ^ carry0 ^ term3;
  assign carry1 = ((sum0 & carry0) | (sum0 & term3) | (carry0 & term3)) << 1;
  assign product = sum1 + carry1;
  assign result = (variant == `RV32_MD_MUL) ? product[31:0] : product[63:32];
endmodule
