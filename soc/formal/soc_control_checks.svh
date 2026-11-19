// Included in the real SoC for soc-control. Reset is the only
// environmental constraint; subsequent resets and pin inputs are free.
initial assume (rst);
logic f_soc_past_valid;
logic f_soc_apb_access, f_soc_exit_write;
logic [31:0] f_soc_strobe_mask;
initial f_soc_past_valid = 1'b0;
assign f_soc_apb_access = psel && penable && pready;
assign f_soc_exit_write = f_soc_apb_access && pwrite && paddr[15:0] == 16'h1000;
for (genvar i = 0; i < 4; i++) begin : gen_soc_strobe_mask
  assign f_soc_strobe_mask[8*i+:8] = {8{pstrb[i]}};
end

always_ff @(posedge clk) begin
  f_soc_past_valid <= 1'b1;
  if (!rst) begin
    assert (!penable || psel);
    if (uart_tx_valid && !boot_tx_valid) begin
      assert (f_soc_apb_access && pwrite && paddr[15:0] == 0 && pstrb[0]);
      assert (uart_tx_ready && uart_tx_data == pwdata[7:0]);
    end
    if (uart_rx_ready && !boot_rx_ready) begin
      assert (f_soc_apb_access && !pwrite && paddr[15:0] == 0 && uart_rx_valid);
    end
    if (boot_restart) begin
      assert (dmem_req && !dmem_in_sdram && mmio_done);
      assert (pwrite && paddr[15:0] == 16'h0108 && |pstrb);
    end
    if (halted || core_rst) assert (!trace_valid);
    cover (f_soc_apb_access);
    cover (uart_tx_valid && !boot_tx_valid);
    cover (f_soc_exit_write);
    cover (halted);
    cover (core_rst && !boot_cache_maintenance);
    cover (!core_rst);
  end
  if (f_soc_past_valid && !rst && !$past(rst)) begin
    assert (core_rst == (boot_cache_maintenance || !$past(boot_done_eff)));
    if ($past(psel && (!penable || !pready))) begin
      assert (psel && penable);
      assert ($stable({paddr, pwrite, pwdata, pstrb}));
    end
    if ($past(f_soc_apb_access)) assert (!psel);
    if ($past(boot_restart)) begin
      assert (!halted && exit_code == 0);
    end else begin
      if ($past(f_soc_exit_write)) begin
        assert (exit_code == (($past(exit_code) & ~$past(f_soc_strobe_mask)) |
                              ($past(pwdata) & $past(f_soc_strobe_mask))));
      end else assert ($stable(exit_code));
      if (halted && !$past(halted)) begin
        assert ($past(dmem_req && !dmem_in_sdram && mmio_done));
        assert ($past(pwrite && paddr[15:0] == 16'h1000 && |pstrb));
      end
      if ($past(halted)) assert (halted);
    end
  end
end
