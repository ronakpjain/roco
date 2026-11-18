// Connect a cache/boot memory port to AXI4. The client holds its request
// through address acceptance and consumes read data without backpressure.
// The client considers writes done on the final W beat; keep the port
// reserved until B so its next transaction cannot overtake that write.
`include "axi4_defs.svh"
`default_nettype none

module axi4_mem_master (
  input logic clk,
  rst,
  input logic req,
  we,
  input logic [31:0] addr,
  input logic [3:0] len,
  output logic ready,
  input logic wvalid,
  output logic wready,
  input logic [31:0] wdata,
  input logic [3:0] wbe,
  output logic rvalid,
  output logic [31:0] rdata,
  output logic rlast,
  output logic write_done,
  output axi4_ar_t ar,
  input logic ar_ready,
  input axi4_r_t r,
  output logic r_ready,
  output axi4_aw_t aw,
  input logic aw_ready,
  output axi4_w_t w,
  input logic w_ready,
  input axi4_b_t b,
  output logic b_ready
);
  typedef enum logic [1:0] {
    Idle,
    Read,
    Write,
    Reply
  } state_t;
  state_t state;
  logic [3:0] remaining;
  axi4_ar_t ar_payload;
  axi4_aw_t aw_payload;
  axi4_w_t w_payload;
  assign ar = ar_payload;
  assign aw = aw_payload;
  assign w = w_payload;
  assign ar_payload = {
    state == Idle && req && !we, 4'd0, addr, 4'd0, len, 3'd2, `AXI4_BURST_INCR, 3'd0
  };
  assign aw_payload = {
    state == Idle && req && we, 4'd0, addr, 4'd0, len, 3'd2, `AXI4_BURST_INCR, 3'd0
  };
  assign w_payload = {state == Write && wvalid, wdata, wbe, remaining == 0};
  assign ready = state == Idle && (we ? aw_ready : ar_ready);
  assign wready = state == Write && w_ready;
  assign r_ready = state == Read;
  assign rvalid = state == Read && r.valid;
  assign rdata = r.resp == `AXI4_RESP_OKAY ? r.data : 32'd0;
  assign rlast = r.last;
  assign b_ready = state == Reply;
  assign write_done = state == Reply && b.valid;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      state <= Idle;
      remaining <= '0;
    end else begin
      case (state)
        Idle:
        if (req && ready) begin
          remaining <= len;
          if (we) state <= Write;
          else state <= Read;
        end
        Read: if (rvalid && rlast) state <= Idle;
        Write:
        if (wvalid && wready) begin
          if (remaining == 0) state <= Reply;
          else remaining <= remaining - 4'd1;
        end
        Reply: if (write_done) state <= Idle;
        default: state <= Idle;
      endcase
    end
  end
endmodule
