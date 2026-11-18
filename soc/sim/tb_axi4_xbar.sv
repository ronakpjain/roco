// AXI4 crossbar testbench.
//
// Directed checks cover window decode, read-after-write data flow,
// catch-all routing, cross-slave concurrency and same-slave write
// ownership. A stress phase runs two masters against one slave in
// parallel to check round-robin service and burst serialization. The
// slave models flag misrouted addresses, overlong bursts and beat/last
// mismatches; the master drivers are registered state machines, so
// VALID and payload signals stay stable until the matching READY.

`timescale 1ns / 1ps

`include "axi4_defs.svh"

// Behavioural AXI4 slave: one transaction at a time, one beat per cycle,
// one cycle to the write response. Reads return a stored write when the
// word was written, otherwise a deterministic address-derived pattern.
module tb_axi4_slave_model #(
    parameter bit EXPECT_SDRAM = 1'b1
) (
  input logic clk,
  input logic rst,
  input logic stall_address,
  input axi4_aw_t aw,
  output logic aw_ready,
  input axi4_w_t w,
  output logic w_ready,
  input logic b_ready,
  output axi4_b_t b,
  input axi4_ar_t ar,
  output logic ar_ready,
  input logic r_ready,
  output axi4_r_t r
);

  localparam int WORDS = 1 << 16;

  typedef enum logic [1:0] {
    T_IDLE,
    T_READ,
    T_WRITE,
    T_RESP
  } t_state_t;

  t_state_t state;
  logic [31:0] addr_q;
  logic [7:0] len_q;
  logic [3:0] id_q;
  logic [7:0] bidx;
  logic [31:0] mem[0:WORDS-1];
  logic written[0:WORDS-1];

  function automatic logic [15:0] word_idx(input logic [31:0] base, input logic [7:0] beat);
    word_idx = (base[17:2] + {8'b0, beat}) & 16'hFFFF;
  endfunction

  function automatic logic [31:0] read_word(input logic [31:0] base, input logic [7:0] beat);
    logic [15:0] widx;
    widx = word_idx(base, beat);
    read_word = written[widx] ? mem[widx] : {8'hA5, 8'h00, widx};
  endfunction

  // A read is always accepted first when both directions arrive together,
  // so a pending write never blocks the only idle state.
  always_comb begin
    ar_ready = (state == T_IDLE) && !stall_address;
    aw_ready = (state == T_IDLE) && !stall_address && !ar.valid;
    w_ready = (state == T_WRITE);
    b.valid = (state == T_RESP);
    b.id = id_q;
    b.resp = `AXI4_RESP_OKAY;
    r.valid = (state == T_READ);
    r.id = id_q;
    r.resp = `AXI4_RESP_OKAY;
    r.data = read_word(addr_q, bidx);
    r.last = (bidx == len_q);
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      state <= T_IDLE;
      addr_q <= '0;
      len_q <= '0;
      id_q <= '0;
      bidx <= '0;
    end else begin
      case (state)
        T_IDLE: begin
          if (ar.valid && ar_ready) begin
            if ((ar.addr[31:25] == 7'd8) != EXPECT_SDRAM)
              $fatal(1, "slave model saw a misrouted address");
            if (ar.len > 8'd15) $fatal(1, "slave model saw an overlong burst");
            addr_q <= ar.addr;
            len_q <= ar.len;
            id_q <= ar.id;
            bidx <= '0;
            state <= T_READ;
          end else if (aw.valid && aw_ready) begin
            if ((aw.addr[31:25] == 7'd8) != EXPECT_SDRAM)
              $fatal(1, "slave model saw a misrouted address");
            if (aw.len > 8'd15) $fatal(1, "slave model saw an overlong burst");
            addr_q <= aw.addr;
            len_q <= aw.len;
            id_q <= aw.id;
            bidx <= '0;
            state <= T_WRITE;
          end
        end
        T_READ: begin
          if (r_ready) begin
            if (bidx == len_q) begin
              state <= T_IDLE;
            end else begin
              bidx <= bidx + 8'd1;
            end
          end
        end
        T_WRITE: begin
          if (w.valid && w_ready) begin
            mem[word_idx(addr_q, bidx)] <= w.data;
            written[word_idx(addr_q, bidx)] <= 1'b1;
            if (w.last != (bidx == len_q))
              $fatal(1, "write last flag did not match the burst length");
            if (bidx == len_q) begin
              state <= T_RESP;
            end else begin
              bidx <= bidx + 8'd1;
            end
          end
        end
        T_RESP: begin
          if (b_ready) begin
            state <= T_IDLE;
          end
        end
        default: begin
          state <= T_IDLE;
        end
      endcase
    end
  end

endmodule

module tb_axi4_xbar;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1;
  logic stall_address = 0;
  axi4_ar_t stalled_ar;
  axi4_aw_t stalled_aw;

  axi4_aw_t m_aw[0:4];
  axi4_w_t m_w[0:4];
  axi4_b_t m_b[0:4];
  axi4_ar_t m_ar[0:4];
  axi4_r_t m_r[0:4];
  logic m_aw_ready[0:4];
  logic m_w_ready[0:4];
  logic m_b_ready[0:4];
  logic m_ar_ready[0:4];
  logic m_r_ready[0:4];

  axi4_aw_t aw_s0;
  logic aw_ready_s0;
  axi4_w_t w_s0;
  logic w_ready_s0;
  logic b_ready_s0;
  axi4_b_t b_s0;
  axi4_ar_t ar_s0;
  logic ar_ready_s0;
  logic r_ready_s0;
  axi4_r_t r_s0;
  axi4_aw_t aw_s1;
  logic aw_ready_s1;
  axi4_w_t w_s1;
  logic w_ready_s1;
  logic b_ready_s1;
  axi4_b_t b_s1;
  axi4_ar_t ar_s1;
  logic ar_ready_s1;
  logic r_ready_s1;
  axi4_r_t r_s1;

  // Per-master command mailboxes.
  logic cmd_valid[0:4];
  logic cmd_we[0:4];
  logic [31:0] cmd_addr[0:4];
  logic [4:0] cmd_beats[0:4];
  logic [31:0] cmd_data[0:4];

  typedef enum logic [2:0] {
    MS_IDLE,
    MS_AR,
    MS_R,
    MS_AW,
    MS_W,
    MS_B
  } ms_t;

  ms_t mstate[0:4];
  logic [4:0] t_beats[0:4];
  logic [31:0] t_data[0:4];
  logic [3:0] rx_cnt[0:4];
  logic [3:0] wbeat[0:4];
  logic [31:0] rx[0:4][0:15];
  integer done_stamp[0:4];

  integer cyc = 0;
  integer i;
  integer mid;

  axi4_xbar dut (
      .clk(clk),
      .rst(rst),
      .m0_aw(m_aw[0]),
      .m0_aw_ready(m_aw_ready[0]),
      .m0_w(m_w[0]),
      .m0_w_ready(m_w_ready[0]),
      .m0_b_ready(m_b_ready[0]),
      .m0_b(m_b[0]),
      .m0_ar(m_ar[0]),
      .m0_ar_ready(m_ar_ready[0]),
      .m0_r_ready(m_r_ready[0]),
      .m0_r(m_r[0]),
      .m1_aw(m_aw[1]),
      .m1_aw_ready(m_aw_ready[1]),
      .m1_w(m_w[1]),
      .m1_w_ready(m_w_ready[1]),
      .m1_b_ready(m_b_ready[1]),
      .m1_b(m_b[1]),
      .m1_ar(m_ar[1]),
      .m1_ar_ready(m_ar_ready[1]),
      .m1_r_ready(m_r_ready[1]),
      .m1_r(m_r[1]),
      .m2_aw(m_aw[2]),
      .m2_aw_ready(m_aw_ready[2]),
      .m2_w(m_w[2]),
      .m2_w_ready(m_w_ready[2]),
      .m2_b_ready(m_b_ready[2]),
      .m2_b(m_b[2]),
      .m2_ar(m_ar[2]),
      .m2_ar_ready(m_ar_ready[2]),
      .m2_r_ready(m_r_ready[2]),
      .m2_r(m_r[2]),
      .m3_aw(m_aw[3]),
      .m3_aw_ready(m_aw_ready[3]),
      .m3_w(m_w[3]),
      .m3_w_ready(m_w_ready[3]),
      .m3_b_ready(m_b_ready[3]),
      .m3_b(m_b[3]),
      .m3_ar(m_ar[3]),
      .m3_ar_ready(m_ar_ready[3]),
      .m3_r_ready(m_r_ready[3]),
      .m3_r(m_r[3]),
      .m4_aw(m_aw[4]),
      .m4_aw_ready(m_aw_ready[4]),
      .m4_w(m_w[4]),
      .m4_w_ready(m_w_ready[4]),
      .m4_b_ready(m_b_ready[4]),
      .m4_b(m_b[4]),
      .m4_ar(m_ar[4]),
      .m4_ar_ready(m_ar_ready[4]),
      .m4_r_ready(m_r_ready[4]),
      .m4_r(m_r[4]),
      .s0_aw(aw_s0),
      .s0_aw_ready(aw_ready_s0),
      .s0_w(w_s0),
      .s0_w_ready(w_ready_s0),
      .s0_b_ready(b_ready_s0),
      .s0_b(b_s0),
      .s0_ar(ar_s0),
      .s0_ar_ready(ar_ready_s0),
      .s0_r_ready(r_ready_s0),
      .s0_r(r_s0),
      .s1_aw(aw_s1),
      .s1_aw_ready(aw_ready_s1),
      .s1_w(w_s1),
      .s1_w_ready(w_ready_s1),
      .s1_b_ready(b_ready_s1),
      .s1_b(b_s1),
      .s1_ar(ar_s1),
      .s1_ar_ready(ar_ready_s1),
      .s1_r_ready(r_ready_s1),
      .s1_r(r_s1)
  );

  tb_axi4_slave_model #(
      .EXPECT_SDRAM(1'b1)
  ) u_slave_s0 (
      .clk(clk),
      .rst(rst),
      .stall_address(stall_address),
      .aw(aw_s0),
      .aw_ready(aw_ready_s0),
      .w(w_s0),
      .w_ready(w_ready_s0),
      .b_ready(b_ready_s0),
      .b(b_s0),
      .ar(ar_s0),
      .ar_ready(ar_ready_s0),
      .r_ready(r_ready_s0),
      .r(r_s0)
  );

  tb_axi4_slave_model #(
      .EXPECT_SDRAM(1'b0)
  ) u_slave_s1 (
      .clk(clk),
      .rst(rst),
      .stall_address(stall_address),
      .aw(aw_s1),
      .aw_ready(aw_ready_s1),
      .w(w_s1),
      .w_ready(w_ready_s1),
      .b_ready(b_ready_s1),
      .b(b_s1),
      .ar(ar_s1),
      .ar_ready(ar_ready_s1),
      .r_ready(r_ready_s1),
      .r(r_s1)
  );

  always @(posedge clk) cyc <= cyc + 1;

  // Registered master drivers: VALID and payloads are held stable from
  // issue until the matching READY, as AXI4 requires.
  always @(posedge clk) begin
    if (rst) begin
      for (mid = 0; mid < 5; mid = mid + 1) begin
        mstate[mid] <= MS_IDLE;
        m_ar[mid].valid <= 1'b0;
        m_aw[mid].valid <= 1'b0;
        m_w[mid].valid <= 1'b0;
        m_w[mid].last <= 1'b0;
        m_r_ready[mid] <= 1'b0;
        m_b_ready[mid] <= 1'b0;
        rx_cnt[mid] <= '0;
        wbeat[mid] <= '0;
      end
    end else begin
      for (mid = 0; mid < 5; mid = mid + 1) begin
        case (mstate[mid])
          MS_IDLE: begin
            if (cmd_valid[mid]) begin
              t_beats[mid] <= cmd_beats[mid];
              t_data[mid] <= cmd_data[mid];
              if (cmd_we[mid]) begin
                m_aw[mid].valid <= 1'b1;
                m_aw[mid].id <= 4'(mid);
                m_aw[mid].addr <= cmd_addr[mid];
                m_aw[mid].len <= 8'(cmd_beats[mid]) - 8'd1;
                m_aw[mid].size <= 3'd2;
                m_aw[mid].burst <= `AXI4_BURST_INCR;
                m_aw[mid].prot <= 3'd0;
                m_w[mid].valid <= 1'b1;
                m_w[mid].data <= cmd_data[mid];
                m_w[mid].strb <= 4'hf;
                m_w[mid].last <= (cmd_beats[mid] == 5'd1);
                wbeat[mid] <= '0;
                mstate[mid] <= MS_AW;
              end else begin
                m_ar[mid].valid <= 1'b1;
                m_ar[mid].id <= 4'(mid);
                m_ar[mid].addr <= cmd_addr[mid];
                m_ar[mid].len <= 8'(cmd_beats[mid]) - 8'd1;
                m_ar[mid].size <= 3'd2;
                m_ar[mid].burst <= `AXI4_BURST_INCR;
                m_ar[mid].prot <= 3'd0;
                mstate[mid] <= MS_AR;
              end
            end
          end
          MS_AR: begin
            if (m_ar_ready[mid]) begin
              m_ar[mid].valid <= 1'b0;
              rx_cnt[mid] <= '0;
              m_r_ready[mid] <= 1'b1;
              mstate[mid] <= MS_R;
            end
          end
          MS_R: begin
            if (m_r[mid].valid) begin
              if (m_r[mid].id != 4'(mid) || m_r[mid].resp != `AXI4_RESP_OKAY)
                $fatal(1, "unexpected read ID or response");
              rx[mid][rx_cnt[mid]] <= m_r[mid].data;
              rx_cnt[mid] <= rx_cnt[mid] + 4'd1;
              if (m_r[mid].last) begin
                if (5'(rx_cnt[mid]) + 5'd1 != t_beats[mid]) $fatal(1, "read burst length mismatch");
                m_r_ready[mid] <= 1'b0;
                mstate[mid] <= MS_IDLE;
                done_stamp[mid] <= cyc;
              end
            end
          end
          MS_AW: begin
            if (m_aw_ready[mid]) begin
              m_aw[mid].valid <= 1'b0;
              mstate[mid] <= MS_W;
            end
          end
          MS_W: begin
            if (m_w_ready[mid]) begin
              if (5'(wbeat[mid]) + 5'd1 == t_beats[mid]) begin
                m_w[mid].valid <= 1'b0;
                m_b_ready[mid] <= 1'b1;
                mstate[mid] <= MS_B;
              end else begin
                wbeat[mid] <= wbeat[mid] + 4'd1;
                m_w[mid].data <= t_data[mid] + {28'd0, wbeat[mid]} + 32'd1;
                m_w[mid].last <= (5'(wbeat[mid]) + 5'd2 == t_beats[mid]);
              end
            end
          end
          MS_B: begin
            if (m_b[mid].valid) begin
              if (m_b[mid].id != 4'(mid) || m_b[mid].resp != `AXI4_RESP_OKAY)
                $fatal(1, "unexpected write ID or response");
              m_b_ready[mid] <= 1'b0;
              mstate[mid] <= MS_IDLE;
              done_stamp[mid] <= cyc;
            end
          end
          default: begin
            mstate[mid] <= MS_IDLE;
          end
        endcase
      end
    end
  end

  task automatic start_cmd(input int m, input bit we, input logic [31:0] addr, input int beats,
                           input logic [31:0] data);
    begin
      while (mstate[m] != MS_IDLE) @(negedge clk);
      cmd_we[m] = we;
      cmd_addr[m] = addr;
      if (beats < 1 || beats > 16) $fatal(1, "unsupported test burst length");
      cmd_beats[m] = beats[4:0];
      cmd_data[m] = data;
      cmd_valid[m] = 1'b1;
      @(negedge clk);
      while (mstate[m] == MS_IDLE) @(negedge clk);
      cmd_valid[m] = 1'b0;
    end
  endtask

  task automatic wait_done(input int m);
    begin
      while (mstate[m] != MS_IDLE) @(negedge clk);
    end
  endtask

  task automatic issue(input int m, input bit we, input logic [31:0] addr, input int beats,
                       input logic [31:0] data);
    begin
      start_cmd(m, we, addr, beats, data);
      wait_done(m);
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst = 0;
    @(negedge clk);

    // A late higher-priority request must not replace a stalled grant.
    // The write driver asserts W alongside AW, but W must not escape early.
    stall_address = 1;
    start_cmd(4, 1'b0, 32'h1000_00A0, 1, '0);
    start_cmd(3, 1'b1, 32'h8000_00A4, 1, 32'h7600_0033);
    while (!ar_s0.valid || !aw_s1.valid) @(negedge clk);
    stalled_ar = ar_s0;
    stalled_aw = aw_s1;
    start_cmd(0, 1'b0, 32'h1000_00A8, 1, '0);
    start_cmd(1, 1'b1, 32'h8000_00AC, 1, 32'h7600_0011);
    repeat (3) begin
      @(negedge clk);
      if (ar_s0 !== stalled_ar || aw_s1 !== stalled_aw)
        $fatal(1, "address grant changed under backpressure");
      if (w_s1.valid || m_w_ready[3] || m_w_ready[1]) $fatal(1, "W routed before AW handshake");
    end
    stall_address = 0;
    wait_done(4);
    wait_done(3);
    wait_done(0);
    wait_done(1);
    if (done_stamp[4] >= done_stamp[0] || done_stamp[3] >= done_stamp[1])
      $fatal(1, "stalled grants did not complete first");

    // Four-beat read from the SDRAM window through master 0.
    issue(0, 1'b0, 32'h1000_0100, 4, 32'd0);
    if (rx[0][0] !== {8'hA5, 8'h00, 16'h0040}) $fatal(1, "beat 0 data mismatch");
    if (rx[0][1] !== {8'hA5, 8'h00, 16'h0041}) $fatal(1, "beat 1 data mismatch");
    if (rx[0][3] !== {8'hA5, 8'h00, 16'h0043}) $fatal(1, "last beat data mismatch");

    // Single-beat write through master 2, then read back.
    issue(2, 1'b1, 32'h1000_0104, 1, 32'hDEAD_BEEF);
    issue(0, 1'b0, 32'h1000_0100, 4, 32'd0);
    if (rx[0][1] !== 32'hDEAD_BEEF) $fatal(1, "write did not reach the slave");
    if (rx[0][0] !== {8'hA5, 8'h00, 16'h0040})
      $fatal(1, "read after write corrupted a neighbour word");

    // Catch-all routing: master 4 writes and reads the peripheral window.
    issue(4, 1'b1, 32'h8000_0010, 1, 32'hCAFE_BABE);
    issue(4, 1'b0, 32'h8000_0010, 1, 32'd0);
    if (rx[4][0] !== 32'hCAFE_BABE) $fatal(1, "catch-all window lost the write");
    issue(4, 1'b0, 32'h8000_0004, 1, 32'd0);
    if (rx[4][0] !== {8'hA5, 8'h00, 16'h0001}) $fatal(1, "unwritten catch-all read mismatch");

    // Cross-slave concurrency: a long SDRAM read overlaps a catch-all write.
    fork
      begin
        start_cmd(0, 1'b0, 32'h1000_0200, 16, 32'd0);
        wait_done(0);
      end
      begin
        start_cmd(4, 1'b1, 32'h8000_0020, 1, 32'h1234_5678);
        wait_done(4);
      end
    join
    if (done_stamp[4] >= done_stamp[0]) $fatal(1, "cross-slave concurrency was serialized");

    // Same-slave ownership: a second write waits for the first response.
    start_cmd(1, 1'b1, 32'h1000_0300, 8, 32'h1111_0000);
    repeat (4) @(negedge clk);
    start_cmd(2, 1'b1, 32'h1000_0340, 1, 32'h2222_2222);
    wait_done(1);
    wait_done(2);
    if (done_stamp[2] <= done_stamp[1]) $fatal(1, "same-slave writes were not serialized");
    issue(1, 1'b0, 32'h1000_0340, 1, 32'd0);
    if (rx[1][0] !== 32'h2222_2222) $fatal(1, "second same-slave write was lost");

    // Round-robin service: two masters in parallel against one slave.
    for (i = 0; i < 8; i = i + 1) begin
      fork
        begin
          start_cmd(0, 1'b0, 32'h1000_0400 + 64 * i, 4, 32'd0);
          wait_done(0);
        end
        begin
          start_cmd(1, 1'b0, 32'h1000_0500 + 64 * i, 4, 32'd0);
          wait_done(1);
        end
      join
    end
    for (i = 0; i < 8; i = i + 1) begin
      fork
        begin
          start_cmd(1, 1'b1, 32'h1000_0600 + 64 * i, 4, 32'h3100_0000 + i);
          wait_done(1);
        end
        begin
          start_cmd(2, 1'b1, 32'h1000_0700 + 64 * i, 2, 32'h3200_0000 + i);
          wait_done(2);
        end
      join
    end
    issue(0, 1'b0, 32'h1000_0600, 4, 32'd0);
    if (rx[0][0] !== 32'h3100_0000) $fatal(1, "round-robin write burst was lost");

    $display("tb_axi4_xbar: PASS (decode, bursts, stalls, concurrency, ownership, round-robin)");
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1, "crossbar timeout or starvation");
  end

endmodule
