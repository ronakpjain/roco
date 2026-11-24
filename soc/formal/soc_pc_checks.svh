// verilog_syntax: parse-as-module-body
`include "soc_mem_decode_checks.svh"

// Track the next architectural PC using only reset, RVFI events, and trap
// entry. IRQ entry overrides the next PC but is not a retirement event.
logic f_have_pc, f_irq_handler;
logic [31:0] f_retire_pc, f_expected_pc, f_after_mem_pc;
logic [31:0] f_idex_pred_target, f_idex_pred_next;
logic f_mem_vec, f_mem_vec_final, f_mem_barrier;
assign f_expected_pc = f_have_pc ? f_retire_pc : boot_addr;
assign f_mem_vec = exmem_valid && (exmem_is_vload || exmem_is_vstore);
assign f_mem_vec_final = f_mem_vec && exmem_vec_last;
assign f_mem_barrier = exmem_valid && (exmem_is_fence_i || exmem_is_sfence);
assign f_after_mem_pc = formal_trap_pending ?
                        (formal_irq_pending ? formal_irq_epc : rvfi_exception.pc) :
                        f_mem_barrier ? exmem_pc + 32'd4 :
                        ex_redirect_en ? ex_redirect_pc :
                        f_mem_vec_final && idex_pred_taken ? exmem_pc + 32'd4 :
                        idex_valid && !f_mem_vec_final ? idex_pc : fetch_oldest_pc;
assign f_idex_pred_next = idex_pred_taken ? f_idex_pred_target : idex_pc + 32'd4;

always_ff @(posedge clk or posedge rst) begin
  if (rst) begin
    f_have_pc <= 1'b0;
    f_irq_handler <= 1'b0;
    f_retire_pc <= '0;
  end else begin
    f_have_pc <= 1'b1;
    if (rvfi_trap_entry) f_irq_handler <= formal_irq_pending;
    else if (rvfi_valid) f_irq_handler <= 1'b0;
    if (rvfi_trap_entry) f_retire_pc <= rvfi_trap_vector;
    else if (rvfi_valid) f_retire_pc <= rvfi_pc_wdata;
    else if (!f_have_pc) f_retire_pc <= boot_addr;
  end
end

always_ff @(posedge clk) begin
  if (if_consume && !halt) f_idex_pred_target <= if_pred_target;
  if (!rst && !halt) begin
    assert (f_expected_pc == (exmem_valid ? exmem_pc : f_after_mem_pc));
    if (idex_valid) begin
      assert (idex_pc[1:0] == 0);
      if (!ex_redirect_en && !formal_trap_pending) assert (f_idex_pred_next == fetch_oldest_pc);
      if ((idex_is_branch || idex_is_jal) && idex_pred_taken && idex_pred_target_match)
        assert (f_idex_pred_target == idex_pc + idex_imm);
      if (idex_pred_jalr_aligned) begin
        assert (!f_idex_pred_target[0]);
        assert (idex_pred_jalr_base[30:0] == f_idex_pred_target[31:1] - idex_imm[31:1]);
        assert (idex_pred_jalr_carry[30:0] == idex_pred_jalr_base[30:0] - 31'd1);
      end
    end
    if (exmem_valid) begin
      assert (exmem_pc[1:0] == 0);
      if (exmem_instr[6:0] != 7'h63 && exmem_instr[6:0] != 7'h67 && exmem_instr[6:0] != 7'h6f &&
          !(exmem_instr[6:0] == 7'h73 && exmem_instr[14:12] == 0 &&
            (exmem_instr[31:20] == 12'h302 || exmem_instr[31:20] == 12'h102)))
        assert (rvfi_exmem.next_pc == exmem_pc + 32'd4);
      if (f_mem_vec) begin
        assert (idex_valid && idex_pc == exmem_pc && idex_instr == exmem_instr);
        assert (!ex_redirect_en && !formal_trap_pending);
        // The last element can wait in MEM. Repair a stale prediction
        // when it retires, not while its transaction is still pending.
        if (f_mem_vec_final && retire) assert (ex_redirect_raw == idex_pred_taken);
      end
      if (!f_mem_vec || f_mem_vec_final) assert (rvfi_exmem.next_pc == f_after_mem_pc);
    end
    if (ex_redirect_en) assert (ex_redirect_pc[1:0] == 0);
    if (rvfi_valid) assert (rvfi_pc_rdata == f_expected_pc);
    if (formal_irq_pending) begin
      assert (!mem_wait && !fence_req && !mem_redirect);
      assert (!dmem_req && !dmem_lu_valid && !div_wb_en);
      assert (!exmem_valid || retire);
      assert (formal_irq_epc == (exmem_valid ? rvfi_exmem.next_pc : f_expected_pc));
    end
    if (!$past(rst) && $past(rvfi_trap_entry))
      assert (ex_redirect_en && ex_redirect_pc == $past(rvfi_trap_vector));
    cover (rvfi_trap_entry && formal_irq_pending && retire);
    cover (rvfi_trap_entry && formal_irq_pending && !retire);
    cover (f_irq_handler && rvfi_valid && rvfi_intr && !rvfi_trap && rvfi_insn == 32'h34102273);
  end
end
