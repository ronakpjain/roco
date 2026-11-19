// Payload tags follow the actual queue RAM write, including speculative
// writes into an unoccupied tail slot. Only occupied slots are checked.
logic watched_slot[DEPTH];
always_ff @(posedge clk) begin
  if (q_count < 3'(DEPTH)) watched_slot[q_tail] <= !fault_push && formal_response_watch;
  if (!rst) begin
    assert (q_count <= 3'(DEPTH) && q_tail == q_head + q_count[1:0]);
    if (formal_coherent && imem_rsp_valid && formal_response_watch)
      assert (imem_rsp_data == formal_watch_data);
    if (!halt && !flush && if_consume && watched_slot[q_head] && formal_coherent)
      assert (!if_fault && if_instr == formal_watch_data);
  end
end
for (genvar slot = 0; slot < DEPTH; slot++) begin : g_soc_fetch_data
  logic [1:0] distance;
  assign distance = 2'(slot) - q_head;
  always_ff @(posedge clk) begin
    if (!rst && 3'(distance) < q_count) begin
      if (q_fault[slot]) assert (!watched_slot[slot]);
      if (formal_coherent && watched_slot[slot]) assert (q_instr[slot] == formal_watch_data);
    end
  end
end
