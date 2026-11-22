// verilog_syntax: parse-as-module-body
// An abstract fetch head moves only on ID consumption or a redirect.
// Speculative issue and misses may change physical queue occupancy, not
// the PC of its oldest instruction. Page faults occupy ordinary slots.
logic [31:0] f_fetch_head_pc, f_queue_end;
assign f_queue_end = prediction_pending ? last_req : request_pc;

always_ff @(posedge clk) begin
  if (boot_load) f_fetch_head_pc <= boot_addr;
  else if (!rst && !halt) begin
    if (flush) f_fetch_head_pc <= redirect_pc;
    else if (if_consume) f_fetch_head_pc <= if_pred_taken ? if_pred_target : if_pc + 32'd4;
  end

  if (!rst && !halt) begin
    assert (q_count <= 3'(DEPTH) && q_tail == q_head + q_count[1:0]);
    assert (request_pc[1:0] == 0 && pc_if[1:0] == 0 && last_req[1:0] == 0);
    if (boot_load)
      assert (q_empty && !prediction_pending && !retry_pending);
      else assert (oldest_pc == f_fetch_head_pc);
    assert (prediction_pending == (imem_rsp_valid || imem_retry_previous));
    if (prediction_pending) begin
      assert (!retry_pending && q_count < 3'(DEPTH) && pc_if == last_req + 32'd4);
      if (imem_rsp_valid) assert (imem_rsp_addr == last_req);
      if (imem_retry_previous) assert (imem_miss_addr == last_req);
      if (pending_pred_taken) begin
        assert (pending_pred_target[1:0] == 0);
        if (pending_pred_direct)
          assert (pending_pred_target == last_req + {{11{pending_pred_imm[20]}}, pending_pred_imm});
      end
    end
    if (fault_push) assert (!prediction_pending);
  end
end

for (genvar slot = 0; slot < DEPTH; slot++) begin : g_fetch_pc
  localparam int Next = (slot + 1) % DEPTH;
  logic [1:0] distance;
  logic [31:0] successor;
  assign distance = 2'(slot) - q_head;
  assign successor = q_pred_taken[slot] ? q_pred_target[slot] : q_pc[slot] + 32'd4;
  always_ff @(posedge clk) begin
    if (!rst && !halt && 3'(distance) < q_count) begin
      assert (q_pc[slot][1:0] == 0);
      if (q_fault[slot]) assert (!q_pred_taken[slot]);
      if (q_pred_taken[slot]) begin
        assert (q_pred_target[slot][1:0] == 0);
        if (q_pred_direct[slot])
          assert (q_pred_target[slot] == q_pc[slot] + {{11{q_pred_imm[slot][20]}}, q_pred_imm[slot]});
      end
      assert (successor == (3'(distance) + 3'd1 == q_count ? f_queue_end : q_pc[Next]));
    end
  end
end
