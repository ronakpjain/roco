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
`ifdef ROCO_FETCH_PROTOCOL_CHECKS
  input logic [22:0] formal_watch_word,
  input logic [31:0] formal_watch_data,
  input logic formal_filling,
  input logic [22:0] formal_ram_addr,
`endif
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
  /* Memory side: read-only, the instruction cache never writes. */
  output logic mem_req,
  output logic [22:0] mem_word_addr,
  output logic [3:0] mem_len,
  input logic mem_ready,
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
  (* ram_style = "distributed" *) logic [TAG_BITS-1:0] tag_ram[0:NUM_LINES-1];
  logic valid_ram[0:NUM_LINES-1];

  logic lookup_pending;
  logic tag_valid_q;
  logic [TAG_BITS-1:0] tag_data_q, requested_tag_q;
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
  // Read tags with the data, then compare after the register boundary.
  // Hit responses retain their one-cycle latency. A miss is reported with
  // that request's response address; the next speculative request is not
  // accepted while the miss is being recognized.
  assign lu_hit = tag_valid_q && (tag_data_q == requested_tag_q);
  always_ff @(posedge clk) begin
    tag_valid_q <= valid_ram[cpu_addr[IDX_HI:IDX_LO]];
    tag_data_q <= tag_ram[cpu_addr[IDX_HI:IDX_LO]];
    requested_tag_q <= cpu_addr[31:IDX_HI+1];
  end
  always_ff @(posedge clk or posedge rst) begin
    if (rst) lookup_pending <= 1'b0;
    else lookup_pending <= cpu_req && (state == S_IDLE) && !cpu_miss && !flush;
  end

  always_ff @(posedge clk) begin
    ram_data <= data_ram[ram_raddr];
  end

  assign cpu_rsp_valid = lookup_pending && lu_hit;
  assign cpu_rsp_addr = rsp_addr_q;
  assign cpu_rsp_data = ram_data;
  assign cpu_miss = lookup_pending && !lu_hit;
  assign cpu_busy = (state != S_IDLE) || cpu_miss || flush;
  assign hit_pulse = cpu_rsp_valid;
  assign miss_pulse = cpu_miss;

  assign mem_req = (state == S_REQ);
  assign mem_word_addr = fill_word_addr;
  assign mem_len = 4'(LINE_WORDS - 1);

  // Response validity and the miss state publish these payloads. Capture
  // them before the late TLB/cache hit decision, so that decision controls
  // only narrow state bits rather than address-register enables.
  always_ff @(posedge clk) begin
    rsp_addr_q <= cpu_addr;
    if (state == S_IDLE) begin
      fill_word_addr <= rsp_addr_q[24:2] & LINE_MASK;
      fill_idx <= rsp_addr_q[IDX_HI:IDX_LO];
      fill_tag <= rsp_addr_q[31:IDX_HI+1];
    end
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      state <= S_IDLE;
      beat <= '0;
      flush_pending <= 1'b0;
      for (i = 0; i < NUM_LINES; i = i + 1) begin
        valid_ram[i] <= 1'b0;
      end
    end else begin
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
          if (cpu_miss) state <= S_REQ;
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
                valid_ram[fill_idx] <= 1'b0;
                flush_pending <= 1'b0;
              end else begin
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

  // Tag and data RAM carry no reset value. A line is only observable once
  // its valid bit is set in the state machine above, so both arrays stay out
  // of the asynchronous reset cone and remain block RAM.
  always_ff @(posedge clk) begin
    if ((state == S_FILL) && mem_rvalid) begin
      data_ram[{fill_idx, beat}] <= mem_rdata;
      if (mem_rlast && !(flush || flush_pending)) begin
        tag_ram[fill_idx] <= fill_tag;
      end
    end
  end

`ifdef ROCO_SOC_RAM_FORMAL
  always_ff @(posedge clk) begin
    if (!rst && state == S_REQ) assert ((fill_word_addr & LINE_MASK) == fill_word_addr);
  end
`endif

`ifdef ROCO_SOC_FENCE_FORMAL
  (* anyconst *) logic [IDX_BITS-1:0] f_flush_line;
  logic f_flush_past;
  initial f_flush_past = 1'b0;
  always_ff @(posedge clk) begin
    f_flush_past <= 1'b1;
    if (!rst && flush_pending) begin
      assert (!valid_ram[f_flush_line]);
      assert (!cpu_rsp_valid);
    end
    if (f_flush_past && !rst && !$past(rst) && $past(flush)) begin
      assert (!valid_ram[f_flush_line]);
      assert (!cpu_rsp_valid);
    end
  end
`endif

`ifdef ROCO_FETCH_PROTOCOL_CHECKS
  `include "icache_backing_checks.svh"
`endif
`ifdef ROCO_ICACHE_FORMAL
  `include "icache_checks.svh"
`endif
endmodule
