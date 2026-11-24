// Write-back data cache with a lookup-in-EX pipeline.
//
// EX presents the address early enough for a registered data read, so hits
// do not stall. MEM checks that this read still belongs to a live line and
// can reissue the read or miss if a peer probe raced the EX lookup.
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
`ifdef ROCO_SOC_DCACHE_MEMORY_FORMAL
  input logic [22:0] formal_memory_addr,
  input logic [31:0] formal_initial_word,
  input logic [31:0] formal_backing_word,
  input logic formal_cancel,
  input logic formal_boot_loading,
  input logic formal_global_reset,
  input logic formal_flush_clean,
  input logic formal_external_write,
  input logic [31:0] formal_external_data,
  input logic [3:0] formal_external_be,
  output logic [22:0] formal_beat_word,
  output logic formal_memory_active,
  output logic formal_memory_write,
  output logic [4:0] formal_write_left,
  output logic [4:0] formal_read_left,
  output logic formal_pending,
  output logic formal_abandoned,
  output logic [22:0] formal_cpu_word,
  output logic [31:0] formal_arch_data,
`endif
`ifdef ROCO_SOC_FENCE_FORMAL
  output logic f_idle,
  output logic f_lookup_pending,
`endif
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
  input logic cm_amo_read,
  output logic cm_amo_retry,
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
  output logic miss_pulse,
  /* Exclusive-fill snoop. A dirty probe requests a targeted writeback. */
  input logic snoop_valid,
  input logic [22:0] snoop_addr,
  output logic snoop_dirty,
  input logic snoop_invalidate,
  input logic snoop_writeback,
  output logic snoop_writeback_done,
  /* Lookup stall: the core must hold EX while a flush runs, otherwise a
     lookup issued into the flush window is dropped (no miss is raised) yet
     the pipeline advances on the MMU hit, stranding MEM with stale hitq. */
  output logic flush_busy,
  /* Line base of the in-flight miss for the coherence hub's probe. Clean
     and dirty lines are both exclusive; a store never needs an upgrade. */
  output logic [22:0] miss_line
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
  // Keep the early EX lookup copy separate from the MEM/eviction ports.
  (* ram_style = "distributed" *) logic [MEM_TAG_BITS-1:0] lookup_tag_ram[0:NUM_LINES-1];

  logic [7:0] lane0[0:DEPTH-1];
  logic [7:0] lane1[0:DEPTH-1];
  logic [7:0] lane2[0:DEPTH-1];
  logic [7:0] lane3[0:DEPTH-1];

  // A LUT-RAM mirror registers its read at the fabric edge. It supplies
  // forwarding without the block RAM's long clock-to-output delay.
  // Both copies receive every byte write and refill beat.
  localparam int BANK_ADDR_BITS = (IDX_BITS + OFF_BITS > 8) ? 8 : IDX_BITS + OFF_BITS;
  localparam int BANK_DEPTH = 1 << BANK_ADDR_BITS;
  localparam int BANK_COUNT = DEPTH / BANK_DEPTH;
  logic [31:0] forward_bank_data[0:BANK_COUNT-1];
  logic [31:0] forward_raw, forward_mask;
  logic [IDX_BITS+OFF_BITS-1:0] forward_raddr;
  logic [31:0] forward_store_data_q, forward_mask_q;
  logic forward_store_q;
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
  logic store_compare_q;
  // Capture the complete comparison alongside the read. Forwarding in
  // MEM starts from one match bit instead of a wide comparison tree.
  always_ff @(posedge clk) begin
    store_compare_q <= (cm_addr == lu_addr);
  end
  logic prev_store_match;

  logic [MEM_WORD_BITS-1:0] miss_line_word;
  logic [IDX_BITS-1:0] miss_idx;
  logic [MEM_TAG_BITS-1:0] miss_tag;
  logic [IDX_BITS-1:0] flush_idx;
  logic [OFF_BITS-1:0] beat;
  logic flush_active, probe_writeback_active, resume_fill;
  logic full_flush_entry, probe_writeback_entry, probe_writeback_pending;
  assign flush_busy = flush_active || probe_writeback_active;

  logic [MEM_WORD_BITS-1:0] victim_word;
  logic [MEM_WORD_BITS-1:0] flush_word;
  logic [31:0] merged;
  integer i;

  assign victim_word = {tag_ram[miss_idx], miss_idx, {(OFF_BITS) {1'b0}}};
  assign flush_word = {tag_ram[flush_idx], flush_idx, {(OFF_BITS) {1'b0}}};

  // Resolve the EX lookup alongside the data read so a cold miss can
  // start before the MEM request arrives.
  logic lookup_hit_q;
  always_ff @(posedge clk) begin
    if ((state == S_FILL) && mem_rvalid && mem_rlast) begin
      lookup_tag_ram[miss_idx] <= miss_tag;
    end
  end
  assign hit_pulse = lookup_valid_q && (state == S_IDLE) && lookup_hit_q;
  assign miss_pulse = lookup_valid_q && (state == S_IDLE) && !lookup_hit_q;

  // A clean hit can be invalidated at probe time. A dirty hit retains
  // ownership until its data is sent on the writeback path.
  logic [IDX_BITS-1:0] snoop_idx;
  logic [MEM_TAG_BITS-1:0] snoop_tag;
  logic [OFF_BITS-1:0] unused_snoop_offset;
  assign unused_snoop_offset = snoop_addr[OFF_BITS-1:0];
  assign snoop_idx = snoop_addr[OFF_BITS+IDX_BITS-1:OFF_BITS];
  assign snoop_tag = snoop_addr[22:OFF_BITS+IDX_BITS];
  logic snoop_match, snoop_drop;
  assign snoop_match = valid_ram[snoop_idx] && tag_ram[snoop_idx] == snoop_tag;
  assign snoop_dirty = snoop_valid && snoop_match && dirty_ram[snoop_idx];
  assign snoop_drop = snoop_valid && snoop_invalidate && snoop_match && !snoop_dirty;
  // Both MEM phases name their address. A registered data read is usable
  // only if it belongs to that word and its line still has the right tag.
  // Use this same test for EX hits, replays, and recovery after a fill.
  logic demand, read_valid_q, read_hit_q, read_matches, read_live, read_probed;
  logic ex_tag_match, replay_tag_match, demand_blocked;
  logic [24:2] target_addr, read_addr, read_addr_q;
  logic [IDX_BITS-1:0] target_idx, ex_idx, read_idx_q;
  assign demand = cm_valid || cm_amo_read;
  assign target_addr = demand ? cm_addr : lu_addr_q;
  assign target_idx = target_addr[IDX_HI:IDX_LO];
  assign ex_idx = lu_addr[IDX_HI:IDX_LO];
  assign read_idx_q = read_addr_q[IDX_HI:IDX_LO];
  // The late EX issue/hold decision selects a hit bit, not a tag-RAM
  // address. Keep both tag checks independent of that decision.
  assign ex_tag_match = lookup_tag_ram[ex_idx] == lu_addr[24:IDX_HI+1];
  assign replay_tag_match = tag_ram[target_idx] == target_addr[24:IDX_HI+1];
  assign read_matches = read_valid_q && (demand ? read_addr_q == cm_addr : read_addr_q == lu_addr_q);
  assign read_probed = snoop_valid && read_addr_q[24:OFF_BITS+2] == snoop_addr[22:OFF_BITS];
  // Register the tag check alongside the data. A fill can change the tag
  // only in S_FILL, which cannot produce a valid read. Invalidation can
  // still race the registered read, so recheck the valid bit.
  assign read_live = read_hit_q && valid_ram[read_idx_q];
  // A matching invalidate window waits even if the probe turns out not
  // to drop the line. The CPU hold path must not read the snoop tag RAM.
  // A probe writeback likewise owns the data port before checking its tag.
  assign demand_blocked = flush_busy || flush || probe_writeback_pending ||
                          (read_probed && (snoop_invalidate || cm_amo_read));
  assign recovery_ready = pending_miss && read_valid_q;
  assign cm_ready = state == S_IDLE && !demand_blocked &&
                    (demand || lookup_hit_q || recovery_ready) && read_live && read_matches;

  // Do not pin the line against probes. If ownership is revoked while the
  // core holds an AMO operand, send it back to the read phase, not to a
  // refill followed by a store computed from the old operand.
  logic amo_operand_valid;
  logic [22:OFF_BITS] amo_operand_line;
  assign cm_amo_retry = !amo_operand_valid;
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      amo_operand_valid <= 1'b0;
      amo_operand_line <= '0;
    end else if (cm_amo_read && cm_ready) begin
      amo_operand_valid <= 1'b1;
      amo_operand_line <= cm_addr[24:OFF_BITS+2];
    end else if ((cm_valid && cm_ready) || full_flush_entry ||
                 ((snoop_drop || probe_writeback_entry) &&
                  amo_operand_line[22:OFF_BITS] == snoop_addr[22:OFF_BITS]) ||
                 (state == S_FILL_REQ && mem_req && mem_ready)) begin
      amo_operand_valid <= 1'b0;
    end
  end
`ifdef ROCO_SOC_FENCE_FORMAL
  assign f_idle = state == S_IDLE;
  assign f_lookup_pending = lookup_valid_q;
`endif
  assign miss_line = miss_line_word;
  logic start_miss;
  assign start_miss = state == S_IDLE && !demand_blocked &&
                      (demand ? read_matches && !read_live : miss_pulse);
  assign probe_writeback_pending = snoop_writeback && !snoop_writeback_done;
  assign probe_writeback_entry = (state == S_IDLE || state == S_FILL_REQ) &&
      probe_writeback_pending && snoop_match && dirty_ram[snoop_idx] && !flush_busy;
  assign full_flush_entry = state == S_IDLE && flush && !flush_busy && !probe_writeback_entry;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      lookup_hit_q <= 1'b0;
      lookup_valid_q <= 1'b0;
      pending_miss <= 1'b0;
      read_valid_q <= 1'b0;
      read_hit_q <= 1'b0;
      read_addr_q <= '0;
    end else begin
      lookup_valid_q <= lu_valid && state == S_IDLE;
      if (lu_valid) lookup_hit_q <= state == S_IDLE && valid_ram[ex_idx] && ex_tag_match;
      else if (cm_valid && cm_ready) lookup_hit_q <= 1'b0;
      if (start_miss) pending_miss <= 1'b1;
      else if (cm_valid && cm_ready) pending_miss <= 1'b0;
      read_valid_q <= state == S_IDLE && !start_miss && !full_flush_entry && !probe_writeback_entry;
      read_hit_q <= lu_valid ? ex_tag_match : replay_tag_match;
      read_addr_q <= read_addr;
    end
  end

  // EX can read the next word on the current commit edge. When EX is held,
  // replay the actual MEM word, not whatever address EX last looked up.
  assign read_addr = lu_valid ? lu_addr : target_addr;
  always_comb begin
    ram_raddr = read_addr[IDX_HI:2];
    if ((state == S_WB_RD) || (state == S_WB_WR)) begin
      ram_raddr = {miss_idx, beat};
    end else if ((state == S_FLUSH_RD) || (state == S_FLUSH_WR)) begin
      ram_raddr = {flush_idx, beat};
    end
  end

  function automatic [31:0] format_load(input logic [31:0] word_data, input logic [1:0] offset,
                                        input logic [2:0] funct3);
    logic [15:0] shifted;
    shifted = 16'(word_data >> {offset, 3'b000});
    case (funct3)
      3'b000: format_load = {{24{shifted[7]}}, shifted[7:0]};
      3'b001: format_load = {{16{shifted[15]}}, shifted[15:0]};
      3'b100: format_load = {24'd0, shifted[7:0]};
      3'b101: format_load = {16'd0, shifted[15:0]};
      default: format_load = word_data;
    endcase
  endfunction
  // The forwarding mirror is never used for writeback or flush reads.
  assign forward_raddr = read_addr[IDX_HI:2];
`ifdef ROCO_DCACHE_MEMORY_FORMAL
  `include "dcache_memory_checks.svh"
`endif
  // Read and align small banks in parallel. Select one bank before the
  // register; MEM merges the resulting one-hot data with an OR tree.
  for (genvar bank = 0; bank < BANK_COUNT; bank = bank + 1) begin : g_forward_bank
    (* ram_style = "distributed" *) logic [7:0] bank_lane0[0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [7:0] bank_lane1[0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [7:0] bank_lane2[0:BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [7:0] bank_lane3[0:BANK_DEPTH-1];
    logic [31:0] word_data;
    logic [BANK_ADDR_BITS-1:0] bank_read_addr;
    logic [BANK_ADDR_BITS-1:0] write_addr;
    assign bank_read_addr = forward_raddr[BANK_ADDR_BITS-1:0];
    assign write_addr = ram_waddr[BANK_ADDR_BITS-1:0];
    assign word_data = {
      bank_lane3[bank_read_addr],
      bank_lane2[bank_read_addr],
      bank_lane1[bank_read_addr],
      bank_lane0[bank_read_addr]
    };
`ifdef ROCO_DCACHE_MEMORY_FORMAL
    assign f_forward_cell[bank] = {
      bank_lane3[f_location[BANK_ADDR_BITS-1:0]],
      bank_lane2[f_location[BANK_ADDR_BITS-1:0]],
      bank_lane1[f_location[BANK_ADDR_BITS-1:0]],
      bank_lane0[f_location[BANK_ADDR_BITS-1:0]]
    };
`endif
    always_ff @(posedge clk) begin
      forward_bank_data[bank] <= (forward_raddr >> BANK_ADDR_BITS) == bank ? format_load(
          word_data, forward_offset, forward_funct3
      ) : 32'd0;
      if (ram_we && ((ram_waddr >> BANK_ADDR_BITS) == bank)) begin
        if (ram_wbe[0]) bank_lane0[write_addr] <= ram_wdata[7:0];
        if (ram_wbe[1]) bank_lane1[write_addr] <= ram_wdata[15:8];
        if (ram_wbe[2]) bank_lane2[write_addr] <= ram_wdata[23:16];
        if (ram_wbe[3]) bank_lane3[write_addr] <= ram_wdata[31:24];
      end
    end
  end
  always_comb begin
    forward_raw = '0;
    for (int bank = 0; bank < BANK_COUNT; bank++) forward_raw |= forward_bank_data[bank];
  end
  assign forward_store = (state == S_IDLE) && cm_valid && cm_ready && cm_we && lu_valid;
  for (genvar b = 0; b < 4; b = b + 1) begin : g_forward_mask
    assign forward_mask[8*b+:8] = {8{cm_be[b]}};
  end
  assign forward_offset = lu_valid ? lu_offset : lookup_offset_q;
  assign forward_funct3 = lu_valid ? lu_funct3 : lookup_funct3_q;
  always_ff @(posedge clk) begin
    ram_data <= {lane3[ram_raddr], lane2[ram_raddr], lane1[ram_raddr], lane0[ram_raddr]};
    // Register alignment and store matching independently. Formatting the
    // byte mask also selects the sign-extension bits of partial loads.
    forward_store_q <= forward_store;
    forward_store_data_q <= format_load(cm_wdata, forward_offset, forward_funct3);
    forward_mask_q <= format_load(forward_mask, forward_offset, forward_funct3);
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
    // A level-held commit strobe must not write the array before the
    // commit is accepted: an early write would clobber the victim line
    // that a pending miss is about to write back.
    if (state == S_IDLE) begin
      if (cm_valid && cm_ready && cm_we) begin
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

  assign prev_store_match = store_compare_q;
  assign merged[7:0] = (prev_store_match && prev_store_be[0]) ? prev_store_data[7:0] : ram_data[7:0];
  assign merged[15:8] = (prev_store_match && prev_store_be[1]) ? prev_store_data[15:8] : ram_data[15:8];
  assign merged[23:16] = (prev_store_match && prev_store_be[2]) ? prev_store_data[23:16] : ram_data[23:16];
  assign merged[31:24] = (prev_store_match && prev_store_be[3]) ? prev_store_data[31:24] : ram_data[31:24];
  assign cm_rdata = merged;
  assign cm_forward_data = (forward_store_q && prev_store_match) ?
                           ((forward_raw & ~forward_mask_q) |
                            (forward_store_data_q & forward_mask_q)) : forward_raw;

  assign mem_req = (state == S_WB_REQ) || (state == S_FILL_REQ && !probe_writeback_entry) ||
                   (state == S_FLUSH_REQ);
  assign mem_we = (state == S_WB_REQ) || (state == S_FLUSH_REQ);
  assign mem_word_addr = (state == S_WB_REQ) ? victim_word :
                         (state == S_FLUSH_REQ) ? flush_word : miss_line_word;
  assign mem_len = 4'(LINE_WORDS - 1);
  assign mem_wvalid = (state == S_WB_WR) || (state == S_FLUSH_WR);
  assign mem_wdata = ram_data;
  assign mem_wbe = 4'hf;

  always_ff @(posedge clk or posedge rst) begin
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
      probe_writeback_active <= 1'b0;
      snoop_writeback_done <= 1'b0;
      resume_fill <= 1'b0;
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

      if (snoop_drop) valid_ram[snoop_idx] <= 1'b0;
      if (!snoop_writeback) snoop_writeback_done <= 1'b0;
      else if (!snoop_match || !dirty_ram[snoop_idx]) snoop_writeback_done <= 1'b1;

      // Readiness already includes liveness and same-cycle invalidation.
      // Only the store that writes the RAM is allowed to mark it dirty.
      prev_store_be <= forward_store ? cm_be : 4'b0000;
      if (cm_valid && cm_ready && cm_we) begin
        prev_store_data <= cm_wdata;
        dirty_ram[cm_addr[IDX_HI:IDX_LO]] <= 1'b1;
      end

      case (state)
        S_IDLE: begin
          if (full_flush_entry) begin
            flush_active <= 1'b1;
            flush_idx <= '0;
            state <= S_FLUSH;
          end else if (start_miss) begin
            miss_idx <= target_idx;
            miss_tag <= target_addr[24:IDX_HI+1];
            miss_line_word <= target_addr & LINE_MASK;
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
          if (mem_req && mem_ready) begin
            valid_ram[miss_idx] <= 1'b0;
            beat <= '0;
            state <= S_FILL;
          end
        end
        S_FILL: begin
          if (mem_rvalid) begin
            if (mem_rlast) begin
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
              if (probe_writeback_active) begin
                valid_ram[flush_idx] <= 1'b0;
                probe_writeback_active <= 1'b0;
                snoop_writeback_done <= 1'b1;
                if (resume_fill) state <= S_FILL_REQ;
                else state <= S_IDLE;
              end else if (flush_idx == IDX_BITS'(NUM_LINES - 1)) begin
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

      // The peer may need a dirty line even while our own fill waits for
      // its grant. Drain that line without consuming or abandoning our miss.
      if (probe_writeback_entry) begin
        probe_writeback_active <= 1'b1;
        resume_fill <= state == S_FILL_REQ;
        flush_idx <= snoop_idx;
        state <= S_FLUSH_REQ;
      end
    end
  end

`ifdef ROCO_DCACHE_SNOOP_FORMAL
  // Structural safety with arbitrary snoops and bus stalls. No backing
  // data model is needed to prove these metadata invariants.
  (* anyconst *) logic [IDX_BITS-1:0] f_snoop_index;
  initial assume (rst);
  always_ff @(posedge clk) begin
    if (!rst) begin
      assert (!dirty_ram[f_snoop_index] || valid_ram[f_snoop_index]);
      if (valid_ram[f_snoop_index])
        assert (lookup_tag_ram[f_snoop_index] == tag_ram[f_snoop_index]);
      if (read_valid_q && read_hit_q && read_idx_q == f_snoop_index && valid_ram[f_snoop_index])
        assert (tag_ram[f_snoop_index] == read_addr_q[24:IDX_HI+1]);
      if (cm_ready && target_idx == f_snoop_index) begin
        assert (valid_ram[f_snoop_index]);
        assert (tag_ram[f_snoop_index] == target_addr[24:IDX_HI+1]);
        assert (!(snoop_drop && snoop_idx == f_snoop_index));
      end
      if (amo_operand_valid && amo_operand_line[OFF_BITS+:IDX_BITS] == f_snoop_index) begin
        assert (valid_ram[f_snoop_index]);
        assert (tag_ram[f_snoop_index] == amo_operand_line[22:OFF_BITS+IDX_BITS]);
      end
      if (state == S_FILL) assert (!amo_operand_valid);
      if (probe_writeback_active) begin
        assert (state == S_FLUSH_REQ || state == S_FLUSH_RD || state == S_FLUSH_WR);
        if (amo_operand_valid && amo_operand_line[OFF_BITS+:IDX_BITS] == f_snoop_index)
          assert (flush_idx != f_snoop_index);
      end
      if ((state == S_FILL_REQ || (probe_writeback_active && resume_fill)) &&
          miss_idx == f_snoop_index)
        assert (!dirty_ram[f_snoop_index]);
    end
  end
`endif

`ifdef ROCO_SOC_RAM_FORMAL
  always_ff @(posedge clk) begin
    if (!rst && (state == S_START || state == S_WB_REQ || state == S_WB_RD ||
                 state == S_WB_WR || state == S_FILL_REQ)) begin
      assert ((miss_line_word & LINE_MASK) == miss_line_word);
    end
  end
`endif

`ifdef ROCO_SOC_FENCE_FORMAL
  (* anyconst *) logic [IDX_BITS-1:0] f_flush_index;
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (!probe_writeback_active && (state == S_FLUSH || state == S_FLUSH_REQ ||
                                     state == S_FLUSH_RD || state == S_FLUSH_WR)) begin
        assert (flush && flush_active && !flush_done);
        if (f_flush_index < flush_idx) assert (!dirty_ram[f_flush_index]);
      end
      if (flush_done && flush) assert (!dirty_ram[f_flush_index]);
    end
  end
`endif

  // The tag array carries no reset value. A line is only observable once its
  // valid bit is set in the state machine above, so the tag RAM stays out of
  // the asynchronous reset cone.
  always_ff @(posedge clk) begin
    if ((state == S_FILL) && mem_rvalid && mem_rlast) begin
      tag_ram[miss_idx] <= miss_tag;
    end
  end

endmodule
