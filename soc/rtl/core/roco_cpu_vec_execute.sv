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
  input logic [4:0] vl,
  input logic [4:0] vstart,
  input logic [2:0] sew,
  input logic vta,
  output logic [127:0] result
);
  logic [127:0] broadcast_data, operand_b, raw_result;
  logic [31:0] reduction;
  logic [4:0] write_vl;
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
      .source(vs2),
      .seed(vs1[31:0]),
      .vl(vl),
      .sew(sew),
      .result(reduction)
  );
  assign write_vl = ((op == `RV32_VOP_SCALAR) && (form == 3'b110)) ||
                   ((op != `RV32_VOP_SCALAR) && (form == 3'b010)) ? 5'd1 : vl;
  always_comb begin
    result = raw_result;
    if (op == `RV32_VOP_MOVE) result = (form == 3'b000) ? vs1 : broadcast_data;
    else if (op == `RV32_VOP_SCALAR && form != 3'b010) result = {old_vd[127:32], scalar};
    else if (op != `RV32_VOP_SCALAR && form == 3'b010) result = {96'd0, reduction};
    for (int k = 0; k < 16; k++) begin
      if ((k >= write_vl) || ((k < vstart) &&
          !((k == 0) && (op == `RV32_VOP_SCALAR) && (form == 3'b110)))) begin
        case (sew)
          3'd0: result[8*k+:8] = (vta && k >= vstart) ? 8'hff : old_vd[8*k+:8];
          3'd1: if (k < 8) result[16*k+:16] = (vta && k >= vstart) ? 16'hffff : old_vd[16*k+:16];
          default:
          if (k < 4) result[32*k+:32] = (vta && k >= vstart) ? 32'hffff_ffff : old_vd[32*k+:32];
        endcase
      end
    end
  end
endmodule
