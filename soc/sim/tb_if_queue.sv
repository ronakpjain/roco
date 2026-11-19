`timescale 1ns / 1ps
module tb_if_queue;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1;
  logic flush = 0;
  logic consume = 0;
  logic stall = 1;
  logic busy = 0;
  logic miss = 0;
  logic rsp_valid = 0;
  logic fault = 0;
  logic [31:0] rsp_addr = 0;
  logic [31:0] rsp_data = 0;
  logic [31:0] fault_addr;
  logic valid, head_fault, pred_taken, req;
  logic [31:0] pc, instr, pred_target, fetch_pc, req_addr;
  assign fault_addr = fetch_pc;

  roco_cpu_if_stage dut (
      .oldest_pc(),
      .clk(clk),
      .rst(rst),
      .halt(1'b0),
      .boot_addr(32'h80000000),
      .stall(stall),
      .flush(flush),
      .redirect_pc(32'h80001000),
      .pred_taken(1'b0),
      .pred_target(32'd0),
      .pred_direct(1'b0),
      .pred_imm(21'd0),
      .imem_req(req),
      .imem_addr(req_addr),
      .imem_rsp_valid(rsp_valid),
      .imem_rsp_addr(rsp_addr),
      .imem_rsp_data(rsp_data),
      .imem_miss(miss),
      .imem_retry_previous(1'b0),
      .imem_miss_addr(32'd0),
      .imem_busy(busy),
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
    // Asynchronous reset wins over both a full queue and live response
    // inputs; speculative writes during reset must never publish a slot.
    fault = 1;
    repeat (4) tick();
    rsp_valid = 1;
    rst = 1;
    #1;
    if (valid) $fatal(1, "asynchronous reset did not invalidate full queue");
    repeat (3) tick();
    if (valid) $fatal(1, "response during reset became visible");
    fault = 0;
    rsp_valid = 0;
    rst = 0;
    tick();
    if (valid || fetch_pc !== 32'h80000000) $fatal(1, "reset did not restore boot fetch");
    // A miss must retry the original PC without losing the first hit
    // response or publishing it twice, then resume a one-per-cycle stream.
    stall = 0;
    miss = 1;
    tick();
    if (fetch_pc !== 32'h80000000) $fatal(1, "miss skipped request PC");
    miss = 0;
    busy = 1;
    repeat (10) begin
      tick();
      if (fetch_pc !== 32'h80000000) $fatal(1, "busy retry changed request PC");
    end
    busy = 0;
    tick();
    if (fetch_pc !== 32'h80000004) $fatal(1, "retry did not resume sequential fetch");
    rsp_valid = 1;
    rsp_addr = 32'h80000000;
    rsp_data = 32'h11111111;
    tick();
    check_head(32'h80000000, 1'b0, 32'h11111111);
    consume = 1;
    rsp_addr = 32'h80000004;
    rsp_data = 32'h22222222;
    tick();
    check_head(32'h80000004, 1'b0, 32'h22222222);
    rsp_valid = 0;
    stall = 1;
    tick();
    consume = 0;
    if (valid) $fatal(1, "retry duplicated a response");
    $display("tb_if_queue: PASS");
    $finish;
  end
endmodule
