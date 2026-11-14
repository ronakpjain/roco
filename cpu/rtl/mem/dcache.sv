// Write-back data cache with a lookup-in-EX pipeline.
//
// The EX stage presents the address of a load/store. Tag and data RAM
// reads are registered; tags compare in MEM alongside the returned data,
// so hits need no cache-induced stall. A miss
// stalls MEM while the line is written back and refilled. Registered
// hit/readiness metadata keeps the tag lookup off pipeline hold enables.
//
// The lookup and commit ports carry word addresses (byte address bits
// 24:2) of the 32 MB SDRAM window, so tags hold only the address bits
// that vary inside that window.
//
// Stores commit in MEM through the byte-enable write port. A store in
// MEM and a lookup in EX to the same word are merged (store-to-load
// forwarding) because both access the array on the same edge. The data
// array is split into four byte lanes for ECP5 block RAM byte enables.

`default_nettype none

module dcache #(
    parameter int LINE_WORDS = 4,
    parameter int NUM_LINES = 256
) (
  input logic clk,
  input logic rst,
  input logic flush,
  output logic flush_done,
  /* EX lookup. */
  input logic lu_valid,
  input logic [24:2] lu_addr,
  input logic [1:0] lu_offset,
  input logic [2:0] lu_funct3,
  /* MEM commit. */
  input logic cm_valid,
  input logic cm_we,
  input logic [24:2] cm_addr,
  input logic [31:0] cm_wdata,
  input logic [3:0] cm_be,
  output logic [31:0] cm_rdata,
  output logic [31:0] cm_forward_data,
  output logic cm_ready,
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
  localparam int DEPTH = NUM_LINES * LINE_WORDS;
  localparam int IDX_LO = OFF_BITS + 2;
  localparam int IDX_HI = IDX_LO + IDX_BITS - 1;
  // The cache addresses words inside the 32 MB SDRAM window, so a tag only
  // needs the address bits above the index that still vary inside it.
  localparam int MEM_WORD_BITS = 23;
  localparam int MEM_TAG_BITS = MEM_WORD_BITS - IDX_BITS - OFF_BITS;
  localparam logic [22:0] LINE_MASK = ~23'(LINE_WORDS - 1);
  localparam logic [OFF_BITS-1:0] LAST_BEAT = OFF_BITS'(LINE_WORDS - 1);

  typedef enum logic [3:0] {
    S_IDLE,
    S_START,
    S_WB_REQ,
    S_WB_RD,
    S_WB_WR,
    S_FILL_REQ,
    S_FILL,
    S_FLUSH,
    S_FLUSH_REQ,
    S_FLUSH_RD,
    S_FLUSH_WR
  } state_t;

  state_t state;
  logic valid_ram[0:NUM_LINES-1];
  logic dirty_ram[0:NUM_LINES-1];
  logic [MEM_TAG_BITS-1:0] tag_ram[0:NUM_LINES-1];
  // Keep the synchronous lookup copy separate from the asynchronous
  // eviction/flush port. Register the LUT-RAM output so hit readiness
  // starts from a fabric flop, independent of block RAM output latency.
  (* ram_style = "distributed" *) logic [MEM_TAG_BITS-1:0] lookup_tag_ram[0:NUM_LINES-1];
  logic [MEM_TAG_BITS-1:0] lookup_tag_q;
  logic [MEM_TAG_BITS-1:0] request_tag_q;
  logic lookup_line_valid_q;

  logic [7:0] lane0[0:DEPTH-1];
  logic [7:0] lane1[0:DEPTH-1];
  logic [7:0] lane2[0:DEPTH-1];
  logic [7:0] lane3[0:DEPTH-1];

  // A LUT-RAM mirror registers its read at the fabric edge. It supplies
  // forwarding without the block RAM's long clock-to-output delay.
  // Both copies receive every byte write and refill beat.
  (* ram_style = "distributed" *) logic [7:0] forward_lane0[0:DEPTH-1];
  (* ram_style = "distributed" *) logic [7:0] forward_lane1[0:DEPTH-1];
  (* ram_style = "distributed" *) logic [7:0] forward_lane2[0:DEPTH-1];
  (* ram_style = "distributed" *) logic [7:0] forward_lane3[0:DEPTH-1];
  logic [31:0] forward_raw;
  logic [31:0] forward_word, forward_merged;
  logic [1:0] lookup_offset_q, forward_offset;
  logic [2:0] lookup_funct3_q, forward_funct3;
  logic forward_store;
  logic [31:0] ram_data;
  logic [IDX_BITS+OFF_BITS-1:0] ram_raddr;
  logic [IDX_BITS+OFF_BITS-1:0] ram_waddr;
  logic [31:0] ram_wdata;
  logic [3:0] ram_wbe;
  logic ram_we;
  // Word addresses: the byte offset inside a word never reaches the tag
  // RAM, index or store-to-load comparator.
  logic [24:2] lu_addr_q;
  logic lookup_valid_q;
  logic pending_miss;
  logic recovery_ready;

  logic [31:0] prev_store_data;
  logic [3:0] prev_store_be;

  logic [MEM_WORD_BITS-1:0] miss_line_word;
  logic [IDX_BITS-1:0] miss_idx;
  logic [MEM_TAG_BITS-1:0] miss_tag;
  logic [IDX_BITS-1:0] flush_idx;
  logic [OFF_BITS-1:0] beat;
  logic flush_active;

  logic [MEM_WORD_BITS-1:0] victim_word;
  logic [MEM_WORD_BITS-1:0] flush_word;
  logic [31:0] merged;
  integer i;

  assign victim_word = {tag_ram[miss_idx], miss_idx, {(OFF_BITS) {1'b0}}};
  assign flush_word = {tag_ram[flush_idx], flush_idx, {(OFF_BITS) {1'b0}}};

  // Read tags on the same edge as the data. Only the address reaches the
  // lookup RAM in EX; full tag comparison starts from registers in MEM.
  logic lookup_hit_q;
  assign lookup_hit_q = lookup_line_valid_q && (lookup_tag_q == request_tag_q);
  always_ff @(posedge clk) begin
    if (lu_valid && (state == S_IDLE)) begin
      lookup_tag_q <= lookup_tag_ram[lu_addr[IDX_HI:IDX_LO]];
    end
    if ((state == S_FILL) && mem_rvalid && mem_rlast) begin
      lookup_tag_ram[miss_idx] <= miss_tag;
    end
  end
  assign hit_pulse = lookup_valid_q && (state == S_IDLE) && lookup_hit_q;
  assign miss_pulse = lookup_valid_q && (state == S_IDLE) && !lookup_hit_q;

  assign cm_ready = pending_miss ? recovery_ready : lookup_hit_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      lookup_line_valid_q <= 1'b0;
      request_tag_q <= '0;
      lookup_valid_q <= 1'b0;
      pending_miss <= 1'b0;
      recovery_ready <= 1'b0;
    end else begin
      lookup_valid_q <= lu_valid && (state == S_IDLE);
      // Keep each response until MEM commits it.
      if (lu_valid) begin
        lookup_line_valid_q <= (state == S_IDLE) && valid_ram[lu_addr[IDX_HI:IDX_LO]];
        request_tag_q <= lu_addr[24:IDX_HI+1];
      end else if (cm_valid) begin
        lookup_line_valid_q <= 1'b0;
      end
      // One registered RAM read after refill makes the missed word ready.
      if (pending_miss && (state == S_IDLE) && !recovery_ready) begin
        recovery_ready <= 1'b1;
      end
      if (pending_miss && recovery_ready && cm_valid) begin
        pending_miss <= 1'b0;
        recovery_ready <= 1'b0;
      end
      // A following miss may start on the preceding request's commit edge.
      if (miss_pulse) begin
        pending_miss <= 1'b1;
        recovery_ready <= 1'b0;
      end
    end
  end

  always_comb begin
    ram_raddr = {lu_addr[IDX_HI:IDX_LO], lu_addr[OFF_BITS+1:2]};
    if (pending_miss && !recovery_ready) begin
      ram_raddr = {lu_addr_q[IDX_HI:IDX_LO], lu_addr_q[OFF_BITS+1:2]};
    end
    if ((state == S_WB_RD) || (state == S_WB_WR)) begin
      ram_raddr = {miss_idx, beat};
    end else if ((state == S_FLUSH_RD) || (state == S_FLUSH_WR)) begin
      ram_raddr = {flush_idx, beat};
    end
  end

  function automatic [31:0] format_load(input logic [31:0] word_data, input logic [1:0] offset,
                                        input logic [2:0] funct3);
    logic [31:0] shifted;
    shifted = word_data >> {offset, 3'b000};
    case (funct3)
      3'b000: format_load = {{24{shifted[7]}}, shifted[7:0]};
      3'b001: format_load = {{16{shifted[15]}}, shifted[15:0]};
      3'b100: format_load = {24'd0, shifted[7:0]};
      3'b101: format_load = {16'd0, shifted[15:0]};
      default: format_load = word_data;
    endcase
  endfunction
  assign forward_word = {
    forward_lane3[ram_raddr],
    forward_lane2[ram_raddr],
    forward_lane1[ram_raddr],
    forward_lane0[ram_raddr]
  };
  assign forward_store = (state == S_IDLE) && cm_valid && cm_we && lu_valid && (cm_addr == lu_addr);
  for (genvar b = 0; b < 4; b = b + 1) begin : g_early_merge
    assign forward_merged[8*b+:8] = (forward_store && cm_be[b]) ? cm_wdata[8*b+:8] : forward_word[8*b+:8];
  end
  assign forward_offset = (pending_miss && !recovery_ready) ? lookup_offset_q : lu_offset;
  assign forward_funct3 = (pending_miss && !recovery_ready) ? lookup_funct3_q : lu_funct3;
  always_ff @(posedge clk) begin
    ram_data <= {lane3[ram_raddr], lane2[ram_raddr], lane1[ram_raddr], lane0[ram_raddr]};
    // Alignment and same-edge store forwarding finish before this flop.
    // Dependent EX consumers start from the final scalar value.
    forward_raw <= format_load(forward_merged, forward_offset, forward_funct3);
    if (lu_valid) begin
      lookup_offset_q <= lu_offset;
      lookup_funct3_q <= lu_funct3;
    end
  end

  always_comb begin
    ram_we = 1'b0;
    ram_waddr = {lu_addr[IDX_HI:IDX_LO], lu_addr[OFF_BITS+1:2]};
    ram_wdata = cm_wdata;
    ram_wbe = cm_be;
    if (state == S_IDLE) begin
      if (cm_valid && cm_we) begin
        ram_we = 1'b1;
        ram_waddr = {cm_addr[IDX_HI:IDX_LO], cm_addr[OFF_BITS+1:2]};
      end
    end else if (state == S_FILL) begin
      if (mem_rvalid) begin
        ram_we = 1'b1;
        ram_waddr = {miss_idx, beat};
        ram_wdata = mem_rdata;
        ram_wbe = 4'hf;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (ram_we) begin
      if (ram_wbe[0]) begin
        lane0[ram_waddr] <= ram_wdata[7:0];
        forward_lane0[ram_waddr] <= ram_wdata[7:0];
      end
      if (ram_wbe[1]) begin
        lane1[ram_waddr] <= ram_wdata[15:8];
        forward_lane1[ram_waddr] <= ram_wdata[15:8];
      end
      if (ram_wbe[2]) begin
        lane2[ram_waddr] <= ram_wdata[23:16];
        forward_lane2[ram_waddr] <= ram_wdata[23:16];
      end
      if (ram_wbe[3]) begin
        lane3[ram_waddr] <= ram_wdata[31:24];
        forward_lane3[ram_waddr] <= ram_wdata[31:24];
      end
    end
  end

  assign merged[7:0] = prev_store_be[0] ? prev_store_data[7:0] : ram_data[7:0];
  assign merged[15:8] = prev_store_be[1] ? prev_store_data[15:8] : ram_data[15:8];
  assign merged[23:16] = prev_store_be[2] ? prev_store_data[23:16] : ram_data[23:16];
  assign merged[31:24] = prev_store_be[3] ? prev_store_data[31:24] : ram_data[31:24];
  assign cm_rdata = merged;
  assign cm_forward_data = forward_raw;

  assign mem_req = (state == S_WB_REQ) || (state == S_FILL_REQ) || (state == S_FLUSH_REQ);
  assign mem_we = (state == S_WB_REQ) || (state == S_FLUSH_REQ);
  assign mem_word_addr = (state == S_WB_REQ) ? victim_word :
                         (state == S_FLUSH_REQ) ? flush_word : miss_line_word;
  assign mem_len = 4'(LINE_WORDS - 1);
  assign mem_wvalid = (state == S_WB_WR) || (state == S_FLUSH_WR);
  assign mem_wdata = ram_data;
  assign mem_wbe = 4'hf;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE;
      lu_addr_q <= '0;
      prev_store_data <= '0;
      prev_store_be <= '0;
      miss_line_word <= '0;
      miss_idx <= '0;
      miss_tag <= '0;
      flush_idx <= '0;
      beat <= '0;
      flush_active <= 1'b0;
      flush_done <= 1'b0;
      for (i = 0; i < NUM_LINES; i = i + 1) begin
        valid_ram[i] <= 1'b0;
        dirty_ram[i] <= 1'b0;
      end
    end else begin
      if (!flush) begin
        flush_done <= 1'b0;
        flush_active <= 1'b0;
      end

      if (lu_valid) begin
        lu_addr_q <= lu_addr;
      end

      // Resolve forwarding alongside the lookup, before MEM arithmetic.
      prev_store_be <= ((state == S_IDLE) && cm_valid && cm_we && lu_valid &&
                        (cm_addr == lu_addr)) ? cm_be : 4'b0000;
      if ((state == S_IDLE) && cm_valid && cm_we) begin
        prev_store_data <= cm_wdata;
        dirty_ram[cm_addr[IDX_HI:IDX_LO]] <= 1'b1;
      end

      case (state)
        S_IDLE: begin
          // Only the state transition depends on the tag comparison.
          // The captured address is used after entering S_START.
          miss_idx <= lu_addr_q[IDX_HI:IDX_LO];
          miss_tag <= lu_addr_q[24:IDX_HI+1];
          miss_line_word <= lu_addr_q & LINE_MASK;
          if (flush && !flush_active) begin
            flush_active <= 1'b1;
            flush_idx <= '0;
            state <= S_FLUSH;
          end else if (miss_pulse) begin
            state <= S_START;
          end
        end
        S_START: begin
          if (dirty_ram[miss_idx]) begin
            state <= S_WB_REQ;
          end else begin
            state <= S_FILL_REQ;
          end
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
              dirty_ram[miss_idx] <= 1'b0;
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
              tag_ram[miss_idx] <= miss_tag;
              valid_ram[miss_idx] <= 1'b1;
              dirty_ram[miss_idx] <= 1'b0;
              state <= S_IDLE;
            end else begin
              beat <= beat + 1'b1;
            end
          end
        end
        S_FLUSH: begin
          if (dirty_ram[flush_idx]) begin
            state <= S_FLUSH_REQ;
          end else if (flush_idx == IDX_BITS'(NUM_LINES - 1)) begin
            flush_done <= 1'b1;
            state <= S_IDLE;
          end else begin
            flush_idx <= flush_idx + 1'b1;
          end
        end
        S_FLUSH_REQ: begin
          if (mem_ready) begin
            beat <= '0;
            state <= S_FLUSH_RD;
          end
        end
        S_FLUSH_RD: begin
          state <= S_FLUSH_WR;
        end
        S_FLUSH_WR: begin
          if (mem_wready) begin
            if (beat == LAST_BEAT) begin
              dirty_ram[flush_idx] <= 1'b0;
              if (flush_idx == IDX_BITS'(NUM_LINES - 1)) begin
                flush_done <= 1'b1;
                state <= S_IDLE;
              end else begin
                flush_idx <= flush_idx + 1'b1;
                state <= S_FLUSH;
              end
            end else begin
              beat <= beat + 1'b1;
              state <= S_FLUSH_RD;
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
