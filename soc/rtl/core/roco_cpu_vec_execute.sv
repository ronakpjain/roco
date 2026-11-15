// Wide vector arithmetic and tail handling from registered EX operands.
`default_nettype none
`include "roco_cpu_defs.svh"
module roco_cpu_vec_execute (
  input logic [127:0] vs1,
  input logic [127:0] vs2,
  input logic [127:0] old_vd,
  input logic [31:0] scalar,
  input logic [5:0] op,
  input logic [2:0] form,
  input logic [15:0] active_bytes,
  input logic [15:0] fill_bytes,
  input logic [127:0] reduction_source,
  input logic [2:0] sew,
  output logic [127:0] result
);
  logic [127:0] broadcast_data, operand_b, raw_result;
  logic [31:0] reduction;
  always_comb begin
    case (sew)
      3'd0: broadcast_data = {16{scalar[7:0]}};
      3'd1: broadcast_data = {8{scalar[15:0]}};
      default: broadcast_data = {4{scalar}};
    endcase
  end
  assign operand_b = (form == 3'b000) ? vs1 : broadcast_data;
  roco_cpu_vec_alu u_alu (
      .a(vs2),
      .b(operand_b),
      .sew(sew),
      .op(op),
      .result(raw_result)
  );
  roco_cpu_vec_reduce u_reduce (
      .source(reduction_source),
      .seed(vs1[31:0]),
      .vl(5'd16),
      .sew(sew),
      .result(reduction)
  );
  always_comb begin
    result = raw_result;
    if (op == `RV32_VOP_MOVE) result = (form == 3'b000) ? vs1 : broadcast_data;
    else if (op == `RV32_VOP_SCALAR && form != 3'b010) result = {old_vd[127:32], scalar};
    else if (op != `RV32_VOP_SCALAR && form == 3'b010) result = {96'd0, reduction};
    for (int k = 0; k < 16; k++) begin
      if (!active_bytes[k]) result[8*k+:8] = fill_bytes[k] ? 8'hff : old_vd[8*k+:8];
    end
  end
endmodule
