// 32 x 32-bit RISC-V register file.
//
// x0 is hardwired to zero. The read port bypasses a write in the same
// cycle, which lets the decoder read a value produced by the instruction
// currently committing in writeback.

`default_nettype none

module rv32_regfile (
  input logic clk,
  input logic rst,
  input logic [4:0] rs1,
  input logic [4:0] rs2,
  input logic we,
  input logic [4:0] rd,
  input logic [31:0] wdata,
  output logic [31:0] rdata1,
  output logic [31:0] rdata2
);

  logic [31:0] regs[1:31];
  integer i;

  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 1; i < 32; i = i + 1) begin
        regs[i] <= '0;
      end
    end else if (we && (rd != 5'd0)) begin
      regs[rd] <= wdata;
    end
  end

  always_comb begin
    rdata1 = (rs1 == 5'd0) ? 32'd0 : (we && (rd == rs1)) ? wdata : regs[rs1];
    rdata2 = (rs2 == 5'd0) ? 32'd0 : (we && (rd == rs2)) ? wdata : regs[rs2];
  end

endmodule
