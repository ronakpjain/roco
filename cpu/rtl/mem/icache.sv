// Direct-mapped instruction cache with a streaming fetch port.
//
// The IF stage presents one address per cycle. A hit produces a
// registered response in the following cycle (data comes from the
// synchronous data RAM read of the presented address), so the fetch
// stream can sustain one instruction per cycle. A miss stalls the fetch
// with cpu_busy while the line is filled; the IF retries the same
// address afterwards. FENCE.I clears all valid bits.

`default_nettype none

module icache #(
    parameter int LINE_WORDS = 4,
    parameter int NUM_LINES = 128
) (
  input logic clk,
  input logic rst,
  input logic flush,
  /* Streaming fetch port. */
  input logic cpu_req,
  input logic [31:0] cpu_addr,
  output logic cpu_rsp_valid,
  output logic [31:0] cpu_rsp_addr,
  output logic [31:0] cpu_rsp_data,
  output logic cpu_miss,
  output logic cpu_busy,
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

  typedef enum logic [1:0] {
    S_IDLE,
    S_REQ,
    S_FILL
  } state_t;

  state_t state;
  logic [31:0] data_ram[0:DEPTH-1];
  logic [TAG_BITS-1:0] tag_ram[0:NUM_LINES-1];
  logic valid_ram[0:NUM_LINES-1];

  logic rsp_valid_q;
  logic [31:0] rsp_addr_q;
  logic [22:0] fill_word_addr;
  logic [IDX_BITS-1:0] fill_idx;
  logic [TAG_BITS-1:0] fill_tag;
  logic [OFF_BITS-1:0] beat;
  logic flush_pending;
  logic [31:0] ram_data;
  logic [IDX_BITS+OFF_BITS-1:0] ram_raddr;
  logic lu_hit;
  integer i;

  assign ram_raddr = {cpu_addr[IDX_HI:IDX_LO], cpu_addr[OFF_BITS+1:2]};
  assign lu_hit = valid_ram[cpu_addr[IDX_HI:IDX_LO]] &&
                  (tag_ram[cpu_addr[IDX_HI:IDX_LO]] == cpu_addr[31:IDX_HI+1]);

  always_ff @(posedge clk) begin
    ram_data <= data_ram[ram_raddr];
  end

  assign cpu_rsp_valid = rsp_valid_q;
  assign cpu_rsp_addr = rsp_addr_q;
  assign cpu_rsp_data = ram_data;
  assign cpu_miss = cpu_req && (state == S_IDLE) && !lu_hit;
  assign cpu_busy = (state != S_IDLE);
  assign hit_pulse = cpu_req && (state == S_IDLE) && lu_hit;
  assign miss_pulse = cpu_miss;

  assign mem_req = (state == S_REQ);
  assign mem_we = 1'b0;
  assign mem_word_addr = fill_word_addr;
  assign mem_len = 4'(LINE_WORDS - 1);
  assign mem_wvalid = 1'b0;
  assign mem_wdata = 32'd0;
  assign mem_wbe = 4'd0;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE;
      rsp_valid_q <= 1'b0;
      rsp_addr_q <= '0;
      fill_word_addr <= '0;
      fill_idx <= '0;
      fill_tag <= '0;
      beat <= '0;
      flush_pending <= 1'b0;
      for (i = 0; i < NUM_LINES; i = i + 1) begin
        valid_ram[i] <= 1'b0;
      end
    end else begin
      rsp_valid_q <= 1'b0;
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
            if (lu_hit) begin
              rsp_valid_q <= 1'b1;
              rsp_addr_q <= cpu_addr;
            end else begin
              fill_word_addr <= cpu_addr[24:2] & LINE_MASK;
              fill_idx <= cpu_addr[IDX_HI:IDX_LO];
              fill_tag <= cpu_addr[31:IDX_HI+1];
              state <= S_REQ;
            end
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
            data_ram[{fill_idx, beat}] <= mem_rdata;
            if (mem_rlast) begin
              if (flush || flush_pending) begin
                valid_ram[fill_idx] <= 1'b0;
                flush_pending <= 1'b0;
              end else begin
                tag_ram[fill_idx] <= fill_tag;
                valid_ram[fill_idx] <= 1'b1;
              end
              state <= S_IDLE;
            end else begin
              beat <= beat + 1'b1;
            end
          end
        end
        default: begin
          state <= S_IDLE;
        end
      endcase
    end
  end

endmodule
