`default_nettype none

// Control-equivalent abstraction for the single-divide integration proof.
// The independently proved divider contract establishes this schedule.
// Choosing the result nondeterministically covers every possible value
// without unrolling the restoring arithmetic in the core-control proof.
module roco_cpu_divider (
  input logic clk,
  rst,
  halt,
  input logic [2:0] op,
  input logic [31:0] a,
  b,
  input logic start,
  output logic busy,
  done,
  output logic [31:0] div_result
);
  (* anyseq *) logic [31:0] next_result;
  logic [31:0] pending_result;
  logic [4:0] steps_left;
  assign busy = (steps_left != 0) || done;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      done <= 0;
      div_result <= 0;
      steps_left <= 0;
      pending_result <= 0;
    end else if (!halt) begin
      done <= 0;
      if (steps_left == 0) begin
        if (start) begin
          steps_left <= 19;
          pending_result <= next_result;
        end
      end else begin
        steps_left <= steps_left - 1'b1;
        if (steps_left == 1) begin
          done <= 1;
          div_result <= pending_result;
        end
      end
    end
  end
endmodule
