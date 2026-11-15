`timescale 1ns / 1ps
module tb_compare;
  logic [31:0] a, b;
  logic equal, signed_lt, unsigned_lt;
  logic [31:0] difference, predecessor;
  roco_cpu_sub_pair u_sub_pair (.*);
  logic [31:0] target, delta, rs;
  logic [31:0] half_difference, half_predecessor;
  logic [30:0] expected_half;
  logic full_match, jalr_match;
  roco_cpu_sub_pair u_half_pair (
      .a({1'b0, target[31:1]}),
      .b({1'b0, delta[31:1]}),
      .difference(half_difference),
      .predecessor(half_predecessor)
  );
  assign expected_half = (rs[0] && delta[0]) ? half_predecessor[30:0] : half_difference[30:0];
  assign full_match = ((rs[0] ^ delta[0]) == target[0]) && (rs[31:1] == expected_half);
  assign jalr_match = !target[0] && (rs[31:1] == expected_half);
  task automatic check_target;
    #1;
    if (full_match !== ((rs + delta) == target) ||
        jalr_match !== (((rs + delta) & 32'hfffffffe) == target))
      $fatal(1, "target carry mismatch rs=%h delta=%h target=%h", rs, delta, target);
  endtask
  roco_cpu_compare dut (.*);
  task automatic check(input logic [31:0] x, input logic [31:0] y);
    a = x;
    b = y;
    #1;
    if (equal !== (x == y) || unsigned_lt !== (x < y) || signed_lt !== ($signed(x) < $signed(y)))
      $fatal(1, "comparison mismatch a=%h b=%h", x, y);
    if (difference !== (x - y) || predecessor !== (x - y - 32'd1))
      $fatal(1, "consecutive subtraction mismatch a=%h b=%h", x, y);
    target = y;
    delta = x;
    rs = target - delta;
    check_target();
    rs = rs + 32'd1;
    check_target();
    rs = rs ^ 32'd2;
    check_target();
  endtask
  initial begin
    check(0, 0);
    check(0, 1);
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
