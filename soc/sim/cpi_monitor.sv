// Opt-in retirement-rate measurement shared by core/SoC.
//
// This reports the cycles per retired instruction over a warmed region. It
// is informational: frequency and total execution time are the optimisation
// targets, so a window is allowed to contain bubble cycles. Only a window
// that never completes is an error, because that means the measurement did
// not happen.
`timescale 1ns / 1ps
module cpi_monitor (
  input logic clk,
  input logic rst,
  input logic halt,
  input logic retire_valid,
  input logic [31:0] retire_pc
);
  logic enabled;
  logic active = 0;
  logic done = 0;
  logic [31:0] start_pc;
  int unsigned skip_visits;
  int unsigned count;
  int unsigned seen = 0;
  int unsigned retired = 0;
  int unsigned cycles = 0;
  int unsigned bubbles = 0;

  initial begin
    enabled = $value$plusargs("cpi_pc=%h", start_pc);
    if (!$value$plusargs("cpi_skip=%d", skip_visits)) skip_visits = 0;
    if (!$value$plusargs("cpi_count=%d", count)) count = 128;
    if (enabled && count < 2) $fatal(1, "CPI window must contain at least two instructions");
  end

  final begin
    if (enabled && !done) $fatal(1, "CPI window did not complete");
  end

  always @(posedge clk) begin
    if (!rst && enabled && !done) begin
      if (halt) $fatal(1, "CPI window did not complete");
      if (!active && retire_valid && retire_pc == start_pc) begin
        if (seen == skip_visits) active = 1;
        seen = seen + 1;
      end
      if (active) begin
        cycles = cycles + 1;
        if (retire_valid) begin
          retired = retired + 1;
          if (retired == count) begin
            active = 0;
            done = 1;
            $display("CPI %0d.%03d (%0d instructions, %0d cycles, %0d bubbles)", cycles / retired,
                     (1000 * (cycles % retired)) / retired, retired, cycles, bubbles);
          end
        end else begin
          bubbles = bubbles + 1;
        end
      end
    end
  end
endmodule
