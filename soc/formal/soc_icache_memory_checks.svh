// Relate instruction bytes to the CPU data-port reference after cache
// invalidation. A store to this word ends coherence until the next fence;
// the real boot sequencer admits external writes only with invalid lines.
logic [31:0] coherent_byte_addr;
logic coherent_cached, coherent_fill;
assign coherent_byte_addr = {7'd8, formal_watch_word, 2'b00};
assign coherent_cached = row_valid && row_tag == coherent_byte_addr[31:IDX_HI+1];
assign coherent_fill = fill_word_addr == (formal_watch_word & LINE_MASK);

always_ff @(posedge clk) begin
  if (!rst) begin
    assert ((formal_read_left != 0) == burst_pending);
    if (burst_pending) begin
      assert (formal_read_left == 3'(LINE_WORDS) - 3'(burst_beat));
      assert (formal_ram_word == fill_word_addr + 23'(burst_beat));
    end
    if (mem_rvalid && formal_ram_word == formal_watch_word)
      assert (mem_rdata == formal_backing_data);
    if (formal_boot_loading) begin
      assert (!lookup_pending && !row_valid);
      if (request_pending || burst_pending) assert (drop_fill);
    end
    if (formal_coherent) begin
      if ((coherent_cached && !(burst_pending && fill_idx == watch_index)) ||
          (burst_pending && coherent_fill && burst_beat > watch_offset && !drop_fill)) begin
        assert (row_word == formal_watch_data);
        assert (data_ram[{watch_index, watch_offset}] == formal_watch_data);
      end
      if (check_lookup && check_hit && check_word_valid &&
          check_lookup_addr[31:2] == coherent_byte_addr[31:2])
        assert (check_word == formal_watch_data);
      if (cpu_rsp_valid && cpu_rsp_addr[31:2] == coherent_byte_addr[31:2])
        assert (cpu_rsp_data == formal_watch_data);
    end
  end
end
