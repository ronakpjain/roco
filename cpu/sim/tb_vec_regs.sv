`timescale 1ns / 1ps
`default_nettype none

// Check byte insertion, untouched elements, reset, and EX/MEM priority.
module tb_vec_regs;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst = 1'b1;
  logic [4:0] vs1, vs2, vd;
  logic [127:0] vs1_data, vs2_data, vd_data;
  logic ex_we, mem_we;
  logic [4:0] ex_wd, mem_wd;
  logic [127:0] ex_wdata;
  logic [3:0] mem_elem;
  logic [2:0] mem_sew;
  logic [31:0] mem_wdata;
  logic [127:0] expected[0:31];

  roco_cpu_vec dut (.*);

  always @(posedge clk) begin
    if (rst) begin
      for (int r = 0; r < 32; r++) expected[r] = '0;
    end else if (ex_we) begin
      expected[ex_wd] = ex_wdata;
    end else if (mem_we) begin
      case (mem_sew)
        3'd0: expected[mem_wd][8*mem_elem+:8] = mem_wdata[7:0];
        3'd1: expected[mem_wd][16*mem_elem[2:0]+:16] = mem_wdata[15:0];
        default: expected[mem_wd][32*mem_elem[1:0]+:32] = mem_wdata;
      endcase
    end
  end

  task automatic check_reads;
    for (int r = 0; r < 32; r++) begin
      vs1 = 5'(r);
      vs2 = 5'((r + 1) % 32);
      vd = 5'((r + 2) % 32);
      #0.01;
      if ((vs1_data !== expected[vs1]) || (vs2_data !== expected[vs2]) ||
          (vd_data !== expected[vd])) begin
        $fatal(1, "vector register read mismatch: vs1=%0d vs2=%0d vd=%0d", vs1, vs2, vd);
      end
    end
  endtask

  initial begin
    vs1 = '0;
    vs2 = '0;
    vd = '0;
    ex_we = 1'b0;
    mem_we = 1'b0;
    ex_wd = '0;
    mem_wd = '0;
    ex_wdata = '0;
    mem_elem = '0;
    mem_sew = '0;
    mem_wdata = '0;
    repeat (2) @(negedge clk);
    check_reads();
    // Begin with partial loads, so untouched bytes must read as reset zero.
    rst = 1'b0;
    for (int sew = 0; sew < 3; sew++) begin
      for (int r = 0; r < 32; r++) begin
        for (int elem = 0; elem < (16 >> sew); elem++) begin
          mem_we = 1'b1;
          mem_wd = 5'(r);
          mem_sew = 3'(sew);
          mem_elem = 4'(elem);
          mem_wdata = $random;
          @(negedge clk);
          check_reads();
        end
      end
    end
    for (int n = 0; n < 3000; n++) begin
      rst = (n == 1500);
      ex_we = ($urandom_range(0, 3) == 0);
      mem_we = 1'($urandom_range(0, 1));
      ex_wd = 5'($random);
      mem_wd = 5'($random);
      ex_wdata = {$random, $random, $random, $random};
      mem_wdata = $random;
      mem_elem = 4'($random);
      mem_sew = 3'($urandom_range(0, 2));
      @(negedge clk);
      check_reads();
    end
    $display("tb_vec_regs: PASS");
    $finish;
  end
endmodule
