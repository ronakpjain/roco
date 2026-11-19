`include "axi4_defs.svh"
`default_nettype none

module axi_sdram_contract (
  input logic clk
);
  (* anyseq *) logic rst, r_ready, b_ready, req_ready, wready, rvalid;
  (* anyseq *) logic [31:0] rdata;
  (* anyseq *) axi4_ar_t ar;
  (* anyseq *) axi4_aw_t aw;
  (* anyseq *) axi4_w_t w;
  axi4_r_t r;
  axi4_b_t b;
  logic ar_ready, aw_ready, w_ready, req_valid, req_we, wvalid;
  logic [22:0] req_word_addr;
  logic [3:0] req_len, wbe;
  logic [31:0] wdata;

  logic past_valid, active, writing, supported, issued, final_w, drained;
  logic ar_fire, aw_fire, w_fire, req_fire, r_fire, b_fire;
  logic [31:0] base;
  logic [3:0] id;
  logic [8:0] length, transferred;
  logic [4:0] received;
  (* anyconst *) logic [3:0] f_watch;
  logic [31:0] watched_data, f_read_word;
  logic [5:0] f_phase;
  logic [4:0] f_captured;
  logic [7:0] f_beat, f_len;
  logic [3:0] f_id;
  logic [22:0] f_addr;
  logic f_write, f_error;
  axi4_sdram_adapter dut (.*);

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
        if ($past(ar.valid && !ar_ready)) assume ($stable(ar));
        if ($past(aw.valid && !aw_ready)) assume ($stable(aw));
        if ($past(w.valid && !w_ready)) assume ($stable(w));
        if ($past(r.valid && !r_ready)) assert ($stable(r));
        if ($past(b.valid && !b_ready)) assert ($stable(b));
      end
      // The controller cannot send a beat on the request handshake itself,
      // or send more than requested. It need not make forward progress.
      if (rvalid) assume (active && !writing && supported && issued && 9'(received) < length);
      // AXI masters declare the burst length in AW and mark the final W beat.
      if (w_fire && active && writing) assume (w.last == (transferred + 9'd1 == length));

      // Induction relations are asserted, never supplied as assumptions.
      assert (f_phase == (!active ? 6'b000001 :
                          supported && !issued ? 6'b000010 :
                          !writing ? 6'b000100 : !final_w ? 6'b001000 :
                          !drained ? 6'b010000 : 6'b100000));
      if (active) begin
        assert ({f_id, f_addr, f_write, f_error} == {id, base[24:2], writing, !supported});
        assert (length == 9'(f_len) + 9'd1);
        assert (!supported || length <= 16);
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

      cover (r_fire && supported && received == 16 && transferred == 0);
      cover (b_fire && supported && length == 16);
      cover (r_fire && !supported && transferred == 255);
      cover (b_fire && !supported && length == 256);
    end
  end
endmodule
