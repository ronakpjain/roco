// RVFI sequences both normal retirements and synchronous traps. An IRQ
// may enter alongside an older normal retirement but is not itself an event.
logic [63:0] f_retirement_order;
logic f_handler_event_pending;
always_ff @(posedge clk or posedge rst) begin
  if (rst) begin
    f_retirement_order <= '0;
    f_handler_event_pending <= 1'b0;
  end else begin
    if (trace_valid || rvfi_sync_exception) f_retirement_order <= f_retirement_order + 64'd1;
    if (rvfi_trap_entry) f_handler_event_pending <= 1'b1;
    else if (trace_valid) f_handler_event_pending <= 1'b0;
  end
end
always_ff @(posedge clk) begin
  if (!rst) begin
    assert (rvfi_order == f_retirement_order);
    assert (rvfi_intr == f_handler_event_pending);
    assert (rvfi_valid == (trace_valid || rvfi_sync_exception));
    if (!$past(rst) && $past(rvfi_sync_exception)) begin
      assert (ex_redirect_en && ex_redirect_pc == $past(rvfi_trap_vector));
    end
    if (rvfi_sync_exception) begin
      assert (!trace_valid && !dmem_req && !dmem_lu_valid);
      assert (rvfi_valid && rvfi_trap && rvfi_rd_addr == 0);
      assert (rvfi_mem_rmask == 0 && rvfi_mem_wmask == 0);
      assert (rvfi_pc_wdata == rvfi_trap_vector);
    end
  end
end
