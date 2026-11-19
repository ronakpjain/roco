// One arbitrary SDRAM word. The device copy changes only at the pins;
// the architectural copy changes only on accepted AXI W beats. No coherence
// is required of any other word, so aliases with unrelated traffic are tested.
(* anyconst *) logic [22:0] cell_addr;
(* anyconst *) logic [31:0] initial_cell;
(* anyseq *) logic [15:0] other_halfword;
logic [31:0] pin_cell, axi_cell, accepted_data;
logic [3:0] accepted_mask;
logic pin_read, pin_write, high_write, axi_write;
logic expect_low, expect_high;
logic [22:0] pin_word;
logic [4:0] read_valid_pipe;
(* mem2reg *) logic [15:0] read_data_pipe[5];

assign pin_word = {f_pin_row, sd_a[8:1]};
assign pin_read = !sd_cs_n && sd_ras_n && !sd_cas_n && sd_we_n && pin_word == cell_addr;
assign pin_write = !sd_cs_n && sd_ras_n && !sd_cas_n && !sd_we_n && pin_word == cell_addr;
assign axi_write = active && writing && supported && w_fire &&
                   base[24:2] + 23'(transferred) == cell_addr;
assign sd_dq_in = read_valid_pipe[0] ? read_data_pipe[0] : other_halfword;

function automatic logic [15:0] overlay(input logic [15:0] prior, input logic [15:0] payload,
                                        input logic [1:0] mask);
  overlay = {mask[1] ? payload[15:8] : prior[15:8], mask[0] ? payload[7:0] : prior[7:0]};
endfunction

always_ff @(posedge clk) begin
  if (rst) begin
    pin_cell <= initial_cell;
    axi_cell <= initial_cell;
    {high_write, expect_low, expect_high, accepted_data, accepted_mask, read_valid_pipe} <= '0;
    for (int i = 0; i < 5; i++) read_data_pipe[i] <= '0;
  end else begin
    // The BL2/CL3 pin model snapshots the tracked word on READ, returns
    // low then high, and samples DQ/DQM separately on each write edge.
    read_valid_pipe <= {1'b0, read_valid_pipe[4:1]};
    for (int i = 0; i < 4; i++) read_data_pipe[i] <= read_data_pipe[i+1];
    if (pin_read) begin
      read_valid_pipe[4:3] <= 2'b11;
      read_data_pipe[3] <= pin_cell[15:0];
      read_data_pipe[4] <= pin_cell[31:16];
    end
    high_write <= pin_write;
    if (pin_write) pin_cell[15:0] <= overlay(pin_cell[15:0], sd_dq_out, ~sd_dqm);
    if (high_write) pin_cell[31:16] <= overlay(pin_cell[31:16], sd_dq_out, ~sd_dqm);

    expect_low <= axi_write;
    expect_high <= expect_low;
    if (axi_write) begin
      accepted_data <= w.data;
      accepted_mask <= w.strb;
      axi_cell <= {
        overlay(axi_cell[31:16], w.data[31:16], w.strb[3:2]),
        overlay(axi_cell[15:0], w.data[15:0], w.strb[1:0])
      };
    end
    assert (pin_write == expect_low);
    assert (high_write == expect_high);
    assert (!(axi_write && (expect_low || expect_high)));
    if (expect_low)
      assert (sd_dq_oe && {sd_dq_out, sd_dqm} == {accepted_data[15:0], ~accepted_mask[1:0]});
    if (expect_high)
      assert (sd_dq_oe && {sd_dq_out, sd_dqm} == {accepted_data[31:16], ~accepted_mask[3:2]});
    assert (axi_cell[15:0] == (expect_low ? overlay(
        pin_cell[15:0], accepted_data[15:0], accepted_mask[1:0]
    ) : pin_cell[15:0]));
    assert (axi_cell[31:16] == (expect_low || expect_high ? overlay(
        pin_cell[31:16], accepted_data[31:16], accepted_mask[3:2]
    ) : pin_cell[31:16]));

    if (b.valid) assert (pin_cell == axi_cell);
    if (rvalid && base[24:2] + 23'(received) == cell_addr) assert (rdata == axi_cell);
    // The adapter's arbitrary buffer index is independent of the tracked
    // physical word. Together these invariants cover each R position.
    if (active && !writing && supported && received > 5'(f_watch) &&
        base[24:2] + 23'(f_watch) == cell_addr)
      assert (watched_data == axi_cell);
    if (r.valid && supported && transferred == 9'(f_watch) &&
        base[24:2] + 23'(transferred) == cell_addr)
      assert (r.data == axi_cell);
    cover (r_fire && supported && transferred == 9'(f_watch) &&
           base[24:2] + 23'(transferred) == cell_addr && axi_cell != initial_cell);
  end
end
