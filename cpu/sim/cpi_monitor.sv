// Opt-in continuous architectural retirement assertion shared by core/SoC.
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
        if (!retire_valid) $fatal(1, "CPI=1 violated after %0d instructions", retired);
        retired = retired + 1;
        if (retired == count) begin
          active = 0;
          done = 1;
          $display("CPI=1 PASS (%0d consecutive instructions)", retired);
        end
      end
    end
  end
endmodule
