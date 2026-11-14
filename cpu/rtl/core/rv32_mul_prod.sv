// M-extension multiply, split across EX and MEM.
//
// A single 32x32 combinational multiply cannot meet 48 MHz on this part:
// the DSP blocks and their partial-product adders end up chained. The EX
// stage therefore computes the four 16x16 partial products of the raw
// operand halves in parallel and registers them in EX/MEM; the MEM stage
// performs the 64-bit sum and any sign correction.
//
// Working from the unsigned product keeps adder logic out of the DSP
// input path. With a_u and b_u the raw operands and a31/b31 their sign
// bits, the signed products follow from
//   a_s * b_s = a_u * b_u - a31 * b_u * 2^32 - b31 * a_u * 2^32  (mod 2^64)
// so only the high word needs correcting.

`default_nettype none
`include "rv32_defs.svh"

// EX stage: unsigned partial products plus the two sign-correction
// terms. Correcting in EX would add an adder to the operand path.
module rv32_mul_prod (
  input logic [31:0] a,
  input logic [31:0] b,
  output logic [31:0] p0,
  output logic [31:0] p1,
  output logic [31:0] p2,
  output logic [31:0] p3,
  output logic [31:0] sub_a,
  output logic [31:0] sub_b
);

  assign p0 = {16'd0, a[15:0]} * {16'd0, b[15:0]};
  assign p1 = {16'd0, a[15:0]} * {16'd0, b[31:16]};
  assign p2 = {16'd0, a[31:16]} * {16'd0, b[15:0]};
  assign p3 = {16'd0, a[31:16]} * {16'd0, b[31:16]};
  assign sub_a = a[31] ? b : 32'd0;
  assign sub_b = b[31] ? a : 32'd0;

endmodule
