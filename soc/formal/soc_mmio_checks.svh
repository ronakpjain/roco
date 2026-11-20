// Observe the real SoC's CPU, fabric, APB and peripheral boundaries.
// soc-control supplies the initial-reset assumption; pin inputs are free.
logic f_mmio_sampled;
logic f_mmio_access, f_mmio_read, f_mmio_write, f_mmio_led_write;
assign f_mmio_access = psel && penable && pready;
assign f_mmio_read = f_mmio_access && !pwrite;
assign f_mmio_write = f_mmio_access && pwrite;
assign f_mmio_led_write = f_mmio_write && paddr[15:0] == 16'h0010 && pstrb[0];
initial f_mmio_sampled = 1'b0;

always_ff @(posedge clk) begin
  f_mmio_sampled <= 1'b1;
  if (!rst) begin
    // The bridge retains PADDR outside APB setup/access, so the address
    // invariant must hold there too, including while it waits for W.
    if (periph_ar.valid) assert (periph_ar.addr[31:25] != 7'd8);
    if (periph_aw.valid) assert (periph_aw.addr[31:25] != 7'd8);
    assert (paddr[1:0] == 2'b00);
    assert (paddr[31:25] != 7'd8);
    if (f_mmio_read) begin
      if (paddr[15:0] == 16'h0010) assert (mmio_rdata == {28'd0, leds});
      if (paddr[15:0] == 16'h0014) assert (mmio_rdata == {30'd0, buttons});
    end
    assert (mmio_tx_push == (f_mmio_write && paddr[15:0] == 16'h0000 && pstrb[0]));
    assert (mmio_rx_pop == (f_mmio_read && paddr[15:0] == 16'h0000 && uart_rx_valid));
    assert (uart_rx_clear == (f_mmio_read && paddr[15:0] == 16'h0004));
    if (mmio_tx_push) begin
      assert (!boot_tx_valid && uart_tx_ready && uart_tx_valid);
      assert (uart_tx_data == pwdata[7:0]);
    end
    if (mmio_rx_pop) assert (uart_rx_ready);

    // Check the response on the CPU side of the crossbar too, not just
    // the peripheral decoder's PRDATA before it crosses the bridge.
    assert (!(mmio_read_done && mmio_write_done));
    if (mmio_read_done && mmio_r.resp == `AXI4_RESP_OKAY) begin
      assert (periph_r.valid && periph_r.resp == `AXI4_RESP_OKAY);
      assert (mmio_rsp_data == periph_r.data);
    end
    if (dmem_req && !dmem_in_sdram) assert (mmio_done);
  end

  if (f_mmio_sampled && !rst && !$past(rst)) begin
    if ($past(f_mmio_led_write))
      assert (leds == $past(pwdata[3:0]));
      else assert ($stable(leds));
    if ($past(f_mmio_read)) begin
      assert (periph_r.valid && periph_r.resp == `AXI4_RESP_OKAY);
      assert (periph_r.data == $past(mmio_rdata));
    end
    if ($past(f_mmio_write)) assert (periph_b.valid && periph_b.resp == `AXI4_RESP_OKAY);
    if (periph_r.valid && periph_r.resp == `AXI4_RESP_OKAY) begin
      if (!$past(periph_r.valid))
        assert ($past(f_mmio_read));
        else if (!$past(periph_rready)) assert ($stable(periph_r));
    end
    if (periph_b.valid && periph_b.resp == `AXI4_RESP_OKAY) begin
      if (!$past(periph_b.valid))
        assert ($past(f_mmio_write));
        else if (!$past(periph_bready)) assert ($stable(periph_b));
    end

    cover (mmio_read_done && mmio_rsp_data == 32'd3 && $past(
        f_mmio_read && paddr[15:0] == 16'h0014 && buttons == 2'd3
    ));
    cover ($past(f_mmio_led_write) && leds == 4'd3);
    cover (!$past(halted) && halted && exit_code != 0);
  end
end
