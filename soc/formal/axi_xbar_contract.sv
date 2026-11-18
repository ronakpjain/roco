`include "axi4_defs.svh"
`default_nettype none

module axi_xbar_contract (
  input logic clk
);
  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;

  // Vector arrays keep the native Yosys frontend from losing struct widths.
  `define CHANNEL(T, name, sources, sinks) \
    T name``_width_ref; \
    localparam integer name``_width = $bits(name``_width_ref); \
    (* anyseq *) logic [(sources)*name``_width-1:0] name``_symbolic; \
    (* anyseq *) logic [sinks-1:0] name``_out_ready; \
    logic [name``_width-1:0] name``_in[sources], name``_out[sinks]; \
    logic [sources-1:0] name``_in_ready; \
    for (genvar j = 0; j < sources; j++) begin : g_``name``_input \
      assign name``_in[j] = name``_symbolic[j*name``_width+:name``_width]; \
    end
  `CHANNEL(axi4_ar_t, ar, 5, 2)
  `CHANNEL(axi4_aw_t, aw, 5, 2)
  `CHANNEL(axi4_w_t, w, 5, 2)
  `CHANNEL(axi4_r_t, r, 2, 5)
  `CHANNEL(axi4_b_t, b, 2, 5)
  `undef CHANNEL

  `define PORTS(P, N, REQ, RESP) \
    .P``_ar(ar_``REQ[N]), .P``_ar_ready(ar_``REQ``_ready[N]), \
    .P``_aw(aw_``REQ[N]), .P``_aw_ready(aw_``REQ``_ready[N]), \
    .P``_w(w_``REQ[N]), .P``_w_ready(w_``REQ``_ready[N]), \
    .P``_r(r_``RESP[N]), .P``_r_ready(r_``RESP``_ready[N]), \
    .P``_b(b_``RESP[N]), .P``_b_ready(b_``RESP``_ready[N])
  axi4_xbar dut (
      .clk(clk),
      .rst(rst),
      `PORTS(m0, 0, in, out),
      `PORTS(m1, 1, in, out),
      `PORTS(m2, 2, in, out),
      `PORTS(m3, 3, in, out),
      `PORTS(m4, 4, in, out),
      `PORTS(s0, 0, out, in),
      `PORTS(s1, 1, out, in)
  );
  `undef PORTS

  logic [4:0] read_accept[2], write_accept[2];
  logic [4:0] w_transfer[2], r_transfer[2], b_transfer[2];
  logic [1:0] downstream_read, downstream_write;

  `define STABLE(kind, payload, ready) \
    if ($past(payload.valid && !ready)) kind ($stable(payload));

  for (genvar m = 0; m < 5; m++) begin : g_master
    axi4_ar_t ar;
    assign ar = ar_in[m];
    axi4_aw_t aw;
    assign aw = aw_in[m];
    axi4_w_t w;
    assign w = w_in[m];
    axi4_r_t r;
    assign r = r_out[m];
    axi4_b_t b;
    assign b = b_out[m];
    logic read_live, write_live, write_last, read_dest, write_dest;
    logic ar_fire;
    assign ar_fire = ar.valid && ar_in_ready[m];
    logic aw_fire;
    assign aw_fire = aw.valid && aw_in_ready[m];
    logic w_fire;
    assign w_fire = w.valid && w_in_ready[m];
    logic r_fire;
    assign r_fire = r.valid && r_out_ready[m];
    logic b_fire;
    assign b_fire = b.valid && b_out_ready[m];

    for (genvar s = 0; s < 2; s++) begin : g_route
      axi4_w_t slave_w;
      assign slave_w = w_out[s];
      axi4_r_t slave_r;
      assign slave_r = r_in[s];
      axi4_b_t slave_b;
      assign slave_b = b_in[s];
      assign read_accept[s][m] = ar_fire && ((ar.addr[31:25] != 7'd8) == s);
      assign write_accept[s][m] = aw_fire && ((aw.addr[31:25] != 7'd8) == s);
      assign w_transfer[s][m] = w_fire && write_dest == s;
      assign r_transfer[s][m] = r_fire && read_dest == s;
      assign b_transfer[s][m] = b_fire && write_dest == s;
      always @(posedge clk)
        if (!rst) begin
          if (read_accept[s][m]) assert (ar == ar_out[s]);
          if (write_accept[s][m]) assert (aw == aw_out[s]);
          if (w_transfer[s][m]) assert (w == slave_w);
          if (r.valid && read_dest == s) assert (r == slave_r);
          if (b.valid && write_dest == s) assert (b == slave_b);
        end
    end

    always @(posedge clk) begin
      if (rst) begin
        read_live <= 0;
        write_live <= 0;
        write_last <= 0;
        read_dest <= 0;
        write_dest <= 0;
      end else begin
        if (!$past(rst)) begin
          `STABLE(assume, ar, ar_in_ready[m])
          `STABLE(assume, aw, aw_in_ready[m])
          `STABLE(assume, w, w_in_ready[m])
          `STABLE(assert, r, r_out_ready[m])
          `STABLE(assert, b, b_out_ready[m])
        end
        if (ar_fire) begin
          assert (!read_live);
          read_live <= 1;
          read_dest <= ar.addr[31:25] != 7'd8;
        end
        if (aw_fire) begin
          assert (!write_live);
          write_live <= 1;
          write_last <= 0;
          write_dest <= aw.addr[31:25] != 7'd8;
        end
        if (w_fire) begin
          assert (write_live && !write_last);
          if (w.last) write_last <= 1;
        end
        if (r.valid) assert (read_live);
        if (r_fire && r.last) read_live <= 0;
        if (b.valid) assert (write_live && write_last);
        if (b_fire) write_live <= 0;
      end
    end
  end

  for (genvar s = 0; s < 2; s++) begin : g_slave
    axi4_ar_t ar;
    assign ar = ar_out[s];
    axi4_aw_t aw;
    assign aw = aw_out[s];
    axi4_w_t w;
    assign w = w_out[s];
    axi4_r_t r;
    assign r = r_in[s];
    axi4_b_t b;
    assign b = b_in[s];
    assign downstream_read[s] = ar.valid && ar_out_ready[s];
    assign downstream_write[s] = aw.valid && aw_out_ready[s];
    always @(posedge clk) begin
      if (rst) begin
        assert (!ar.valid && !aw.valid && !w.valid && !r_in_ready[s] && !b_in_ready[s]);
      end else begin
        if (!$past(rst)) begin
          `STABLE(assert, ar, ar_out_ready[s])
          `STABLE(assert, aw, aw_out_ready[s])
          `STABLE(assert, w, w_out_ready[s])
          `STABLE(assume, r, r_in_ready[s])
          `STABLE(assume, b, b_in_ready[s])
        end
        if (ar.valid) assert ((ar.addr[31:25] != 7'd8) == s);
        if (aw.valid) assert ((aw.addr[31:25] != 7'd8) == s);
        // Exactly one peer handshake, or none when the channel is stalled.
        assert ($countones(read_accept[s]) == downstream_read[s]);
        assert ($countones(write_accept[s]) == downstream_write[s]);
        assert ($countones(w_transfer[s]) == (w.valid && w_out_ready[s]));
        assert ($countones(r_transfer[s]) == (r.valid && r_in_ready[s]));
        assert ($countones(b_transfer[s]) == (b.valid && b_in_ready[s]));
        cover (ar.valid && !ar_out_ready[s]);
        cover (|b_transfer[s] && |r_transfer[s]);
      end
    end
  end
  `undef STABLE

  always @(posedge clk)
    if (!rst) begin
      cover (&downstream_read);
      cover (&downstream_write);
    end
endmodule
