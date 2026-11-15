// Multiply stage one: compress the four signed partial products to two
// carry-save terms. All arithmetic is modulo 2^64. Registering these two
// terms at EX/MEM keeps the final carry propagation out of the execute
// cycle, and an ECP5 carry chain cannot cross a PFU column, so a 64-bit
// carry-propagate sum is by far the most expensive part of the operation.
`default_nettype none
`include "roco_cpu_defs.svh"

module roco_cpu_mul_term (
  input logic [31:0] p0,
  input logic [33:0] p1,
  input logic [33:0] p2,
  input logic [31:0] p3,
  output logic [63:0] sum1,
  output logic [63:0] carry1
);
  logic [63:0] term0, term1, term2, term3;
  logic [63:0] sum0, carry0;

  assign term0 = {32'd0, p0};
  assign term1 = {{14{p1[33]}}, p1, 16'd0};
  assign term2 = {{14{p2[33]}}, p2, 16'd0};
  assign term3 = {p3, 32'd0};

  assign sum0 = term0 ^ term1 ^ term2;
  assign carry0 = ((term0 & term1) | (term0 & term2) | (term1 & term2)) << 1;
  assign sum1 = sum0 ^ carry0 ^ term3;
  assign carry1 = ((sum0 & carry0) | (sum0 & term3) | (carry0 & term3)) << 1;
endmodule
