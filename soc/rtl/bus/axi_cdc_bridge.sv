// Single-outstanding AXI4 clock-domain-crossing bridge.
//
// Carries the SDRAM slave port from the core clock (slow, e.g. 48 MHz) to
// the memory clock (fast, e.g. 96 MHz). The upstream crossbar guarantees
// at most one read owner and one write owner per slave, so one handshake
// slot per AXI channel is sufficient; multi-beat W/R bursts cross one
// beat per handshake. IDs, bursts and responses pass through unchanged.
//
// Handshake: the source holds its payload and toggles REQ; the sink
// double-flops REQ, consumes the stable payload, then toggles ACK back.
// Both toggles reset to zero so no edge is invented across reset. The two
// clocks may be phase-aligned 2:1 or fully asynchronous.
`include "axi4_defs.svh"
`default_nettype none

module axi_cdc_bridge (
  // Slow (core) side: slave facing the crossbar.
  input logic clk_s,
  input logic rst_s,
  input axi4_ar_t s_ar,
  output logic s_ar_ready,
  output axi4_r_t s_r,
  input logic s_r_ready,
  input axi4_aw_t s_aw,
  output logic s_aw_ready,
  input axi4_w_t s_w,
  output logic s_w_ready,
  output axi4_b_t s_b,
  input logic s_b_ready,
  // Fast (memory) side: master facing the SDRAM adapter.
  input logic clk_f,
  input logic rst_f,
  output axi4_ar_t m_ar,
  input logic m_ar_ready,
  input axi4_r_t m_r,
  output logic m_r_ready,
  output axi4_aw_t m_aw,
  input logic m_aw_ready,
  output axi4_w_t m_w,
  input logic m_w_ready,
  input axi4_b_t m_b,
  output logic m_b_ready
);
  // Slow->fast request channels (AR/AW): payload latched in slow domain,
  // toggled across, presented in fast domain until accepted.
  logic ar_s_req, ar_s_ack_q, ar_s_ack_sync0, ar_s_ack_sync1;
  axi4_ar_t ar_s_payload;
  logic ar_s_busy;
  logic ar_f_req_sync0, ar_f_req_sync1, ar_f_seen;
  axi4_ar_t ar_f_payload;
  logic ar_f_valid, ar_f_ack;
  logic aw_s_req, aw_s_ack_q, aw_s_ack_sync0, aw_s_ack_sync1;
  axi4_aw_t aw_s_payload;
  logic aw_s_busy;
  logic aw_f_req_sync0, aw_f_req_sync1, aw_f_seen;
  axi4_aw_t aw_f_payload;
  logic aw_f_valid, aw_f_ack;

  // Slow->fast write beats: one handshake per W beat.
  logic w_s_req, w_s_ack_sync0, w_s_ack_sync1;
  axi4_w_t w_s_payload;
  logic w_s_busy;
  logic w_f_req_sync0, w_f_req_sync1, w_f_seen;
  axi4_w_t w_f_payload;
  logic w_f_valid, w_f_ack;

  // Fast->slow channels (R/B): payload latched in fast domain.
  logic r_f_req, r_f_ack_sync0, r_f_ack_sync1;
  axi4_r_t r_f_payload;
  logic r_f_busy;
  logic r_s_req_sync0, r_s_req_sync1, r_s_seen;
  axi4_r_t r_s_payload;
  logic r_s_valid, r_s_ack;
  logic b_f_req, b_f_ack_sync0, b_f_ack_sync1;
  axi4_b_t b_f_payload;
  logic b_f_busy;
  logic b_s_req_sync0, b_s_req_sync1, b_s_seen;
  axi4_b_t b_s_payload;
  logic b_s_valid, b_s_ack;

  // ------------------------------------------------ Slow-side sources
  assign s_ar_ready = !ar_s_busy;
  always_ff @(posedge clk_s or posedge rst_s) begin
    if (rst_s) begin
      ar_s_busy <= 1'b0;
      ar_s_req <= 1'b0;
      ar_s_ack_q <= 1'b0;
      ar_s_ack_sync0 <= 1'b0;
      ar_s_ack_sync1 <= 1'b0;
    end else begin
      ar_s_ack_sync0 <= ar_f_ack;
      ar_s_ack_sync1 <= ar_s_ack_sync0;
      if (!ar_s_busy && s_ar.valid) begin
        ar_s_payload <= s_ar;
        ar_s_busy <= 1'b1;
        ar_s_req <= ~ar_s_req;
      end else if (ar_s_busy && (ar_s_ack_sync1 != ar_s_ack_q)) begin
        ar_s_ack_q <= ar_s_ack_sync1;
        ar_s_busy <= 1'b0;
      end
    end
  end

  assign s_aw_ready = !aw_s_busy;
  always_ff @(posedge clk_s or posedge rst_s) begin
    if (rst_s) begin
      aw_s_busy <= 1'b0;
      aw_s_req <= 1'b0;
      aw_s_ack_q <= 1'b0;
      aw_s_ack_sync0 <= 1'b0;
      aw_s_ack_sync1 <= 1'b0;
    end else begin
      aw_s_ack_sync0 <= aw_f_ack;
      aw_s_ack_sync1 <= aw_s_ack_sync0;
      if (!aw_s_busy && s_aw.valid) begin
        aw_s_payload <= s_aw;
        aw_s_busy <= 1'b1;
        aw_s_req <= ~aw_s_req;
      end else if (aw_s_busy && (aw_s_ack_sync1 != aw_s_ack_q)) begin
        aw_s_ack_q <= aw_s_ack_sync1;
        aw_s_busy <= 1'b0;
      end
    end
  end

  assign s_w_ready = !w_s_busy;
  always_ff @(posedge clk_s or posedge rst_s) begin
    if (rst_s) begin
      w_s_busy <= 1'b0;
      w_s_req <= 1'b0;
      w_s_ack_sync0 <= 1'b0;
      w_s_ack_sync1 <= 1'b0;
    end else begin
      w_s_ack_sync0 <= w_f_ack;
      w_s_ack_sync1 <= w_s_ack_sync0;
      if (!w_s_busy && s_w.valid) begin
        w_s_payload <= s_w;
        w_s_busy <= 1'b1;
        w_s_req <= ~w_s_req;
      end else if (w_s_busy && (w_s_ack_sync1 == w_s_req)) begin
        w_s_busy <= 1'b0;
      end
    end
  end

  // ------------------------------------------------ Slow-side sinks
  // Gate VALID with the handshake slot so idle links read as no-op.
  assign s_r = r_s_valid ? r_s_payload : '0;
  assign s_b = b_s_valid ? b_s_payload : '0;
  always_ff @(posedge clk_s or posedge rst_s) begin
    if (rst_s) begin
      r_s_req_sync0 <= 1'b0;
      r_s_req_sync1 <= 1'b0;
      r_s_seen <= 1'b0;
      r_s_valid <= 1'b0;
      r_s_payload <= '0;
      r_s_ack <= 1'b0;
    end else begin
      r_s_req_sync0 <= r_f_req;
      r_s_req_sync1 <= r_s_req_sync0;
      if ((r_s_req_sync1 != r_s_seen) && !r_s_valid) begin
        r_s_payload <= r_f_payload;
        r_s_valid <= 1'b1;
      end else if (r_s_valid && s_r_ready) begin
        r_s_valid <= 1'b0;
        r_s_seen <= r_s_req_sync1;
        r_s_ack <= ~r_s_ack;
      end
    end
  end
  // Ack toggle back to fast domain is r_s_ack; continuous assign below via sync.

  always_ff @(posedge clk_s or posedge rst_s) begin
    if (rst_s) begin
      b_s_req_sync0 <= 1'b0;
      b_s_req_sync1 <= 1'b0;
      b_s_seen <= 1'b0;
      b_s_valid <= 1'b0;
      b_s_payload <= '0;
      b_s_ack <= 1'b0;
    end else begin
      b_s_req_sync0 <= b_f_req;
      b_s_req_sync1 <= b_s_req_sync0;
      if ((b_s_req_sync1 != b_s_seen) && !b_s_valid) begin
        b_s_payload <= b_f_payload;
        b_s_valid <= 1'b1;
      end else if (b_s_valid && s_b_ready) begin
        b_s_valid <= 1'b0;
        b_s_seen <= b_s_req_sync1;
        b_s_ack <= ~b_s_ack;
      end
    end
  end

  // ------------------------------------------------ Fast-side sinks (AR/AW/W)
  assign m_ar = ar_f_valid ? ar_f_payload : '0;
  assign m_aw = aw_f_valid ? aw_f_payload : '0;
  assign m_w = w_f_valid ? w_f_payload : '0;
  always_ff @(posedge clk_f or posedge rst_f) begin
    if (rst_f) begin
      ar_f_req_sync0 <= 1'b0;
      ar_f_req_sync1 <= 1'b0;
      ar_f_seen <= 1'b0;
      ar_f_valid <= 1'b0;
      ar_f_payload <= '0;
      ar_f_ack <= 1'b0;
    end else begin
      ar_f_req_sync0 <= ar_s_req;
      ar_f_req_sync1 <= ar_f_req_sync0;
      if ((ar_f_req_sync1 != ar_f_seen) && !ar_f_valid) begin
        ar_f_payload <= ar_s_payload;
        ar_f_valid <= 1'b1;
      end else if (ar_f_valid && m_ar_ready) begin
        ar_f_valid <= 1'b0;
        ar_f_seen <= ar_f_req_sync1;
        ar_f_ack <= ~ar_f_ack;
      end
    end
  end


  always_ff @(posedge clk_f or posedge rst_f) begin
    if (rst_f) begin
      aw_f_req_sync0 <= 1'b0;
      aw_f_req_sync1 <= 1'b0;
      aw_f_seen <= 1'b0;
      aw_f_valid <= 1'b0;
      aw_f_payload <= '0;
      aw_f_ack <= 1'b0;
    end else begin
      aw_f_req_sync0 <= aw_s_req;
      aw_f_req_sync1 <= aw_f_req_sync0;
      if ((aw_f_req_sync1 != aw_f_seen) && !aw_f_valid) begin
        aw_f_payload <= aw_s_payload;
        aw_f_valid <= 1'b1;
      end else if (aw_f_valid && m_aw_ready) begin
        aw_f_valid <= 1'b0;
        aw_f_seen <= aw_f_req_sync1;
        aw_f_ack <= ~aw_f_ack;
      end
    end
  end


  always_ff @(posedge clk_f or posedge rst_f) begin
    if (rst_f) begin
      w_f_req_sync0 <= 1'b0;
      w_f_req_sync1 <= 1'b0;
      w_f_seen <= 1'b0;
      w_f_valid <= 1'b0;
      w_f_payload <= '0;
      w_f_ack <= 1'b0;
    end else begin
      w_f_req_sync0 <= w_s_req;
      w_f_req_sync1 <= w_f_req_sync0;
      if ((w_f_req_sync1 != w_f_seen) && !w_f_valid) begin
        w_f_payload <= w_s_payload;
        w_f_valid <= 1'b1;
      end else if (w_f_valid && m_w_ready) begin
        w_f_valid <= 1'b0;
        w_f_seen <= w_f_req_sync1;
        w_f_ack <= ~w_f_ack;
      end
    end
  end

  // ------------------------------------------------ Fast-side sources (R/B)
  // m_r_ready gates capture: only handshake a beat the slow side can take.
  // The adapter buffers the burst, so holding here applies backpressure.
  logic r_f_can_take;
  assign r_f_can_take = !r_f_busy;
  assign m_r_ready = r_f_can_take;
  always_ff @(posedge clk_f or posedge rst_f) begin
    if (rst_f) begin
      r_f_busy <= 1'b0;
      r_f_req <= 1'b0;
      r_f_ack_sync0 <= 1'b0;
      r_f_ack_sync1 <= 1'b0;
    end else begin
      r_f_ack_sync0 <= r_s_ack;
      r_f_ack_sync1 <= r_f_ack_sync0;
      if (!r_f_busy && m_r.valid) begin
        r_f_payload <= m_r;
        r_f_busy <= 1'b1;
        r_f_req <= ~r_f_req;
      end else if (r_f_busy && (r_f_ack_sync1 == r_f_req)) begin
        r_f_busy <= 1'b0;
      end
    end
  end

  assign m_b_ready = !b_f_busy;
  always_ff @(posedge clk_f or posedge rst_f) begin
    if (rst_f) begin
      b_f_busy <= 1'b0;
      b_f_req <= 1'b0;
      b_f_ack_sync0 <= 1'b0;
      b_f_ack_sync1 <= 1'b0;
    end else begin
      b_f_ack_sync0 <= b_s_ack;
      b_f_ack_sync1 <= b_f_ack_sync0;
      if (!b_f_busy && m_b.valid) begin
        b_f_payload <= m_b;
        b_f_busy <= 1'b1;
        b_f_req <= ~b_f_req;
      end else if (b_f_busy && (b_f_ack_sync1 == b_f_req)) begin
        b_f_busy <= 1'b0;
      end
    end
  end

endmodule
