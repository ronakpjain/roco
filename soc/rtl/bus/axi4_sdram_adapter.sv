// AXI4 slave adapter for the non-backpressurable SDRAM controller.
// Supports aligned 32-bit INCR bursts of up to 16 beats within one SDRAM
// row. Unsupported requests complete with SLVERR without touching SDRAM.
`include "axi4_defs.svh"
`default_nettype none

module axi4_sdram_adapter (
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
  output logic req_valid,
  input logic req_ready,
  output logic req_we,
  output logic [22:0] req_word_addr,
  output logic [3:0] req_len,
  output logic wvalid,
  input logic wready,
  output logic [31:0] wdata,
  output logic [3:0] wbe,
  input logic rvalid,
  input logic [31:0] rdata
);
  typedef enum logic [2:0] {
    Idle,
    Issue,
    Read,
    Write,
    WriteDrain,
    Reply
  } state_t;
  state_t state;
  logic prefer_write, write_q, error_q;
  logic [3:0] id_q;
  logic [7:0] len_q, beat;
  logic [22:0] addr_q;
  logic [4:0] captured;
  logic [31:0] read_buf[16];
  axi4_r_t r_payload;
  axi4_b_t b_payload;

  function automatic logic supported(input logic [31:0] addr, input logic [7:0] len,
                                     input logic [2:0] size, input logic [1:0] burst);
    logic [8:0] last_col;
    last_col = {1'b0, addr[9:2]} + {1'b0, len};
    supported = addr[31:25] == 7'd8 && addr[1:0] == 0 && size == 3'd2 &&
                burst == `AXI4_BURST_INCR && len < 8'd16 && !last_col[8];
  endfunction

  assign ar_ready = state == Idle && (!aw.valid || !prefer_write);
  assign aw_ready = state == Idle && (!ar.valid || prefer_write);
  assign req_valid = state == Issue;
  assign req_we = write_q;
  assign req_word_addr = addr_q;
  assign req_len = len_q[3:0];
  assign wvalid = state == Write && !error_q && w.valid;
  assign w_ready = state == Write && (error_q || wready);
  assign wdata = w.data;
  assign wbe = w.strb;
  assign r = r_payload;
  assign b = b_payload;
  assign r_payload.valid = state == Read && (error_q || {1'b0, beat} < {4'b0, captured});
  assign r_payload.id = id_q;
  assign r_payload.resp = error_q ? `AXI4_RESP_SLVERR : `AXI4_RESP_OKAY;
  assign r_payload.last = beat == len_q;
  assign r_payload.data = error_q ? '0 : read_buf[beat[3:0]];
  assign b_payload.valid = state == Reply;
  assign b_payload.id = id_q;
  assign b_payload.resp = error_q ? `AXI4_RESP_SLVERR : `AXI4_RESP_OKAY;

  // The controller can send a whole burst while AXI RREADY is low. Keep
  // all 16 words and expose only entries that have already been written.
  always_ff @(posedge clk) begin
    if (state == Read && !error_q && rvalid) read_buf[captured[3:0]] <= rdata;
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      state <= Idle;
      prefer_write <= 1'b0;
      write_q <= 1'b0;
      error_q <= 1'b0;
      id_q <= '0;
      len_q <= '0;
      beat <= '0;
      addr_q <= '0;
      captured <= '0;
    end else begin
      case (state)
        Idle: begin
          beat <= '0;
          captured <= '0;
          if (ar.valid && ar_ready) begin
            prefer_write <= 1'b1;
            write_q <= 1'b0;
            id_q <= ar.id;
            len_q <= ar.len;
            addr_q <= ar.addr[24:2];
            error_q <= !supported(ar.addr, ar.len, ar.size, ar.burst);
            state <= supported(ar.addr, ar.len, ar.size, ar.burst) ? Issue : Read;
          end else if (aw.valid && aw_ready) begin
            prefer_write <= 1'b0;
            write_q <= 1'b1;
            id_q <= aw.id;
            len_q <= aw.len;
            addr_q <= aw.addr[24:2];
            error_q <= !supported(aw.addr, aw.len, aw.size, aw.burst);
            state <= supported(aw.addr, aw.len, aw.size, aw.burst) ? Issue : Write;
          end
        end
        Issue: if (req_ready) state <= write_q ? Write : Read;
        Read: begin
          if (rvalid && !error_q) captured <= captured + 5'd1;
          if (r_payload.valid && r_ready) begin
            if (r_payload.last) state <= Idle;
            else beat <= beat + 8'd1;
          end
        end
        Write:
        if (w.valid && w_ready) begin
          if (beat == len_q) state <= error_q ? Reply : WriteDrain;
          else beat <= beat + 8'd1;
        end
        // A controller W handshake accepts a 32-bit word before its
        // second halfword reaches SDRAM. Wait for controller completion.
        WriteDrain: if (req_ready) state <= Reply;
        Reply: if (b_ready) state <= Idle;
        default: state <= Idle;
      endcase
    end
  end
endmodule

`default_nettype wire
