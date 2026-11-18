`default_nettype none

// Select the upstream RV32I and multiplication models without allowing the
// divide models: deferred divide writeback is checked in a separate job.
module rvfi_isa_rv32i_mul (
  input logic rvfi_valid,
  input logic [31:0] rvfi_insn,
  rvfi_pc_rdata,
  rvfi_rs1_rdata,
  rvfi_rs2_rdata,
  rvfi_mem_rdata,
  output logic spec_valid,
  spec_trap,
  output logic [4:0] spec_rs1_addr,
  spec_rs2_addr,
  spec_rd_addr,
  output logic [31:0] spec_rd_wdata,
  spec_pc_wdata,
  spec_mem_addr,
  spec_mem_wdata,
  output logic [3:0] spec_mem_rmask,
  spec_mem_wmask
);
  typedef struct packed {
    logic valid, trap;
    logic [4:0] rs1, rs2, rd;
    logic [31:0] rd_data, pc, addr, wdata;
    logic [3:0] rmask, wmask;
  } result_t;
  result_t base, mul, mulh, mulhsu, mulhu;

  `define MODEL_PORTS(R) \
    .rvfi_valid(rvfi_valid), .rvfi_insn(rvfi_insn), .rvfi_pc_rdata(rvfi_pc_rdata), \
    .rvfi_rs1_rdata(rvfi_rs1_rdata), .rvfi_rs2_rdata(rvfi_rs2_rdata), \
    .rvfi_mem_rdata(rvfi_mem_rdata), .spec_valid(R.valid), .spec_trap(R.trap), \
    .spec_rs1_addr(R.rs1), .spec_rs2_addr(R.rs2), .spec_rd_addr(R.rd), \
    .spec_rd_wdata(R.rd_data), .spec_pc_wdata(R.pc), .spec_mem_addr(R.addr), \
    .spec_mem_wdata(R.wdata), .spec_mem_rmask(R.rmask), .spec_mem_wmask(R.wmask)

  rvfi_isa_rv32i u_base (`MODEL_PORTS(base));
  rvfi_insn_mul u_mul (`MODEL_PORTS(mul));
  rvfi_insn_mulh u_mulh (`MODEL_PORTS(mulh));
  rvfi_insn_mulhsu u_mulhsu (`MODEL_PORTS(mulhsu));
  rvfi_insn_mulhu u_mulhu (`MODEL_PORTS(mulhu));
  `undef MODEL_PORTS

  assign {spec_valid, spec_trap, spec_rs1_addr, spec_rs2_addr, spec_rd_addr,
          spec_rd_wdata, spec_pc_wdata, spec_mem_addr, spec_mem_wdata,
          spec_mem_rmask, spec_mem_wmask} = mul.valid ? mul : mulh.valid ? mulh :
              mulhsu.valid ? mulhsu : mulhu.valid ? mulhu : base;
endmodule
