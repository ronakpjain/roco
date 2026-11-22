// verilog_syntax: parse-as-module-body
`include "soc_mem_decode_checks.svh"

// Connect decoded operands and virtual addresses to the real MEM packet.
// The MEM checker independently computes the reservation and AMO result
// from the accepted physical transaction and its read data.
logic f_a_lookup;
logic [31:0] f_a_virtual, f_a_physical;
always_ff @(posedge clk or posedge rst) begin
  if (rst) begin
    {f_a_lookup, f_a_virtual, f_a_physical} <= '0;
  end else if (!halt && !mem_wait && !fence_req) begin
    f_a_lookup <= dmem_lu_valid && idex_instr[6:0] == 7'h2f;
    f_a_virtual <= ex_lu_vaddr;
    f_a_physical <= {dmem_lu_addr, dmem_lu_offset};
  end
end

always_ff @(posedge clk) begin
  if (!rst) assert (f_a_lookup == (exmem_valid && exmem_instr[6:0] == 7'h2f));
  if (!rst && f_a_lookup) begin
    assert (rvfi_exmem.vaddr == f_a_virtual && exmem_alu == f_a_physical);
    assert (exmem_is_lr || exmem_is_sc || exmem_is_amo);
    assert (exmem_regwrite && exmem_instr[14:12] == 3'd2);
    if (exmem_is_lr) assert (exmem_instr[24:20] == 0);
    assert (rvfi_exmem.rs1 == exmem_instr[19:15]);
    assert (rvfi_exmem.rs2 == (exmem_is_lr ? 5'd0 : exmem_instr[24:20]));
    assert (rvfi_exmem.vaddr == rvfi_exmem.rs1_data);
    assert (rvfi_exmem.vaddr[1:0] == 0 && exmem_alu[1:0] == 0 && exmem_be == 4'hf);
    if (!exmem_is_lr) assert (exmem_store_data == rvfi_exmem.rs2_data);
    assert (rvfi_exmem.next_pc == exmem_pc + 32'd4);
    if (retire) begin
      assert (rvfi_valid && !rvfi_trap && dmem_req);
      assert (rvfi_rd_addr == exmem_rd);
      assert (rvfi_rd_wdata == (exmem_rd == 0 ? 32'd0 : commit_wdata));
      assert (rvfi_mem_addr == rvfi_exmem.rs1_data);
      assert (rvfi_mem_rmask == (exmem_is_sc ? 4'h0 : 4'hf));
      assert (rvfi_mem_wmask == (dmem_we ? 4'hf : 4'h0));
      assert (rvfi_mem_rdata == (exmem_is_sc ? 32'd0 : exmem_is_amo ? commit_wdata : dmem_rsp_data));
      assert (rvfi_mem_wdata == (dmem_we ? dmem_wdata : 32'd0));
      cover (exmem_is_lr && rvfi_rd_addr != 0);
      cover (exmem_is_sc && rvfi_rd_addr != 0 && rvfi_rd_wdata == 0 && |rvfi_mem_wmask);
      cover (exmem_is_sc && rvfi_rd_addr != 0 && rvfi_rd_wdata == 1 && !dmem_valid);
      cover (exmem_is_amo && rvfi_rd_addr != 0 && rvfi_mem_wdata != rvfi_mem_rdata);
    end
  end
  if (!rst) cover (rvfi_sync_exception && rvfi_insn == 32'h1020a1af);
end
