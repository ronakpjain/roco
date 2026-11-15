// Byte carry-select keeps the 32-bit add/subtract off one long carry chain.
`default_nettype none
module roco_cpu_addsub #(
    // -1 chooses the usual add/sub carry; 0/1 override it for fixed sums.
    parameter int INITIAL_CARRY = -1
) (
  input logic [31:0] a,
  input logic [31:0] b,
  input logic subtract,
  output logic [31:0] result
);
  logic [31:0] operand_b;
  logic [7:0] sum_zero[0:3], sum_one[0:3];
  logic [2:0] byte_generate, byte_propagate;
  logic [3:0] carry;
  assign operand_b = b ^ {32{subtract}};
  assign carry[0] = (INITIAL_CARRY < 0) ? subtract : 1'(INITIAL_CARRY);
  for (genvar k = 0; k < 4; k++) begin : g_byte
    if (k < 3) begin : g_carry
      logic [8:0] expanded;
      assign expanded = {1'b0, a[8*k+:8]} + {1'b0, operand_b[8*k+:8]};
      assign sum_zero[k] = expanded[7:0];
      assign byte_generate[k] = expanded[8];
      assign byte_propagate[k] = &(a[8*k+:8] ^ operand_b[8*k+:8]);
    end else begin : g_high
      assign sum_zero[k] = a[8*k+:8] + operand_b[8*k+:8];
    end
    assign sum_one[k] = a[8*k+:8] + operand_b[8*k+:8] + 8'd1;
    assign result[8*k+:8] = carry[k] ? sum_one[k] : sum_zero[k];
  end
  assign carry[1] = byte_generate[0] || (byte_propagate[0] && carry[0]);
  assign carry[2] = byte_generate[1] || (byte_propagate[1] && byte_generate[0]) ||
                    (byte_propagate[1] && byte_propagate[0] && carry[0]);
  assign carry[3] = byte_generate[2] || (byte_propagate[2] && byte_generate[1]) ||
                    (byte_propagate[2] && byte_propagate[1] && byte_generate[0]) ||
                    (byte_propagate[2] && byte_propagate[1] && byte_propagate[0] && carry[0]);
endmodule
