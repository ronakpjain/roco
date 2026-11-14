// SEW-specific carry-save trees keep reductions within one EX cycle.
// Arithmetic is modulo SEW, so unused high bits never enter the tree.
`default_nettype none

module rv32_vec_reduce (
  input logic [127:0] source,
  input logic [31:0] seed,
  input logic [4:0] vl,
  input logic [2:0] sew,
  output logic [31:0] result
);
  function automatic integer term_count(input integer initial_count, input integer level);
    integer count;
    count = initial_count;
    for (integer k = 0; k < level; k = k + 1) count = 2 * (count / 3) + count % 3;
    term_count = count;
  endfunction

  logic [31:0] sums[0:2];
  for (genvar size = 0; size < 3; size = size + 1) begin : g_size
    localparam integer WIDTH = 8 << size;
    localparam integer LANES = 128 / WIDTH;
    wire [WIDTH-1:0] terms[0:6][0:LANES];
    for (genvar lane = 0; lane < LANES; lane = lane + 1) begin : g_lane
      assign terms[0][lane] = (5'(lane) < vl) ? source[WIDTH*lane+:WIDTH] : '0;
    end
    assign terms[0][LANES] = seed[WIDTH-1:0];
    for (genvar level = 0; level < 6; level = level + 1) begin : g_level
      localparam integer INPUTS  = term_count(LANES + 1, level);
      localparam integer GROUPS  = INPUTS / 3;
      localparam integer OUTPUTS = 2 * GROUPS + INPUTS % 3;
      for (genvar g = 0; g < GROUPS; g = g + 1) begin : g_compress
        wire [WIDTH-1:0] a = terms[level][3*g];
        wire [WIDTH-1:0] b = terms[level][3*g+1];
        wire [WIDTH-1:0] c = terms[level][3*g+2];
        assign terms[level+1][2*g] = a ^ b ^ c;
        assign terms[level+1][2*g+1] = ((a & b) | (a & c) | (b & c)) << 1;
      end
      for (genvar k = 0; k < INPUTS % 3; k = k + 1) begin : g_remainder
        assign terms[level+1][2*GROUPS+k] = terms[level][3*GROUPS+k];
      end
      for (genvar k = OUTPUTS; k < LANES + 1; k = k + 1) begin : g_unused
        assign terms[level+1][k] = '0;
      end
    end
    wire [WIDTH-1:0] sum = terms[6][0] + terms[6][1];
    assign sums[size] = 32'(sum);
  end
  assign result = (sew == 3'd0) ? sums[0] : (sew == 3'd1) ? sums[1] : sums[2];
endmodule
