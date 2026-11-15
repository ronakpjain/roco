// Predicted JALR targets need consecutive modular differences. Form the
// successor with parallel byte increments instead of a second wide carry
// chain behind the subtraction.
`default_nettype none
module roco_cpu_sub_pair (
  input logic [31:0] a,
  input logic [31:0] b,
  output logic [31:0] difference,
  output logic [31:0] successor
);
  roco_cpu_addsub u_difference (
      .a(a),
      .b(b),
      .subtract(1'b1),
      .result(difference)
  );
  for (genvar byte_index = 0; byte_index < 4; byte_index++) begin : g_byte
    logic carry;
    logic [7:0] incremented;
    if (byte_index == 0) assign carry = 1'b1;
    else assign carry = &difference[8*byte_index-1:0];
    assign incremented = difference[8*byte_index+:8] + 8'd1;
    assign successor[8*byte_index+:8] = carry ? incremented : difference[8*byte_index+:8];
  end
endmodule
