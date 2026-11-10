// Instruction fetch stage.
//
// Owns the program counter and the IF/ID pipeline register. The fetch
// request is held stable until the memory returns that exact address;
// responses for a superseded (redirected) PC are ignored. A redirect
// clears the IF/ID register so the instruction being decoded is not
// allowed to proceed.

`default_nettype none

module rv32_if_stage (
  input logic clk,
  input logic rst,
  input logic halt,
  input logic [31:0] boot_addr,
  input logic stall,
  input logic flush,
  input logic if_consume,
  input logic [31:0] redirect_pc,
  /* Instruction memory: request held until rsp_valid. */
  output logic imem_req,
  output logic [31:0] imem_addr,
  input logic imem_rsp_valid,
  input logic [31:0] imem_rsp_addr,
  input logic [31:0] imem_rsp_data,
  /* IF/ID pipeline register. */
  output logic if_valid,
  output logic [31:0] if_pc,
  output logic [31:0] if_instr
);

  logic [31:0] pc_if;

  assign imem_addr = pc_if;
  assign imem_req = !rst && !halt;

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_if <= boot_addr;
      if_valid <= 1'b0;
      if_pc <= boot_addr;
      if_instr <= 32'h0000_0013;  // NOP
    end else if (halt) begin
      // Frozen after a tohost store.
    end else if (flush) begin
      pc_if <= redirect_pc;
      if_valid <= 1'b0;
    end else if (stall) begin
      // Hold the pending fetch; the I-cache may still be filling.
    end else if (imem_rsp_valid && (imem_rsp_addr == pc_if)) begin
      if_valid <= 1'b1;
      if_pc <= pc_if;
      if_instr <= imem_rsp_data;
      pc_if <= pc_if + 32'd4;
    end else if (if_consume) begin
      // The ID stage took this instruction; wait for the next fetch.
      if_valid <= 1'b0;
    end
  end

endmodule
