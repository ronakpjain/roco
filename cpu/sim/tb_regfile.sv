`timescale 1ns / 1ps
`default_nettype none

// A flop-based reference checks reset, x0, bypass, and divider priority.
module tb_regfile;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst = 1'b1;
  logic [4:0] rs1 = '0, rs2 = '0, rd = '0, drd = '0;
  logic we = 1'b0, dwe = 1'b0;
  logic [31:0] wdata = '0, ddata = '0;
  logic [31:0] rdata1, rdata2;
  logic [31:0] expected[0:31];

  roco_cpu_regfile dut (.*);

  always @(posedge clk) begin
    if (rst) begin
      for (int r = 0; r < 32; r++) expected[r] = '0;
    end else if (dwe && (drd != 5'd0)) begin
      expected[drd] = ddata;
    end else if (we && (rd != 5'd0)) begin
      expected[rd] = wdata;
    end
  end

  task automatic check_reads;
    logic [31:0] want1, want2;
    for (int r = 0; r < 32; r++) begin
      rs1 = 5'(r);
      rs2 = 5'(31 - r);
      #0.01;
      // The regular WB bypass remains independent of divider priority.
      want1 = (rs1 == 5'd0) ? 32'd0 : (we && (rd == rs1)) ? wdata : expected[rs1];
      want2 = (rs2 == 5'd0) ? 32'd0 : (we && (rd == rs2)) ? wdata : expected[rs2];
      if ((rdata1 !== want1) || (rdata2 !== want2)) begin
        $fatal(1, "register read mismatch rs1=%0d rs2=%0d", rs1, rs2);
      end
    end
  endtask

  initial begin
    repeat (2) @(negedge clk);
    check_reads();
    rst = 1'b0;
    for (int n = 0; n < 3000; n++) begin
      rst = (n == 1500);
      we = 1'($urandom_range(0, 1));
      dwe = 1'($urandom_range(0, 1));
      rd = (n % 8 == 0) ? 5'd0 : 5'($random);
      drd = (n % 4 == 0) ? rd : 5'($random);
      wdata = $random;
      ddata = $random;
      check_reads();
      @(negedge clk);
      check_reads();
    end
    $display("tb_regfile: PASS");
    $finish;
  end
endmodule
