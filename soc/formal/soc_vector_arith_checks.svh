// verilog_syntax: parse-as-module-body
// Compose the separately proved vector ALU and reduction tree with the
// real EX pipeline: when EX/MEM carries a whole-register arithmetic result,
// recompute it from an independent ALU and reduction instance driven by the
// same captured operands the DUT used. The pipeline must transport operands
// correctly and route the result; leaf arithmetic is closed by
// vector-execute and the reduction contract.
logic [5:0] f_a_op;
logic [2:0] f_a_form, f_a_sew;
logic [127:0] f_a_broadcast, f_a_operand_b, f_a_raw, f_a_expected;
logic [31:0] f_a_reduction;
logic [127:0] f_a_reduce_source;
assign f_a_op = exmem_instr[31:26];
assign f_a_form = exmem_instr[14:12];
assign f_a_sew = vec_sew_q;
assign f_a_reduce_source = vec_reduce_q;
always_comb begin
  case (f_a_sew)
    3'd0: f_a_broadcast = {16{vec_scalar_q[7:0]}};
    3'd1: f_a_broadcast = {8{vec_scalar_q[15:0]}};
    default: f_a_broadcast = {4{vec_scalar_q}};
  endcase
end
assign f_a_operand_b = (f_a_form == 3'b000) ? vec_vs1_q : f_a_broadcast;
roco_cpu_vec_alu f_a_alu (
    .a(vec_vs2_q),
    .b(f_a_operand_b),
    .sew(f_a_sew),
    .op(f_a_op),
    .result(f_a_raw)
);
roco_cpu_vec_reduce f_a_reduce (
    .source(f_a_reduce_source),
    .seed(vec_vs1_q[31:0]),
    .vl(5'd16),
    .sew(f_a_sew),
    .result(f_a_reduction)
);
always_comb begin
  f_a_expected = f_a_raw;
  if (f_a_op == `RV32_VOP_MOVE) f_a_expected = (f_a_form == 3'b000) ? vec_vs1_q : f_a_broadcast;
  else if (f_a_op == `RV32_VOP_SCALAR && f_a_form != 3'b010)
    f_a_expected = {vec_vd_q[127:32], vec_scalar_q};
  else if (f_a_op != `RV32_VOP_SCALAR && f_a_form == 3'b010) f_a_expected = {96'd0, f_a_reduction};
  for (int k = 0; k < 16; k++) begin
    if (!vec_active_q[k]) f_a_expected[8*k+:8] = vec_fill_q[k] ? 8'hff : vec_vd_q[8*k+:8];
  end
end

// The shared decode checks already tie exmem_vec_we to arithmetic decode
// (vector, not vset/memory). Here only the result value is composed.
// No covers: the pin program contains no arithmetic instructions.
always_ff @(posedge clk) begin
  if (!rst && !halt && exmem_valid && exmem_vec_we) begin
    assert (exmem_vec_data == f_a_expected);
  end
end
