`include "roco_cpu_defs.svh"
`default_nettype none

module rv32m_divider_contract (
  input logic clk
);
  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;

  (* anyseq *) logic halt, start;
  (* anyseq *) logic [2:0] op;
  (* anyseq *) logic [31:0] a, b;
  logic busy, done;
  logic [31:0] div_result;
  roco_cpu_divider dut (.*);

  always @(posedge clk) begin
    if (!rst && start && !halt) begin
      assume (!busy);
      // The four divide/remainder encodings occupy funct3 values 4 through 7.
      assume (op >= `RV32_MD_DIV);
    end
  end
endmodule
