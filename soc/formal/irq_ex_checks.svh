assign formal_trap_pending = trap_pending;
assign formal_irq_pending = trap_pending && trap_is_irq_q;
assign formal_irq_epc = csr_irq_pc_q;
always @(posedge clk) begin
  if (!rst) begin
    assert (!csr_commit_q || (csr_commit_addr_q != 12'h180 && csr_commit_addr_q != 12'h302 &&
                             csr_commit_addr_q != 12'h303));
    if (irq_take) begin
      assert (!ex_trap && !csr_issue && !csr_commit_q);
      assert (!div_busy && !div_start && !div_wb_en);
      assert (!fence_hold && !cancel_ex);
    end
    if (formal_irq_pending) begin
      assert (!csr_commit_q && !div_busy && !div_wb_en);
      assert (csr_entry_tval == 0 && csr_trap_cause[31]);
      assert (csr_trap_vector == ({unused_csr_mtvec[31:2], 2'b00} +
              (unused_csr_mtvec[0] ? {25'd0, csr_irq_code_q, 2'b00} : 32'd0)));
    end
    if ($past(!rst && formal_irq_pending && trap_commit && !halt)) begin
      assert (csr_mepc == $past(formal_irq_epc));
      assert (csr_priv == `RV32_PRIV_M);
    end
    if ($past(!rst && irq_take)) begin
      assert (formal_irq_pending && csr_irq_code_q == $past(irq_code));
      assert (formal_irq_epc == $past(irq_next_pc));
    end
    cover (irq_take && idex_valid);
    cover (irq_take && !idex_valid);
    cover ($past(!rst && irq_req && div_busy) && irq_take);
    cover ($past(!rst && irq_req && fence_hold) && irq_take);
  end
end
