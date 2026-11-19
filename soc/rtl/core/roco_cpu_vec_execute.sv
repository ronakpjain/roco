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
`ifdef ROCO_VECTOR_EXECUTE_FORMAL
  // Check each lane independently at all supported widths. The reduction
  // value comes from the separately checked reduction tree.
  for (genvar size = 0; size < 3; size++) begin : g_check_size
    localparam int Width = 8 << size;
    for (genvar lane = 0; lane < 128 / Width; lane++) begin : g_check_lane
      logic [Width-1:0] left, right, expected;
      assign left = vs2[Width*lane+:Width];
      assign right = form == 0 ? vs1[Width*lane+:Width] : scalar[Width-1:0];
      always_comb begin
        case (op)
          `RV32_VOP_ADD: expected = left + right;
          `RV32_VOP_SUB: expected = left - right;
          `RV32_VOP_AND: expected = left & right;
          `RV32_VOP_OR: expected = left | right;
          default: expected = left ^ right;
        endcase
        if (op == `RV32_VOP_MOVE) begin
          expected = right;
        end else if (form == 2 && op != `RV32_VOP_SCALAR) begin
          expected = lane == 0 ? reduction[Width-1:0] : 0;
        end else if (op == `RV32_VOP_SCALAR && form != 2) begin
          expected = lane < 32 / Width ? Width'(scalar >> (Width * lane)) : old_vd[Width*lane+:Width];
        end
      end
      for (genvar b = 0; b < Width / 8; b++) begin : g_check_byte
        localparam int Offset = Width * lane + 8 * b;
        always @* begin
          if (sew == 3'(size)) begin
            assert (result[Offset+:8] == (active_bytes[Offset/8] ? expected[8*b+:8] :
                                         fill_bytes[Offset/8] ? 8'hff : old_vd[Offset+:8]));
          end
        end
      end
    end
  end
  always @* begin
    cover (sew == 0 && form == 0 && op == `RV32_VOP_ADD && active_bytes == '1 && result != 0);
    cover (sew == 1 && form == 3 && op == `RV32_VOP_MOVE && active_bytes == '1 && result != 0);
    cover (sew == 2 && form == 2 && op == `RV32_VOP_REDSUM && active_bytes == 16'h000f &&
           fill_bytes == '1 && result[31:0] != 0);
  end
`endif
endmodule
