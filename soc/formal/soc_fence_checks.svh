// Observe the real fence handshake without assuming CPU or RAM traffic.
initial assume (rst);
logic f_fence_pending, f_fence_clean, f_fence_drained;
logic f_fence_history;
logic f_boot_epoch, f_boot_clean, f_boot_invalidated;
initial f_fence_history = 1'b0;

always_ff @(posedge clk) begin
  f_fence_history <= 1'b1;
  if (rst) begin
    {f_boot_epoch, f_boot_clean, f_boot_invalidated} <= '0;
  end else begin
    if (boot_restart && !BOOT_OVERRIDE) begin
      f_boot_epoch <= 1'b1;
      {f_boot_clean, f_boot_invalidated} <= '0;
    end else begin
      if (boot_cache_maintenance && dcache_flush && dcache_flush_done) f_boot_clean <= 1'b1;
      if (boot_cache_maintenance && icache_flush) f_boot_invalidated <= 1'b1;
    end
  end
  if (rst) begin
    {f_fence_pending, f_fence_clean, f_fence_drained} <= '0;
  end else if ((boot_restart && !BOOT_OVERRIDE) || (core_fence_req && fence_state == F_IDLE)) begin
    f_fence_pending <= 1'b1;
    {f_fence_clean, f_fence_drained} <= '0;
  end else if (fence_done) begin
    {f_fence_pending, f_fence_clean, f_fence_drained} <= '0;
  end else begin
    if (dcache_flush && dcache_flush_done) f_fence_clean <= 1'b1;
    if (f_fence_clean && c_ready) f_fence_drained <= 1'b1;
  end

  if (!rst) begin
    if (!core_rst) assert (boot_done_eff);
    if (fence_state != F_IDLE && !boot_cache_maintenance) assert (boot_done_eff && boot_release);
    if (f_boot_invalidated) assert (f_boot_clean);
    if (f_boot_epoch && !boot_cache_maintenance) assert (f_boot_clean && f_boot_invalidated);
    if (fence_state != F_IDLE) assert (core_fence_req || core_rst);
    if (boot_cache_maintenance && (fence_state == F_DRAIN || fence_state == F_ICACHE))
      assert (f_boot_clean && f_dc_idle && !f_dc_lookup_pending);
    if (boot_cache_maintenance && dcache_flush && dcache_flush_done)
      assert (f_dc_idle && !f_dc_lookup_pending);
    if (boot_cache_maintenance) begin
      assert (core_rst && !dmem_req && !dmem_lu_valid && !trace_valid && !boot_mem_ready);
      assert (f_boot_epoch && fence_state != F_IDLE);
    end
    if (cache_rst)
      assert (boot_cache_maintenance && f_boot_clean && f_fence_drained && icache_flush);
    if (f_boot_epoch && boot_mem_req && boot_mem_ready)
      assert (f_boot_clean && f_boot_invalidated && !cache_rst && !boot_cache_maintenance);
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
    cover (core_fence_req);
    cover (dcache_flush);
    cover (icache_flush);
    cover (fence_done);
    cover (cache_rst);
    if (f_fence_history && !$past(rst)) begin
      if ($past(dcache_flush && !dcache_flush_done)) assert (dcache_flush);
      if ($past(ic_mem_req && !ic_mem_ready))
        assert ($stable({ic_mem_req, ic_mem_word_addr, ic_mem_len}));
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
