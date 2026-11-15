`timescale 1ns / 1ps
module tb_compare;
  logic [31:0] a, b;
  logic equal, signed_lt, unsigned_lt;
  roco_cpu_compare dut (.*);
  task automatic check(input logic [31:0] x, input logic [31:0] y);
    a = x;
    b = y;
    #1;
    if (equal !== (x == y) || unsigned_lt !== (x < y) || signed_lt !== ($signed(x) < $signed(y)))
      $fatal(1, "comparison mismatch a=%h b=%h", x, y);
  endtask
  initial begin
    check(0, 0);
    check(32'h80000000, 32'h7fffffff);
    check(32'hffffffff, 0);
    check(0, 32'hffffffff);
    for (int bitpos = 0; bitpos < 32; bitpos++) begin
      check((32'd1 << bitpos) - 1, 32'd1 << bitpos);
      check(32'd1 << bitpos, (32'd1 << bitpos) - 1);
      check(32'd1 << bitpos, 32'd1 << bitpos);
    end
    repeat (5000) check($random, $random);
    $display("tb_compare: PASS");
    $finish;
  end
endmodule
