// Direct-mapped write-back data cache.
//
// Each line is LINE_WORDS words with one dirty bit. A store hit updates
// the line through the byte-enable write port and marks the line dirty;
// a store miss allocates the line (fetch first, then merge the bytes),
// so partial-word stores never write back fabricated data. Misses
// write back a dirty victim before filling the new line.
//
// The data array is split into four byte-lane memories so that ECP5
// block RAMs can implement byte enables directly.

`default_nettype none

module dcache #(
    parameter int LINE_WORDS = 4,
    parameter int NUM_LINES = 256
) (
  input logic clk,
  input logic rst,
  /* CPU side: hold req until rsp. */
  input logic cpu_req,
  input logic cpu_we,
  input logic [31:0] cpu_addr,
  input logic [31:0] cpu_wdata,
  input logic [3:0] cpu_be,
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
  localparam logic [OFF_BITS-1:0] LAST_BEAT = OFF_BITS'(LINE_WORDS - 1);

  typedef enum logic [3:0] {
    S_IDLE,
    S_LOOK,
    S_STORE,
    S_RESP,
    S_WB_REQ,
    S_WB_RD,
    S_WB_WR,
    S_FILL_REQ,
    S_FILL,
    S_STORE_FILL
  } state_t;

  state_t state;
  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0] req_be;
  logic req_we;
  logic [22:0] req_line_word;
  logic [OFF_BITS-1:0] req_off;
  logic [IDX_BITS-1:0] req_idx;
  logic [TAG_BITS-1:0] req_tag;
  logic [OFF_BITS-1:0] beat;
  logic [31:0] fill_word;
  logic [31:0] resp_data;
  logic [22:0] victim_word;

  logic valid_ram[0:NUM_LINES-1];
  logic dirty_ram[0:NUM_LINES-1];
  logic [TAG_BITS-1:0] tag_ram[0:NUM_LINES-1];

  logic [7:0] lane0[0:DEPTH-1];
  logic [7:0] lane1[0:DEPTH-1];
  logic [7:0] lane2[0:DEPTH-1];
  logic [7:0] lane3[0:DEPTH-1];

  logic [31:0] ram_rdata;
  logic ram_we;
  logic [IDX_BITS+OFF_BITS-1:0] ram_waddr;
  logic [31:0] ram_wdata;
  logic [3:0] ram_wbe;
  logic [IDX_BITS+OFF_BITS-1:0] ram_raddr;
  logic [31:0] victim_byte;
  logic cache_hit;
  integer i;

  assign req_off = req_addr[OFF_BITS+1:2];
  assign req_idx = req_addr[IDX_HI:IDX_LO];
  assign req_tag = req_addr[31:IDX_HI+1];
  assign victim_byte = {tag_ram[req_idx], req_idx, {(OFF_BITS + 2) {1'b0}}};
  assign victim_word = victim_byte[24:2];
  assign cache_hit = valid_ram[req_idx] && (tag_ram[req_idx] == req_tag);

  assign hit_pulse = (state == S_LOOK) && cache_hit;
  assign miss_pulse = (state == S_LOOK) && !cache_hit;

  always_comb begin
    ram_raddr = {req_idx, req_off};
    if (state == S_IDLE) begin
      ram_raddr = {cpu_addr[IDX_HI:IDX_LO], cpu_addr[OFF_BITS+1:2]};
    end else if (state == S_WB_RD) begin
      ram_raddr = {req_idx, beat};
    end
  end

  always_ff @(posedge clk) begin
    ram_rdata <= {lane3[ram_raddr], lane2[ram_raddr], lane1[ram_raddr], lane0[ram_raddr]};
  end

  always_comb begin
    ram_we = 1'b0;
    ram_waddr = {req_idx, req_off};
    ram_wdata = req_wdata;
    ram_wbe = req_be;
    case (state)
      S_STORE: begin
        ram_we = 1'b1;
      end
      S_STORE_FILL: begin
        ram_we = 1'b1;
      end
      S_FILL: begin
        if (mem_rvalid) begin
          ram_we = 1'b1;
          ram_waddr = {req_idx, beat};
          ram_wdata = mem_rdata;
          ram_wbe = 4'hf;
        end
      end
      default: begin
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (ram_we) begin
      if (ram_wbe[0]) begin
        lane0[ram_waddr] <= ram_wdata[7:0];
      end
      if (ram_wbe[1]) begin
        lane1[ram_waddr] <= ram_wdata[15:8];
      end
      if (ram_wbe[2]) begin
        lane2[ram_waddr] <= ram_wdata[23:16];
      end
      if (ram_wbe[3]) begin
        lane3[ram_waddr] <= ram_wdata[31:24];
      end
    end
  end

  assign mem_req = (state == S_WB_REQ) || (state == S_FILL_REQ);
  assign mem_we = (state == S_WB_REQ);
  assign mem_word_addr = (state == S_WB_REQ) ? victim_word : req_line_word;
  assign mem_len = 4'(LINE_WORDS - 1);
  assign mem_wvalid = (state == S_WB_WR);
  assign mem_wdata = ram_rdata;
  assign mem_wbe = 4'hf;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE;
      req_addr <= '0;
      req_wdata <= '0;
      req_be <= '0;
      req_we <= 1'b0;
      req_line_word <= '0;
      beat <= '0;
      fill_word <= '0;
      resp_data <= '0;
      cpu_rsp <= 1'b0;
      cpu_rsp_addr <= '0;
      cpu_rsp_data <= '0;
      for (i = 0; i < NUM_LINES; i = i + 1) begin
        valid_ram[i] <= 1'b0;
        dirty_ram[i] <= 1'b0;
      end
    end else begin
      cpu_rsp <= 1'b0;
      case (state)
        S_IDLE: begin
          if (cpu_req) begin
            req_addr <= cpu_addr;
            req_we <= cpu_we;
            req_wdata <= cpu_wdata;
            req_be <= cpu_be;
            req_line_word <= cpu_addr[24:2] & LINE_MASK;
            state <= S_LOOK;
          end
        end
        S_LOOK: begin
          if (cache_hit) begin
            if (req_we) begin
              state <= S_STORE;
            end else begin
              resp_data <= ram_rdata;
              state <= S_RESP;
            end
          end else if (dirty_ram[req_idx]) begin
            state <= S_WB_REQ;
          end else begin
            state <= S_FILL_REQ;
          end
        end
        S_STORE: begin
          dirty_ram[req_idx] <= 1'b1;
          state <= S_RESP;
        end
        S_RESP: begin
          cpu_rsp <= 1'b1;
          cpu_rsp_addr <= req_addr;
          cpu_rsp_data <= req_we ? 32'd0 : resp_data;
          state <= S_IDLE;
        end
        S_WB_REQ: begin
          if (mem_ready) begin
            beat <= '0;
            state <= S_WB_RD;
          end
        end
        S_WB_RD: begin
          state <= S_WB_WR;
        end
        S_WB_WR: begin
          if (mem_wready) begin
            if (beat == LAST_BEAT) begin
              dirty_ram[req_idx] <= 1'b0;
              state <= S_FILL_REQ;
            end else begin
              beat <= beat + 1'b1;
              state <= S_WB_RD;
            end
          end
        end
        S_FILL_REQ: begin
          if (mem_ready) begin
            beat <= '0;
            state <= S_FILL;
          end
        end
        S_FILL: begin
          if (mem_rvalid) begin
            if (mem_rlast) begin
              tag_ram[req_idx] <= req_tag;
              valid_ram[req_idx] <= 1'b1;
              if (req_we) begin
                dirty_ram[req_idx] <= 1'b1;
                state <= S_STORE_FILL;
              end else begin
                resp_data <= (beat == req_off) ? mem_rdata : fill_word;
                state <= S_RESP;
              end
            end else begin
              if (beat == req_off) begin
                fill_word <= mem_rdata;
              end
              beat <= beat + 1'b1;
            end
          end
        end
        S_STORE_FILL: begin
          state <= S_RESP;
        end
        default: begin
          state <= S_IDLE;
        end
      endcase
    end
  end

endmodule
