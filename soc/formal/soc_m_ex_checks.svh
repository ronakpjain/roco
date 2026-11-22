// verilog_syntax: parse-as-module-body
// Account for the one outstanding divide by its launch, independently
// of the busy and pending-completion state used by the GPR scoreboard.
logic f_div_waiting;
logic [4:0] f_div_dest;
logic [2:0] f_div_op;
always_ff @(posedge clk or posedge rst) begin
  if (rst) begin
    f_div_waiting <= 1'b0;
    f_div_dest <= '0;
    f_div_op <= '0;
  end else if (div_start) begin
    f_div_waiting <= idex_rd != 0;
    f_div_dest <= idex_instr[11:7];
    f_div_op <= idex_instr[14:12];
  end else if (div_wb_en) begin
    f_div_waiting <= 1'b0;
  end
end

always_ff @(posedge clk) begin
  if (!rst) begin
    assert (f_div_waiting == (div_busy && div_rd != 0));
    if (div_busy) assert (div_rd == f_div_dest);
    if (div_wb_en) begin
      assert (f_div_waiting && div_wb_rd == f_div_dest);
      assert (div_wb_data == md_div_result);
    end
    if (!halt && !fence_hold && !cancel_ex && idex_valid && (idex_is_div || idex_is_mul)) begin
      assert (!ex_trap && !lu_stall && !rvfi_operands_held);
      assert (idex_md_op == idex_instr[14:12]);
      assert (rs1_fwd == rvfi_ex.rs1_data && rs2_fwd == rvfi_ex.rs2_data);
      if (idex_is_div) assert (div_start);
    end
  end
end

for (genvar variant = 4; variant < 8; variant++) begin : g_div_witness
  always_ff @(posedge clk)
    if (!rst)
      cover (div_wb_en && f_div_op == 3'(variant) && div_wb_data != 0);
end
