// Pin-facing safety monitor for the actual controller. No SDRAM data model
// is needed: every sampled halfword is symbolic and must be preserved.
initial assume (rst);
logic f_past_valid;
logic f_activate, f_precharge, f_refresh, f_mode, f_read, f_write, f_accept_w;
logic f_open;
logic [1:0] f_bank;
logic [12:0] f_row;
logic [CL+1:0] f_read_delay, f_last_delay;
logic f_busy, f_request, f_request_we;
logic [22:0] f_word_addr;
logic [3:0] f_len;
logic [4:0] f_read_commands, f_written_words;
logic [8:0] f_column;
logic [31:0] f_write_word;
logic [3:0] f_write_mask;
logic [1:0] f_write_half;

initial f_past_valid = 1'b0;
assign f_activate = !sd_cs_n && !sd_ras_n && sd_cas_n && sd_we_n;
assign f_precharge = !sd_cs_n && !sd_ras_n && sd_cas_n && !sd_we_n;
assign f_refresh = !sd_cs_n && !sd_ras_n && !sd_cas_n && sd_we_n;
assign f_mode = !sd_cs_n && !sd_ras_n && !sd_cas_n && !sd_we_n;
assign f_read = !sd_cs_n && sd_ras_n && !sd_cas_n && sd_we_n;
assign f_write = !sd_cs_n && sd_ras_n && !sd_cas_n && !sd_we_n;
assign f_accept_w = wvalid && wready;
assign f_request = req_valid && req_ready;
assign f_column = 9'(f_word_addr[7:0]) + (f_write ? 9'(f_written_words) : 9'(f_read_commands));

always_ff @(posedge clk) begin
  f_past_valid <= 1'b1;
  if (rst) begin
    {f_open, f_bank, f_row, f_read_delay, f_last_delay} <= '0;
    {f_busy, f_request_we, f_word_addr, f_len, f_read_commands, f_written_words} <= '0;
    {f_write_half, f_write_word, f_write_mask} <= '0;
  end else begin
    if (f_request) begin
      assume (9'(req_word_addr[7:0]) + 9'(req_len) <= 9'd255);
      assert (!f_busy);
      f_busy <= 1'b1;
      f_request_we <= req_we;
      f_word_addr <= req_word_addr;
      f_len <= req_len;
      {f_read_commands, f_written_words} <= '0;
    end
    if (f_read) f_read_commands <= f_read_commands + 5'd1;
    if (f_write_half == 2) f_written_words <= f_written_words + 5'd1;
    if (f_last_delay[CL+1] || (f_write_half == 2 && f_written_words == 5'(f_len))) begin
      f_busy <= 1'b0;
    end
    if (f_activate) begin
      assert (!f_open && init_done);
      f_open <= 1'b1;
      f_bank <= sd_ba;
      f_row <= sd_a;
    end
    if (f_precharge) begin
      assert (sd_a[10]);
      f_open <= 1'b0;
    end
    if (f_refresh || f_mode) assert (!f_open);
    if (f_mode) assert (!init_done && sd_ba == 0 && sd_a == (13'd1 | (13'(CL) << 4)));
    if (f_read || f_write) begin
      assert (init_done && f_open && sd_ba == f_bank && !sd_a[0]);
      assert (f_busy && f_row == f_word_addr[20:8] && sd_ba == f_word_addr[22:21]);
      assert (f_write == f_request_we);
      assert ((f_write ? f_written_words : f_read_commands) <= 5'(f_len));
      assert (f_column <= 9'd255 && sd_a[8:0] == {f_column[7:0], 1'b0});
    end

    if (f_accept_w) begin
      assert (f_write_half == 0);
      f_write_half <= 1;
      f_write_word <= wdata;
      f_write_mask <= wbe;
    end else if (f_write_half == 1) f_write_half <= 2;
    else f_write_half <= 0;
    assert (f_write == (f_write_half == 1));
    assert (sd_dq_oe == (f_write_half != 0));
    if (f_write_half == 1) begin
      assert ({sd_dq_out, sd_dqm} == {f_write_word[15:0], ~f_write_mask[1:0]});
    end
    if (f_write_half == 2) begin
      assert (sd_cs_n);
      assert ({sd_dq_out, sd_dqm} == {f_write_word[31:16], ~f_write_mask[3:2]});
    end

    f_read_delay <= {f_read_delay[CL:0], f_read};
    f_last_delay <= {f_last_delay[CL:0], f_read && f_read_commands == 5'(f_len)};
    if (f_past_valid && !$past(rst)) begin
      // BL2 low is sampled CL+1 edges after READ; high follows one
      // edge later. The output flop publishes the assembled word.
      assert (rvalid == $past(f_read_delay[CL+1]));
      if (rvalid) begin
        assert (rlast == $past(f_last_delay[CL+1]));
        assert (rdata[31:16] == $past(sd_dq_in));
      end
      if (rvalid) assert (rdata[15:0] == $past(sd_dq_in, 2));
    end

    cover (rvalid && rlast && f_len == 15);
    cover (f_write_half == 2 && f_written_words == 15);
    cover (f_refresh && init_done);

    // Inductive links to the pin monitor. These are checked, not assumed.
    assert (f_open == row_open);
    if (f_open) assert ({f_bank, f_row} == {row_bank, row_addr});
    assert (init_done == (state >= S_IDLE));
    if (!init_done || state == S_ACT || state == S_REFRESH || state == S_PRECHARGE_WAIT) begin
      assert (!row_open);
    end
    if (state == S_READ || state == S_WRITE || state == S_ACT_WAIT) begin
      assert (init_done && row_open && row_bank == cmd_bank && row_addr == cmd_row);
    end
    assert (f_write_half == (state == S_WRITE ? wr_phase : 2'd0));
    assert (f_write_half <= 2);
    if (f_write_half != 0) assert ({f_write_word, f_write_mask} == {wr_word, wr_be});
    assert (f_busy == (state == S_ACT || state == S_ACT_WAIT || state == S_READ ||
                      state == S_WRITE || ((state == S_PRECHARGE ||
                      state == S_PRECHARGE_WAIT) && !pre_for_refresh)));
    if (f_busy) begin
      assert ({cmd_addr, cmd_len, cmd_we} == {f_word_addr, f_len, f_request_we});
      assert (9'(f_word_addr[7:0]) + 9'(f_len) <= 9'd255);
      if (state != S_READ) assert (f_read_commands == 0);
      if (state != S_WRITE) assert (f_written_words == 0);
    end
    if (state == S_WRITE) begin
      assert (cmd_we && 5'(wr_beat) == f_written_words && wr_beat <= cmd_len);
    end
    if (state == S_READ) begin
      assert (!cmd_we && rd_issue == f_read_commands);
      assert (rd_t <= 2 * 6'(cmd_len) + 6'(CL + 2));
      assert (rd_issue == (((rd_t + 6'd1) >> 1) > 6'(cmd_len) ?
                          (5'(cmd_len) + 5'd1) : 5'((rd_t + 6'd1) >> 1)));
    end
    for (int j = 0; j < CL + 2; j++) begin
      assert (f_read_delay[j] == (state == S_READ && rd_t > 6'(j) &&
                                 ((rd_t - 6'(j+1)) & 6'd1) == 0 &&
                                 ((rd_t - 6'(j+1)) >> 1) <= 6'(cmd_len)));
      assert (f_last_delay[j] == (f_read_delay[j] && ((rd_t - 6'(j + 1)) >> 1) == 6'(cmd_len)));
    end
  end
end
