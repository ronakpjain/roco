// Direct-mapped instruction cache.
//
// One line is LINE_WORDS 32-bit words; misses fill the whole line with a
// single burst from the memory arbiter. The CPU request is held until a
// response is produced, and the response echoes the request address so
// that a redirected fetch can discard a stale line.
//
// FENCE.I is handled with `flush`: all valid bits are cleared, an
// in-flight fill is allowed to finish but does not revalidate its line.

`default_nettype none

module icache #(
    parameter int LINE_WORDS = 4,
    parameter int NUM_LINES = 128
) (
  input logic clk,
  input logic rst,
  input logic flush,
  /* CPU side: hold req until rsp. */
  input logic cpu_req,
  input logic [31:0] cpu_addr,
  output logic cpu_rsp,
  output logic [31:0] cpu_rsp_addr,
  output logic [31:0] cpu_rsp_data,
  /* Memory side. */
  output logic mem_req,
  output logic mem_we,
  output logic [22:0] mem_word_addr,
  output logic [3:0] mem_len,
  input logic mem_ready,
  output logic mem_wvalid,
  input logic mem_wready,
  output logic [31:0] mem_wdata,
  output logic [3:0] mem_wbe,
  input logic mem_rvalid,
  input logic [31:0] mem_rdata,
  input logic mem_rlast,
  /* Performance counters. */
  output logic hit_pulse,
  output logic miss_pulse
);

  localparam int OFF_BITS = $clog2(LINE_WORDS);
  localparam int IDX_BITS = $clog2(NUM_LINES);
  localparam int TAG_BITS = 32 - IDX_BITS - OFF_BITS - 2;
  localparam int DEPTH = NUM_LINES * LINE_WORDS;
  localparam int IDX_LO = OFF_BITS + 2;
  localparam int IDX_HI = IDX_LO + IDX_BITS - 1;
  localparam logic [22:0] LINE_MASK = ~23'(LINE_WORDS - 1);

  typedef enum logic [2:0] {
    S_IDLE,
    S_LOOK,
    S_REQ,
    S_FILL,
    S_RESP
  } state_t;

  state_t state;
  logic [31:0] req_addr;
  logic [22:0] req_line_word;
  logic [OFF_BITS-1:0] req_off;
  logic [IDX_BITS-1:0] req_idx;
  logic [TAG_BITS-1:0] req_tag;
  logic [OFF_BITS-1:0] beat;
  logic [31:0] fill_word;
  logic [31:0] resp_data;
  logic flush_pending;

  logic [31:0] data_ram[0:DEPTH-1];
  logic [TAG_BITS-1:0] tag_ram[0:NUM_LINES-1];
  logic valid_ram[0:NUM_LINES-1];

  logic [31:0] ram_rdata;
  logic [IDX_BITS+OFF_BITS-1:0] ram_raddr;
  integer i;

  assign req_off = req_addr[OFF_BITS+1:2];
  assign req_idx = req_addr[IDX_HI:IDX_LO];
  assign req_tag = req_addr[31:IDX_HI+1];

  always_comb begin
    ram_raddr = {req_idx, req_off};
    if (state == S_IDLE) begin
      ram_raddr = {cpu_addr[IDX_HI:IDX_LO], cpu_addr[OFF_BITS+1:2]};
    end
  end

  always_ff @(posedge clk) begin
    ram_rdata <= data_ram[ram_raddr];
    if (state == S_FILL && mem_rvalid) begin
      data_ram[{req_idx, beat}] <= mem_rdata;
    end
  end

  assign mem_req = (state == S_REQ);
  assign mem_we = 1'b0;
  assign mem_word_addr = req_line_word;
  assign mem_len = 4'(LINE_WORDS - 1);
  assign mem_wvalid = 1'b0;
  assign mem_wdata = 32'd0;
  assign mem_wbe = 4'd0;

  assign hit_pulse = (state == S_LOOK) && valid_ram[req_idx] && (tag_ram[req_idx] == req_tag);
  assign miss_pulse = (state == S_LOOK) && !(valid_ram[req_idx] && (tag_ram[req_idx] == req_tag));

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE;
      req_addr <= '0;
      req_line_word <= '0;
      beat <= '0;
      fill_word <= '0;
      resp_data <= '0;
      flush_pending <= 1'b0;
      cpu_rsp <= 1'b0;
      cpu_rsp_addr <= '0;
      cpu_rsp_data <= '0;
      for (i = 0; i < NUM_LINES; i = i + 1) begin
        valid_ram[i] <= 1'b0;
      end
    end else begin
      cpu_rsp <= 1'b0;
      if (flush) begin
        for (i = 0; i < NUM_LINES; i = i + 1) begin
          valid_ram[i] <= 1'b0;
        end
        flush_pending <= 1'b1;
      end else if (state == S_IDLE) begin
        flush_pending <= 1'b0;
      end

      case (state)
        S_IDLE: begin
          if (cpu_req) begin
            req_addr <= cpu_addr;
            req_line_word <= cpu_addr[24:2] & LINE_MASK;
            state <= S_LOOK;
          end
        end
        S_LOOK: begin
          if (valid_ram[req_idx] && (tag_ram[req_idx] == req_tag)) begin
            resp_data <= ram_rdata;
            state <= S_RESP;
          end else begin
            state <= S_REQ;
          end
        end
        S_REQ: begin
          if (mem_ready) begin
            beat <= '0;
            state <= S_FILL;
          end
        end
        S_FILL: begin
          if (mem_rvalid) begin
            if (mem_rlast) begin
              if (flush || flush_pending) begin
                valid_ram[req_idx] <= 1'b0;
                flush_pending <= 1'b0;
              end else begin
                tag_ram[req_idx] <= req_tag;
                valid_ram[req_idx] <= 1'b1;
              end
              resp_data <= (beat == req_off) ? mem_rdata : fill_word;
              state <= S_RESP;
            end else begin
              if (beat == req_off) begin
                fill_word <= mem_rdata;
              end
              beat <= beat + 1'b1;
            end
          end
        end
        S_RESP: begin
          cpu_rsp <= 1'b1;
          cpu_rsp_addr <= req_addr;
          cpu_rsp_data <= resp_data;
          state <= S_IDLE;
        end
        default: begin
          state <= S_IDLE;
        end
      endcase
    end
  end

endmodule
