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
  /* MSI snoop (bus-side coherence). Single-core ties valid/ack low/high. */
  input logic snoop_valid,
  input logic [22:0] snoop_addr,
  input logic snoop_exclusive,
  output logic snoop_hit,
  output logic snoop_dirty,
  input logic snoop_invalidate,
  /* Lookup stall: the core must hold EX while a flush runs, otherwise a
     lookup issued into the flush window is dropped (no miss is raised) yet
     the pipeline advances on the MMU hit, stranding MEM with stale hitq. */
  output logic flush_busy,
  /* S->M upgrade: store to a clean (Shared) line must invalidate peers. */
  output logic upgrade_req,
  output logic [22:0] upgrade_addr,
  input logic upgrade_ack,
  /* Line base of the in-flight miss for the coherence hub's probe. All
     hub fills are exclusive (MSI without E): the peer is invalidated
     after a dirty writeback, so read-sharing migrates instead of copying. */
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
  // Keep the lookup copy separate from the eviction/flush port. Compare
  // tags in EX and register the hit bit so MEM readiness starts at one
  // flop rather than a wide comparator feeding every pipeline hold.
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
  logic flush_active;
  assign flush_busy = flush_active;

  logic [MEM_WORD_BITS-1:0] victim_word;
  logic [MEM_WORD_BITS-1:0] flush_word;
  logic [31:0] merged;
  integer i;

  assign victim_word = {tag_ram[miss_idx], miss_idx, {(OFF_BITS) {1'b0}}};
  assign flush_word = {tag_ram[flush_idx], flush_idx, {(OFF_BITS) {1'b0}}};

  // Resolve the tag lookup alongside the data read, without adding a
  // cache-hit cycle. Hold its registered response until MEM commits.
  logic lookup_hit_q;
  always_ff @(posedge clk) begin
    if ((state == S_FILL) && mem_rvalid && mem_rlast) begin
      lookup_tag_ram[miss_idx] <= miss_tag;
    end
  end
  assign hit_pulse = lookup_valid_q && (state == S_IDLE) && lookup_hit_q;
  assign miss_pulse = lookup_valid_q && (state == S_IDLE) && !lookup_hit_q;

  // MSI snoop: probe the authoritative tag/valid/dirty RAMs. A dirty hit
  // must be written back by the coherence hub before invalidation, so a
  // snoop invalidate only drops clean lines here; dirty lines stay valid
  // and report snoop_dirty until the hub drains them.
  logic [IDX_BITS-1:0] snoop_idx;
  logic [MEM_TAG_BITS-1:0] snoop_tag;
  assign snoop_idx = snoop_addr[OFF_BITS+IDX_BITS-1:OFF_BITS];
  assign snoop_tag = snoop_addr[22:OFF_BITS+IDX_BITS];
  assign snoop_hit = snoop_valid && valid_ram[snoop_idx] && (tag_ram[snoop_idx] == snoop_tag);
  assign snoop_dirty = snoop_hit && dirty_ram[snoop_idx];
  // Commit-time hit without the tag RAM re-read. tag_ram and
  // lookup_tag_ram change only on our own fills (which imply a lookup
  // Commit-time hit without the tag RAM re-read. tag_ram and
  // lookup_tag_ram change only on our own fills (which imply a lookup
  // miss) and valid_ram clears only on a peer snoop invalidate of a
  // clean line, so a held lookup hit stays a hit unless the line died
  // after we looked it up.
  //
  // The snapshot records the committing op's own lookup result (hit + full
  // address) the first cycle it is presented. A full-address match is
  // exact across evictions and aliases, so no tag re-read is needed; a
  // mismatch can only cost a refill, never a false hit. killed_q shadows
  // every valid_ram clear (snoop invalidate; reset) with a sticky bit per
  // index, cleared by our fill. Invariant: killed_q[i] -> !valid_ram[i].
  //
  // New-op detection keys on the presented address (commits may stream
  // back-to-back with cm_valid never dropping), and the snapshot is only
  // as fresh as the in-order, level-held commit protocol the cache
  // already assumes (see prev_store_be): a younger lookup can only
  // overwrite the EX-side registers once per op, so at the commit's first
  // cycle they still hold its own lookup. Anything else mismatches the
  // full address and safely misses. No lu_* signal enters the commit cone,
  // so no combinational ready loop is possible.
  logic cm_hit_now;
  logic lu_hit_live;
  assign lu_hit_live = (state == S_IDLE) && valid_ram[lu_addr[IDX_HI:IDX_LO]] &&
                       (lookup_tag_ram[lu_addr[IDX_HI:IDX_LO]] == lu_addr[24:IDX_HI+1]);
  logic mem_hit_q;
  logic [24:2] mem_addr_q;
  logic [24:2] cm_addr_q;
  logic cm_valid_q;
  logic cm_new;
  assign cm_new = cm_valid && (!cm_valid_q || (cm_addr != cm_addr_q));
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      mem_hit_q <= 1'b0;
      mem_addr_q <= '0;
      cm_addr_q <= '0;
      cm_valid_q <= 1'b0;
    end else begin
      cm_valid_q <= cm_valid;
      if (cm_valid) cm_addr_q <= cm_addr;
      if (cm_new) begin
        mem_hit_q <= lookup_hit_q;
        mem_addr_q <= lu_addr_q;
      end
    end
  end
  logic killed_q[0:NUM_LINES-1];
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      for (int k = 0; k < NUM_LINES; k = k + 1) killed_q[k] <= 1'b0;
    end else if (snoop_invalidate && snoop_valid && valid_ram[snoop_idx] &&
                 (tag_ram[snoop_idx] == snoop_tag) && !dirty_ram[snoop_idx]) begin
      killed_q[snoop_idx] <= 1'b1;
    end else if ((state == S_FILL) && mem_rvalid && mem_rlast) begin
      killed_q[miss_idx] <= 1'b0;
    end
  end
  // First cycle of a (new-address) commit answers from the live EX-side
  // registers; held cycles use the snapshot. No lu_* signal enters the
  // commit cone, so no combinational ready loop is possible.
  // A peer snoop that drops a line must also drop the microarchitectural
  // state shadowing it: a registered hit for a dead line, a pending
  // miss about to serve one, or a retiring store about to dirty it would
  // otherwise commit stale data or leave a dirty-invalid line the hub
  // believes is gone. The guard mirrors the valid_ram clear exactly, so
  // the clears fire precisely when the line dies. Safe direction only:
  // a coincidental same-cycle lookup loses its result and refetches.
  logic snoop_kill_lu, snoop_kill_pending, snoop_kill_cm;
  assign snoop_kill_lu = snoop_valid && snoop_invalidate &&
                          (snoop_idx == lu_addr_q[IDX_HI:IDX_LO]) && valid_ram[snoop_idx] &&
                          (tag_ram[snoop_idx] == snoop_tag) && !dirty_ram[snoop_idx];
  assign snoop_kill_pending = snoop_valid && snoop_invalidate && pending_miss &&
                              (snoop_idx == miss_idx) && valid_ram[snoop_idx] &&
                              (tag_ram[snoop_idx] == snoop_tag) && !dirty_ram[snoop_idx];
  assign snoop_kill_cm = snoop_valid && snoop_invalidate && cm_valid &&
                          (snoop_idx == cm_addr[IDX_HI:IDX_LO]) && valid_ram[snoop_idx] &&
                          (tag_ram[snoop_idx] == snoop_tag) && !dirty_ram[snoop_idx];
  logic src_hit;
  logic [24:2] src_addr;
  assign src_hit = cm_new ? lookup_hit_q : mem_hit_q;
  assign src_addr = cm_new ? lu_addr_q : mem_addr_q;
  // The live kill drops readiness the same cycle the line dies, so the
  // commit re-misses instead of retiring into a dead line (which would
  // silently lose a vetoed store). snoop_valid comes from the hub's
  // registered outputs, so this adds no combinational ready loop.
  assign cm_hit_now = src_hit && (cm_addr == src_addr) &&
                       !killed_q[cm_addr[IDX_HI:IDX_LO]] && !snoop_kill_cm;
  logic hit_eff;
  assign hit_eff = lookup_hit_q && (!cm_valid || cm_hit_now);
  // S->M upgrade: a store hit on a clean line is Shared and must
  // invalidate the peer before going Modified. Gate commit on hub ack.
  logic upgrade_needed;
  assign upgrade_needed = (state == S_IDLE) && cm_valid && cm_we && hit_eff &&
                          !dirty_ram[cm_addr[IDX_HI:IDX_LO]] && !flush_active;
  assign upgrade_req = upgrade_needed;
  assign upgrade_addr = cm_addr;
  // Recovery serves a completed fill while pending; it may only serve
  // while the recovered line is still alive. The kill shadow revokes it
  // when a snoop lands after the fill -- or the commit would retire into
  // a dead line (silently losing a vetoed store). The core then holds cm
  // and the race logic refetches. Gated on the miss line rather than the
  // commit address, since recovery asserts before the commit arrives.
  logic recovery_ok;
  assign recovery_ok = recovery_ready && !killed_q[miss_idx];
  assign cm_ready = (pending_miss ? (recovery_ok && !snoop_kill_pending) : hit_eff) &&
      (!upgrade_needed || upgrade_ack) && !flush_active;
`ifdef ROCO_SOC_FENCE_FORMAL
  assign f_idle = state == S_IDLE;
  assign f_lookup_pending = lookup_valid_q;
`endif
  assign miss_line = miss_line_word;
  // Lost-upgrade race: our commit target vanished under a peer snoop
  // between lookup and commit. The S_IDLE capture below already holds our
  // line (the pipeline holds EX while MEM waits, so lu_addr_q is ours);
  // just raise a miss and let the fill path hold cm until recovery.
  logic race_miss;
  assign race_miss = (state == S_IDLE) && !pending_miss && cm_valid && !cm_hit_now;
  // A flush starting on the same cycle abandons a just-detected miss: the
  // stalled core re-issues the lookup after the flush drains.
  logic flush_entry;
  assign flush_entry = (state == S_IDLE) && flush && !flush_active;
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      lookup_hit_q <= 1'b0;
      lookup_valid_q <= 1'b0;
      pending_miss <= 1'b0;
      recovery_ready <= 1'b0;
    end else begin
      lookup_valid_q <= lu_valid && (state == S_IDLE);
      // Keep each response until MEM commits it. The commit strobe is
      // level-held through stalls, so only clear on the retire cycle
      // (cm_ready) exactly as the old single-cycle pulse did; clearing on
      // a still-waiting commit would drop the hit before it is consumed.
      // A snoop kill of the looked-up line voids the held hit first: the
      // line is dead, so the next commit must re-miss, never consume it.
      if (snoop_kill_lu) begin
        lookup_hit_q <= 1'b0;
      end else if (lu_valid) begin
        lookup_hit_q <= lu_hit_live;
      end else if (cm_valid && cm_ready) begin
        lookup_hit_q <= 1'b0;
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
      // A snoop kill of the pending line discards the recovery with it:
      // the invalidation raced the fill, so the commit must re-miss and
      // refetch rather than consume possibly-stale data.
      if (flush_entry) begin
        pending_miss <= 1'b0;
        recovery_ready <= 1'b0;
      end else if (miss_pulse || race_miss) begin
        pending_miss <= 1'b1;
        recovery_ready <= 1'b0;
      end else if (snoop_kill_pending) begin
        pending_miss <= 1'b0;
        recovery_ready <= 1'b0;
      end
    end
  end

  always_comb begin
    ram_raddr = {lu_addr[IDX_HI:IDX_LO], lu_addr[OFF_BITS+1:2]};
    // A lookup owns the response until commit. EX may already present
    // another packet while MEM is paused, without issuing a new lookup.
    if (!lu_valid || (pending_miss && !recovery_ready)) begin
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
  // Only the live lookup and saved miss address belong on its read path.
  assign forward_raddr = (!lu_valid || (pending_miss && !recovery_ready)) ?
                         lu_addr_q[IDX_HI:2] : lu_addr[IDX_HI:2];
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
    logic [BANK_ADDR_BITS-1:0] read_addr;
    logic [BANK_ADDR_BITS-1:0] write_addr;
    assign read_addr = forward_raddr[BANK_ADDR_BITS-1:0];
    assign write_addr = ram_waddr[BANK_ADDR_BITS-1:0];
    assign word_data = {
      bank_lane3[read_addr], bank_lane2[read_addr], bank_lane1[read_addr], bank_lane0[read_addr]
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
  assign forward_offset = (!lu_valid || (pending_miss && !recovery_ready)) ? lookup_offset_q : lu_offset;
  assign forward_funct3 = (!lu_valid || (pending_miss && !recovery_ready)) ? lookup_funct3_q : lu_funct3;
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

  assign mem_req = (state == S_WB_REQ) || (state == S_FILL_REQ) || (state == S_FLUSH_REQ);
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

      // MSI snoop invalidate: drop clean lines immediately. Dirty hits
      // are retained so the hub can flush them first (see snoop_dirty).
      // valid_ram alone gates lookups, so the lookup-tag mirror needs no
      // update here (it refreshes on the next fill to this index).
      if (snoop_invalidate && snoop_valid && valid_ram[snoop_idx] &&
          (tag_ram[snoop_idx] == snoop_tag) && !dirty_ram[snoop_idx]) begin
        valid_ram[snoop_idx] <= 1'b0;
      end

      // Save the store payload alongside the address comparison. The commit
      // strobe is level-held through stalls, so qualify with cm_ready: only a
      // retire-cycle (ready) commit may set dirty state. Otherwise a store
      // that is still waiting for its fill would dirty an invalid line and
      // the eviction would write back unfilled (zero) data over SDRAM.
      // A snoop kill of the committing line vetoes the retire: the line
      // is dead, so the hub believes it is gone -- dirtying it would leave
      // a dirty-invalid entry whose later writeback would clobber the
      // peer's data. The commit re-misses instead.
      prev_store_be <= ((state == S_IDLE) && cm_valid && cm_ready && cm_we && lu_valid &&
                        !snoop_kill_cm) ? cm_be :
          4'b0000;
      if ((state == S_IDLE) && cm_valid && cm_ready && cm_we && !snoop_kill_cm &&
          (!upgrade_needed || upgrade_ack)) begin
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
          end else if (miss_pulse || race_miss) begin
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
      if (state == S_FLUSH || state == S_FLUSH_REQ || state == S_FLUSH_RD || state == S_FLUSH_WR) begin
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
