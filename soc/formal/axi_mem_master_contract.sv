`include "axi4_defs.svh"
`default_nettype none

module axi_mem_master_contract (
  input logic clk
);
  (* anyseq *) logic rst, req, we, wvalid, ar_ready, aw_ready, w_ready;
  (* anyseq *) logic [31:0] addr, wdata;
  (* anyseq *) logic [3:0] len, wbe;
  (* anyseq *) axi4_r_t r;
  (* anyseq *) axi4_b_t b;
  axi4_ar_t ar;
  axi4_aw_t aw;
  axi4_w_t w;
  logic ready, wready, rvalid, rlast, write_done, r_ready, b_ready;
  logic [31:0] rdata;
  axi4_mem_master dut (.*);

  initial assume (rst);
  logic f_valid, reading, sending, draining;
  logic [4:0] remaining;
  initial f_valid = 1'b0;
  always_ff @(posedge clk) begin
    f_valid <= 1'b1;
    if (rst) begin
      {reading, sending, draining, remaining} <= '0;
    end else begin
      if (f_valid && !$past(rst)) begin
        // The client holds its request until acceptance and holds each W
        // payload until the corresponding ready. The master may insert gaps.
        if ($past(req && !ready)) assume ($stable({req, we, addr, len}));
        if ($past(wvalid && !wready)) assume ($stable({wvalid, wdata, wbe}));
        if ($past(ar.valid && !ar_ready)) assert ($stable(ar));
        if ($past(aw.valid && !aw_ready)) assert ($stable(aw));
        if ($past(w.valid && !w_ready)) assert ($stable(w));
      end

      assert (ar.valid == (req && !we && !reading && !sending && !draining));
      assert (aw.valid == (req && we && !reading && !sending && !draining));
      if (ar.valid) begin
        assert ({ar.addr, ar.len} == {addr, 8'(len)});
        assert (ar.size == 2 && ar.burst == `AXI4_BURST_INCR && ar.id == 0 && ar.prot == 0);
      end
      if (aw.valid) begin
        assert ({aw.addr, aw.len} == {addr, 8'(len)});
        assert (aw.size == 2 && aw.burst == `AXI4_BURST_INCR && aw.id == 0 && aw.prot == 0);
      end
      if (req) assert (ready == ((ar.valid && ar_ready) || (aw.valid && aw_ready)));
      assert ((w_ready && w.valid) == (wvalid && wready));
      assert (w.valid == (sending && wvalid));
      assert (wready == (sending && w_ready));
      if (w.valid) begin
        assert ({w.data, w.strb} == {wdata, wbe});
        assert (w.last == (remaining == 1));
      end
      assert (r_ready == reading);
      assert (rvalid == (reading && r.valid));
      if (rvalid) begin
        assert (rlast == r.last);
        assert (rdata == (r.resp == `AXI4_RESP_OKAY ? r.data : 32'd0));
      end
      assert (b_ready == draining);
      assert (write_done == (draining && b.valid));

      if (req && ready) begin
        reading <= !we;
        sending <= we;
        remaining <= 5'(len) + 5'd1;
      end
      if (rvalid && rlast) reading <= 1'b0;
      if (wvalid && wready) begin
        remaining <= remaining - 5'd1;
        if (remaining == 1) begin
          sending <= 1'b0;
          draining <= 1'b1;
        end
      end
      if (write_done) draining <= 1'b0;
      cover (write_done && req && $past(req && !ready && b_ready && !b.valid));
      cover (rvalid && rlast && r.resp == `AXI4_RESP_SLVERR);
    end
  end
endmodule
