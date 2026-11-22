// verilog_syntax: parse-as-module-body
// A retire write is visible through WB before the physical GPR updates.
// A divider result enters this history at its separately arbitrated write.
logic [31:0] f_arch_gpr;
logic f_mem_gpr_write, f_mem_div;
assign f_mem_div = exmem_instr[6:0] == 7'h33 && exmem_instr[31:25] == 7'd1 && exmem_instr[14];
assign f_arch_gpr = f_gpr_pending ? f_gpr_pending_data : f_gpr_value;
assign f_mem_gpr_write = exmem_valid && exmem_regwrite && exmem_rd != 0 &&
                        exmem_rd == rvfi_gpr_watch_addr;
assign rvfi_gpr_hist_value = f_arch_gpr;

always_ff @(posedge clk) begin
  // A syscon halt freezes the packet registers; only reset can resume.
  if (!rst && !halt) begin
    if (idex_valid && !rvfi_fwd_cancel) begin
      if (div_busy) begin
        assert (!idex_is_div);
        if (div_rd != 0) begin
          assert (rvfi_idex_rs1 != div_rd && rvfi_idex_rs2 != div_rd);
          assert (!idex_regwrite || idex_rd != div_rd);
        end
      end
      if (rvfi_fwd_mem_ready) assert (!exmem_valid || !exmem_regwrite);
      if (rvfi_idex_rs1 == rvfi_gpr_watch_addr && rvfi_gpr_watch_addr != 0) begin
        if (rvfi_fwd_mem_ready)
          assert (rvfi_fwd_held_rs1 == f_arch_gpr);
          else if (idex_rs1_from_mem) begin
            assert (f_mem_gpr_write && !mem_result_late);
            assert (mem_forward_data == commit_wdata);
          end else begin
            assert (!f_mem_gpr_write && idex_rs1_val == f_arch_gpr);
          end
      end
      if (rvfi_idex_rs2 == rvfi_gpr_watch_addr && rvfi_gpr_watch_addr != 0) begin
        if (rvfi_fwd_mem_ready)
          assert (rvfi_fwd_held_rs2 == f_arch_gpr);
          else if (idex_rs2_from_mem) begin
            assert (f_mem_gpr_write && !mem_result_late);
            assert (mem_forward_data == commit_wdata);
          end else begin
            assert (!f_mem_gpr_write && idex_rs2_val == f_arch_gpr);
          end
      end
    end
    if (exmem_valid) begin
      // Only the divide's own in-order packet may use its destination
      // before the deferred result. It drains before the divider writes.
      if (f_mem_div)
        assert (!mem_wait && !fence_req && !div_wb_en && !exmem_regwrite);
        else if (div_busy && div_rd != 0) begin
          assert (rvfi_exmem.rs1 != div_rd && rvfi_exmem.rs2 != div_rd);
          assert (!exmem_regwrite || exmem_rd != div_rd);
        end
      if (rvfi_exmem.rs1 == rvfi_gpr_watch_addr) assert (rvfi_exmem.rs1_data == f_arch_gpr);
      if (rvfi_exmem.rs2 == rvfi_gpr_watch_addr) assert (rvfi_exmem.rs2_data == f_arch_gpr);
    end
    if (rvfi_valid) begin
      if (rvfi_rs1_addr == rvfi_gpr_watch_addr) assert (rvfi_rs1_rdata == f_arch_gpr);
      if (rvfi_rs2_addr == rvfi_gpr_watch_addr) assert (rvfi_rs2_rdata == f_arch_gpr);
    end
    cover (idex_valid && !rvfi_fwd_cancel && !rvfi_fwd_mem_ready && idex_rs1_from_mem &&
           rvfi_idex_rs1 == rvfi_gpr_watch_addr && mem_forward_data != 0);
    cover (idex_valid && !rvfi_fwd_cancel && rvfi_fwd_mem_ready && idex_is_store &&
           rvfi_idex_rs2 == rvfi_gpr_watch_addr && rvfi_fwd_held_rs2 != 0);
    cover (idex_valid && !rvfi_fwd_cancel && rvfi_fwd_mem_ready && idex_is_vec &&
           idex_rs1_from_mem && rvfi_idex_rs1 == rvfi_gpr_watch_addr && rvfi_fwd_held_rs1 != 0);
    cover (vec_element_commit && exmem_is_vload && rvfi_exmem.rs1 == rvfi_gpr_watch_addr &&
           rvfi_exmem.rs1_data == 32'h20000010);
  end
end
