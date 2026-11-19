// Division has two architectural observations: the in-order instruction
// event and the later single-port GPR write. A younger instruction cannot
// read or overwrite that destination until the deferred write lands.
logic exmem_div;
assign exmem_div = exmem_instr[6:0] == 7'h33 && exmem_instr[31:25] == 1 && exmem_instr[14];
always @(posedge clk) begin
  if (!rst) begin
    if (idex_valid) begin
      assert (idex_is_div == (idex_instr[6:0] == 7'h33 && idex_instr[31:25] == 1 && idex_instr[14]));
      assert (idex_is_mul == (idex_instr[6:0] == 7'h33 && idex_instr[31:25] == 1 && !idex_instr[14]));
      if (idex_is_div || idex_is_mul) begin
        assert (!idex_is_csr && !idex_ifault && !idex_illegal);
        assert (idex_rd == idex_instr[11:7] && idex_md_op == idex_instr[14:12]);
        assert (rvfi_idex_rs1 == idex_instr[19:15] && rvfi_idex_rs2 == idex_instr[24:20]);
      end
      if (!rvfi_fwd_mem_ready && !rvfi_fwd_cancel && (idex_rs1_from_mem || idex_rs2_from_mem))
        assert (exmem_valid && exmem_regwrite && !mem_result_late);
      if (div_busy) begin
        assert (!idex_is_div);
        if (div_rd != 0) begin
          assert (rvfi_idex_rs1 != div_rd && rvfi_idex_rs2 != div_rd);
          assert (!idex_regwrite || idex_rd != div_rd);
        end
      end
    end
    if (exmem_valid) begin
      if (rvfi_exmem.rs1 == 0) assert (rvfi_exmem.rs1_data == 0);
      if (rvfi_exmem.rs2 == 0) assert (rvfi_exmem.rs2_data == 0);
    end
    if (exmem_valid && exmem_div) begin
      assert (div_busy && !exmem_regwrite && !mem_wait);
      assert (exmem_rd == div_rd);
    end
    if (div_busy && exmem_valid && !exmem_div && div_rd != 0) begin
      assert (rvfi_exmem.rs1 != div_rd && rvfi_exmem.rs2 != div_rd);
      assert (!exmem_regwrite || exmem_rd != div_rd);
    end
    if (!$past(rst)) begin
      assert ((rvfi_valid && !rvfi_trap && exmem_div) == $past(rvfi_div_start));
      if (!$past(rvfi_div_start)) assert ($stable(div_rd));
      if ($past(rvfi_div_start)) begin
        assert (rvfi_insn == $past(idex_instr) && rvfi_pc_rdata == $past(idex_pc));
        assert (rvfi_rs1_rdata == $past(rvfi_div_a) && rvfi_rs2_rdata == $past(rvfi_div_b));
      end
    end
    assert (!(fwd_watched_write && fwd_div_write));
    cover (rvfi_div_start && rvfi_div_b != 0);
    cover (rvfi_div_wb_valid && rvfi_div_wb_rd == rvfi_gpr_watch_addr);
    cover (div_conflict && div_busy && if_valid && dec_is_div);
    cover (retire && exmem_is_mul && trace_rd != 0 && trace_wdata != 0);
  end
end
