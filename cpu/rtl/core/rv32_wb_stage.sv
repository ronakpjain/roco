// Writeback stage.
//
// Drives the register file and WB forwarding from the MEM/WB register.

`default_nettype none

module rv32_wb_stage (
  input logic halt,
  input logic memwb_valid,
  input logic memwb_regwrite,
  input logic [4:0] memwb_rd,
  input logic [31:0] memwb_data,
  output logic wb_we,
  output logic [4:0] wb_rd,
  output logic [31:0] wb_data
);

  assign wb_data = memwb_data;
  assign wb_we = memwb_valid && memwb_regwrite && !halt;
  assign wb_rd = memwb_rd;

endmodule
