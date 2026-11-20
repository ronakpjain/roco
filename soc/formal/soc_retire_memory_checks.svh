// Follow the watched physical-fetch tag through the real stage enables.
// Payloads may refresh while invalid; validity alone controls observation.
logic retire_idex_watch, retire_exmem_watch, retire_exception_watch;
logic [31:0] retire_idex_pc, retire_exmem_pc, retire_exception_pc;
always_ff @(posedge clk) begin
  if (rst) begin
    {retire_idex_watch, retire_exmem_watch, retire_exception_watch} <= '0;
    {retire_idex_pc, retire_exmem_pc, retire_exception_pc} <= '0;
  end else begin
    assert (!(retire && rvfi_sync_exception));
    if (!halt && !stall) begin
      retire_idex_watch <= f_head_watch;
      retire_idex_pc <= if_pc;
    end
    if (!halt && !fence_req && !mem_wait) begin
      retire_exmem_watch <= retire_idex_watch;
      retire_exmem_pc <= retire_idex_pc;
    end
    if (f_sync_capture) begin
      retire_exception_watch <= retire_idex_watch;
      retire_exception_pc <= retire_idex_pc;
    end
    if (f_fetch_coherent) begin
      if (idex_valid && retire_idex_watch) begin
        assert (!idex_ifault && idex_instr == formal_watch_data);
        assert (idex_pc == retire_idex_pc);
      end
      if (exmem_valid && retire_exmem_watch) begin
        assert (exmem_instr == formal_watch_data && exmem_pc == retire_exmem_pc);
      end
      if (f_sync_pending && retire_exception_watch) begin
        assert (rvfi_exception.instr == formal_watch_data);
        assert (rvfi_exception.pc == retire_exception_pc);
      end
      if (trace_valid && retire_exmem_watch) begin
        assert (trace_instr == formal_watch_data && trace_pc == retire_exmem_pc);
      end
      if (rvfi_valid && !rvfi_trap && retire_exmem_watch) begin
        assert (rvfi_insn == formal_watch_data && rvfi_pc_rdata == retire_exmem_pc);
      end
      if (rvfi_valid && rvfi_trap && retire_exception_watch) begin
        assert (rvfi_insn == formal_watch_data && rvfi_pc_rdata == retire_exception_pc);
      end
    end
    cover (idex_valid && retire_idex_watch && f_fetch_coherent);
    cover (trace_valid && retire_exmem_watch && f_fetch_coherent);
    cover (rvfi_valid && rvfi_trap && retire_exception_watch && f_fetch_coherent);
  end
end
