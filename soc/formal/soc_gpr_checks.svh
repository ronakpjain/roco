// Observe an arbitrary scalar GPR in the real SoC. Derive the scalar
// write from the retirement interface, not the physical write port.
logic f_gpr_pending;
logic [31:0] f_gpr_pending_data, f_gpr_value;
logic f_gpr_retire_write, f_gpr_div_write;
assign f_gpr_retire_write = rvfi_valid && !rvfi_trap && rvfi_rd_addr != 0 &&
                            rvfi_rd_addr == rvfi_gpr_watch_addr;
assign f_gpr_div_write = div_wb_en && div_wb_rd == rvfi_gpr_watch_addr;

always_ff @(posedge clk or posedge rst) begin
  if (rst) begin
    f_gpr_pending <= 1'b0;
    f_gpr_pending_data <= '0;
    f_gpr_value <= '0;
  end else begin
    // The MEM/WB slot holds during halt or fence service. The file can
    // receive the same scalar value again during a fence, which is idempotent.
    if (!halt && !fence_req) begin
      f_gpr_pending <= f_gpr_retire_write;
      if (f_gpr_retire_write) f_gpr_pending_data <= rvfi_rd_wdata;
    end
    if (f_gpr_div_write) f_gpr_value <= div_wb_data;
    else if (!halt && f_gpr_pending) f_gpr_value <= f_gpr_pending_data;
  end
end

always_ff @(posedge clk) begin
  if (!rst) begin
    assert (!(wb_we && div_wb_en));
    if (div_wb_en) assert (!halt && div_wb_rd != 0);
    assert (!(retire && rvfi_sync_exception));
    // Vector memory packets never write a scalar GPR, even when held
    // before the per-element commit handshake.
    if (exmem_valid && (exmem_is_vload || exmem_is_vstore)) assert (!exmem_regwrite);
    assert (rvfi_gpr_watch_value == f_gpr_value);
    // The ungated slot identity must hold even while halted.
    assert (f_gpr_pending == (memwb_valid && memwb_regwrite && memwb_rd != 0 &&
                             memwb_rd == rvfi_gpr_watch_addr));
    if (f_gpr_pending) assert (memwb_data == f_gpr_pending_data);
    assert ((wb_we && wb_rd != 0 && wb_rd == rvfi_gpr_watch_addr) == (!halt && f_gpr_pending));
    cover (rvfi_gpr_watch_addr == 5'd2 && f_gpr_value == 32'd3);
  end
end
