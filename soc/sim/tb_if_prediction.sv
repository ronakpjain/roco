`timescale 1ns / 1ps
`default_nettype none
module tb_if_prediction;
  logic clk = 0;
  always #5 clk = !clk;
  logic rst = 1, flush = 0, consume_enable = 1;
  logic [31:0] redirect = 32'h300;
  wire req, valid, fault, pred_taken;
  wire [31:0] addr, pc, instr, pred_target, fetch_pc;
  logic rsp_valid = 0;
  logic [31:0] rsp_addr = 0, rsp_data = 0;
  wire lookup_taken = (fetch_pc == 32'h100 || fetch_pc == 32'h200);
  wire [31:0] lookup_target = fetch_pc == 32'h100 ? 32'h200 : 32'h100;
  wire consume = valid && consume_enable;
  roco_cpu_if_stage dut (
      .clk(clk),
      .rst(rst),
      .halt(1'b0),
      .boot_addr(32'h100),
      .stall(1'b0),
      .flush(flush),
      .redirect_pc(redirect),
      .pred_taken(lookup_taken),
      .pred_target(lookup_target),
      .imem_req(req),
      .imem_addr(addr),
      .imem_rsp_valid(rsp_valid),
      .imem_rsp_addr(rsp_addr),
      .imem_rsp_data(rsp_data),
      .imem_miss(1'b0),
      .imem_busy(1'b0),
      .imem_fault(1'b0),
      .imem_fault_addr(32'd0),
      .if_valid(valid),
      .if_pc(pc),
      .if_instr(instr),
      .if_fault(fault),
      .if_pred_taken(pred_taken),
      .if_pred_target(pred_target),
      .fetch_pc(fetch_pc),
      .if_consume(consume)
  );
  always_ff @(posedge clk) begin
    rsp_valid <= req && !rst;
    rsp_addr <= addr;
    rsp_data <= addr ^ 32'h12345678;
  end
  logic [31:0] expected_pc = 32'h100;
  integer retired = 0;
  always @(posedge clk) begin
    if (rst) expected_pc = 32'h100;
    else if (flush) expected_pc = redirect;
    else if (consume) begin
      assert (pc == expected_pc && instr == (pc ^ 32'h12345678) && !fault)
      else $fatal(1, "prediction stream expected %h got %h", expected_pc, pc);
      assert (pred_taken == (pc == 32'h100 || pc == 32'h200))
      else $fatal(1, "prediction metadata mismatch");
      if (pred_taken) begin
        assert (pred_target == (pc == 32'h100 ? 32'h200 : 32'h100))
        else $fatal(1, "prediction target mismatch");
      end
      expected_pc = pc == 32'h100 ? 32'h200 : pc == 32'h200 ? 32'h100 : pc + 4;
      retired++;
    end
  end
  initial begin
    repeat (3) @(negedge clk);
    rst = 0;
    wait (retired >= 20);
    // A redirect wins even when a taken prediction is pending.
    @(negedge clk);
    while (!dut.apply_prediction) @(negedge clk);
    flush = 1;
    @(negedge clk);
    flush = 0;
    wait (retired >= 40);
    consume_enable = 0;
    repeat (12) @(negedge clk);
    consume_enable = 1;
    wait (retired >= 60);
    @(negedge clk);
    redirect = 32'h100;
    flush = 1;
    @(negedge clk);
    flush = 0;
    wait (retired >= 80);
    $display("tb_if_prediction: PASS (taken stream, redirect priority, queue hold)");
    $finish;
  end
  initial begin
    #20000;
    $fatal(1, "timeout");
  end
endmodule
