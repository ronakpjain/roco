// Hazard detection.
//
// Two events stall the front end: a load-use dependency (one bubble)
// and a data memory operation that has not completed (hold everything
// behind MEM). A redirect is only allowed when neither is active so
// that older instructions always retire first.

`default_nettype none

module rv32_hazard_unit (
  input logic idex_valid,
  input logic idex_is_load,
  input logic [4:0] idex_rd,
  input logic if_valid,
  input logic dec_use_rs1,
  input logic dec_use_rs2,
  input logic [4:0] dec_rs1,
  input logic [4:0] dec_rs2,
  input logic mem_wait,
  output logic load_use,
  output logic stall
);

  assign load_use = idex_valid && idex_is_load && (idex_rd != 5'd0) && if_valid &&
                    ((dec_use_rs1 && (dec_rs1 == idex_rd)) ||
                     (dec_use_rs2 && (dec_rs2 == idex_rd)));
  assign stall = mem_wait || load_use;

endmodule
