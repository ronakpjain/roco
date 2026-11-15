// Single-cycle multiply reference: both multiply stages in one cone. The
// pipeline uses roco_cpu_mul_term in EX and roco_cpu_mul_sum in MEM; this
// wrapper keeps the whole operation available as one combinational unit for
// the arithmetic unit test.
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
  logic [63:0] sum1, carry1;

  roco_cpu_mul_term u_term (
      .p0(p0),
      .p1(p1),
      .p2(p2),
      .p3(p3),
      .sum1(sum1),
      .carry1(carry1)
  );

  roco_cpu_mul_sum u_sum (
      .sum1(sum1),
      .carry1(carry1),
      .hi(variant != `RV32_MD_MUL),
      .result(result)
  );
endmodule
