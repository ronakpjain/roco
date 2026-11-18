// 32 x 32-bit RISC-V register file.
//
// x0 is hardwired to zero. The read port bypasses a write in the same
// cycle, which lets the decoder read a value produced by the instruction
// currently committing in writeback.

`default_nettype none

module roco_cpu_regfile (
`ifdef ROCO_RVFI_GPR_STATE
  input logic [4:0] rvfi_gpr_watch_addr,
  output logic [31:0] rvfi_gpr_watch_value,
`endif
  input logic clk,
  input logic rst,
  input logic [4:0] rs1,
  input logic [4:0] rs2,
  input logic we,
  input logic [4:0] rd,
  input logic [31:0] wdata,
  /* Decoupled divider write port. */
  input logic dwe,
  input logic [4:0] drd,
  input logic [31:0] ddata,
  output logic [31:0] rdata1,
  output logic [31:0] rdata2
);

  // A single physical write port can serve both writers. Keep reset
  // validity separately so the data array can use distributed RAM.
  logic [31:0] regs[0:31];
  logic [31:0] valid_regs;
  logic divider_write;
  logic write_enable;
  logic [4:0] write_reg;
  logic [31:0] write_data;
  assign divider_write = dwe && (drd != 5'd0);
  assign write_enable = divider_write || (we && (rd != 5'd0));
  assign write_reg = divider_write ? drd : rd;
  assign write_data = divider_write ? ddata : wdata;

  // The data array is distributed RAM and cannot take an asynchronous
  // clear, so it stays a plain clocked write. Writers are themselves held
  // cleared during reset, which keeps the array untouched before release.
  always_ff @(posedge clk) begin
    if (write_enable) begin
      regs[write_reg] <= write_data;
    end
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      valid_regs <= '0;
    end else if (write_enable) begin
      valid_regs[write_reg] <= 1'b1;
    end
  end

  // The divider port needs no read bypass: the scoreboard holds a
  // dependent instruction until the write has landed.
  always_comb begin
    rdata1 = (rs1 == 5'd0) ? 32'd0 : (we && (rd == rs1)) ? wdata :
             valid_regs[rs1] ? regs[rs1] : 32'd0;
    rdata2 = (rs2 == 5'd0) ? 32'd0 : (we && (rd == rs2)) ? wdata :
             valid_regs[rs2] ? regs[rs2] : 32'd0;
  end

`ifdef ROCO_RVFI_GPR_STATE
  // Observe the stored contents without the pending scalar WB bypass.
  assign rvfi_gpr_watch_value = rvfi_gpr_watch_addr == 0 ? 32'd0 :
      valid_regs[rvfi_gpr_watch_addr] ? regs[rvfi_gpr_watch_addr] : 32'd0;
`endif

`ifdef ROCO_REGFILE_FORMAL
  `include "scalar_regs_checks.svh"
`endif
endmodule
