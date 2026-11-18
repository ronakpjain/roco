// One arbitrary architectural register models both physical read ports and
// the stored state underneath the scalar write bypass.
(* anyconst *) logic [4:0] watched_reg;
logic [31:0] reference_value;
logic past_clock = 1'b0;
logic normal_hits;
assign normal_hits = we && rd == watched_reg && watched_reg != 0;

always @(posedge clk) begin
  past_clock <= 1;
  if (!past_clock) assume (rst);
  if (rst) begin
    reference_value <= 0;
  end else begin
    if (dwe && drd != 0) begin
      if (drd == watched_reg) reference_value <= ddata;
    end else if (normal_hits) begin
      reference_value <= wdata;
    end

    if (watched_reg == 0) assert (!valid_regs[0]);
    assert ((valid_regs[watched_reg] ? regs[watched_reg] : 32'd0) == reference_value);
    if (rs1 == watched_reg) assert (rdata1 == (normal_hits ? wdata : reference_value));
    if (rs2 == watched_reg) assert (rdata2 == (normal_hits ? wdata : reference_value));

    cover (normal_hits && rs1 == watched_reg && wdata != reference_value);
    cover (dwe && drd == watched_reg && drd != 0 && !we);
    cover (normal_hits && dwe && drd != 0 && drd != rd);
    cover (normal_hits && dwe && drd == rd && ddata != wdata);
  end
end
