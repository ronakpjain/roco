// Discharge the SDRAM slave's address-shape requirements at the actual
// crossbar output, with every SoC master and the controller still present.
initial assume (rst);
logic f_ram_past, f_ram_write_is_boot;
logic [4:0] f_ram_write_left;
logic [31:2] f_last_lookup_word;
initial f_ram_past = 1'b0;

function automatic logic ram_burst(input logic [31:0] addr, input logic [7:0] len,
                                   input logic [2:0] size, input logic [1:0] burst);
  ram_burst = addr[31:25] == 7'd8 && addr[1:0] == 0 && size == 3'd2 &&
              burst == `AXI4_BURST_INCR && len <= 15 && 9'(addr[9:2]) + 9'(len) <= 255;
endfunction

always_ff @(posedge clk) begin
  f_ram_past <= 1'b1;
  if (rst) begin
    {f_ram_write_left, f_ram_write_is_boot, f_last_lookup_word} <= '0;
  end else begin
    if (dmem_lu_valid) f_last_lookup_word <= dmem_lu_addr;
    // Count the real downstream AW/W handshakes. Link the observed
    // burst to the selected master, even across indefinitely long stalls.
    if (ram_aw.valid && ram_awready) begin
      assert (f_ram_write_left == 0);
      assert ((boot_aw.valid && boot_awready) != (d_aw.valid && d_awready));
      f_ram_write_left <= 5'(ram_aw.len) + 5'd1;
      f_ram_write_is_boot <= boot_aw.valid && boot_awready;
    end
    if (ram_w.valid) begin
      assert (f_ram_write_left != 0 && ram_w.last == (f_ram_write_left == 1));
      if (ram_wready) f_ram_write_left <= f_ram_write_left - 1'b1;
    end
    assert (f_ram_wphase == (f_ram_write_left != 0));
    if (f_ram_wphase) assert (f_ram_wowner_boot == f_ram_write_is_boot);
    assert (f_d_write_left == (f_ram_write_is_boot ? 5'd0 : f_ram_write_left));
    assert (f_boot_write_left == (f_ram_write_is_boot ? f_ram_write_left : 5'd0));
    if (boot_restart && !BOOT_OVERRIDE) begin
      assert (!core_rst);
      assert (!boot_mem_req && !boot_mem_wvalid);
    end
    if (f_ram_past && !$past(rst)) begin
      assert (boot_release == $past(boot_done_eff));
      if ($past(ram_ar.valid && !ram_arready)) assert ($stable(ram_ar));
      if ($past(ram_aw.valid && !ram_awready)) assert ($stable(ram_aw));
      if ($past(ram_w.valid && !ram_wready)) assert ($stable(ram_w));
    end
    if (f_mem_packet) begin
      assert (dmem_addr[31:2] == f_last_lookup_word);
      assert (dmem_in_sdram == (dmem_addr[31:25] == 7'd8));
      if (dmem_lu_valid) assert (dmem_req);
    end
    if (dmem_valid || dmem_req) assert (f_mem_packet);
    if (ram_ar.valid) assert (ram_burst(ram_ar.addr, ram_ar.len, ram_ar.size, ram_ar.burst));
    if (ram_aw.valid) assert (ram_burst(ram_aw.addr, ram_aw.len, ram_aw.size, ram_aw.burst));
  end
end
