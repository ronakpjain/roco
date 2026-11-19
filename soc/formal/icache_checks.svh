// Scoreboard for the public lookup/refill protocol. Only one arbitrary
// row and word are shadowed; proving the assertions quantifies over both.
(* anyconst *) logic [IDX_BITS-1:0] watch_index;
(* anyconst *) logic [OFF_BITS-1:0] watch_offset;
logic check_lookup, check_hit, check_word_valid;
logic [31:0] check_lookup_addr, check_word;
logic row_valid;
logic [TAG_BITS-1:0] row_tag;
logic [31:0] row_word;
logic request_pending, burst_pending, drop_fill;
logic [31:0] miss_address;
logic [OFF_BITS-1:0] burst_beat;
logic past_reset = 1'b1;
always @(posedge clk) begin
  past_reset <= 1'b0;
  if (past_reset) assume (rst);
  // The arbiter returns exactly LINE_WORDS ordered beats for an
  // accepted refill. It need not accept or supply a beat at any time.
  if (!rst && mem_rvalid) begin
    assume (burst_pending);
    assume (mem_rlast == (burst_beat == OFF_BITS'(LINE_WORDS - 1)));
  end
end

always @(posedge clk) begin
  check_lookup_addr <= cpu_addr;
  check_hit <= row_valid && (row_tag == cpu_addr[31:IDX_HI+1]);
  check_word_valid <= cpu_addr[OFF_BITS+1:2] == watch_offset;
  check_word <= row_word;
  if (rst) begin
    check_lookup <= 0;
    row_valid <= 0;
    request_pending <= 0;
    burst_pending <= 0;
    drop_fill <= 0;
    burst_beat <= 0;
  end else begin
    check_lookup <= cpu_req && !cpu_busy && !flush;
    if (flush) row_valid <= 0;
    if (cpu_miss) begin
      request_pending <= 1;
      miss_address <= check_lookup_addr;
      drop_fill <= flush;
    end else if (flush && (request_pending || burst_pending)) begin
      drop_fill <= 1;
    end
    if (mem_req && mem_ready) begin
      request_pending <= 0;
      burst_pending <= 1;
      burst_beat <= 0;
    end
    if (mem_rvalid) begin
      burst_beat <= burst_beat + 1'b1;
      if (miss_address[IDX_HI:IDX_LO] == watch_index && burst_beat == watch_offset)
        row_word <= mem_rdata;
      if (mem_rlast) begin
        burst_pending <= 0;
        if (miss_address[IDX_HI:IDX_LO] == watch_index) begin
          row_tag <= miss_address[31:IDX_HI+1];
          row_valid <= !drop_fill && !flush;
        end
      end
    end
  end
end

always @(posedge clk) begin
  if (!rst && !past_reset) begin
    assert (cpu_busy == (request_pending || burst_pending || cpu_miss));
    assert (mem_req == request_pending);
    assert (!(cpu_rsp_valid && cpu_miss));
    assert ((cpu_rsp_valid || cpu_miss) == check_lookup);
    if (check_lookup) begin
      assert (cpu_rsp_addr == check_lookup_addr);
      if (check_lookup_addr[IDX_HI:IDX_LO] == watch_index) begin
        assert (cpu_rsp_valid == check_hit);
        if (check_hit && check_word_valid) assert (cpu_rsp_data == check_word);
      end
    end
    if (mem_req) begin
      assert (mem_word_addr == (miss_address[24:2] & LINE_MASK));
      assert (mem_len == 4'(LINE_WORDS - 1));
    end

    // Induction anchors, including the data during a partially filled
    // line. Every anchor is asserted on the RTL, not assumed.
    assert (request_pending == (state == S_REQ));
    assert (burst_pending == (state == S_FILL));
    assert (request_pending || burst_pending || state == S_IDLE);
    assert (check_lookup == lookup_pending);
    if (burst_pending) assert (beat == burst_beat);
    if (request_pending || burst_pending) begin
      assert (fill_idx == miss_address[IDX_HI:IDX_LO]);
      assert (fill_tag == miss_address[31:IDX_HI+1]);
      assert (fill_word_addr == (miss_address[24:2] & LINE_MASK));
      assert (flush_pending == drop_fill);
    end
    assert (valid_ram[watch_index] == row_valid);
    if (row_valid) assert (tag_ram[watch_index] == row_tag);
    // Suppress uninitialized words prior to the beat that writes them.
    if (row_valid || (burst_pending && fill_idx == watch_index && beat > watch_offset))
      assert (data_ram[{watch_index, watch_offset}] == row_word);
    cover (cpu_rsp_valid && check_lookup_addr[IDX_HI:IDX_LO] == watch_index && check_word_valid);
    cover (burst_pending && drop_fill && mem_rvalid && mem_rlast);
    cover (mem_req && !mem_ready);
  end
end
