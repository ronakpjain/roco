`timescale 1ns / 1ps
module tb_vec_reduce;
  logic [127:0] source;
  logic [31:0] seed;
  logic [4:0] vl;
  logic [2:0] sew;
  logic [31:0] result;
  logic [31:0] expected, mask;
  int width, lanes;

  rv32_vec_reduce dut (.*);

  initial begin
    for (int size = 0; size < 3; size++) begin
      sew = 3'(size);
      width = 8 << size;
      lanes = 128 / width;
      mask = 32'hffffffff >> (32 - width);
      for (int sample = 0; sample < 1000; sample ++) begin
        source = {$urandom, $urandom, $urandom, $urandom};
        seed = $urandom;
        vl = 5'($urandom_range(0, lanes));
        if (sample == 0) begin
          source = '1;
          seed = '1;
          vl = 5'(lanes);
        end
        expected = seed;
        for (int k = 0; k < vl; k++) expected += 32'(source >> (k * width)) & mask;
        expected &= mask;
        #1;
        if (result !== expected)
          $fatal(1, "SEW=%0d VL=%0d seed=%h got=%h expected=%h", width, vl, seed, result, expected);
      end
    end
    $display("tb_vec_reduce: PASS (3000 reductions)");
    $finish;
  end
endmodule
