// Observe the real fence handshake without assuming CPU or RAM traffic.
initial assume (rst);
logic f_fence_pending, f_fence_clean, f_fence_drained;
logic f_fence_history;
initial f_fence_history = 1'b0;

always_ff @(posedge clk) begin
  f_fence_history <= 1'b1;
  if (rst || fence_done) begin
    {f_fence_pending, f_fence_clean, f_fence_drained} <= '0;
  end else begin
    if (core_fence_req) f_fence_pending <= 1'b1;
    if (dcache_flush && dcache_flush_done) f_fence_clean <= 1'b1;
    if (f_fence_clean && c_ready) f_fence_drained <= 1'b1;
  end

  if (!rst) begin
    if (core_fence_req) assert (!dmem_req && !dmem_lu_valid && !trace_valid);
    if (trace_valid && trace_instr[6:0] == 7'h0f && trace_instr[14:12] == 3'd1) begin
      assert (fence_done);
    end
    if (dcache_flush) assert (f_fence_pending && !f_fence_clean && !icache_flush);
    if (icache_flush) assert (f_fence_pending && f_fence_clean && f_fence_drained);
    if (fence_done) begin
      assert (f_fence_pending && f_fence_clean && f_fence_drained);
      assert (!dcache_flush && !icache_flush && !ic_cpu_rsp);
    end
    if (f_fence_history && !$past(rst)) begin
      if (icache_flush) assert ($past(c_ready && f_fence_clean));
      if (fence_done) assert ($past(icache_flush));
    end

    // Check the actual SoC's phase correspondence, not an assumption
    // about the controller's hidden state at the induction boundary.
    assert (f_fence_pending == (fence_state != F_IDLE || fence_done));
    assert (f_fence_clean == (fence_state == F_DRAIN || fence_state == F_ICACHE || fence_done));
    assert (f_fence_drained == (fence_state == F_ICACHE || fence_done));
    assert (dcache_flush == (fence_state == F_DCACHE));
    assert (icache_flush == (fence_state == F_ICACHE));
  end
end
