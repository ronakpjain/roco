// Multiply stage two: one carry-propagating sum of the two compressed terms
// plus the low/high word selection. This runs in MEM, so the 64-bit carry
// chain gets a full cycle and is registered into MEM/WB.
`default_nettype none
`include "roco_cpu_defs.svh"

module roco_cpu_mul_sum (
  input logic [63:0] sum1,
  input logic [63:0] carry1,
  input logic hi,
  output logic [31:0] result
);
  logic [63:0] product;

  assign product = sum1 + carry1;
  assign result = hi ? product[63:32] : product[31:0];
endmodule
