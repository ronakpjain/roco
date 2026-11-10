// RV32I arithmetic/logic unit.
//
// One combinational opcode selects a 32-bit result. Branches reuse SUB,
// SLT and SLTU so that the pipeline only needs a single carry chain.

`default_nettype none
`include "rv32_defs.svh"

module rv32_alu (
  input logic [31:0] a,
  input logic [31:0] b,
  input logic [3:0] op,
  output logic [31:0] result
);

  always_comb begin
    result = '0;
    case (op)
      `RV32_ALU_ADD: begin
        result = a + b;
      end
      `RV32_ALU_SUB: begin
        result = a - b;
      end
      `RV32_ALU_SLL: begin
        result = a << b[4:0];
      end
      `RV32_ALU_SLT: begin
        result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
      end
      `RV32_ALU_SLTU: begin
        result = (a < b) ? 32'd1 : 32'd0;
      end
      `RV32_ALU_XOR: begin
        result = a ^ b;
      end
      `RV32_ALU_SRL: begin
        result = a >> b[4:0];
      end
      `RV32_ALU_SRA: begin
        result = $signed(a) >>> b[4:0];
      end
      `RV32_ALU_OR: begin
        result = a | b;
      end
      `RV32_ALU_AND: begin
        result = a & b;
      end
      `RV32_ALU_PASS_B: begin
        result = b;
      end
      default: begin
        result = '0;
      end
    endcase
  end

endmodule
