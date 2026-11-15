// EX completion: compress the four signed partial products to two terms, then
// use parallel 16-bit carry-select sums. All arithmetic is modulo 2^64.
`default_nettype none
`include "rv32_defs.svh"

module rv32_mul_finish (
  input logic [31:0] p0,
  input logic [33:0] p1,
  input logic [33:0] p2,
  input logic [33:0] p3,
  input logic [2:0] variant,
  output logic [31:0] result
);
  logic [63:0] term0, term1, term2, term3;
  logic [63:0] sum0, carry0, sum1, carry1, product;
  assign term0 = {32'd0, p0};
  assign term1 = {{14{p1[33]}}, p1, 16'd0};
  assign term2 = {{14{p2[33]}}, p2, 16'd0};
  assign term3 = {p3[31:0], 32'd0};
  assign sum0 = term0 ^ term1 ^ term2;
  assign carry0 = ((term0 & term1) | (term0 & term2) | (term1 & term2)) << 1;
  assign sum1 = sum0 ^ carry0 ^ term3;
  assign carry1 = ((sum0 & carry0) | (sum0 & term3) | (carry0 & term3)) << 1;
  // Bits below 16 contain only p0, so no carry enters bit 16.
  // Compute each upper block for both possible carries in parallel.
  // Block carry lookahead avoids a serial 48-bit ripple after the DSPs.
  logic [2:0] generate_carry, propagate_carry;
  logic [3:0] block_carry;
  assign block_carry[0] = 1'b0;
  assign block_carry[1] = generate_carry[0];
  assign block_carry[2] = generate_carry[1] | (propagate_carry[1] && generate_carry[0]);
  assign block_carry[3] = generate_carry[2] |
                         (propagate_carry[2] && generate_carry[1]) |
                         (propagate_carry[2] && propagate_carry[1] && generate_carry[0]);
  assign product[15:0] = sum1[15:0];
  for (genvar block_idx = 0; block_idx < 3; block_idx++) begin : g_carry_select
    localparam int LO = 16 + 16 * block_idx;
    logic [16:0] with_zero;
    logic [15:0] with_one;
    assign with_zero = {1'b0, sum1[LO+:16]} + {1'b0, carry1[LO+:16]};
    assign with_one = sum1[LO+:16] + carry1[LO+:16] + 16'd1;
    assign generate_carry[block_idx] = with_zero[16];
    assign propagate_carry[block_idx] = &(sum1[LO+:16] ^ carry1[LO+:16]);
    assign product[LO+:16] = block_carry[block_idx] ? with_one : with_zero[15:0];
  end
  logic unused_final_carry;
  assign unused_final_carry = block_carry[3];
  assign result = (variant == `RV32_MD_MUL) ? product[31:0] : product[63:32];
endmodule
