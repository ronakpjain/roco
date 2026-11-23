// Nine-master, two-slave AXI4 crossbar for the dual-hart SoC's AXI subset.
// Slave 0: 0x1000_0000–0x11FF_FFFF (SDRAM); slave 1: all other addresses.
// Bursts must stay within one window. Each master can have one read and
// one write outstanding, independently; IDs are passed through unchanged.
//
// Master map (hart0, shared, hart1):
//   m0: hart0 I$  m1: hart0 D$  m2: boot  m3: hart0 PTW  m4: hart0 MMIO
//   m5: hart1 I$  m6: hart1 D$  m7: hart1 PTW  m8: hart1 MMIO
`include "axi4_defs.svh"
`default_nettype none

module axi4_xbar (
  input logic clk,
  rst,
  input axi4_aw_t m0_aw,
  output logic m0_aw_ready,
  input axi4_w_t m0_w,
  output logic m0_w_ready,
  input logic m0_b_ready,
  output axi4_b_t m0_b,
  input axi4_ar_t m0_ar,
  output logic m0_ar_ready,
  input logic m0_r_ready,
  output axi4_r_t m0_r,
  input axi4_aw_t m1_aw,
  output logic m1_aw_ready,
  input axi4_w_t m1_w,
  output logic m1_w_ready,
  input logic m1_b_ready,
  output axi4_b_t m1_b,
  input axi4_ar_t m1_ar,
  output logic m1_ar_ready,
  input logic m1_r_ready,
  output axi4_r_t m1_r,
  input axi4_aw_t m2_aw,
  output logic m2_aw_ready,
  input axi4_w_t m2_w,
  output logic m2_w_ready,
  input logic m2_b_ready,
  output axi4_b_t m2_b,
  input axi4_ar_t m2_ar,
  output logic m2_ar_ready,
  input logic m2_r_ready,
  output axi4_r_t m2_r,
  input axi4_aw_t m3_aw,
  output logic m3_aw_ready,
  input axi4_w_t m3_w,
  output logic m3_w_ready,
  input logic m3_b_ready,
  output axi4_b_t m3_b,
  input axi4_ar_t m3_ar,
  output logic m3_ar_ready,
  input logic m3_r_ready,
  output axi4_r_t m3_r,
  input axi4_aw_t m4_aw,
  output logic m4_aw_ready,
  input axi4_w_t m4_w,
  output logic m4_w_ready,
  input logic m4_b_ready,
  output axi4_b_t m4_b,
  input axi4_ar_t m4_ar,
  output logic m4_ar_ready,
  input logic m4_r_ready,
  output axi4_r_t m4_r,
  input axi4_aw_t m5_aw,
  output logic m5_aw_ready,
  input axi4_w_t m5_w,
  output logic m5_w_ready,
  input logic m5_b_ready,
  output axi4_b_t m5_b,
  input axi4_ar_t m5_ar,
  output logic m5_ar_ready,
  input logic m5_r_ready,
  output axi4_r_t m5_r,
  input axi4_aw_t m6_aw,
  output logic m6_aw_ready,
  input axi4_w_t m6_w,
  output logic m6_w_ready,
  input logic m6_b_ready,
  output axi4_b_t m6_b,
  input axi4_ar_t m6_ar,
  output logic m6_ar_ready,
  input logic m6_r_ready,
  output axi4_r_t m6_r,
  input axi4_aw_t m7_aw,
  output logic m7_aw_ready,
  input axi4_w_t m7_w,
  output logic m7_w_ready,
  input logic m7_b_ready,
  output axi4_b_t m7_b,
  input axi4_ar_t m7_ar,
  output logic m7_ar_ready,
  input logic m7_r_ready,
  output axi4_r_t m7_r,
  input axi4_aw_t m8_aw,
  output logic m8_aw_ready,
  input axi4_w_t m8_w,
  output logic m8_w_ready,
  input logic m8_b_ready,
  output axi4_b_t m8_b,
  input axi4_ar_t m8_ar,
  output logic m8_ar_ready,
  input logic m8_r_ready,
  output axi4_r_t m8_r,
  output axi4_aw_t s0_aw,
  input logic s0_aw_ready,
  output axi4_w_t s0_w,
  input logic s0_w_ready,
  output logic s0_b_ready,
  input axi4_b_t s0_b,
  output axi4_ar_t s0_ar,
  input logic s0_ar_ready,
  output logic s0_r_ready,
  input axi4_r_t s0_r,
  output axi4_aw_t s1_aw,
  input logic s1_aw_ready,
  output axi4_w_t s1_w,
  input logic s1_w_ready,
  output logic s1_b_ready,
  input axi4_b_t s1_b,
  output axi4_ar_t s1_ar,
  input logic s1_ar_ready,
  output logic s1_r_ready,
`ifdef ROCO_SOC_RAM_FORMAL
  output logic f_ram_wphase,
  output logic f_ram_wowner_boot,
`endif
`ifdef ROCO_SOC_DC_CLIENT_FORMAL
  output logic f_ram_read_d,
  output logic f_ram_read_i,
`endif
  input axi4_r_t s1_r
);
  localparam int NUM_MASTERS = 9;
  localparam logic [3:0] NO_OWNER = 4'd9;
  typedef enum logic [1:0] {
    Idle,
    Address,
    Data,
    Response
  } phase_t;
  phase_t rd[2], wr[2];
  logic [3:0] ro[2], wo[2], rr[2], rw[2];
  logic [3:0] r_pick[2], w_pick[2];
  logic [8:0] r_reserved, w_reserved;
  logic [8:0] ar_req[2], aw_req[2];
  // Use vectors for payload arrays so the Yosys frontend preserves each
  // element's width. Named fields are accessed through scalar aliases.
  logic [$bits(m0_ar)-1:0] mar[9], sar[2];
  logic [$bits(m0_aw)-1:0] maw[9], saw[2];
  logic [$bits(m0_w)-1:0] mw[9], sw[2];
  logic [$bits(m0_r)-1:0] mr[9], sr[2];
  logic [$bits(m0_b)-1:0] mb[9], sb[2];
  logic [8:0] mrr;
  assign mrr = {
    m8_r_ready,
    m7_r_ready,
    m6_r_ready,
    m5_r_ready,
    m4_r_ready,
    m3_r_ready,
    m2_r_ready,
    m1_r_ready,
    m0_r_ready
  };
  logic [8:0] mbr;
  assign mbr = {
    m8_b_ready,
    m7_b_ready,
    m6_b_ready,
    m5_b_ready,
    m4_b_ready,
    m3_b_ready,
    m2_b_ready,
    m1_b_ready,
    m0_b_ready
  };
  logic [1:0] sar_ready;
  assign sar_ready = {s1_ar_ready, s0_ar_ready};
  logic [1:0] saw_ready;
  assign saw_ready = {s1_aw_ready, s0_aw_ready};
  logic [1:0] sw_ready;
  assign sw_ready = {s1_w_ready, s0_w_ready};
  logic [1:0] sr_ready, sb_ready;
  logic [8:0] mar_ready, maw_ready, mw_ready;
  // Slice s_ready (flopped not-full): replaces the slave READY inputs in
  // the arbiter so both directions terminate in flops. VALID is the MSB
  // of each channel vector (axi4_defs.svh field order).
  logic [1:0] ar_sr, aw_sr, w_sr;
  logic [8:0] mr_sr, mb_sr;
  // AW slice occupancy per slave (slice output VALID): a new AW is only
  // accepted into an empty slice, so at most one address is ever outstanding
  // ahead of the drain-side FSM advance. AR needs no gate (push-side advance
  // leaves Address immediately); W/R/B stream through their FIFOs in order.
  logic [1:0] aw_out_v;

  assign {mar[8], mar[7], mar[6], mar[5], mar[4], mar[3], mar[2], mar[1], mar[0]} = {
    m8_ar, m7_ar, m6_ar, m5_ar, m4_ar, m3_ar, m2_ar, m1_ar, m0_ar
  };
  assign {maw[8], maw[7], maw[6], maw[5], maw[4], maw[3], maw[2], maw[1], maw[0]} = {
    m8_aw, m7_aw, m6_aw, m5_aw, m4_aw, m3_aw, m2_aw, m1_aw, m0_aw
  };
  assign {mw[8], mw[7], mw[6], mw[5], mw[4], mw[3], mw[2], mw[1], mw[0]} = {
    m8_w, m7_w, m6_w, m5_w, m4_w, m3_w, m2_w, m1_w, m0_w
  };
  assign {sr[1], sr[0]} = {s1_r, s0_r};
  assign {sb[1], sb[0]} = {s1_b, s0_b};
  assign {s1_ar, s0_ar} = {sar[1], sar[0]};
  assign {s1_aw, s0_aw} = {saw[1], saw[0]};
  assign {s1_w, s0_w} = {sw[1], sw[0]};
  assign {s1_r_ready, s0_r_ready} = sr_ready;
  assign {s1_b_ready, s0_b_ready} = sb_ready;
  assign {m8_r, m7_r, m6_r, m5_r, m4_r, m3_r, m2_r, m1_r, m0_r} = {
    mr[8], mr[7], mr[6], mr[5], mr[4], mr[3], mr[2], mr[1], mr[0]
  };
  assign {m8_b, m7_b, m6_b, m5_b, m4_b, m3_b, m2_b, m1_b, m0_b} = {
    mb[8], mb[7], mb[6], mb[5], mb[4], mb[3], mb[2], mb[1], mb[0]
  };
  assign {m8_ar_ready, m7_ar_ready, m6_ar_ready, m5_ar_ready, m4_ar_ready,
          m3_ar_ready, m2_ar_ready, m1_ar_ready, m0_ar_ready} = mar_ready;
  assign {m8_aw_ready, m7_aw_ready, m6_aw_ready, m5_aw_ready, m4_aw_ready,
          m3_aw_ready, m2_aw_ready, m1_aw_ready, m0_aw_ready} = maw_ready;
  assign {m8_w_ready, m7_w_ready, m6_w_ready, m5_w_ready, m4_w_ready,
          m3_w_ready, m2_w_ready, m1_w_ready, m0_w_ready} = mw_ready;

  function automatic logic [3:0] next_master(input logic [3:0] m);
    next_master = m == 4'd8 ? 4'd0 : m + 4'd1;
  endfunction

  function automatic logic [3:0] pick(input logic [8:0] req, input logic [3:0] first);
    logic [3:0] m;
    m = first;
    pick = NO_OWNER;
    for (int i = 0; i < 9; i++) begin
      if (pick == NO_OWNER && req[m]) pick = m;
      m = next_master(m);
    end
  endfunction

  always_comb begin
    r_reserved = '0;
    w_reserved = '0;
    for (int s = 0; s < 2; s++) begin
      if (rd[s] != Idle) r_reserved[ro[s]] = 1'b1;
      if (wr[s] != Idle) w_reserved[wo[s]] = 1'b1;
    end
  end

  for (genvar m = 0; m < 9; m++) begin : g_decode
    axi4_ar_t ar;
    assign ar = mar[m];
    axi4_aw_t aw;
    assign aw = maw[m];
    logic ar_sdram;
    assign ar_sdram = ar.addr[31:25] == 7'd8;
    logic aw_sdram;
    assign aw_sdram = aw.addr[31:25] == 7'd8;
    assign ar_req[0][m] = ar.valid && ar_sdram;
    assign ar_req[1][m] = ar.valid && !ar_sdram;
    assign aw_req[0][m] = aw.valid && aw_sdram;
    assign aw_req[1][m] = aw.valid && !aw_sdram;
  end

`ifdef ROCO_SOC_RAM_FORMAL
  assign f_ram_wphase = wr[0] == Data;
  assign f_ram_wowner_boot = wo[0] == 2;
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (rd[0] != Idle && rd[1] != Idle) assert (ro[0] != ro[1]);
      if (wr[0] != Idle && wr[1] != Idle) assert (wo[0] != wo[1]);
    end
  end
`endif

`ifdef ROCO_SOC_DC_CLIENT_FORMAL
  assign f_ram_read_d = rd[0] == Data && ro[0] == 1;
  assign f_ram_read_i = rd[0] == Data && ro[0] == 0;
`endif

  for (genvar s = 0; s < 2; s++) begin : g_slave
    assign r_pick[s] = pick(ar_req[s] & ~r_reserved, rr[s]);
    assign w_pick[s] = pick(aw_req[s] & ~w_reserved, rw[s]);

`ifdef ROCO_SOC_RAM_FORMAL
    // Induction must not invent an owner outside the master array.
    // m4/m8 are MMIO-only (peripheral slave); m3/m7 are PTW reads.
    always_ff @(posedge clk) begin
      if (!rst) begin
        if (rd[s] != Idle) begin
          assert (ro[s] < 9);
          if (s == 0) assert (ro[s] != 4 && ro[s] != 8);
          if (s == 1) assert (ro[s] == 4 || ro[s] == 8);
        end
        if (wr[s] != Idle) begin
          assert (wo[s] < 9);
          if (s == 0) assert (wo[s] == 1 || wo[s] == 2 || wo[s] == 6);
          if (s == 1) assert (wo[s] == 4 || wo[s] == 8);
        end
      end
    end
`endif

    // Lock the owner before asserting downstream VALID, including while
    // READY is low. The originating master holds the address payload.
    axi4_ar_t ar;
    assign ar = rd[s] == Address ? mar[ro[s]] : '0;
    // Gate the AW mux on slice-empty, exactly like maw_ready: otherwise a
    // master holding VALID would push ghost beats into a non-empty slice
    // that the arbiter never granted.
    axi4_aw_t aw;
    assign aw = (wr[s] == Address && aw_sr[s] && !aw_out_v[s]) ? maw[wo[s]] : '0;
    axi4_w_t w;
    assign w = wr[s] == Data ? mw[wo[s]] : '0;
    axi4_r_t r;
    assign r = sr[s];
    axi4_b_t b;
    assign b = sb[s];
    // Slave-side slices register the 9:1 owner muxes (AR/AW/W); R/B are
    // sliced per master in g_return to keep beat->owner pairing.
    axi4_register_slice #(
        .WIDTH($bits(m0_ar))
    ) u_ar_slice (
        .clk(clk),
        .rst(rst),
        .s_data(ar),
        .s_ready(ar_sr[s]),
        .m_data(sar[s]),
        .m_ready(sar_ready[s])
    );
    axi4_register_slice #(
        .WIDTH($bits(m0_aw))
    ) u_aw_slice (
        .clk(clk),
        .rst(rst),
        .s_data(aw),
        .s_ready(aw_sr[s]),
        .m_data(saw[s]),
        .m_ready(saw_ready[s])
    );
    // Slave-side handshake uses the slice DRAIN (not push) for AW/W so the
    // slave always observes AW before W. AR stays push-side: R has no such
    // ordering constraint and the earlier advance shortens miss latency.
    logic w_out_v, w_out_last;
    assign aw_out_v[s] = saw[s][$bits(m0_aw)-1];
    assign w_out_v = sw[s][$bits(m0_w)-1];
    assign w_out_last = sw[s][0];
    axi4_register_slice #(
        .WIDTH($bits(m0_w))
    ) u_w_slice (
        .clk(clk),
        .rst(rst),
        .s_data(w),
        .s_ready(w_sr[s]),
        .m_data(sw[s]),
        .m_ready(sw_ready[s])
    );
    assign sr_ready[s] = rd[s] == Data && mr_sr[ro[s]];
    assign sb_ready[s] = wr[s] == Response && mb_sr[wo[s]];

    always_ff @(posedge clk or posedge rst) begin
      if (rst) begin
        rd[s] <= Idle;
        wr[s] <= Idle;
        ro[s] <= '0;
        wo[s] <= '0;
        rr[s] <= '0;
        rw[s] <= '0;
      end else begin
        case (rd[s])
          Idle:
          if (r_pick[s] != NO_OWNER) begin
            ro[s] <= r_pick[s];
            rd[s] <= Address;
          end
          Address:
          if (ar.valid && ar_sr[s]) begin
            rr[s] <= next_master(ro[s]);
            rd[s] <= Data;
          end
          Data: if (r.valid && r.last && sr_ready[s]) rd[s] <= Idle;
          default: rd[s] <= Idle;
        endcase
        case (wr[s])
          Idle:
          if (w_pick[s] != NO_OWNER) begin
            wo[s] <= w_pick[s];
            wr[s] <= Address;
          end
          Address:
          if (aw_out_v && saw_ready[s]) begin
            rw[s] <= next_master(wo[s]);
            wr[s] <= Data;
          end
          Data: if (w_out_v && w_out_last && sw_ready[s]) wr[s] <= Response;
          Response: if (b.valid && sb_ready[s]) wr[s] <= Idle;
          default: wr[s] <= Idle;
        endcase
      end
    end
  end

  for (genvar m = 0; m < 9; m++) begin : g_return
    localparam logic [3:0] Master = 4'(m);
    logic r0;
    assign r0 = ro[0] == Master;
    logic r1;
    assign r1 = ro[1] == Master;
    logic w0;
    assign w0 = wo[0] == Master;
    logic w1;
    assign w1 = wo[1] == Master;
    assign mar_ready[m] = (r0 && rd[0] == Address && ar_sr[0]) ||
                          (r1 && rd[1] == Address && ar_sr[1]);
    assign maw_ready[m] = (w0 && wr[0] == Address && aw_sr[0] && !aw_out_v[0]) ||
                          (w1 && wr[1] == Address && aw_sr[1] && !aw_out_v[1]);
    assign mw_ready[m] = (w0 && wr[0] == Data && w_sr[0]) || (w1 && wr[1] == Data && w_sr[1]);
    // Per-master return slices: the 2:1 slave mux stays combinational
    // (small) and the slice registers both the beat and the READY return,
    // so in-flight beats can never misroute when the owner advances.
    axi4_register_slice #(
        .WIDTH($bits(m0_r))
    ) u_r_slice (
        .clk(clk),
        .rst(rst),
        .s_data((r0 && rd[0] == Data) ? sr[0] : (r1 && rd[1] == Data) ? sr[1] : '0),
        .s_ready(mr_sr[m]),
        .m_data(mr[m]),
        .m_ready(mrr[m])
    );
    axi4_register_slice #(
        .WIDTH($bits(m0_b))
    ) u_b_slice (
        .clk(clk),
        .rst(rst),
        .s_data((w0 && wr[0] == Response) ? sb[0] : (w1 && wr[1] == Response) ? sb[1] : '0),
        .s_ready(mb_sr[m]),
        .m_data(mb[m]),
        .m_ready(mbr[m])
    );
  end
endmodule
