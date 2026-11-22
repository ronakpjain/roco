// verilog_syntax: parse-as-module-body
// Atomics have no address immediate and SC/AMO use an unshifted source
// word when aligned. Assert the setup-time relation across TLB waits.
logic f_a_op_legal, f_a_lr, f_a_sc;
assign f_a_lr = idex_instr[31:27] == 5'd2;
assign f_a_sc = idex_instr[31:27] == 5'd3;
always_comb begin
  case (idex_instr[31:27])
    5'd2: f_a_op_legal = idex_instr[24:20] == 0;
    5'd0, 5'd1, 5'd3, 5'd4, 5'd8, 5'd12: f_a_op_legal = 1'b1;
    5'd16, 5'd20, 5'd24, 5'd28: f_a_op_legal = 1'b1;
    default: f_a_op_legal = 1'b0;
  endcase
end
always_ff @(posedge clk) begin
  if (!rst && idex_valid && !idex_ifault && idex_instr[6:0] == 7'h2f) begin
    if (!f_a_op_legal || idex_instr[14:12] != 3'd2) begin
      assert (ex_trap && ex_trap_cause == `RV32_CAUSE_ILLEGAL && ex_trap_tval == idex_instr);
      assert (!ex_lu_valid);
    end else begin
      assert (idex_is_lr == f_a_lr && idex_is_sc == f_a_sc);
      assert (idex_is_amo == (!f_a_lr && !f_a_sc));
      if (!halt && !cancel_ex && scalar_mem_ready) begin
        assert (!lookup_is_vec_q && !exmem_valid);
        assert (ex_lu_vaddr == rvfi_held_rs1 && memory_addr_held == rvfi_held_rs1);
        assert (ex_lu_we == !f_a_lr);
        if (rvfi_idex_rs1 == 0) assert (rvfi_held_rs1 == 0);
        if (memory_addr_held[1:0] == 0) begin
          assert (stall_be == 4'hf);
          if (!f_a_lr) assert (stall_store_data == rvfi_held_rs2);
        end else if (!dmem_lu_fault) begin
          assert (ex_trap && !ex_lu_present && ex_trap_tval == rvfi_held_rs1);
          assert (ex_trap_cause == (f_a_lr ? `RV32_CAUSE_LOAD_MISALIGNED : `RV32_CAUSE_STORE_MISALIGNED));
        end
        if (!f_a_lr && rvfi_idex_rs2 == 0) assert (rvfi_held_rs2 == 0);
      end
    end
  end
end
