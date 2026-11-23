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
      // Unmodeled masters (hart1 side) are tied idle: no requests, always
      // ready. Undriven DUT inputs would otherwise float free in SMT and get
      // picked by the arbiter with arbitrary addresses.
      .m5_ar('0),
      .m5_ar_ready(),
      .m5_aw('0),
      .m5_aw_ready(),
      .m5_w('0),
      .m5_w_ready(),
      .m5_b_ready(1'b1),
      .m5_b(),
      .m5_r_ready(1'b1),
      .m5_r(),
      .m6_ar('0),
      .m6_ar_ready(),
      .m6_aw('0),
      .m6_aw_ready(),
      .m6_w('0),
      .m6_w_ready(),
      .m6_b_ready(1'b1),
      .m6_b(),
      .m6_r_ready(1'b1),
      .m6_r(),
      .m7_ar('0),
      .m7_ar_ready(),
      .m7_aw('0),
      .m7_aw_ready(),
      .m7_w('0),
      .m7_w_ready(),
      .m7_b_ready(1'b1),
      .m7_b(),
      .m7_r_ready(1'b1),
      .m7_r(),
      .m8_ar('0),
      .m8_ar_ready(),
      .m8_aw('0),
      .m8_aw_ready(),
      .m8_w('0),
      .m8_w_ready(),
      .m8_b_ready(1'b1),
      .m8_b(),
      .m8_r_ready(1'b1),
      .m8_r(),
      `PORTS(s0, 0, out, in),
      `PORTS(s1, 1, out, in)
  );
  `undef PORTS

  logic [4:0] read_accept[2], write_accept[2];
  logic [4:0] w_transfer[2], r_transfer[2], b_transfer[2];
  // Grant-time owner per slave: set on AR/AW push (the grant), read when a
  // slave delivery must be attributed to a master's stream. Deliveries for
  // a transaction strictly follow its grant, so this is exact.
  logic [2:0] r_owner[2], w_owner[2];
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

    // Per-master return scoreboards mirror the per-master skid slices: a
    // per-slave FIFO cannot represent owner change with undrained beats
    // (each side holds up to the skid depth). Depth 2 matches the slices.
    // Push = slave delivery attributed to this master via the grant-time
    // owner registers below; pop = this master's accept.
    logic [1:0] mr_n, mb_n;
    logic [r_width-1:0] mr_q0, mr_q1, mr_push_data, mr_pop_data;
    logic [b_width-1:0] mb_q0, mb_q1, mb_push_data, mb_pop_data;
    logic mr_push, mr_pop, mb_push, mb_pop;
    assign mr_push = r_owner[0] == m && r_in[0][r_width-1] && r_in_ready[0] ||
                     r_owner[1] == m && r_in[1][r_width-1] && r_in_ready[1];
    assign mr_push_data = (r_owner[0] == m && r_in[0][r_width-1] && r_in_ready[0]) ? r_in[0] : r_in[1];
    assign mr_pop = r_fire;
    assign mr_pop_data = r_out[m];
    assign mb_push = w_owner[0] == m && b_in[0][b_width-1] && b_in_ready[0] ||
                     w_owner[1] == m && b_in[1][b_width-1] && b_in_ready[1];
    assign mb_push_data = (w_owner[0] == m && b_in[0][b_width-1] && b_in_ready[0]) ? b_in[0] : b_in[1];
    assign mb_pop = b_fire;
    assign mb_pop_data = b_out[m];

    for (genvar s = 0; s < 2; s++) begin : g_route
      assign read_accept[s][m] = ar_fire && ((ar.addr[31:25] != 7'd8) == s);
      assign write_accept[s][m] = aw_fire && ((aw.addr[31:25] != 7'd8) == s);
      assign w_transfer[s][m] = w_fire && write_dest == s;
      assign r_transfer[s][m] = r_fire && read_dest == s;
      assign b_transfer[s][m] = b_fire && write_dest == s;
    end

    always @(posedge clk) begin
      if (rst) begin
        read_live <= 0;
        write_live <= 0;
        write_last <= 0;
        read_dest <= 0;
        write_dest <= 0;
        mr_n <= 2'd0;
        mb_n <= 2'd0;
        mr_q0 <= '0;
        mr_q1 <= '0;
        mb_q0 <= '0;
        mb_q1 <= '0;
      end else begin
        if (!$past(rst)) begin
          // Hold every source payload until its consuming fire, not merely
          // while stalled: the owner is picked on the Idle-cycle address,
          // so a change between pick and push would misroute into a slice.
          // This matches AXI (payload stable until handshake).
          if ($past(ar.valid && !ar_fire)) assume ($stable(ar));
          if ($past(aw.valid && !aw_fire)) assume ($stable(aw));
          if ($past(w.valid && !w_fire)) assume ($stable(w));
          `STABLE(assert, r, r_out_ready[m])
          `STABLE(assert, b, b_out_ready[m])
        end
        // Single-outstanding masters (like axi_mem_master, which drops AR/AW
        // once accepted): the sliced fabric decouples grant from consumption,
        // so backpressure alone no longer prevents a second fire. Assume the
        // master discipline; delivery integrity is still asserted below.
        if (ar_fire) begin
          assume (!read_live);
          read_live <= 1;
          read_dest <= ar.addr[31:25] != 7'd8;
        end
        if (aw_fire) begin
          assume (!write_live);
          write_live <= 1;
          write_last <= 0;
          write_dest <= aw.addr[31:25] != 7'd8;
        end
        if (w_fire) begin
          assume (write_live && !write_last);
          if (w.last) write_last <= 1;
        end
        if (r.valid) assert (read_live);
        if (r_fire && r.last) read_live <= 0;
        if (b.valid) assert (write_live && write_last);
        if (b_fire) write_live <= 0;
        if (mr_push) assert (mr_n != 2'd2);
        if (mr_pop) assert (mr_n != 2'd0);
        if (mr_pop && mr_n != 2'd0) assert (mr_pop_data == mr_q0);
        if (mb_push) assert (mb_n != 2'd2);
        if (mb_pop) assert (mb_n != 2'd0);
        if (mb_pop && mb_n != 2'd0) assert (mb_pop_data == mb_q0);
        case ({
          mr_push, mr_pop
        })
          2'b10: begin
            if (mr_n == 2'd0) mr_q0 <= mr_push_data;
            else mr_q1 <= mr_push_data;
            mr_n <= mr_n + 2'd1;
          end
          2'b01: begin
            if (mr_n == 2'd2) mr_q0 <= mr_q1;
            if (mr_n != 2'd0) mr_n <= mr_n - 2'd1;
          end
          2'b11: begin
            if (mr_n == 2'd2) begin
              mr_q0 <= mr_q1;
              mr_q1 <= mr_push_data;
            end else if (mr_n != 2'd0) mr_q0 <= mr_push_data;
          end
          default: begin
          end
        endcase
        case ({
          mb_push, mb_pop
        })
          2'b10: begin
            if (mb_n == 2'd0) mb_q0 <= mb_push_data;
            else mb_q1 <= mb_push_data;
            mb_n <= mb_n + 2'd1;
          end
          2'b01: begin
            if (mb_n == 2'd2) mb_q0 <= mb_q1;
            if (mb_n != 2'd0) mb_n <= mb_n - 2'd1;
          end
          2'b11: begin
            if (mb_n == 2'd2) begin
              mb_q0 <= mb_q1;
              mb_q1 <= mb_push_data;
            end else if (mb_n != 2'd0) mb_q0 <= mb_push_data;
          end
          default: begin
          end
        endcase
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
    // Latency-tolerant scoreboards for the sliced fabric: one side may
    // fire up to the skid depth ahead of the other. Each FIFO mirrors its
    // slice exactly (push = slice accept, pop = slice drain), so underflow
    // means delivery-without-accept and a pop mismatch means loss/reorder.
    logic [1:0] ar_n, aw_n, w_n;
    logic [ar_width-1:0] ar_q0, ar_q1, ar_push_data;
    logic [aw_width-1:0] aw_q0, aw_q1, aw_push_data;
    logic [w_width-1:0] w_q0, w_q1, w_push_data;
    logic ar_push, aw_push, w_push;
    logic ar_pop, aw_pop, w_pop;
    assign ar_push = |read_accept[s];
    assign ar_push_data = read_accept[s][0] ? ar_in[0] : read_accept[s][1] ? ar_in[1] :
                          read_accept[s][2] ? ar_in[2] : read_accept[s][3] ? ar_in[3] : ar_in[4];
    assign ar_pop = downstream_read[s];
    assign aw_push = |write_accept[s];
    assign aw_push_data = write_accept[s][0] ? aw_in[0] : write_accept[s][1] ? aw_in[1] :
                          write_accept[s][2] ? aw_in[2] : write_accept[s][3] ? aw_in[3] : aw_in[4];
    assign aw_pop = downstream_write[s];
    assign w_push = |w_transfer[s];
    assign w_push_data = w_transfer[s][0] ? w_in[0] : w_transfer[s][1] ? w_in[1] :
                         w_transfer[s][2] ? w_in[2] : w_transfer[s][3] ? w_in[3] : w_in[4];
    assign w_pop = w.valid && w_out_ready[s];
    always @(posedge clk) begin
      if (rst) begin
        assert (!ar.valid && !aw.valid && !w.valid && !r_in_ready[s] && !b_in_ready[s]);
        r_owner[s] <= 3'd0;
        w_owner[s] <= 3'd0;
        ar_n <= 2'd0;
        aw_n <= 2'd0;
        w_n <= 2'd0;
        ar_q0 <= '0;
        ar_q1 <= '0;
        aw_q0 <= '0;
        aw_q1 <= '0;
        w_q0 <= '0;
        w_q1 <= '0;
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
        // Upstream->slave channels: push on master fire, pop on slave handshake.
        if (ar_push) assert (ar_n != 2'd2);
        if (ar_pop) assert (ar_n != 2'd0);
        if (ar_push) begin
          if (read_accept[s][0]) r_owner[s] <= 3'd0;
          else if (read_accept[s][1]) r_owner[s] <= 3'd1;
          else if (read_accept[s][2]) r_owner[s] <= 3'd2;
          else if (read_accept[s][3]) r_owner[s] <= 3'd3;
          else if (read_accept[s][4]) r_owner[s] <= 3'd4;
        end
        if (aw_push) begin
          if (write_accept[s][0]) w_owner[s] <= 3'd0;
          else if (write_accept[s][1]) w_owner[s] <= 3'd1;
          else if (write_accept[s][2]) w_owner[s] <= 3'd2;
          else if (write_accept[s][3]) w_owner[s] <= 3'd3;
          else if (write_accept[s][4]) w_owner[s] <= 3'd4;
        end
        if (ar_pop && ar_n != 2'd0) assert (ar_out[s] == ar_q0);
        if (aw_push) assert (aw_n != 2'd2);
        if (aw_pop) assert (aw_n != 2'd0);
        if (aw_pop && aw_n != 2'd0) assert (aw_out[s] == aw_q0);
        if (w_push) assert (w_n != 2'd2);
        if (w_pop) assert (w_n != 2'd0);
        if (w_pop && w_n != 2'd0) assert (w_out[s] == w_q0);
        // R/B return paths are scored per master in g_master (mirroring the
        // per-master skid slices); a per-slave FIFO cannot represent owner
        // change with undrained beats.
        case ({
          ar_push, ar_pop
        })
          2'b10: begin
            if (ar_n == 2'd0) ar_q0 <= ar_push_data;
            else ar_q1 <= ar_push_data;
            ar_n <= ar_n + 2'd1;
          end
          2'b01: begin
            if (ar_n == 2'd2) ar_q0 <= ar_q1;
            if (ar_n != 2'd0) ar_n <= ar_n - 2'd1;
          end
          2'b11: begin
            if (ar_n == 2'd2) begin
              ar_q0 <= ar_q1;
              ar_q1 <= ar_push_data;
            end else if (ar_n != 2'd0) ar_q0 <= ar_push_data;
          end
          default: begin
          end
        endcase
        case ({
          aw_push, aw_pop
        })
          2'b10: begin
            if (aw_n == 2'd0) aw_q0 <= aw_push_data;
            else aw_q1 <= aw_push_data;
            aw_n <= aw_n + 2'd1;
          end
          2'b01: begin
            if (aw_n == 2'd2) aw_q0 <= aw_q1;
            if (aw_n != 2'd0) aw_n <= aw_n - 2'd1;
          end
          2'b11: begin
            if (aw_n == 2'd2) begin
              aw_q0 <= aw_q1;
              aw_q1 <= aw_push_data;
            end else if (aw_n != 2'd0) aw_q0 <= aw_push_data;
          end
          default: begin
          end
        endcase
        case ({
          w_push, w_pop
        })
          2'b10: begin
            if (w_n == 2'd0) w_q0 <= w_push_data;
            else w_q1 <= w_push_data;
            w_n <= w_n + 2'd1;
          end
          2'b01: begin
            if (w_n == 2'd2) w_q0 <= w_q1;
            if (w_n != 2'd0) w_n <= w_n - 2'd1;
          end
          2'b11: begin
            if (w_n == 2'd2) begin
              w_q0 <= w_q1;
              w_q1 <= w_push_data;
            end else if (w_n != 2'd0) w_q0 <= w_push_data;
          end
          default: begin
          end
        endcase

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
