// Five-master, two-slave AXI4 crossbar for the SoC's AXI subset.
// Slave 0: 0x1000_0000–0x11FF_FFFF (SDRAM); slave 1: all other addresses.
// Bursts must stay within one window. Each master can have one read and
// one write outstanding, independently; IDs are passed through unchanged.
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
  input axi4_r_t s1_r
);
  localparam logic [2:0] NO_OWNER = 3'd7;
  typedef enum logic [1:0] {
    Idle,
    Address,
    Data,
    Response
  } phase_t;
  phase_t rd[2], wr[2];
  logic [2:0] ro[2], wo[2], rr[2], rw[2];
  logic [2:0] r_pick[2], w_pick[2];
  logic [4:0] r_reserved, w_reserved;
  logic [4:0] ar_req[2], aw_req[2];
  // Use vectors for payload arrays so the Yosys frontend preserves each
  // element's width. Named fields are accessed through scalar aliases.
  logic [$bits(m0_ar)-1:0] mar[5], sar[2];
  logic [$bits(m0_aw)-1:0] maw[5], saw[2];
  logic [$bits(m0_w)-1:0] mw[5], sw[2];
  logic [$bits(m0_r)-1:0] mr[5], sr[2];
  logic [$bits(m0_b)-1:0] mb[5], sb[2];
  logic [4:0] mrr;
  assign mrr = {m4_r_ready, m3_r_ready, m2_r_ready, m1_r_ready, m0_r_ready};
  logic [4:0] mbr;
  assign mbr = {m4_b_ready, m3_b_ready, m2_b_ready, m1_b_ready, m0_b_ready};
  logic [1:0] sar_ready;
  assign sar_ready = {s1_ar_ready, s0_ar_ready};
  logic [1:0] saw_ready;
  assign saw_ready = {s1_aw_ready, s0_aw_ready};
  logic [1:0] sw_ready;
  assign sw_ready = {s1_w_ready, s0_w_ready};
  logic [1:0] sr_ready, sb_ready;
  logic [4:0] mar_ready, maw_ready, mw_ready;

  assign {mar[4], mar[3], mar[2], mar[1], mar[0]} = {m4_ar, m3_ar, m2_ar, m1_ar, m0_ar};
  assign {maw[4], maw[3], maw[2], maw[1], maw[0]} = {m4_aw, m3_aw, m2_aw, m1_aw, m0_aw};
  assign {mw[4], mw[3], mw[2], mw[1], mw[0]} = {m4_w, m3_w, m2_w, m1_w, m0_w};
  assign {sr[1], sr[0]} = {s1_r, s0_r};
  assign {sb[1], sb[0]} = {s1_b, s0_b};
  assign {s1_ar, s0_ar} = {sar[1], sar[0]};
  assign {s1_aw, s0_aw} = {saw[1], saw[0]};
  assign {s1_w, s0_w} = {sw[1], sw[0]};
  assign {s1_r_ready, s0_r_ready} = sr_ready;
  assign {s1_b_ready, s0_b_ready} = sb_ready;
  assign {m4_r, m3_r, m2_r, m1_r, m0_r} = {mr[4], mr[3], mr[2], mr[1], mr[0]};
  assign {m4_b, m3_b, m2_b, m1_b, m0_b} = {mb[4], mb[3], mb[2], mb[1], mb[0]};
  assign {m4_ar_ready, m3_ar_ready, m2_ar_ready, m1_ar_ready, m0_ar_ready} = mar_ready;
  assign {m4_aw_ready, m3_aw_ready, m2_aw_ready, m1_aw_ready, m0_aw_ready} = maw_ready;
  assign {m4_w_ready, m3_w_ready, m2_w_ready, m1_w_ready, m0_w_ready} = mw_ready;

  function automatic logic [2:0] next_master(input logic [2:0] m);
    next_master = m == 3'd4 ? 3'd0 : m + 3'd1;
  endfunction

  function automatic logic [2:0] pick(input logic [4:0] req, input logic [2:0] first);
    logic [2:0] m;
    m = first;
    pick = NO_OWNER;
    for (int i = 0; i < 5; i++) begin
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

  for (genvar m = 0; m < 5; m++) begin : g_decode
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

  for (genvar s = 0; s < 2; s++) begin : g_slave
    assign r_pick[s] = pick(ar_req[s] & ~r_reserved, rr[s]);
    assign w_pick[s] = pick(aw_req[s] & ~w_reserved, rw[s]);

    // Lock the owner before asserting downstream VALID, including while
    // READY is low. The originating master holds the address payload.
    axi4_ar_t ar;
    assign ar = rd[s] == Address ? mar[ro[s]] : '0;
    axi4_aw_t aw;
    assign aw = wr[s] == Address ? maw[wo[s]] : '0;
    axi4_w_t w;
    assign w = wr[s] == Data ? mw[wo[s]] : '0;
    axi4_r_t r;
    assign r = sr[s];
    axi4_b_t b;
    assign b = sb[s];
    assign sar[s] = ar;
    assign saw[s] = aw;
    assign sw[s] = w;
    assign sr_ready[s] = rd[s] == Data && mrr[ro[s]];
    assign sb_ready[s] = wr[s] == Response && mbr[wo[s]];

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
          if (ar.valid && sar_ready[s]) begin
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
          if (aw.valid && saw_ready[s]) begin
            rw[s] <= next_master(wo[s]);
            wr[s] <= Data;
          end
          Data: if (w.valid && w.last && sw_ready[s]) wr[s] <= Response;
          Response: if (b.valid && sb_ready[s]) wr[s] <= Idle;
          default: wr[s] <= Idle;
        endcase
      end
    end
  end

  for (genvar m = 0; m < 5; m++) begin : g_return
    localparam logic [2:0] Master = 3'(m);
    logic r0;
    assign r0 = ro[0] == Master;
    logic r1;
    assign r1 = ro[1] == Master;
    logic w0;
    assign w0 = wo[0] == Master;
    logic w1;
    assign w1 = wo[1] == Master;
    assign mar_ready[m] = (r0 && rd[0] == Address && sar_ready[0]) ||
                          (r1 && rd[1] == Address && sar_ready[1]);
    assign maw_ready[m] = (w0 && wr[0] == Address && saw_ready[0]) ||
                          (w1 && wr[1] == Address && saw_ready[1]);
    assign mw_ready[m] = (w0 && wr[0] == Data && sw_ready[0]) ||
                         (w1 && wr[1] == Data && sw_ready[1]);
    assign mr[m] = (r0 && rd[0] == Data) ? sr[0] : (r1 && rd[1] == Data) ? sr[1] : '0;
    assign mb[m] = (w0 && wr[0] == Response) ? sb[0] : (w1 && wr[1] == Response) ? sb[1] : '0;
  end
endmodule
