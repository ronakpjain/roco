// verilog_syntax: parse-as-module-body
`include "soc_mem_decode_checks.svh"

// Observe one arbitrary VRF byte. Its value after a load comes from the
// accepted memory response and the element's independently checked lane.
// Whole-register arithmetic enters this history at its MEM write port;
// arithmetic result equivalence is a separate obligation.
(* anyconst *) logic [4:0] formal_vec_reg;
(* anyconst *) logic [3:0] formal_vec_byte;
logic [7:0] formal_vec_stored, reference_vec_byte;
logic [4:0] f_vec_byte_delta;
logic [1:0] f_vec_bus_lane;
logic f_vec_lane;
assign f_vec_byte_delta = {1'b0, formal_vec_byte} - (5'(exmem_vec_elem) << exmem_vec_sew);
assign f_vec_bus_lane = dmem_addr[1:0] + f_vec_byte_delta[1:0];
assign f_vec_lane = exmem_instr[11:7] == formal_vec_reg &&
                    f_vec_byte_delta < (5'd1 << exmem_vec_sew);

always_ff @(posedge clk or posedge rst) begin
  if (rst) reference_vec_byte <= '0;
  else if (retire && vec_full_write && exmem_rd == formal_vec_reg)
    reference_vec_byte <= exmem_vec_data[8*formal_vec_byte+:8];
  else if (dmem_req && exmem_is_vload && f_vec_lane)
    reference_vec_byte <= dmem_rsp_data[8*f_vec_bus_lane+:8];
end

always_ff @(posedge clk) begin
  if (!rst) begin
    assert (formal_vec_stored == ($past(rst) ? 8'd0 : $past(reference_vec_byte)));
    if (idex_instr[19:15] == formal_vec_reg)
      assert (vec_rf_vs1_data[8*formal_vec_byte+:8] == reference_vec_byte);
    if (idex_instr[24:20] == formal_vec_reg)
      assert (vec_rf_vs2_data[8*formal_vec_byte+:8] == reference_vec_byte);
    if (idex_instr[11:7] == formal_vec_reg)
      assert (vec_rf_vd_data[8*formal_vec_byte+:8] == reference_vec_byte);

    assert (!(vec_full_write && vec_mem_we));
    assert (vec_mem_we == (dmem_req && exmem_is_vload));
    if (vec_full_write) assert (retire && !dmem_req);
    if (vec_mem_we) begin
      assert (!dmem_we && vec_mem_wd == exmem_instr[11:7]);
      assert (vec_mem_elem == exmem_vec_elem && vec_mem_sew == exmem_vec_sew);
      if (f_vec_lane)
        assert (vec_mem_wdata[8*f_vec_byte_delta[1:0]+:8] == dmem_rsp_data[8*f_vec_bus_lane+:8]);
    end
    if (exmem_valid && (exmem_is_vload || exmem_is_vstore)) begin
      assert (dmem_addr == exmem_alu && dmem_we == exmem_is_vstore && dmem_be == exmem_be);
      assert (dmem_valid == !halt && dmem_req == (dmem_valid && dmem_ready));
      assert (retire == (dmem_req && exmem_vec_last));
      // Store data equivalence against in-flight vector forwarding is a
      // separate obligation; this job proves address, lane, and retirement.
    end
    if (retire && (exmem_instr[6:0] == 7'h07 || exmem_instr[6:0] == 7'h27)) begin
      assert (rvfi_valid && !rvfi_trap && rvfi_rd_addr == 0);
      assert (rvfi_mem_rmask == 0 && rvfi_mem_wmask == 0);
    end
    cover (vec_element_commit && exmem_is_vload && exmem_vec_elem == 0);
    cover (retire && exmem_is_vstore && f_vec_lane && reference_vec_byte != 0);
  end
end
