// Parallel byte comparisons avoid a full-width subtract carry chain.
`default_nettype none
module roco_cpu_compare (
  input logic [31:0] a,
  input logic [31:0] b,
  output logic equal,
  output logic signed_lt,
  output logic unsigned_lt
);
  logic [3:0] byte_lt, byte_eq;
  for (genvar k = 0; k < 4; k++) begin : g_byte
    assign byte_lt[k] = a[8*k+:8] < b[8*k+:8];
    assign byte_eq[k] = a[8*k+:8] == b[8*k+:8];
  end
  assign equal = &byte_eq;
  assign unsigned_lt = byte_lt[3] || (byte_eq[3] && byte_lt[2]) ||
                       (byte_eq[3] && byte_eq[2] && byte_lt[1]) ||
                       (byte_eq[3] && byte_eq[2] && byte_eq[1] && byte_lt[0]);
  assign signed_lt = (a[31] != b[31]) ? a[31] : unsigned_lt;
endmodule
