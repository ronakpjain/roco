// Architectural stream head advances only when ID consumes an entry.
// Redirects restart the stream; speculative addresses must not skip or
// duplicate a word, even if a miss or halt forces the last request back.
logic [31:0] stream_head, queue_end;
assign queue_end = prediction_pending ? last_req : request_pc;
always @(posedge clk) begin
  if (rst || boot_load) stream_head <= boot_addr;
  else if (flush) stream_head <= redirect_pc;
  else if (if_consume) stream_head <= if_pred_taken ? if_pred_target : if_pc + 32'd4;

  if (!rst) begin
    assert (q_count <= 3'(DEPTH) && q_tail == q_head + q_count[1:0]);
    assert (stream_head == oldest_pc);
    assert (pc_if[1:0] == 0 && last_req[1:0] == 0 && request_pc[1:0] == 0);
    assert (prediction_pending == (imem_rsp_valid || imem_retry_previous));
    if (prediction_pending) begin
      assert (!retry_pending && q_count < 3'(DEPTH));
      assert (imem_rsp_addr == last_req && pc_if == last_req + 32'd4);
      if (pending_pred_taken) assert (pending_pred_target[1:0] == 0);
      if (pending_pred_taken && pending_pred_direct)
        assert (pending_pred_target == last_req + {{11{pending_pred_imm[20]}}, pending_pred_imm});
    end
    if (boot_load) assert (q_empty && !prediction_pending && !retry_pending);
    cover (prediction_pending && imem_retry_previous && pending_pred_taken);
    cover (prediction_pending && imem_rsp_valid && halt);
    cover (prediction_pending && imem_retry_previous && flush);
    cover (q_count == 3 && if_consume);
    cover (if_consume && if_pc[31:2] == formal_watch_word);
  end
end

for (genvar slot = 0; slot < DEPTH; slot++) begin : g_cache_pc
  localparam int Next = (slot + 1) % DEPTH;
  logic [1:0] distance;
  logic [31:0] successor;
  assign distance = 2'(slot) - q_head;
  assign successor = q_pred_taken[slot] ? q_pred_target[slot] : q_pc[slot] + 32'd4;
  always @(posedge clk) begin
    if (!rst && 3'(distance) < q_count) begin
      assert (!q_fault[slot] && q_pc[slot][1:0] == 0);
      if (q_pc[slot][31:2] == formal_watch_word) assert (q_instr[slot] == formal_watch_data);
      if (q_pred_taken[slot]) assert (q_pred_target[slot][1:0] == 0);
      if (q_pred_taken[slot] && q_pred_direct[slot])
        assert (q_pred_target[slot] == q_pc[slot] + {{11{q_pred_imm[slot][20]}}, q_pred_imm[slot]});
      if (3'(distance) + 3'd1 == q_count) begin
        assert (successor == queue_end);
      end else begin
        assert (successor == q_pc[Next]);
      end
    end
  end
end
