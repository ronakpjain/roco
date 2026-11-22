// verilog_syntax: parse-as-module-body
// IRQ captures the successor after the current EX instruction, or the
// oldest not-yet-issued PC if EX is empty. The CPU-level monitor proves
// that PC's place in the retirement stream.
always_ff @(posedge clk) begin
  if (!rst && !halt) begin
    if (exmem_valid && (exmem_is_vload || exmem_is_vstore)) begin
      assert (vmem_active && idex_valid && is_vec_mem && idex_pc == exmem_pc);
      assert (vmem_done == exmem_vec_last);
    end
    if (vmem_active && !cancel_ex) begin
      assert (idex_valid && is_vec_mem);
      if (vmem_done) assert (exmem_valid && exmem_vec_last && (exmem_is_vload || exmem_is_vstore));
    end
    // A held vector packet pins ID/EX, so no younger vset or CSR write can
    // change vtype or vl beneath it. The EEW still matches, and the element
    // index is still below vl, unless the op is empty.
    assert (vec_vtype_sew <= 2);
    assert (vec_vl <= (5'd16 >> vec_vtype_sew));
    if (exmem_valid && (exmem_is_vload || exmem_is_vstore) && vec_vl != 0) begin
      assert (exmem_vec_sew == vec_vtype_sew);
      assert (5'(exmem_vec_elem) < vec_vl);
    end
    if (irq_take) begin
      assert (!ex_trap && !csr_issue && !csr_commit_q);
      assert (!div_busy && !div_start && !div_wb_en);
      if (idex_valid) assert (irq_next_pc == rvfi_ex.next_pc);
    end
    if (formal_irq_pending) begin
      assert (!csr_commit_q && !div_busy && !div_wb_en && !trap_capture);
      assert (csr_entry_tval == 0 && csr_trap_cause[31]);
      assert (formal_irq_epc[1:0] == 0);
    end
    if (!$past(rst) && $past(irq_take)) begin
      assert (formal_irq_pending && csr_irq_code_q == $past(irq_code));
      assert (formal_irq_epc == $past(irq_next_pc));
    end
    cover (irq_req && idex_valid && idex_is_fence_i && !fence_hold && !cancel_ex && !csr_commit_q &&
           !irq_take);
  end
end
