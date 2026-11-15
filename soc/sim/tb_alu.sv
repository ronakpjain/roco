`timescale 1ns / 1ps
`include "roco_cpu_defs.svh"
module tb_alu;
  logic [31:0] a, b, result;
  logic [3:0] op;
  roco_cpu_alu dut (.*);
  task automatic check(input logic [31:0] x, input logic [31:0] y, input logic [3:0] operation);
    logic [31:0] expected;
    a = x;
    b = y;
    op = operation;
    case (operation)
      `RV32_ALU_ADD: expected = x + y;
      `RV32_ALU_SUB: expected = x - y;
      `RV32_ALU_SLL: expected = x << y[4:0];
      `RV32_ALU_SLT: expected = {31'd0, $signed(x) < $signed(y)};
      `RV32_ALU_SLTU: expected = {31'd0, x < y};
      `RV32_ALU_XOR: expected = x ^ y;
      `RV32_ALU_SRL: expected = x >> y[4:0];
      `RV32_ALU_SRA: expected = $signed(x) >>> y[4:0];
      `RV32_ALU_OR: expected = x | y;
      `RV32_ALU_AND: expected = x & y;
      `RV32_ALU_PASS_B: expected = y;
      default: expected = 0;
    endcase
    #1;
    if (result !== expected) $fatal(1, "ALU mismatch op=%h a=%h b=%h", operation, x, y);
  endtask
  initial begin
    for (int k = 0; k < 32; k++) begin
      check((32'd1 << k) - 1, 1, `RV32_ALU_ADD);
      check(32'd1 << k, 1, `RV32_ALU_SUB);
      check(0, 32'd1 << k, `RV32_ALU_SUB);
    end
    check(32'hffffffff, 1, `RV32_ALU_ADD);
    check(32'h80000000, 1, `RV32_ALU_SUB);
    repeat (5000) begin
      for (int k = 0; k < 16; k++) check($random, $random, 4'(k));
    end
    $display("tb_alu: PASS");
    $finish;
  end
endmodule
