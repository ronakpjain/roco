// Decoupled iterative divider for the M extension.
//
// The execute stage starts the divide and moves on; the scoreboard in
// the core holds only an instruction that needs the pending destination
// register. Radix-four quotient digits use parallel subtracts against
// registered divisor multiples. Magnitude setup and final sign correction
// have separate cycles; independent instructions can continue to issue.
//
// The start cycle only latches the raw operands, so the operand
// forwarding path does not include the magnitude negation. The sign
// fixup and the final quotient and remainder are registered before
// `done` is asserted, which keeps the result independent of the
// execute-stage contents.

`default_nettype none
`include "roco_cpu_defs.svh"

module roco_cpu_divider (
  input logic clk,
  input logic rst,
  input logic halt,
  /* Execute stage operands. */
  input logic [2:0] op,
  input logic [31:0] a,
  input logic [31:0] b,
  /* Pulse: latch the operands and start a divide. */
  input logic start,
  /* Divide status and registered result. */
  output logic busy,
  output logic done,
  output logic [31:0] div_result
);

  localparam int CHUNK_BITS = 2;
  localparam int CHUNKS = 32 / CHUNK_BITS;
  localparam logic [4:0] FIRST_CHUNK = 5'(CHUNKS);
  localparam logic [4:0] LAST_CHUNK = 5'd1;

  logic fsm_busy;
  logic loading, preparing, finishing;
  logic done_q;
  logic [4:0] div_chunks;

  logic [31:0] start_a;
  logic [31:0] start_b;
  logic [2:0] start_op;

  logic op_signed_a;
  logic op_signed_b;
  logic mag_neg_a;
  logic mag_neg_b;
  logic [31:0] mag_a;
  logic [31:0] mag_b;
  logic mag_neg;
  logic is_rem;
  logic is_zero;

  logic [31:0] div_dividend;
  logic [31:0] div_divisor;
  logic [33:0] div_triple;
  logic [31:0] div_orig_a;
  logic [31:0] div_quot;
  logic [32:0] div_rem;
  logic [31:0] div_result_q;
  logic div_is_rem;
  logic div_sign;
  logic div_a_neg;
  logic div_by_zero;

  logic [33:0] digit_dividend;
  logic [34:0] digit_diff1, digit_diff2, digit_diff3;
  logic [1:0] quotient_digit;
  logic [32:0] remainder_next;
  logic [31:0] quotient_next;
  logic [31:0] div_quot_final;
  logic [31:0] div_rem_final;
  logic [31:0] div_final;

  // ------------------------------------------------ Sign fixup in a cycle
  // The magnitudes are computed from the latched operands, so the
  // forwarding path in the start cycle stays flop to flop.
  assign op_signed_a = (start_op == `RV32_MD_DIV) || (start_op == `RV32_MD_REM);
  assign op_signed_b = op_signed_a;
  assign mag_neg_a = op_signed_a && start_a[31];
  assign mag_neg_b = op_signed_b && start_b[31];
  assign mag_a = mag_neg_a ? -start_a : start_a;
  assign mag_b = mag_neg_b ? -start_b : start_b;
  assign mag_neg = mag_neg_a ^ mag_neg_b;
  assign is_rem = (start_op == `RV32_MD_REM) || (start_op == `RV32_MD_REMU);
  assign is_zero = (mag_b == 32'd0);

  // -------------------------------------------------------------- Divide
  // Choose the largest digit whose subtraction has no borrow. All three
  // subtracts start at registers; no digit depends on another subtract.
  assign digit_dividend = {div_rem[31:0], div_dividend[31:30]};
  assign digit_diff1 = {1'b0, digit_dividend} - {3'b0, div_divisor};
  assign digit_diff2 = {1'b0, digit_dividend} - {2'b0, div_divisor, 1'b0};
  assign digit_diff3 = {1'b0, digit_dividend} - {1'b0, div_triple};
  always_comb begin
    quotient_digit = 2'b00;
    remainder_next = {1'b0, digit_dividend[31:0]};
    if (!digit_diff3[34]) begin
      quotient_digit = 2'b11;
      remainder_next = digit_diff3[32:0];
    end else if (!digit_diff2[34]) begin
      quotient_digit = 2'b10;
      remainder_next = digit_diff2[32:0];
    end else if (!digit_diff1[34]) begin
      quotient_digit = 2'b01;
      remainder_next = digit_diff1[32:0];
    end
  end
  assign quotient_next = {div_quot[29:0], quotient_digit};

  // Completion uses the registered last digit, keeping sign correction
  // out of the restoring-division feedback path.
  assign div_quot_final = div_by_zero ? 32'hffff_ffff : div_sign ? -div_quot : div_quot;
  assign div_rem_final = div_by_zero ? div_orig_a : div_a_neg ? -div_rem[31:0] : div_rem[31:0];
  assign div_final = div_is_rem ? div_rem_final : div_quot_final;

  assign busy = fsm_busy || done_q;
  assign done = done_q;
  assign div_result = div_result_q;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      fsm_busy <= 1'b0;
      loading <= 1'b0;
      preparing <= 1'b0;
      finishing <= 1'b0;
      done_q <= 1'b0;
      div_chunks <= '0;
      start_a <= '0;
      start_b <= '0;
      start_op <= `RV32_MD_DIV;
      div_dividend <= '0;
      div_divisor <= '0;
      div_triple <= '0;
      div_orig_a <= '0;
      div_quot <= '0;
      div_rem <= '0;
      div_result_q <= '0;
      div_is_rem <= 1'b0;
      div_sign <= 1'b0;
      div_a_neg <= 1'b0;
      div_by_zero <= 1'b0;
    end else if (!halt) begin
      done_q <= 1'b0;
      if (!fsm_busy) begin
        if (start) begin
          fsm_busy <= 1'b1;
          loading <= 1'b1;
          preparing <= 1'b0;
          finishing <= 1'b0;
          start_a <= a;
          start_b <= b;
          start_op <= op;
        end
      end else if (loading) begin
        loading <= 1'b0;
        preparing <= 1'b1;
        div_chunks <= FIRST_CHUNK;
        div_dividend <= mag_a;
        div_divisor <= mag_b;
        div_orig_a <= start_a;
        div_quot <= '0;
        div_rem <= '0;
        div_is_rem <= is_rem;
        div_sign <= mag_neg;
        div_a_neg <= mag_neg_a;
        div_by_zero <= is_zero;
      end else if (preparing) begin
        preparing <= 1'b0;
        div_triple <= {2'b0, div_divisor} + {1'b0, div_divisor, 1'b0};
      end else if (finishing) begin
        finishing <= 1'b0;
        fsm_busy <= 1'b0;
        done_q <= 1'b1;
        div_result_q <= div_final;
      end else begin
        div_dividend <= div_dividend << CHUNK_BITS;
        div_quot <= quotient_next;
        div_rem <= remainder_next;
        if (div_chunks == LAST_CHUNK) finishing <= 1'b1;
        else div_chunks <= div_chunks - 1'b1;
      end
    end
  end

endmodule
