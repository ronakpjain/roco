// Two carry choices share the byte carry-select datapath. Prediction
// validation uses a-b and a-b-1, avoiding a serial successor increment.
`default_nettype none
module roco_cpu_sub_pair (
  input logic [31:0] a,
  input logic [31:0] b,
  output logic [31:0] difference,
  output logic [31:0] predecessor
);
  roco_cpu_addsub u_difference (
      .a(a),
      .b(b),
      .subtract(1'b1),
      .result(difference)
  );
  roco_cpu_addsub #(
      .INITIAL_CARRY(0)
  ) u_predecessor (
      .a(a),
      .b(b),
      .subtract(1'b1),
      .result(predecessor)
  );
endmodule
