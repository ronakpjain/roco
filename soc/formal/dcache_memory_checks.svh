// One arbitrary word in the coherent backing store. The CPU copy updates
// only on stores to that address; the memory copy updates only on bus beats.
`ifdef ROCO_SOC_DCACHE_MEMORY_FORMAL
`define DCACHE_ENV_CHECK assert
logic [24:2] f_watch_addr;
logic [31:0] f_initial, f_reset_word;
logic f_abandoned_q, f_abandoned;
assign f_watch_addr = formal_memory_addr;
assign f_reset_word = formal_initial_word;
assign f_abandoned = f_abandoned_q || formal_cancel;
always_ff @(posedge clk) begin
  if (rst) f_initial <= formal_initial_word;
  if (rst) f_abandoned_q <= 1'b0;
  else if (formal_cancel && f_pending) f_abandoned_q <= 1'b1;
end
`else
`define DCACHE_ENV_CHECK assume
initial assume (rst);
// This harness models one cache and no coherent peer.
always_comb assume (!snoop_valid && !snoop_writeback && !cm_amo_read);
(* anyconst *) logic [24:2] f_watch_addr;
(* anyconst *) logic [31:0] f_initial;
wire f_abandoned = 1'b0;
wire [31:0] f_reset_word = f_initial;
`endif
logic [31:0] f_arch_word, f_mem_word, f_ram_word, f_check_forward_word;
logic [31:0] f_forward_cell[BANK_COUNT];
logic [IDX_BITS-1:0] f_index;
logic [OFF_BITS-1:0] f_offset;
logic [IDX_BITS+OFF_BITS-1:0] f_location;
logic f_cached, f_refilled, f_data_valid;
logic f_pending, f_past_valid;
logic [24:2] f_cpu_addr;
logic [1:0] f_cpu_offset;
logic [2:0] f_cpu_funct3;
logic f_mem_active, f_mem_write;
logic [22:0] f_mem_base, f_beat_addr;
logic [OFF_BITS-1:0] f_mem_beat;
logic f_evicting, f_flushing, f_miss_active;
logic f_watch_flush, f_forward_pair;

initial f_past_valid = 1'b0;
assign f_location = f_watch_addr[IDX_HI:2];
assign {f_index, f_offset} = f_location;
assign f_cached = valid_ram[f_index] && tag_ram[f_index] == f_watch_addr[24:IDX_HI+1] &&
                  !(state == S_FILL && miss_idx == f_index);
assign f_refilled = state == S_FILL && miss_line_word == (f_watch_addr & LINE_MASK) &&
                    beat > f_offset;
assign f_data_valid = f_cached || f_refilled;
assign f_ram_word = {lane3[f_location], lane2[f_location], lane1[f_location], lane0[f_location]};
assign f_check_forward_word = f_forward_cell[f_location>>BANK_ADDR_BITS];
assign f_beat_addr = f_mem_base + 23'(f_mem_beat);
`ifdef ROCO_SOC_DCACHE_MEMORY_FORMAL
assign formal_beat_word = f_beat_addr;
assign formal_memory_active = f_mem_active;
assign formal_memory_write = f_mem_write;
assign formal_write_left = f_mem_active && f_mem_write ? 5'(LINE_WORDS) - 5'(f_mem_beat) : 5'd0;
assign formal_read_left = f_mem_active && !f_mem_write ? 5'(LINE_WORDS) - 5'(f_mem_beat) : 5'd0;
assign formal_pending = f_pending;
assign formal_abandoned = f_abandoned;
assign formal_cpu_word = f_cpu_addr;
assign formal_arch_data = f_arch_word;
`endif
assign f_evicting = state == S_WB_RD || state == S_WB_WR;
assign f_flushing = state == S_FLUSH_RD || state == S_FLUSH_WR;
assign f_miss_active = state == S_START || state == S_WB_REQ || f_evicting ||
                       state == S_FILL_REQ || state == S_FILL;

function automatic logic [31:0] f_merge(input logic [31:0] prior, input logic [31:0] payload,
                                        input logic [3:0] byte_en);
  for (int lane = 0; lane < 4; lane++) begin
    f_merge[8*lane+:8] = byte_en[lane] ? payload[8*lane+:8] : prior[8*lane+:8];
  end
endfunction

function automatic logic [31:0] f_format(input logic [31:0] word_data, input logic [1:0] offset,
                                         input logic [2:0] kind);
  logic [7:0] lo, hi;
  lo = word_data[8*offset+:8];
  hi = offset == 2'd3 ? 8'd0 : word_data[8*(int'(offset)+1)+:8];
  case (kind)
    3'b000, 3'b100: f_format = {{24{!kind[2] && lo[7]}}, lo};
    3'b001, 3'b101: f_format = {{16{!kind[2] && hi[7]}}, hi, lo};
    default: f_format = word_data;
  endcase
endfunction

always_ff @(posedge clk) begin
  f_past_valid <= 1'b1;
  if (rst) begin
`ifdef ROCO_SOC_DCACHE_MEMORY_FORMAL
    // A maintenance reset may discard metadata only after all committed
    // stores have reached backing memory. Global reset begins a new epoch.
    if (!formal_global_reset) assert (f_arch_word == formal_backing_word);
`endif
    f_arch_word <= f_reset_word;
    f_mem_word <= f_reset_word;
    {f_pending, f_cpu_addr, f_cpu_offset, f_cpu_funct3} <= '0;
    {f_mem_active, f_mem_write, f_mem_base, f_mem_beat} <= '0;
    {f_watch_flush, f_forward_pair} <= '0;
  end else begin
    // One lookup owns MEM until the ready-qualified commit. A new lookup
    // may overlap the retiring access. FENCE.I holds flush through done.
    if (cm_valid) `DCACHE_ENV_CHECK(f_pending && !f_abandoned && cm_ready && cm_addr == f_cpu_addr);
    if (lu_valid) `DCACHE_ENV_CHECK(!f_abandoned && (!f_pending || cm_valid));
    if (flush) `DCACHE_ENV_CHECK((!f_pending || f_abandoned) && !lu_valid);
    if (f_past_valid && !$past(rst) && $past(flush && !flush_done)) `DCACHE_ENV_CHECK(flush);
    if (lu_valid) begin
      f_pending <= 1'b1;
      {f_cpu_addr, f_cpu_offset, f_cpu_funct3} <= {lu_addr, lu_offset, lu_funct3};
    end else if (cm_valid) f_pending <= 1'b0;
    // The architectural copy advances exactly when the DUT retires the store.
    if (cm_valid && cm_we && cm_addr == f_watch_addr && cm_ready) begin
      f_arch_word <= f_merge(f_arch_word, cm_wdata, cm_be);
    end

    // The backing agent can stall all channels. It returns exactly one
    // line per accepted read and produces the current value at the watch.
    if (mem_rvalid) begin
      `DCACHE_ENV_CHECK(f_mem_active && !f_mem_write && mem_rlast == (f_mem_beat == LAST_BEAT));
      if (f_beat_addr == f_watch_addr) `DCACHE_ENV_CHECK(mem_rdata == f_mem_word);
    end
    if (mem_req && mem_ready) begin
      assert (!f_mem_active);
      {f_mem_active, f_mem_write, f_mem_base, f_mem_beat} <= {
        1'b1, mem_we, mem_word_addr, {OFF_BITS{1'b0}}
      };
    end
    if (mem_rvalid || (mem_wvalid && mem_wready)) begin
      if (f_mem_beat == LAST_BEAT) f_mem_active <= 1'b0;
      else f_mem_beat <= f_mem_beat + 1'b1;
    end
    if (mem_wvalid) begin
      assert (f_mem_active && f_mem_write && mem_wbe == 4'hf);
      if (f_beat_addr == f_watch_addr) begin
        assert (mem_wdata == f_arch_word);
        if (mem_wready) f_mem_word <= f_merge(f_mem_word, mem_wdata, mem_wbe);
      end
    end
    if (f_past_valid && !$past(rst)) begin
      if ($past(mem_req && !mem_ready))
        assert (mem_req && $stable({mem_we, mem_word_addr, mem_len}));
      if ($past(mem_wvalid && !mem_wready)) assert (mem_wvalid && $stable({mem_wdata, mem_wbe}));
    end
    if (mem_req)
      assert (mem_len == 4'(LINE_WORDS - 1) && (mem_word_addr & LINE_MASK) == mem_word_addr);

`ifdef ROCO_SOC_DCACHE_MEMORY_FORMAL
    // Observe external boot writes at their native handshake. The real
    // sequencer must have invalidated this cache before admitting them.
    assert (f_mem_word == formal_backing_word);
    if (!formal_cancel) assert (!f_abandoned_q);
    if (formal_flush_clean) assert (f_mem_word == f_arch_word);
    if (formal_boot_loading) begin
      assert (state == S_IDLE && !pending_miss && !lookup_valid_q && !lookup_hit_q);
      assert (!f_mem_active && !f_pending && !f_abandoned_q && !valid_ram[f_index]);
    end
    if (formal_external_write) begin
      assert (!f_data_valid && !lu_valid && !cm_valid);
      assert (!(mem_wvalid && mem_wready));
      f_mem_word <= f_merge(f_mem_word, formal_external_data, formal_external_be);
      f_arch_word <= f_merge(f_arch_word, formal_external_data, formal_external_be);
    end
`endif

    // The watched word can differ from backing memory only while dirty.
    if (f_data_valid) begin
      assert (f_ram_word == f_arch_word);
      assert (f_check_forward_word == f_arch_word);
    end
    if (!f_cached || !dirty_ram[f_index] ||
        (f_mem_active && f_mem_write && f_mem_base == (f_watch_addr & LINE_MASK) &&
         f_mem_beat > f_offset))
      assert (f_mem_word == f_arch_word);
    if (f_pending && !f_abandoned && cm_ready && f_cpu_addr == f_watch_addr) begin
      assert (f_cached);
      assert (cm_rdata == f_arch_word);
      assert (cm_forward_data == f_format(f_arch_word, f_cpu_offset, f_cpu_funct3));
    end
    if (flush_done) assert (f_mem_word == f_arch_word);

    // Supporting relations for induction. Nothing about the DUT's state
    // is assumed, including the contents of its duplicate RAMs and tags.
    if (valid_ram[f_index]) assert (lookup_tag_ram[f_index] == tag_ram[f_index]);
    if (dirty_ram[f_index]) assert (valid_ram[f_index]);
    if ((state == S_WB_REQ || f_evicting) && miss_idx == f_index) assert (dirty_ram[f_index]);
    if ((state == S_FLUSH_REQ || f_flushing) && flush_idx == f_index) assert (dirty_ram[f_index]);
    assert (f_mem_active == (f_evicting || f_flushing || state == S_FILL));
    if (f_mem_active) begin
      assert (f_mem_beat == beat);
      assert (f_mem_write == (f_evicting || f_flushing));
      assert (f_mem_base == (f_evicting ? victim_word : f_flushing ? flush_word : miss_line_word));
    end
`ifndef ROCO_SOC_DCACHE_MEMORY_FORMAL
    assert (!probe_writeback_active);
`endif
    if (read_valid_q) assert (state == S_IDLE);
    if (f_pending) begin
      assert ({lu_addr_q, lookup_offset_q, lookup_funct3_q} ==
              {f_cpu_addr, f_cpu_offset, f_cpu_funct3});
      if (read_valid_q && !f_abandoned) assert (read_addr_q == f_cpu_addr);
    end
    if (lookup_valid_q) assert (f_pending && !pending_miss && state == S_IDLE);
    if (f_miss_active) begin
      assert (pending_miss && !recovery_ready && f_pending);
      assert (miss_line_word == (f_cpu_addr & LINE_MASK));
      assert ({miss_tag, miss_idx} == miss_line_word[22:OFF_BITS]);
    end
    if (state == S_FILL || state == S_FILL_REQ) begin
      if (miss_idx == f_index) assert (!dirty_ram[f_index]);
    end
    if (pending_miss) assert (f_pending);
    if (recovery_ready) assert (pending_miss && (state == S_IDLE || f_abandoned));
    if (f_pending && !f_abandoned && !pending_miss && f_cpu_addr[IDX_HI:IDX_LO] == f_index) begin
      assert (cm_ready == (valid_ram[f_index] && tag_ram[f_index] == f_cpu_addr[24:IDX_HI+1]));
    end
    if (f_pending && !f_abandoned && f_cpu_addr[IDX_HI:IDX_LO] == f_index &&
        (lookup_hit_q || (pending_miss && state == S_IDLE))) begin
      assert (state == S_IDLE && valid_ram[f_index]);
      assert (tag_ram[f_index] == f_cpu_addr[24:IDX_HI+1]);
    end
    if (state == S_FLUSH || state == S_FLUSH_REQ || f_flushing) begin
      assert (flush_active && flush && !flush_done && (!f_pending || f_abandoned));
      if (f_index < flush_idx) assert (!dirty_ram[f_index]);
    end
    if (flush_done && flush) assert (!dirty_ram[f_index]);

    if (flush_done && f_mem_word != f_initial) f_watch_flush <= 1'b1;
    cover (f_watch_flush && cm_valid && !cm_we &&
           cm_addr == f_watch_addr && f_arch_word != f_initial);
    cover (mem_wvalid && mem_wready && f_evicting && f_beat_addr == f_watch_addr &&
           f_mem_word != f_arch_word);
    f_forward_pair <= cm_valid && cm_we && cm_addr == f_watch_addr && lu_valid &&
                      lu_addr == f_watch_addr && f_merge(
        f_arch_word, cm_wdata, cm_be
    ) != f_arch_word;
    cover (f_forward_pair && cm_valid && !cm_we);
  end
end
`undef DCACHE_ENV_CHECK
