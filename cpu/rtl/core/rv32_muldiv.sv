// Multiply/divide unit for the M extension.
//
// Multiply is combinational so that it keeps one instruction per cycle:
// the product feeds the EX/MEM register on the same edge as any other
// result. All four high-word variants share one unsigned 32x32
// multiplier by multiplying magnitudes and fixing up the two's
// complement afterwards.
//
// Divide is iterative and holds the pipeline until the last quotient
// digit is selected. Four quotient bits are produced per cycle, so a
// divide occupies the execute stage for nine cycles. Divide by zero and
// the signed overflow case follow the architectural results directly:
// the magnitude iteration already yields 0x8000_0000 for -2^31 / -1.

`default_nettype none
`include "rv32_defs.svh"

module rv32_muldiv (
  input logic clk,
  input logic rst,
  input logic halt,
  /* Instruction in EX. */
  input logic op_valid,
  input logic [2:0] op,
  input logic [31:0] a,
  input logic [31:0] b,
  /* Hold the pipeline while the result is not ready. */
  output logic stall,
  output logic [31:0] result
);

  localparam int CHUNK_BITS = 4;
  localparam int CHUNKS = 32 / CHUNK_BITS;
  localparam logic [3:0] FIRST_CHUNK = 4'(CHUNKS);
  localparam logic [3:0] LAST_CHUNK = 4'd1;

  logic op_signed_a;
  logic op_signed_b;
  logic mag_neg_a;
  logic mag_neg_b;
  logic [31:0] mag_a;
  logic [31:0] mag_b;
  logic mag_neg;

  logic is_div;
  logic is_rem;
  logic is_div_zero;

  logic [63:0] product;
  logic [31:0] product_hi;
  logic [31:0] mul_result;

  logic div_busy;
  logic [3:0] div_chunks;
  logic [31:0] div_dividend;
  logic [31:0] div_divisor;
  logic [31:0] div_orig_a;
  logic [31:0] div_quot;
  logic [32:0] div_rem;
  logic div_sign;
  logic div_a_neg;
  logic div_by_zero;

  logic [32:0] rem_step[0:CHUNK_BITS];
  logic [31:0] quot_step[0:CHUNK_BITS];
  logic [32:0] div_shifted;
  logic div_done;
  logic [31:0] div_quot_final;
  logic [31:0] div_rem_final;

  integer i;

  // ------------------------------------------------------------ Multiply
  // MULH is the only signed-signed product; MULHSU signs the first
  // operand only. Division shares the same magnitude computation.
  assign op_signed_a = (op == `RV32_MD_MULH) || (op == `RV32_MD_MULHSU) ||
                       (op == `RV32_MD_DIV) || (op == `RV32_MD_REM);
  assign op_signed_b = (op == `RV32_MD_MULH) || (op == `RV32_MD_DIV) || (op == `RV32_MD_REM);
  assign mag_neg_a = op_signed_a && a[31];
  assign mag_neg_b = op_signed_b && b[31];
  assign mag_a = mag_neg_a ? -a : a;
  assign mag_b = mag_neg_b ? -b : b;
  assign mag_neg = mag_neg_a ^ mag_neg_b;

  assign product = {32'd0, mag_a} * {32'd0, mag_b};
  // Negating a 64-bit two's complement value inverts the high word and
  // adds the carry out of the low word.
  assign product_hi = mag_neg ? (~product[63:32] + {31'd0, (product[31:0] == 32'd0)}) :
                     product[63:32];

  always_comb begin
    case (op)
      `RV32_MD_MULH: begin
        mul_result = product_hi;
      end
      `RV32_MD_MULHSU, `RV32_MD_MULHU: begin
        mul_result = product_hi;
      end
      default: begin
        mul_result = product[31:0];
      end
    endcase
  end

  // -------------------------------------------------------------- Divide
  assign is_div = (op == `RV32_MD_DIV) || (op == `RV32_MD_DIVU) ||
                  (op == `RV32_MD_REM) || (op == `RV32_MD_REMU);
  assign is_rem = (op == `RV32_MD_REM) || (op == `RV32_MD_REMU);
  assign is_div_zero = (mag_b == 32'd0);

  // One chunk of restoring division: shift in one dividend bit, compare
  // and subtract the divisor, and append the quotient bit.
  always_comb begin
    rem_step[0] = div_rem;
    quot_step[0] = div_quot;
    for (i = 0; i < CHUNK_BITS; i = i + 1) begin
      div_shifted = {rem_step[i][31:0], div_dividend[31-i]};
      if (div_shifted >= {1'b0, div_divisor}) begin
        rem_step[i+1] = div_shifted - {1'b0, div_divisor};
        quot_step[i+1] = {quot_step[i][30:0], 1'b1};
      end else begin
        rem_step[i+1] = div_shifted;
        quot_step[i+1] = {quot_step[i][30:0], 1'b0};
      end
    end
  end

  assign div_done = div_busy && (div_chunks == LAST_CHUNK);
  assign stall = op_valid && is_div && !div_done;

  assign div_quot_final = div_by_zero ? 32'hffff_ffff :
                          div_sign ? -quot_step[CHUNK_BITS] : quot_step[CHUNK_BITS];
  assign div_rem_final = div_by_zero ? div_orig_a :
                         div_a_neg ? -rem_step[CHUNK_BITS] : rem_step[CHUNK_BITS];

  always_ff @(posedge clk) begin
    if (rst) begin
      div_busy <= 1'b0;
      div_chunks <= '0;
      div_dividend <= '0;
      div_divisor <= '0;
      div_orig_a <= '0;
      div_quot <= '0;
      div_rem <= '0;
      div_sign <= 1'b0;
      div_a_neg <= 1'b0;
      div_by_zero <= 1'b0;
    end else if (!halt) begin
      if (!div_busy) begin
        if (op_valid && is_div) begin
          div_busy <= 1'b1;
          div_chunks <= FIRST_CHUNK;
          div_dividend <= mag_a;
          div_divisor <= mag_b;
          div_orig_a <= a;
          div_quot <= '0;
          div_rem <= '0;
          div_sign <= mag_neg;
          div_a_neg <= mag_neg_a;
          div_by_zero <= is_div_zero;
        end
      end else if (div_done) begin
        div_busy <= 1'b0;
      end else begin
        div_dividend <= {div_dividend[27:0], 4'b0};
        div_quot <= quot_step[CHUNK_BITS];
        div_rem <= rem_step[CHUNK_BITS];
        div_chunks <= div_chunks - 1'b1;
      end
    end
  end

  // -------------------------------------------------------------- Result
  // The final quotient digit is selected combinationally in the cycle
  // that reports done, so no extra cycle is needed to expose it.
  assign result = is_rem ? div_rem_final : is_div ? div_quot_final : mul_result;

endmodule
