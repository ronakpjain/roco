// The backing memory promises one immutable word at any chosen physical
// address. All other words may vary. Check the actual refill and RAM, not
// just the address supplied to the fetch queue.
localparam int BackingTagBits = 23 - IDX_BITS - OFF_BITS;
logic [IDX_BITS-1:0] backing_row;
logic [OFF_BITS-1:0] backing_offset;
logic [BackingTagBits-1:0] backing_tag;
logic backing_fill, backing_cached;
assign {backing_tag, backing_row, backing_offset} = formal_watch_word;
assign backing_fill = fill_word_addr == (formal_watch_word & LINE_MASK);
assign backing_cached = valid_ram[backing_row] &&
                        tag_ram[backing_row][BackingTagBits-1:0] == backing_tag;
always @(posedge clk) begin
  if (!rst) begin
    assert (formal_filling == (state == S_FILL));
    if (formal_filling) assert (formal_ram_addr == fill_word_addr + 23'(beat));
    if (state != S_IDLE) begin
      assert (fill_word_addr[OFF_BITS-1:0] == 0);
      assert ({fill_tag[BackingTagBits-1:0], fill_idx} == fill_word_addr[22:OFF_BITS]);
      assert (!lookup_pending);
    end
    if ((backing_cached && !(state == S_FILL && fill_idx == backing_row && beat > backing_offset)) ||
        (state == S_FILL && backing_fill && beat > backing_offset))
      assert (data_ram[{backing_row, backing_offset}] == formal_watch_data);
    if (cpu_rsp_valid && cpu_rsp_addr[24:2] == formal_watch_word)
      assert (cpu_rsp_data == formal_watch_data);
  end
end
