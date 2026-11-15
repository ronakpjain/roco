`timescale 1ns / 1ps
module tb_if_queue;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1;
  logic flush = 0;
  logic consume = 0;
  logic rsp_valid = 0;
  logic fault = 0;
  logic [31:0] rsp_addr = 0;
  logic [31:0] rsp_data = 0;
  logic [31:0] fault_addr;
  logic valid, head_fault, pred_taken, req;
  logic [31:0] pc, instr, pred_target, fetch_pc, req_addr;
  assign fault_addr = fetch_pc;

  roco_cpu_if_stage dut (
      .clk(clk),
      .rst(rst),
      .halt(1'b0),
      .boot_addr(32'h80000000),
      .stall(1'b1),
      .flush(flush),
      .redirect_pc(32'h80001000),
      .pred_taken(1'b0),
      .pred_target(32'd0),
      .imem_req(req),
      .imem_addr(req_addr),
      .imem_rsp_valid(rsp_valid),
      .imem_rsp_addr(rsp_addr),
      .imem_rsp_data(rsp_data),
      .imem_miss(1'b0),
      .imem_busy(1'b0),
      .imem_fault(fault),
      .imem_fault_addr(fault_addr),
      .if_valid(valid),
      .if_pc(pc),
      .if_instr(instr),
      .if_fault(head_fault),
      .if_pred_taken(pred_taken),
      .if_pred_target(pred_target),
      .fetch_pc(fetch_pc),
      .if_consume(consume)
  );

  task automatic tick;
    @(posedge clk);
    #1;
    @(negedge clk);
  endtask

  task automatic check_head(input logic [31:0] expected_pc, input logic expected_fault,
                            input logic [31:0] expected_instr);
    if (!valid || pc !== expected_pc || head_fault !== expected_fault || instr !== expected_instr)
      $fatal(1, "queue head mismatch pc=%h fault=%b instr=%h", pc, head_fault, instr);
  endtask

  initial begin
    tick();
    rst = 0;
    tick();
    // Faults can fill all four entries, unlike the reserved request slots.
    fault = 1;
    repeat (4) tick();
    check_head(32'h80000000, 1'b1, 32'h00000013);
    // Full queue payload must survive arbitrary response traffic.
    fault = 0;
    rsp_valid = 1;
    repeat (50) begin
      rsp_addr = fetch_pc;
      rsp_data = $random;
      tick();
      check_head(32'h80000000, 1'b1, 32'h00000013);
    end
    rsp_valid = 0;
    consume = 1;
    tick();
    consume = 0;
    // Only the now-empty tail may be refreshed while no push is accepted.
    repeat (10) tick();
    check_head(32'h80000004, 1'b1, 32'h00000013);
    rsp_valid = 1;
    rsp_addr = fetch_pc;
    rsp_data = 32'h12345678;
    tick();
    rsp_valid = 0;
    consume = 1;
    for (int i = 1; i < 4; i++) begin
      check_head(32'h80000000 + 4 * i, 1'b1, 32'h00000013);
      tick();
    end
    check_head(32'h80000010, 1'b0, 32'h12345678);
    tick();
    consume = 0;
    if (valid) $fatal(1, "queue did not drain");
    fault = 1;
    repeat (4) tick();
    fault = 0;
    flush = 1;
    tick();
    flush = 0;
    if (valid || fetch_pc !== 32'h80001000) $fatal(1, "full queue flush failed");
    repeat (10) tick();
    if (valid) $fatal(1, "speculative payload became visible without a push");
    $display("tb_if_queue: PASS");
    $finish;
  end
endmodule
