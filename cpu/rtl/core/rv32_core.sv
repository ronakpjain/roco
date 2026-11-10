// Pipelined RV32I processor core.
//
// Five stages, each in its own module:
//   rv32_if_stage   program counter, fetch handshake, IF/ID register
//   rv32_id_stage   decode, register file, ID/EX register
//   rv32_ex_stage   ALU, forwarding, branches, traps, CSR file, EX/MEM
//   rv32_mem_stage  data memory request, load alignment, MEM/WB register
//   rv32_wb_stage   register-file write data and retire trace
//   rv32_branch_predictor  bimodal predictor and BTB
//
// Branches and jumps resolve in EX, so a taken control transfer costs two
// flushed slots. Full EX/MEM and MEM/WB forwarding is used; the only
// interlock is load-use, which inserts one bubble. Loads and stores use a
// blocking request/response memory interface; responses carry the request
// address so that stale responses from a redirected fetch are ignored.
//
// Implemented: RV32I base integer instructions, Zicsr, machine-mode traps
// for illegal instructions, ECALL/EBREAK, misaligned load/store and
// misaligned instruction addresses, plus MRET. No interrupts.

`default_nettype none

module rv32_core (
  input logic clk,
  input logic rst,
  input logic [31:0] boot_addr,
  input logic halt,
  /* Instruction memory port: hold req/addr until rsp_valid. */
  output logic imem_req,
  output logic [31:0] imem_addr,
  input logic imem_rsp_valid,
  input logic [31:0] imem_rsp_addr,
  input logic [31:0] imem_rsp_data,
  input logic imem_miss,
  input logic imem_busy,
  /* Data memory: lookup in EX, commit in MEM, data returns combinationally. */
  output logic dmem_lu_valid,
  output logic dmem_lu_we,
  output logic [31:0] dmem_lu_addr,
  output logic [31:0] dmem_lu_wdata,
  output logic [3:0] dmem_lu_be,
  input logic dmem_lu_hit,
  output logic dmem_req,
  output logic dmem_we,
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0] dmem_be,
  input logic [31:0] dmem_rsp_data,
  /* Retire trace, for simulation only. */
  output logic trace_valid,
  output logic [31:0] trace_pc,
  output logic [31:0] trace_instr,
  output logic [4:0] trace_rd,
  output logic [31:0] trace_wdata,
  output logic fence_req,
  input logic fence_done
);

  logic if_valid;
  logic [31:0] if_pc;
  logic [31:0] if_instr;
  logic if_pred_taken;
  logic [31:0] if_pred_target;
  logic [31:0] fetch_pc;
  logic pred_taken;
  logic [31:0] pred_target;
  logic idex_pred_taken;
  logic [31:0] idex_pred_target;
  logic btb_update;
  logic btb_is_branch;
  logic btb_is_jal;
  logic btb_is_jalr;
  logic btb_taken;
  logic [31:0] btb_target;

  logic [4:0] dec_rs1;
  logic [4:0] dec_rs2;
  logic dec_use_rs1;
  logic dec_use_rs2;

  logic idex_valid;
  logic [31:0] idex_pc;
  logic [31:0] idex_instr;
  logic [31:0] idex_rs1_val;
  logic [31:0] idex_rs2_val;
  logic [31:0] idex_imm;
  logic [4:0] idex_rs1;
  logic [4:0] idex_rs2;
  logic [4:0] idex_rd;
  logic [2:0] idex_funct3;
  logic [3:0] idex_alu_op;
  logic idex_alu_b_imm;
  logic idex_alu_a_pc;
  logic idex_regwrite;
  logic idex_is_load;
  logic idex_is_store;
  logic idex_is_branch;
  logic idex_is_jal;
  logic idex_is_jalr;
  logic idex_is_csr;
  logic idex_csr_uimm;
  logic [1:0] idex_csr_op;
  logic [11:0] idex_csr_addr;
  logic idex_illegal;
  logic idex_ecall;
  logic idex_ebreak;
  logic idex_mret;
  logic idex_is_fence_i;

  logic ex_redirect_en;
  logic [31:0] ex_redirect_pc;

  logic exmem_valid;
  logic [31:0] exmem_pc;
  logic [31:0] exmem_instr;
  logic [31:0] exmem_alu;
  logic [31:0] exmem_wbval;
  logic [31:0] exmem_store_data;
  logic [3:0] exmem_be;
  logic [4:0] exmem_rd;
  logic [2:0] exmem_funct3;
  logic exmem_regwrite;
  logic exmem_is_load;
  logic exmem_is_store;
  logic exmem_is_fence_i;

  logic memwb_valid;
  logic [31:0] memwb_wbval;
  logic [31:0] memwb_load_data;
  logic [4:0] memwb_rd;
  logic memwb_regwrite;
  logic memwb_is_load;

  logic wb_we;
  logic [4:0] wb_rd;
  logic [31:0] wb_data;

  logic dmem_lu_stall;
  logic stall;
  logic ex_lu_valid;
  logic ex_lu_we;
  logic [31:0] ex_lu_addr;
  logic [31:0] ex_lu_wdata;
  logic [3:0] ex_lu_be;
  logic [31:0] mem_load_value;
  logic mem_redirect;
  logic retire;
  logic if_consume;
  logic commit_valid;
  logic [31:0] commit_pc;
  logic [31:0] commit_instr;
  logic [4:0] commit_rd;
  logic [31:0] commit_wdata;

  assign retire = commit_valid;
  assign if_consume = if_valid && !stall && !ex_redirect_en && !mem_redirect;
  assign dmem_lu_valid = ex_lu_valid;
  assign dmem_lu_we = ex_lu_we;
  assign dmem_lu_addr = ex_lu_addr;
  assign dmem_lu_wdata = ex_lu_wdata;
  assign dmem_lu_be = ex_lu_be;
  assign dmem_lu_stall = ex_lu_valid && !dmem_lu_hit;
  assign stall = dmem_lu_stall || fence_req;
  assign trace_valid = commit_valid;
  assign trace_pc = commit_pc;
  assign trace_instr = commit_instr;
  assign trace_rd = commit_rd;
  assign trace_wdata = commit_wdata;

  rv32_if_stage u_if (
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .boot_addr(boot_addr),
      .stall(stall),
      .flush(ex_redirect_en || mem_redirect),
      .pred_taken(pred_taken),
      .pred_target(pred_target),
      .if_consume(if_consume),
      .redirect_pc(mem_redirect ? (exmem_pc + 32'd4) : ex_redirect_pc),
      .imem_req(imem_req),
      .imem_addr(imem_addr),
      .imem_rsp_valid(imem_rsp_valid),
      .imem_rsp_addr(imem_rsp_addr),
      .imem_rsp_data(imem_rsp_data),
      .imem_miss(imem_miss),
      .imem_busy(imem_busy),
      .if_valid(if_valid),
      .if_pc(if_pc),
      .if_instr(if_instr),
      .if_pred_taken(if_pred_taken),
      .if_pred_target(if_pred_target),
      .fetch_pc(fetch_pc)
  );

  rv32_id_stage u_id (
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .if_valid(if_valid),
      .if_pc(if_pc),
      .if_instr(if_instr),
      .if_pred_taken(if_pred_taken),
      .if_pred_target(if_pred_target),
      .hold(stall),
      .flush(ex_redirect_en || mem_redirect),
      .wb_we(wb_we),
      .wb_rd(wb_rd),
      .wb_data(wb_data),
      .dec_rs1(dec_rs1),
      .dec_rs2(dec_rs2),
      .dec_use_rs1(dec_use_rs1),
      .dec_use_rs2(dec_use_rs2),
      .idex_valid(idex_valid),
      .idex_pc(idex_pc),
      .idex_instr(idex_instr),
      .idex_pred_taken(idex_pred_taken),
      .idex_pred_target(idex_pred_target),
      .idex_rs1_val(idex_rs1_val),
      .idex_rs2_val(idex_rs2_val),
      .idex_imm(idex_imm),
      .idex_rs1(idex_rs1),
      .idex_rs2(idex_rs2),
      .idex_rd(idex_rd),
      .idex_funct3(idex_funct3),
      .idex_alu_op(idex_alu_op),
      .idex_alu_b_imm(idex_alu_b_imm),
      .idex_alu_a_pc(idex_alu_a_pc),
      .idex_regwrite(idex_regwrite),
      .idex_is_load(idex_is_load),
      .idex_is_store(idex_is_store),
      .idex_is_branch(idex_is_branch),
      .idex_is_jal(idex_is_jal),
      .idex_is_jalr(idex_is_jalr),
      .idex_is_csr(idex_is_csr),
      .idex_csr_uimm(idex_csr_uimm),
      .idex_csr_op(idex_csr_op),
      .idex_csr_addr(idex_csr_addr),
      .idex_illegal(idex_illegal),
      .idex_ecall(idex_ecall),
      .idex_ebreak(idex_ebreak),
      .idex_mret(idex_mret),
      .idex_is_fence_i(idex_is_fence_i)
  );

  rv32_ex_stage u_ex (
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .stall(stall),
      .lu_stall(dmem_lu_stall),
      .retire(retire),
      .idex_valid(idex_valid),
      .idex_pc(idex_pc),
      .idex_instr(idex_instr),
      .idex_pred_taken(idex_pred_taken),
      .idex_pred_target(idex_pred_target),
      .idex_rs1_val(idex_rs1_val),
      .idex_rs2_val(idex_rs2_val),
      .idex_imm(idex_imm),
      .idex_rs1(idex_rs1),
      .idex_rs2(idex_rs2),
      .idex_rd(idex_rd),
      .idex_funct3(idex_funct3),
      .idex_alu_op(idex_alu_op),
      .idex_alu_b_imm(idex_alu_b_imm),
      .idex_alu_a_pc(idex_alu_a_pc),
      .idex_regwrite(idex_regwrite),
      .idex_is_load(idex_is_load),
      .idex_is_store(idex_is_store),
      .idex_is_branch(idex_is_branch),
      .idex_is_jal(idex_is_jal),
      .idex_is_jalr(idex_is_jalr),
      .idex_is_csr(idex_is_csr),
      .idex_csr_uimm(idex_csr_uimm),
      .idex_csr_op(idex_csr_op),
      .idex_csr_addr(idex_csr_addr),
      .idex_illegal(idex_illegal),
      .idex_ecall(idex_ecall),
      .idex_ebreak(idex_ebreak),
      .idex_mret(idex_mret),
      .idex_is_fence_i(idex_is_fence_i),
      .fence_hold(fence_req),
      .wb_we(wb_we),
      .wb_rd(wb_rd),
      .wb_data(wb_data),
      .ex_redirect_en(ex_redirect_en),
      .ex_redirect_pc(ex_redirect_pc),
      .btb_update(btb_update),
      .btb_is_branch(btb_is_branch),
      .btb_is_jal(btb_is_jal),
      .btb_is_jalr(btb_is_jalr),
      .btb_taken(btb_taken),
      .btb_target(btb_target),
      .ex_lu_valid(ex_lu_valid),
      .ex_lu_we(ex_lu_we),
      .ex_lu_addr(ex_lu_addr),
      .ex_lu_wdata(ex_lu_wdata),
      .ex_lu_be(ex_lu_be),
      .exmem_valid(exmem_valid),
      .exmem_pc(exmem_pc),
      .exmem_instr(exmem_instr),
      .exmem_alu(exmem_alu),
      .exmem_wbval(exmem_wbval),
      .exmem_store_data(exmem_store_data),
      .exmem_be(exmem_be),
      .exmem_rd(exmem_rd),
      .exmem_funct3(exmem_funct3),
      .exmem_regwrite(exmem_regwrite),
      .exmem_is_load(exmem_is_load),
      .exmem_is_store(exmem_is_store),
      .exmem_is_fence_i(exmem_is_fence_i)
  );

  rv32_branch_predictor u_bp (
      .clk(clk),
      .rst(rst),
      .flush(fence_req),
      .if_pc(fetch_pc),
      .if_pred_taken(pred_taken),
      .if_pred_target(pred_target),
      .ex_pc(idex_pc),
      .ex_update(btb_update),
      .ex_is_branch(btb_is_branch),
      .ex_is_jal(btb_is_jal),
      .ex_is_jalr(btb_is_jalr),
      .ex_taken(btb_taken),
      .ex_target(btb_target)
  );

  rv32_mem_stage u_mem (
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .fence_done(fence_done),
      .exmem_valid(exmem_valid),
      .exmem_pc(exmem_pc),
      .exmem_instr(exmem_instr),
      .exmem_alu(exmem_alu),
      .exmem_wbval(exmem_wbval),
      .exmem_store_data(exmem_store_data),
      .exmem_be(exmem_be),
      .exmem_rd(exmem_rd),
      .exmem_funct3(exmem_funct3),
      .exmem_regwrite(exmem_regwrite),
      .exmem_is_load(exmem_is_load),
      .exmem_is_store(exmem_is_store),
      .exmem_is_fence_i(exmem_is_fence_i),
      .dmem_req(dmem_req),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_be(dmem_be),
      .dmem_rsp_data(dmem_rsp_data),
      .load_value(mem_load_value),
      .fence_req(fence_req),
      .mem_redirect(mem_redirect),
      .commit_valid(commit_valid),
      .commit_pc(commit_pc),
      .commit_instr(commit_instr),
      .commit_rd(commit_rd),
      .commit_wdata(commit_wdata),
      .memwb_valid(memwb_valid),
      .memwb_wbval(memwb_wbval),
      .memwb_load_data(memwb_load_data),
      .memwb_rd(memwb_rd),
      .memwb_regwrite(memwb_regwrite),
      .memwb_is_load(memwb_is_load)
  );

  rv32_wb_stage u_wb (
      .halt(halt),
      .memwb_valid(memwb_valid),
      .memwb_regwrite(memwb_regwrite),
      .memwb_is_load(memwb_is_load),
      .memwb_rd(memwb_rd),
      .memwb_wbval(memwb_wbval),
      .memwb_load_data(memwb_load_data),
      .wb_we(wb_we),
      .wb_rd(wb_rd),
      .wb_data(wb_data)
  );



endmodule
