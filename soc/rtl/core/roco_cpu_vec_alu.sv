`default_nettype none
`include "roco_cpu_defs.svh"

// Vector element ALU.
//
// Applies one operation to every element of a 128-bit operand pair at
// the configured SEW, then forces elements beyond vl to the tail
// policy: agnostic lanes become all ones, undisturbed lanes keep the
// destination value.
module roco_cpu_vec_alu (
  input logic [127:0] a,
  input logic [127:0] b,
  input logic [2:0] sew,
  input logic [5:0] op,
  output logic [127:0] result
);

  logic [127:0] r8;
  logic [127:0] r16;
  logic [127:0] r32;
  integer k;

  always_comb begin
    r8 = '0;
    r16 = '0;
    r32 = '0;
    for (k = 0; k < 16; k = k + 1) begin
      case (op)
        `RV32_VOP_ADD: begin
          r8[8*k+:8] = a[8*k+:8] + b[8*k+:8];
        end
        `RV32_VOP_SUB: begin
          r8[8*k+:8] = a[8*k+:8] - b[8*k+:8];
        end
        `RV32_VOP_AND: begin
          r8[8*k+:8] = a[8*k+:8] & b[8*k+:8];
        end
        `RV32_VOP_OR: begin
          r8[8*k+:8] = a[8*k+:8] | b[8*k+:8];
        end
        default: begin
          r8[8*k+:8] = a[8*k+:8] ^ b[8*k+:8];
        end
      endcase
    end
    for (k = 0; k < 8; k = k + 1) begin
      case (op)
        `RV32_VOP_ADD: begin
          r16[16*k+:16] = a[16*k+:16] + b[16*k+:16];
        end
        `RV32_VOP_SUB: begin
          r16[16*k+:16] = a[16*k+:16] - b[16*k+:16];
        end
        `RV32_VOP_AND: begin
          r16[16*k+:16] = a[16*k+:16] & b[16*k+:16];
        end
        `RV32_VOP_OR: begin
          r16[16*k+:16] = a[16*k+:16] | b[16*k+:16];
        end
        default: begin
          r16[16*k+:16] = a[16*k+:16] ^ b[16*k+:16];
        end
      endcase
    end
    for (k = 0; k < 4; k = k + 1) begin
      case (op)
        `RV32_VOP_ADD: begin
          r32[32*k+:32] = a[32*k+:32] + b[32*k+:32];
        end
        `RV32_VOP_SUB: begin
          r32[32*k+:32] = a[32*k+:32] - b[32*k+:32];
        end
        `RV32_VOP_AND: begin
          r32[32*k+:32] = a[32*k+:32] & b[32*k+:32];
        end
        `RV32_VOP_OR: begin
          r32[32*k+:32] = a[32*k+:32] | b[32*k+:32];
        end
        default: begin
          r32[32*k+:32] = a[32*k+:32] ^ b[32*k+:32];
        end
      endcase
    end
    case (sew)
      3'd0: begin
        result = r8;
      end
      3'd1: begin
        result = r16;
      end
      default: begin
        result = r32;
      end
    endcase
  end

endmodule
