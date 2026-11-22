// verilog_syntax: parse-as-module-body
// Keep an element cursor rooted in the prepared scalar base, not in the
// RTL's incrementing address. Count translated lookups, including when
// the earlier element retires on the same edge. A fault cancels the
// cursor but leaves already committed load bytes and stores intact.
logic f_v_active, f_v_mem, f_v_element, f_v_last, f_v_load;
logic f_v_owner, f_v_group_ok, f_v_advance, f_v_prepare;
logic f_v_aligned, f_v_lookup, f_v_issue, f_v_empty;
logic [4:0] f_v_index, f_v_first, f_v_count, f_v_mem_index;
logic [2:0] f_v_size, f_v_mem_size;
logic [31:0] f_v_pc, f_v_insn, f_v_base, f_v_address, f_v_natural_mask;
logic [31:0] f_v_mem_pc, f_v_mem_insn, f_v_mem_va, f_v_mem_pa;
logic [3:0] f_v_mem_be;
assign f_v_owner = idex_valid && (idex_is_vload || idex_is_vstore);
assign f_v_size = idex_instr[14:12] == 0 ? 3'd0 : idex_instr[14:12] == 5 ? 3'd1 : 3'd2;
assign f_v_group_ok = vec_vl == 0 || f_v_size == vec_vtype_sew;
assign f_v_advance = !halt && !fence_hold && !cancel_ex;
assign f_v_prepare = f_v_advance && f_v_owner && f_v_group_ok && !f_v_active &&
                     vec_vstart[4:0] < vec_vl && !ex_trap;
assign f_v_address = f_v_base + (32'(f_v_index) << f_v_size);
assign f_v_natural_mask = (32'd1 << f_v_size) - 32'd1;
assign f_v_aligned = (f_v_address & f_v_natural_mask) == 0;
assign f_v_lookup = f_v_owner && f_v_group_ok && f_v_advance && f_v_active &&
                    f_v_index < f_v_count && f_v_aligned;
assign f_v_issue = f_v_lookup && !lu_stall && !dmem_lu_fault;
assign f_v_empty = f_v_advance && f_v_owner && f_v_group_ok && !f_v_active &&
                   vec_vstart[4:0] >= vec_vl && !dmem_lu_fault;

always_ff @(posedge clk) begin
  if (rst) begin
    f_v_active <= 1'b0;
    f_v_mem <= 1'b0;
  end else begin
    if (cancel_ex) f_v_active <= 1'b0;
    else if (f_v_advance) begin
      if (f_v_prepare) begin
        f_v_active <= 1'b1;
        f_v_base <= rs1_fwd;
        f_v_index <= vec_vstart[4:0];
        f_v_first <= vec_vstart[4:0];
        f_v_count <= vec_vl;
        f_v_pc <= idex_pc;
        f_v_insn <= idex_instr;
      end else if (f_v_active) begin
        if (f_v_index == f_v_count) f_v_active <= 1'b0;
        else if (f_v_issue) f_v_index <= f_v_index + 5'd1;
      end
    end
    if (!halt && !fence_hold) begin
      f_v_mem <= f_v_issue || f_v_empty;
      f_v_element <= f_v_issue;
      f_v_last <= f_v_empty || (f_v_index + 5'd1 == f_v_count);
      f_v_load <= idex_instr[6:0] == 7'h07;
      f_v_mem_pc <= idex_pc;
      f_v_mem_insn <= idex_instr;
      f_v_mem_index <= f_v_index;
      f_v_mem_size <= f_v_size;
      f_v_mem_va <= f_v_address;
      f_v_mem_pa <= dmem_lu_paddr;
      f_v_mem_be <= (f_v_size == 0 ? 4'h1 : f_v_size == 1 ? 4'h3 : 4'hf) << f_v_address[1:0];
    end
  end
end

always_ff @(posedge clk) begin
  if (!rst) begin
    assert (vec_vtype_sew <= 2);
    assert (vec_vl <= (5'd16 >> vec_vtype_sew));
    if (!cancel_ex && !halt) begin
      assert (vmem_active == f_v_active);
      if (f_v_active) begin
        assert (f_v_owner && f_v_group_ok && idex_pc == f_v_pc && idex_instr == f_v_insn);
        assert (!vec_operand_ready && lookup_is_vec_q);
        assert (f_v_first < f_v_count && f_v_index >= f_v_first && f_v_index <= f_v_count);
        assert (vec_vl == f_v_count && vec_vstart[4:0] == f_v_first);
        assert (f_v_base == rvfi_held_rs1 && vmem_addr == f_v_address && vmem_k == f_v_index);
      end
    end
    if (f_v_owner) begin
      assert (ex_lu_valid == f_v_lookup);
      if (!f_v_group_ok && !idex_ifault) assert (ex_trap && ex_trap_cause == `RV32_CAUSE_ILLEGAL);
      if (f_v_lookup) begin
        assert (ex_lu_vaddr == f_v_address && ex_lu_we == idex_is_vstore);
        assert (f_v_index < (5'd16 >> f_v_size));
      end
      if (trap_capture)
        assert (vec_vstart_we && vec_vstart_data == (f_v_active ? f_v_index : vec_vstart[4:0]));
      if (f_v_empty || (f_v_advance && f_v_active && f_v_index == f_v_count && !ex_trap))
        assert (vec_vstart_we && vec_vstart_data == 0);
    end

    assert (f_v_mem == (exmem_valid && (exmem_instr[6:0] == 7'h07 || exmem_instr[6:0] == 7'h27)));
    if (f_v_mem) begin
      assert (exmem_pc == f_v_mem_pc && exmem_instr == f_v_mem_insn);
      assert (exmem_vec_last == f_v_last && !exmem_vec_we && !exmem_regwrite);
      assert (exmem_is_vload == (f_v_element && f_v_load));
      assert (exmem_is_vstore == (f_v_element && !f_v_load));
      if (f_v_element) begin
        assert (f_v_active && f_v_index == f_v_mem_index + 5'd1);
        assert (exmem_pc == f_v_pc && exmem_instr == f_v_insn);
        assert (exmem_vec_sew == f_v_mem_size && 5'(exmem_vec_elem) == f_v_mem_index);
        assert (f_v_last == (f_v_index == f_v_count));
        assert (rvfi_exmem.vaddr == f_v_mem_va && exmem_alu == f_v_mem_pa && exmem_be == f_v_mem_be);
        assert (f_v_mem_va[11:0] == f_v_mem_pa[11:0]);
      end
    end
    cover (f_v_issue && f_v_index == 1);
    cover (f_v_empty);
    cover (trap_capture && f_v_owner && !f_v_group_ok);
  end
end
