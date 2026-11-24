// The checker advances with retirement, not IF issue. Interrupt entry
// changes the next PC without consuming an RVFI order number.
`include "irq_fetch_filter.svh"
logic [31:0] architectural_pc, next_after_mem, oldest_live;
logic [31:0] irq_pred_target;
logic handler_expected, irq_handler_expected;
always @(posedge clk) begin
  if (if_consume) irq_pred_target <= if_pred_target;
end
assign next_after_mem = ex_redirect_en ? ex_redirect_pc : idex_valid ? idex_pc : fetch_oldest_pc;
assign oldest_live = formal_trap_pending && !formal_irq_pending ? rvfi_exception.pc :
                     exmem_valid ? exmem_pc : next_after_mem;
always @(posedge clk) begin
  if (rst) begin
    architectural_pc <= boot_addr;
    handler_expected <= 0;
    irq_handler_expected <= 0;
  end else begin
    assert (!lookup_translate_q && !translated_valid_q);
    assert (!d_fault_q && !dmem_lu_stall && !mem_redirect && !fence_req);
    if (idex_valid) begin
      assert (irq_fetch_allowed(idex_instr) && idex_pc[1:0] == 0);
      assert (!idex_ifault && !idex_is_sfence && !idex_is_fence_i && !idex_sret);
      assert (!idex_is_vec && !idex_is_vload && !idex_is_vstore && !idex_is_vset);
      if (idex_is_csr) begin
        assert (idex_instr[6:0] == 7'h73 && idex_instr[14:12] != 0);
        assert (idex_csr_addr == idex_instr[31:20]);
      end
      if (idex_is_branch || idex_is_jal) begin
        assert (idex_imm == {{11{idex_imm[20]}}, idex_imm[20:0]});
        if (idex_pred_taken && idex_pred_target_match)
          assert (irq_pred_target == idex_pc + idex_imm);
      end
      if (idex_pred_jalr_aligned) begin
        assert (!irq_pred_target[0]);
        assert (idex_pred_jalr_base[30:0] == irq_pred_target[31:1] - idex_imm[31:1]);
        assert (idex_pred_jalr_carry[30:0] == idex_pred_jalr_base[30:0] - 31'd1);
      end
    end
    if (exmem_valid) begin
      assert (!exmem_is_vload && !exmem_is_vstore && !exmem_is_sfence && !exmem_is_fence_i);
    end
    if (ex_redirect_en) assert (ex_redirect_pc[1:0] == 0);
    assert (rvfi_intr == handler_expected);
    if (!formal_irq_pending || exmem_valid) assert (architectural_pc == oldest_live);
    if (idex_valid && !formal_trap_pending && !ex_redirect_en) begin
      assert ((idex_pred_taken ? irq_pred_target : idex_pc + 32'd4) == fetch_oldest_pc);
    end
    if (exmem_valid && !formal_trap_pending) assert (rvfi_exmem.next_pc == next_after_mem);
    if (rvfi_valid) begin
      assert (rvfi_pc_rdata == architectural_pc);
      architectural_pc <= rvfi_pc_wdata;
      handler_expected <= rvfi_trap;
      irq_handler_expected <= 0;
    end
    if (formal_irq_pending) begin
      assert (formal_irq_epc == (exmem_valid ? rvfi_exmem.next_pc : architectural_pc));
      assert (!mem_wait && !fence_req);
      assert (!vec_element_commit && !dmem_lu_valid);
    end
    if (rvfi_trap_entry && formal_irq_pending) begin
      assert (!rvfi_trap && !dmem_req && !div_wb_en);
      architectural_pc <= rvfi_trap_vector;
      handler_expected <= 1;
      irq_handler_expected <= 1;
    end
    cover (rvfi_trap_entry && formal_irq_pending && rvfi_valid);
    cover (rvfi_valid && rvfi_intr && irq_handler_expected);
  end
end
