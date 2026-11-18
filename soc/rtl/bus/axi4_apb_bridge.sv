// Single-transfer AXI4-to-APB4 bridge for the peripheral window.
// Narrow transfers retain AXI byte lanes; APB sees a word-aligned address.
// Bursts are rejected with SLVERR and completed on AXI without APB activity.
`include "axi4_defs.svh"
`default_nettype none

module axi4_apb_bridge (
  input logic clk,
  rst,
  input axi4_ar_t ar,
  output logic ar_ready,
  output axi4_r_t r,
  input logic r_ready,
  input axi4_aw_t aw,
  output logic aw_ready,
  input axi4_w_t w,
  output logic w_ready,
  output axi4_b_t b,
  input logic b_ready,
  output logic psel,
  penable,
  pwrite,
  output logic [31:0] paddr,
  pwdata,
  output logic [3:0] pstrb,
  output logic [2:0] pprot,
  input logic pready,
  pslverr,
  input logic [31:0] prdata
);
  typedef enum logic [2:0] {
    Idle,
    AcceptRead,
    AcceptWrite,
    WriteData,
    Setup,
    Access,
    ReadReply,
    WriteReply
  } state_t;
  state_t state;
  logic prefer_write, error_q;
  logic [3:0] id_q;
  logic [7:0] remaining;
  logic [31:0] read_q;
  axi4_r_t r_payload;
  axi4_b_t b_payload;

  function automatic logic supported(input logic [1:0] low, input logic [2:0] size,
                                     input logic [7:0] len, input logic [1:0] burst);
    supported = len == 0 && (burst == `AXI4_BURST_FIXED || burst == `AXI4_BURST_INCR) &&
                (size == 0 || (size == 1 && !low[0]) || (size == 2 && low == 0));
  endfunction

  assign ar_ready = state == AcceptRead;
  assign aw_ready = state == AcceptWrite;
  assign w_ready = state == WriteData;
  assign psel = state == Setup || state == Access;
  assign penable = state == Access;
  assign r = r_payload;
  assign b = b_payload;
  assign r_payload.valid = state == ReadReply;
  assign r_payload.id = id_q;
  assign r_payload.resp = error_q ? `AXI4_RESP_SLVERR : `AXI4_RESP_OKAY;
  assign r_payload.last = remaining == 0;
  assign r_payload.data = read_q;
  assign b_payload.valid = state == WriteReply;
  assign b_payload.id = id_q;
  assign b_payload.resp = error_q ? `AXI4_RESP_SLVERR : `AXI4_RESP_OKAY;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      state <= Idle;
      prefer_write <= 1'b0;
      error_q <= 1'b0;
      id_q <= '0;
      remaining <= '0;
      read_q <= '0;
      paddr <= '0;
      pprot <= '0;
      pwrite <= 1'b0;
      pwdata <= '0;
      pstrb <= '0;
    end else begin
      case (state)
        Idle: begin
          if (aw.valid && (!ar.valid || prefer_write)) state <= AcceptWrite;
          else if (ar.valid) state <= AcceptRead;
        end
        AcceptRead:
        if (ar.valid) begin
          prefer_write <= 1'b1;
          id_q <= ar.id;
          paddr <= {ar.addr[31:2], 2'b00};
          pprot <= ar.prot;
          pwrite <= 1'b0;
          pstrb <= '0;
          read_q <= '0;
          remaining <= ar.len;
          error_q <= !supported(ar.addr[1:0], ar.size, ar.len, ar.burst);
          if (supported(ar.addr[1:0], ar.size, ar.len, ar.burst)) state <= Setup;
          else state <= ReadReply;
        end
        AcceptWrite:
        if (aw.valid) begin
          prefer_write <= 1'b0;
          id_q <= aw.id;
          paddr <= {aw.addr[31:2], 2'b00};
          pprot <= aw.prot;
          pwrite <= 1'b1;
          remaining <= aw.len;
          error_q <= !supported(aw.addr[1:0], aw.size, aw.len, aw.burst);
          state <= WriteData;
        end
        WriteData:
        if (w.valid) begin
          if (remaining == 0) begin
            pwdata <= w.data;
            pstrb <= w.strb;
            error_q <= error_q || !w.last;
            if (error_q || !w.last) state <= WriteReply;
            else state <= Setup;
          end else remaining <= remaining - 8'd1;
        end
        Setup: state <= Access;
        Access:
        if (pready) begin
          error_q <= pslverr;
          read_q <= prdata;
          if (pwrite) state <= WriteReply;
          else state <= ReadReply;
        end
        ReadReply:
        if (r_ready) begin
          if (remaining == 0) state <= Idle;
          else remaining <= remaining - 8'd1;
        end
        WriteReply: if (b_ready) state <= Idle;
        default: state <= Idle;
      endcase
    end
  end
endmodule
