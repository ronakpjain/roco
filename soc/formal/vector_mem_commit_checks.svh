// Per-element checks at the architectural and physical boundaries. In
// this restricted stream only the vector memory instructions use MEM.
`include "vector_mem_filter.svh"
always @(posedge clk) begin
  if (!rst) begin
    assert (!d_fault_q && !dmem_lu_stall && !fence_req && !mem_redirect);
    assert (!vec_full_write);
    if (exmem_valid) begin
      assert (!exmem_is_load && !exmem_is_store && !exmem_is_lr && !exmem_is_sc && !exmem_is_amo);
      assert (!exmem_is_mul && !exmem_vec_we);
      // Tie the vector class bits to the retired word so induction cannot
      // freeze a fabricated combination (for example a vset encoding
      // carrying the load class) across a held cycle.
      assert (stream_vector_word(exmem_instr, formal_vec_width));
      assert (!exmem_is_vload || exmem_instr[6:0] == 7'h07);
      assert (!exmem_is_vstore || exmem_instr[6:0] == 7'h27);
    end
    assert (dmem_valid == (exmem_valid && (exmem_is_vload || exmem_is_vstore)));
    // The EX stage sets exactly one of the two vector memory classes per
    // packet; keep that exclusivity as an explicit invariant so induction
    // cannot freeze a bogus EX/MEM word across a held cycle.
    assert (!exmem_is_vload || !exmem_is_vstore);
    assert (dmem_req == (dmem_valid && dmem_ready));
    assert (vec_mem_we == (dmem_req && !dmem_we));
    if (dmem_valid) begin
      assert (dmem_addr == exmem_alu && dmem_we == exmem_is_vstore && dmem_be == exmem_be);
      assert (retire == (dmem_ready && exmem_vec_last));
      assert (!rvfi_trap);
    end
    if (vec_mem_we) begin
      assert (vec_mem_wd == exmem_rd && vec_mem_elem == exmem_vec_elem);
      assert (vec_mem_sew == exmem_vec_sew);
      assert (vec_mem_wdata == (dmem_rsp_data >> (8 * dmem_addr[1:0])));
    end
    if (!$past(rst) && $past(dmem_valid && !dmem_ready)) begin
      assert (dmem_valid && $stable({dmem_addr, dmem_we, dmem_be}));
      if (dmem_we) assert ($stable(dmem_wdata));
      cover (dmem_req && dmem_we);
    end
  end
end
