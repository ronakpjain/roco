// Independently retain the original EX fault, rather than reproducing
// the retimed CSR payload mux and its separate branch-target adder.
logic f_sync_waiting;
logic [31:0] f_sync_pc, f_sync_instr, f_sync_cause, f_sync_tval;
always_ff @(posedge clk or posedge rst) begin
  if (rst) begin
    f_sync_waiting <= 1'b0;
    {f_sync_pc, f_sync_instr, f_sync_cause, f_sync_tval} <= '0;
  end else begin
    // An older syscon write can halt the core before a younger captured
    // fault enters. The pending latch drains, but no trap is reported.
    if (trap_commit) f_sync_waiting <= 1'b0;
    if (trap_capture && ex_trap) begin
      f_sync_waiting <= 1'b1;
      f_sync_pc <= idex_pc;
      f_sync_instr <= idex_ifault ? 32'd0 : idex_instr;
      f_sync_cause <= ex_trap_cause;
      f_sync_tval <= ex_trap_tval;
    end
  end
end

always_ff @(posedge clk) begin
  if (!rst) begin
    assert (f_sync_waiting == (trap_pending && !trap_is_irq_q));
    if (f_sync_waiting) begin
      assert (!exmem_valid);
      assert (rvfi_exception.pc == f_sync_pc && rvfi_exception.instr == f_sync_instr);
      assert (csr_trap_pc == f_sync_pc && csr_trap_cause == f_sync_cause);
      assert (csr_entry_tval == f_sync_tval);
      assert (!trap_capture);
    end
    // An MMU data exception belongs to a held memory operation, never
    // to a control-transfer instruction using the target-address path.
    if (idex_valid && !cancel_ex && dmem_lu_fault) begin
      assert (scalar_is_mem || is_vec_mem);
      assert (!(idex_is_branch || idex_is_jal || idex_is_jalr));
    end
    if (idex_valid) begin
      if (scalar_is_mem || is_vec_mem) assert (!(idex_is_branch || idex_is_jal || idex_is_jalr));
      // JALR's fast address path and retimed trap-value adder use the
      // same base: a MEM-forwarded value or the captured ID register value.
      assert (!idex_rs1_from_wb && idex_rs1_from_rf == !idex_rs1_from_mem);
      if (idex_rs1_from_mem) assert (idex_rs1_val == 0);
    end
    if (rvfi_sync_exception) begin
      assert (f_sync_waiting && ex_trap_taken);
      cover (f_sync_cause == `RV32_CAUSE_BREAKPOINT);
      cover (f_sync_cause == `RV32_CAUSE_ECALL_M);
      cover (f_sync_cause == `RV32_CAUSE_INSTR_MISALIGNED && f_sync_tval == 32'd2);
      cover (f_sync_cause == `RV32_CAUSE_LOAD_PAGE_FAULT && f_sync_tval == 0);
    end
  end
end
