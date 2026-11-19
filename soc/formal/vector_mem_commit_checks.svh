`include "vector_mem_filter.svh"
// Track one arbitrary byte of one arbitrary vector register. Update it
// from the bus handshake, not the DUT's vector write port.
(* anyconst *) logic [4:0] formal_vec_reg;
(* anyconst *) logic [3:0] formal_vec_byte;
logic [7:0] formal_vec_stored, reference_vec_byte;
logic watched_lane;
logic [4:0] byte_in_element;
logic [1:0] bus_lane;
assign byte_in_element = {1'b0, formal_vec_byte} - (5'(exmem_vec_elem) << formal_vec_width);
assign watched_lane = exmem_instr[11:7] == formal_vec_reg &&
                      byte_in_element < (5'd1 << formal_vec_width);
assign bus_lane = dmem_addr[1:0] + byte_in_element[1:0];
always @(posedge clk) begin
  if (rst) reference_vec_byte <= 0;
  else begin
    if (dmem_req && !dmem_we && watched_lane) reference_vec_byte <= dmem_rsp_data[8*bus_lane+:8];
    // The pending load bypasses the array one cycle before writing it.
    assert (formal_vec_stored == ($past(rst) ? 8'd0 : $past(reference_vec_byte)));
    if (idex_valid && idex_instr[11:7] == formal_vec_reg)
      assert (vec_vd_data[8*formal_vec_byte+:8] == reference_vec_byte);
    if (dmem_valid && dmem_we && watched_lane)
      assert (dmem_wdata[8*bus_lane+:8] == reference_vec_byte);
    cover (dmem_req && dmem_we && watched_lane && reference_vec_byte != 0);

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
      if (!exmem_is_vload && !exmem_is_vstore) assert (retire && !dmem_req);
      if (exmem_instr[6:0] == 7'h57) begin
        assert (rvfi_valid && !rvfi_trap && rvfi_rd_addr == exmem_instr[11:7]);
        assert (rvfi_rd_wdata == (rvfi_rd_addr == 0 ? 32'd0 : exmem_wbval));
        cover (rvfi_rd_wdata != 0);
      end
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
