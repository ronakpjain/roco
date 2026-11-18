`include "axi4_defs.svh"
`default_nettype none

module axi_apb_contract (
  input logic clk
);
  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;

  (* anyseq *) axi4_ar_t ar;
  (* anyseq *) axi4_aw_t aw;
  (* anyseq *) axi4_w_t w;
  (* anyseq *) logic r_ready, b_ready, pready, pslverr;
  (* anyseq *) logic [31:0] prdata;
  axi4_r_t r;
  axi4_b_t b;
  logic ar_ready, aw_ready, w_ready, psel, penable, pwrite;
  logic [31:0] paddr, pwdata;
  logic [3:0] pstrb;
  logic [2:0] pprot;
  axi4_apb_bridge dut (.*);

  // A slave assumes stable request channels and guarantees stable replies.
  always @(posedge clk) begin
    if (rst) begin
      assert (!r.valid && !b.valid && !psel && !penable);
    end else if (!$past(rst)) begin
      if ($past(ar.valid && !ar_ready)) assume ($stable(ar));
      if ($past(aw.valid && !aw_ready)) assume ($stable(aw));
      if ($past(w.valid && !w_ready)) assume ($stable(w));
      if ($past(r.valid && !r_ready)) assert ($stable(r));
      if ($past(b.valid && !b_ready)) assert ($stable(b));
      if ($past(psel && !penable)) assert (psel && penable);
      if ($past(psel && (!penable || !pready))) begin
        assert (psel && penable);
        assert ($stable({paddr, pwrite, pprot, pwdata, pstrb}));
      end
      if (psel && penable) assert ($past(psel && (!penable || !pready)));
    end
    if (!rst) assert (!penable || psel);
  end

  function automatic logic apb_request(input logic [31:0] addr, input logic [7:0] len,
                                       input logic [2:0] size, input logic [1:0] burst);
    apb_request = len == 0 && burst <= 1 && size <= 2 && (addr & ((32'd1 << size) - 1)) == 0;
  endfunction

  // Transaction scoreboard driven only by external handshakes.
  logic pending, writing, rejected, apb_done, write_done, slave_error;
  logic [31:0] address, write_data, read_data;
  logic [2:0] protection;
  logic [3:0] id, strobes;
  logic [7:0] beats_left;
  logic accept_read;
  assign accept_read = ar.valid && ar_ready;
  logic accept_write;
  assign accept_write = aw.valid && aw_ready;
  logic accept_data;
  assign accept_data = w.valid && w_ready;
  logic apb_complete;
  assign apb_complete = psel && penable && pready;

  always @(posedge clk) begin
    if (rst) begin
      pending <= 0;
      writing <= 0;
      rejected <= 0;
      apb_done <= 0;
      write_done <= 0;
      slave_error <= 0;
      address <= 0;
      write_data <= 0;
      read_data <= 0;
      protection <= 0;
      id <= 0;
      strobes <= 0;
      beats_left <= 0;
    end else begin
      assert (!(accept_read && accept_write));
      assert (!(r.valid && b.valid));
      if (accept_read || accept_write) begin
        assert (!pending);
        pending <= 1;
        writing <= accept_write;
        apb_done <= 0;
        write_done <= 0;
        slave_error <= 0;
        read_data <= 0;
        address <= accept_write ? aw.addr : ar.addr;
        protection <= accept_write ? aw.prot : ar.prot;
        id <= accept_write ? aw.id : ar.id;
        beats_left <= accept_write ? aw.len : ar.len;
        rejected <= accept_write ? !apb_request(
            aw.addr, aw.len, aw.size, aw.burst
        ) : !apb_request(
            ar.addr, ar.len, ar.size, ar.burst
        );
      end
      if (accept_data) begin
        assert (pending && writing && !write_done);
        // Also exercise a missing final WLAST; this bridge rejects it.
        if (beats_left == 0) begin
          write_done <= 1;
          write_data <= w.data;
          strobes <= w.strb;
          rejected <= rejected || !w.last;
        end else beats_left <= beats_left - 1;
      end
      if (psel) begin
        assert (pending && !rejected && !apb_done);
        assert (pwrite == writing && paddr == {address[31:2], 2'b00} && pprot == protection);
        if (writing) begin
          assert (write_done && pwdata == write_data && pstrb == strobes);
        end else assert (pstrb == 0);
      end
      if (apb_complete) begin
        apb_done <= 1;
        slave_error <= pslverr;
        read_data <= prdata;
      end
      if (r.valid) begin
        assert (pending && !writing && (rejected || apb_done));
        assert (r.id == id && r.last == (beats_left == 0) && r.data == read_data);
        assert (r.resp == ((rejected || slave_error) ? `AXI4_RESP_SLVERR : `AXI4_RESP_OKAY));
        if (r_ready) begin
          if (beats_left == 0) pending <= 0;
          else beats_left <= beats_left - 1;
        end
      end
      if (b.valid) begin
        assert (pending && writing && write_done && (rejected || apb_done));
        assert (b.id == id);
        assert (b.resp == ((rejected || slave_error) ? `AXI4_RESP_SLVERR : `AXI4_RESP_OKAY));
        if (b_ready) pending <= 0;
      end
      if (pending && !rejected && !apb_done && (!writing || write_done)) assert (psel);
      // Once completion is possible, the reply cannot disappear or be delayed.
      if (pending && (rejected || apb_done)) begin
        if (!writing) assert (r.valid);
        if (writing && write_done) assert (b.valid);
      end

      cover (psel && penable && !pready);
      cover (r.valid && r_ready && !rejected && !slave_error);
      cover (b.valid && b_ready && !rejected && slave_error);
      cover (r.valid && r_ready && rejected && !r.last);
      cover (b.valid && b_ready && rejected);
      cover (r.valid && r_ready && rejected && r.last && $past(r.valid && r_ready && !r.last));
    end
  end
endmodule
