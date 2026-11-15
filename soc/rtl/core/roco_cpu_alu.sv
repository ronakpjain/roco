// RV32I arithmetic/logic unit.
//
// One combinational opcode selects a 32-bit result. The execute stage
// compares branch operands independently of this result-selection path.

`default_nettype none
`include "roco_cpu_defs.svh"

module roco_cpu_alu (
  input logic [31:0] a,
  input logic [31:0] b,
  input logic [3:0] op,
  output logic [31:0] result
);

  logic [31:0] addsub_result;
  roco_cpu_addsub u_addsub (
      .a(a),
      .b(b),
      .subtract(op == `RV32_ALU_SUB),
      .result(addsub_result)
  );

  always_comb begin
    result = '0;
    case (op)
      `RV32_ALU_ADD: begin
        result = addsub_result;
      end
      `RV32_ALU_SUB: begin
        result = addsub_result;
      end
      `RV32_ALU_SLL: begin
        result = a << b[4:0];
      end
      `RV32_ALU_SLT: begin
        result = {31'd0, $signed(a) < $signed(b)};
      end
      `RV32_ALU_SLTU: begin
        result = {31'd0, a < b};
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
