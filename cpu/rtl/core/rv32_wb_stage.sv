// Writeback stage.
//
// Selects the value written to the register file. The MEM/WB register
// itself lives in the memory stage; this block is purely combinational.

`default_nettype none

module rv32_wb_stage (
  input logic halt,
  input logic memwb_valid,
  input logic memwb_regwrite,
  input logic memwb_is_load,
  input logic [4:0] memwb_rd,
  input logic [31:0] memwb_wbval,
  input logic [31:0] memwb_load_data,
  output logic wb_we,
  output logic [4:0] wb_rd,
  output logic [31:0] wb_data
);

  assign wb_data = memwb_is_load ? memwb_load_data : memwb_wbval;
  assign wb_we = memwb_valid && memwb_regwrite && !halt;
  assign wb_rd = memwb_rd;

endmodule
