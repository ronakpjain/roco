`default_nettype none

module if_cache_contract (
  input logic clk
);
  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;

  (* anyconst *) logic [29:0] watch_word;
  (* anyconst *) logic [31:0] watch_data;
  (* anyseq *) logic [31:0] redirect_pc, pred_target, other_data;
  (* anyseq *) logic [20:0] pred_imm;
  (* anyseq *) logic halt, redirect, invalidate, stall, take_head, pred_taken, pred_direct;
  (* anyseq *) logic ram_ready, ram_valid;
  logic req, rsp, cache_miss, cache_busy, live, flush;
  logic [31:0] addr, rsp_addr, rsp_data, fetch_pc;
  logic valid, consume, head_taken;
  logic [31:0] head_pc, head_target;
  logic refill_req, filling;
  logic [22:0] refill_addr, ram_addr;
  logic [1:0] ram_beat;
  logic ram_last;
  logic [31:0] ram_data;

  assign flush = redirect && !halt;
  assign consume = valid && take_head && !flush && !halt;
  assign ram_last = ram_beat == 3;
  assign ram_data = ram_addr == watch_word[22:0] ? watch_data : other_data;
  always @(posedge clk) begin
    assume (redirect_pc[1:0] == 0);
    if (pred_taken) begin
      assume (pred_target[1:0] == 0);
      if (pred_direct) assume (pred_target == fetch_pc + {{11{pred_imm[20]}}, pred_imm});
    end
    live <= !rst && req && !cache_busy && !invalidate && !flush;
    if (rst) begin
      filling <= 0;
      ram_addr <= 0;
      ram_beat <= 0;
    end else begin
      if (ram_valid) assume (filling);
      if (filling) assert (ram_addr[1:0] == ram_beat);
      if (refill_req && ram_ready) begin
        filling <= 1;
        ram_beat <= 0;
        ram_addr <= refill_addr;
      end
      if (ram_valid) begin
        ram_addr <= ram_addr + 1'b1;
        ram_beat <= ram_beat + 1'b1;
        if (ram_last) filling <= 0;
      end
    end
  end

  icache cache (
      .formal_watch_word(watch_word[22:0]),
      .formal_watch_data(watch_data),
      .formal_filling(filling),
      .formal_ram_addr(ram_addr),
      .clk(clk),
      .rst(rst),
      .flush(invalidate),
      .cpu_req(req),
      .cpu_addr(addr),
      .cpu_rsp_valid(rsp),
      .cpu_rsp_addr(rsp_addr),
      .cpu_rsp_data(rsp_data),
      .cpu_miss(cache_miss),
      .cpu_busy(cache_busy),
      .mem_req(refill_req),
      .mem_word_addr(refill_addr),
      .mem_len(),
      .mem_ready(ram_ready),
      .mem_rvalid(ram_valid),
      .mem_rdata(ram_data),
      .mem_rlast(ram_last),
      .hit_pulse(),
      .miss_pulse()
  );

  roco_cpu_if_stage fetch (
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .boot_addr(32'h1000_0000),
      .flush(flush),
      .redirect_pc(redirect_pc),
      .stall(stall),
      .pred_taken(pred_taken),
      .pred_target(pred_target),
      .pred_direct(pred_direct),
      .pred_imm(pred_imm),
      .imem_req(req),
      .imem_addr(addr),
      .imem_rsp_valid(rsp && live),
      .imem_rsp_addr(rsp_addr),
      .imem_rsp_data(rsp_data),
      .imem_miss(cache_miss && live),
      .imem_retry_previous(cache_miss && live),
      .imem_miss_addr(rsp_addr),
      .imem_busy(cache_busy),
      .imem_fault(1'b0),
      .imem_fault_addr(32'd0),
      .if_valid(valid),
      .if_pc(head_pc),
      .if_instr(),
      .if_fault(),
      .if_pred_taken(head_taken),
      .if_pred_target(head_target),
      .if_pred_direct(),
      .if_pred_imm(),
      .fetch_pc(fetch_pc),
      .if_consume(consume),
      .formal_watch_word(watch_word),
      .formal_watch_data(watch_data)
  );
endmodule
