`timescale 1ns / 1ps
`default_nettype none
module tb_if_prediction;
  logic clk = 0;
  always #5 clk = !clk;
  logic rst = 1, flush = 0, consume_enable = 1;
  logic [31:0] redirect = 32'h300;
  logic req, valid, fault, pred_taken, pred_direct;
  logic [20:0] pred_imm;
  logic [31:0] addr, pc, instr, pred_target, fetch_pc;
  logic rsp_valid;
  logic [31:0] rsp_addr, rsp_data;
  logic cache_miss, cache_busy, mem_req;
  logic [22:0] mem_addr;
  logic [3:0] mem_len;
  logic cache_live = 0, mem_active = 0, mem_rvalid = 0, mem_rlast = 0;
  logic [31:0] mem_rdata = 0;
  logic [22:0] mem_base;
  integer mem_delay = 0, mem_beat = 0;
  logic lookup_taken;
  assign lookup_taken = (fetch_pc == 32'h100 || fetch_pc == 32'h200);
  logic [31:0] lookup_target;
  assign lookup_target = fetch_pc == 32'h100 ? 32'h200 : 32'h100;
  logic consume;
  assign consume = valid && consume_enable;
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
      .pred_direct(lookup_taken),
      .pred_imm(21'(lookup_target - fetch_pc)),
      .imem_req(req),
      .imem_addr(addr),
      .imem_rsp_valid(rsp_valid),
      .imem_rsp_addr(rsp_addr),
      .imem_rsp_data(rsp_data),
      .imem_miss(cache_miss && cache_live),
      .imem_retry_previous(cache_miss && cache_live),
      .imem_miss_addr(rsp_addr),
      .imem_busy(cache_busy),
      .imem_fault(1'b0),
      .imem_fault_addr(32'd0),
      .if_valid(valid),
      .if_pc(pc),
      .if_instr(instr),
      .if_fault(fault),
      .if_pred_taken(pred_taken),
      .if_pred_target(pred_target),
      .if_pred_direct(pred_direct),
      .if_pred_imm(pred_imm),
      .fetch_pc(fetch_pc),
      .if_consume(consume)
  );
  // A small real cache makes alternating taken targets conflict. This
  // exercises response-stage misses during prediction bubbles as well
  // as stale misses arriving on a redirect.
  icache #(
      .NUM_LINES(4)
  ) cache (
      .clk(clk),
      .rst(rst),
      .flush(1'b0),
      .cpu_req(req),
      .cpu_addr(addr),
      .cpu_rsp_valid(rsp_valid),
      .cpu_rsp_addr(rsp_addr),
      .cpu_rsp_data(rsp_data),
      .cpu_miss(cache_miss),
      .cpu_busy(cache_busy),
      .mem_req(mem_req),
      .mem_word_addr(mem_addr),
      .mem_len(mem_len),
      .mem_ready(!mem_active),
      .mem_rvalid(mem_rvalid),
      .mem_rdata(mem_rdata),
      .mem_rlast(mem_rlast),
      .hit_pulse(),
      .miss_pulse()
  );
  always_ff @(posedge clk) begin
    if (rst || flush) cache_live <= 1'b0;
    else cache_live <= req && !cache_busy;
    mem_rvalid <= 1'b0;
    mem_rlast <= 1'b0;
    if (rst) mem_active <= 1'b0;
    else if (mem_req && !mem_active) begin
      assert (mem_len == 3)
      else $fatal(1, "unexpected line length");
      mem_base <= mem_addr;
      mem_active <= 1'b1;
      mem_delay <= 2;
      mem_beat <= 0;
    end else if (mem_active) begin
      if (mem_delay != 0) mem_delay <= mem_delay - 1;
      else begin
        mem_rvalid <= 1'b1;
        mem_rdata <= (32'(mem_base + 23'(mem_beat)) << 2) ^ 32'h12345678;
        mem_rlast <= (mem_beat == 3);
        if (mem_beat == 3) mem_active <= 1'b0;
        else mem_beat <= mem_beat + 1;
      end
    end
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
        assert (pred_direct && pred_imm == 21'(pred_target - pc))
        else $fatal(1, "prediction metadata lost during queue/cache replay");
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
    $display("tb_if_prediction: PASS (taken misses, redirect priority, queue hold)");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
