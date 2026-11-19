// Reused on the standalone adapter and on the actual SoC slave wires.
`ifdef ROCO_SOC_SDRAM_MEMORY_FORMAL
`define AXI_SDRAM_MASTER_CHECK assert
`else
`define AXI_SDRAM_MASTER_CHECK assume
`endif
initial assume (rst);
initial past_valid = 1'b0;
assign ar_fire = ar.valid && ar_ready;
assign aw_fire = aw.valid && aw_ready;
assign w_fire = w.valid && w_ready;
assign req_fire = req_valid && req_ready;
assign r_fire = r.valid && r_ready;
assign b_fire = b.valid && b_ready;

function automatic logic legal_burst(input logic [31:0] address, input logic [7:0] len,
                                     input logic [2:0] size, input logic [1:0] burst);
  logic [31:0] last_byte;
  last_byte = address + (32'(len) << 2) + 32'd3;
  legal_burst = (address >= 32'h1000_0000 && address < 32'h1200_0000) &&
                  address[1:0] == 0 && last_byte[31:10] == address[31:10] && len <= 15 &&
                  size == 2 && burst == `AXI4_BURST_INCR;
endfunction

// A scoreboard derived from public handshakes, not the DUT state or RAM.
// Checking a symbolic beat proves the data relation for every buffer entry.
always_ff @(posedge clk) begin
  past_valid <= 1'b1;
  if (rst) begin
    {active, writing, supported, issued, final_w, drained} <= '0;
    {base, id, length, transferred, received, watched_data} <= '0;
  end else begin
    if (past_valid && !$past(rst)) begin
      if ($past(ar.valid && !ar_ready)) `AXI_SDRAM_MASTER_CHECK($stable(ar));
      if ($past(aw.valid && !aw_ready)) `AXI_SDRAM_MASTER_CHECK($stable(aw));
      if ($past(w.valid && !w_ready)) `AXI_SDRAM_MASTER_CHECK($stable(w));
      if ($past(r.valid && !r_ready)) assert ($stable(r));
      if ($past(b.valid && !b_ready)) assert ($stable(b));
    end
    // The controller cannot send a beat on the request handshake itself,
    // or send more than requested. It need not make forward progress.
`ifdef ROCO_SDRAM_LINK_FORMAL
    if (rvalid) assert (active && !writing && supported && issued && 9'(received) < length);
    // The controller owns the read through its last RVALID; the adapter
    // owns the AXI response until RREADY accepts the last buffered word.
    assert (f_ctrl_read_owned == (active && issued && !writing && 9'(received) < length));
    if (f_ctrl_read_owned) assert (f_ctrl_read_count == received);
    if (f_ctrl_busy || f_ctrl_read_owned) begin
      assert (active && issued);
      assert (f_ctrl_we == writing && f_ctrl_addr == base[24:2]);
      assert (9'(f_ctrl_len) + 9'd1 == length);
    end
    if (active && issued && writing) begin
      assert (9'(f_ctrl_write_count) == transferred);
      if (!final_w) assert (f_ctrl_busy);
      if (drained) assert (!f_ctrl_busy);
      if (b.valid) assert (9'(f_ctrl_pins_written) == length);
    end
`else
    if (rvalid) assume (active && !writing && supported && issued && 9'(received) < length);
`endif
    // AXI masters declare the burst length in AW and mark the final W beat.
    if (w_fire && active && writing)
      `AXI_SDRAM_MASTER_CHECK(w.last == (transferred + 9'd1 == length));

    // Induction relations are asserted, never supplied as assumptions.
    assert (f_phase == (!active ? 6'b000001 :
                          supported && !issued ? 6'b000010 :
                          !writing ? 6'b000100 : !final_w ? 6'b001000 :
                          !drained ? 6'b010000 : 6'b100000));
    if (active) begin
      assert ({f_id, f_addr, f_write, f_error} == {id, base[24:2], writing, !supported});
      assert (length == 9'(f_len) + 9'd1);
      if (supported) begin
        assert (length <= 16);
        assert (9'(base[9:2]) + length <= 9'd256);
      end
      assert (!issued || supported);
      if (supported && !issued) assert (transferred == 0);
      if (!supported && final_w) assert (drained);
      assert (transferred <= length);
      assert (9'(f_beat) == transferred - 9'(final_w));
      assert (transferred != length || final_w);
      assert (final_w == (writing && transferred == length));
      assert (!drained || final_w);
      assert (f_captured == received);
      assert (9'(received) <= length);
      if (!supported || !issued || writing) assert (received == 0);
      if (supported && !writing) assert (transferred <= 9'(received));
      if (received > 5'(f_watch)) assert (f_read_word == watched_data);
    end
    assert (!(ar_fire && aw_fire));
    if (active)
      assert (!ar_ready && !aw_ready);
      else if (ar.valid || aw.valid) assert (ar_fire || aw_fire);
    assert (req_valid == (active && supported && !issued));
    if (req_valid) begin
      assert (req_we == writing);
      assert (req_word_addr == base[24:2]);
      assert (9'(req_len) + 9'd1 == length);
    end

    assert (wvalid == (active && writing && supported && issued && !final_w && w.valid));
    assert (w_ready == (active && writing && !final_w && (!supported || (issued && wready))));
    if (wvalid) assert ({wdata, wbe} == {w.data, w.strb});
    assert ((wvalid && wready) == (w_fire && supported));
    assert (b.valid == (active && writing && final_w && drained));
    if (b.valid) begin
      assert (b.id == id);
      assert (b.resp == (supported ? `AXI4_RESP_OKAY : `AXI4_RESP_SLVERR));
    end

    assert (r.valid == (active && !writing && (!supported || 9'(received) > transferred)));
    if (r.valid) begin
      assert (r.id == id);
      assert (r.last == (transferred + 9'd1 == length));
      assert (r.resp == (supported ? `AXI4_RESP_OKAY : `AXI4_RESP_SLVERR));
      if (!supported)
        assert (r.data == 0);
        else if (transferred == 9'(f_watch)) assert (r.data == watched_data);
    end

    if (ar_fire || aw_fire) begin
      active <= 1'b1;
      writing <= aw_fire;
      supported <= aw_fire ? legal_burst(
          aw.addr, aw.len, aw.size, aw.burst
      ) : legal_burst(
          ar.addr, ar.len, ar.size, ar.burst
      );
      base <= aw_fire ? aw.addr : ar.addr;
      id <= aw_fire ? aw.id : ar.id;
      length <= 9'(aw_fire ? aw.len : ar.len) + 9'd1;
      {issued, final_w, drained, transferred, received} <= '0;
    end
    if (req_fire) issued <= 1'b1;
    if (rvalid) begin
      if (received == 5'(f_watch)) watched_data <= rdata;
      received <= received + 5'd1;
    end
    if (w_fire || r_fire) transferred <= transferred + 9'd1;
    if (w_fire && transferred + 9'd1 == length) begin
      final_w <= 1'b1;
      drained <= !supported;
    end
    if (active && writing && final_w && req_ready) drained <= 1'b1;
    if (b_fire || (r_fire && transferred + 9'd1 == length)) active <= 1'b0;

`ifndef ROCO_SDRAM_MEMORY_FORMAL
    cover (r_fire && supported && received == 16 && transferred == 0);
    cover (b_fire && supported && length == 16);
    cover (r_fire && !supported && transferred == 255);
    cover (b_fire && !supported && length == 256);
`endif
  end
end
`undef AXI_SDRAM_MASTER_CHECK
