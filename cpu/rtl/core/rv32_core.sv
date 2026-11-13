// Pipelined RV32I processor core.
//
// Five stages, each in its own module:
//   rv32_if_stage   program counter, fetch handshake, IF/ID register
//   rv32_id_stage   decode, register file, ID/EX register
//   rv32_ex_stage   ALU, forwarding, branches, traps, CSR file, EX/MEM
//   rv32_mem_stage  data memory request, load alignment, MEM/WB register
//   rv32_wb_stage   register-file write data and retire trace
//   rv32_branch_predictor  bimodal predictor and BTB
//   rv32_mmu        Sv32 TLBs and hardware page-table walker
//
// Branches and jumps resolve in EX, so a taken control transfer costs two
// flushed slots. Full EX/MEM and MEM/WB forwarding is used; the only
// interlock is load-use, which inserts one bubble. Loads and stores use a
// blocking request/response memory interface; responses carry the request
// address so that stale responses from a redirected fetch are ignored.
//
// Implemented: RV32I base integer instructions, Zicsr, M/S/U privilege
// modes, trap delegation, Sv32 virtual memory, and traps for illegal
// instructions, ECALL/EBREAK, misaligned addresses and page faults.
// No interrupts.

`default_nettype none

module rv32_core (
  input logic clk,
  input logic rst,
  input logic [31:0] boot_addr,
  input logic halt,
  /* Physical instruction memory port: hold req/addr until rsp_valid. */
  output logic imem_req,
  output logic [31:0] imem_addr,
  input logic imem_rsp_valid,
  input logic [31:0] imem_rsp_addr,
  input logic [31:0] imem_rsp_data,
  input logic imem_miss,
  input logic imem_busy,
  /* Physical data memory: lookup in EX, commit in MEM. */
  output logic dmem_lu_valid,
  output logic [31:2] dmem_lu_addr,
  input logic dmem_lu_hit,
  output logic dmem_req,
  output logic dmem_we,
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0] dmem_be,
  input logic [31:0] dmem_rsp_data,
  /* Physical page-table walker port. */
  output logic ptw_req,
  output logic [22:0] ptw_word_addr,
  input logic ptw_ready,
  input logic ptw_rvalid,
  input logic [31:0] ptw_rdata,
  input logic ptw_rlast,
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
  logic idex_rs1_from_mem;
  logic idex_rs2_from_mem;
  logic idex_rs1_from_wb;
  logic idex_rs2_from_wb;
  logic idex_rs1_from_rf;
  logic idex_rs2_from_rf;
  logic [31:0] idex_imm;
  logic [4:0] idex_rs1;
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
  logic idex_sret;
  logic idex_is_sfence;
  logic idex_is_fence_i;
  logic idex_ifault;
  logic if_fault;
  logic [1:0] priv;
  logic [31:0] satp;
  logic satp_write;
  logic mmu_flush;
  logic mstatus_mprv;
  logic mstatus_sum;
  logic mstatus_mxr;
  logic mstatus_tvm;
  logic mstatus_tsr;
  logic [1:0] mstatus_mpp;
  logic mmu_sfence;

  // IF-side translation.
  logic if_imem_req;
  logic [31:0] if_imem_addr;
  logic if_imem_rsp_valid;
  logic [31:0] if_imem_rsp_addr;
  logic [31:0] if_imem_rsp_data;
  logic if_imem_miss;
  logic if_imem_busy;
  logic if_imem_fault;
  logic [31:0] if_imem_fault_addr;
  logic mmu_ic_req;
  logic [31:0] mmu_ic_addr;
  logic mmu_i_hit;
  logic mmu_i_miss;
  logic mmu_i_busy;
  logic mmu_i_fault;
  logic [31:0] mmu_i_fault_addr;
  logic mmu_i_rsp_valid;
  logic [31:0] mmu_i_rsp_addr;
  logic [31:0] mmu_i_rsp_data;

  // Data-side translation.
  logic [31:0] ex_lu_vaddr;
  logic ex_lu_we;
  logic mmu_d_hit;
  logic mmu_d_fault;
  logic [3:0] mmu_d_fault_cause;
  logic [31:0] mmu_d_paddr;
  logic ex_lu_hit;
  logic [1:0] priv_data;

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
  logic exmem_is_sfence;
  logic exmem_is_fence_i;

  logic memwb_valid;
  logic [31:0] memwb_data;
  logic [4:0] memwb_rd;
  logic memwb_regwrite;

  logic wb_we;
  logic [4:0] wb_rd;
  logic [31:0] wb_data;

  logic load_use;
  logic dmem_lu_stall;
  logic stall;
  logic ex_lu_valid;
  logic mem_redirect;
  logic retire;
  logic if_consume;
  logic commit_valid;
  logic [31:0] commit_pc;
  logic [31:0] commit_instr;
  logic [4:0] commit_rd;
  logic [31:0] commit_wdata;

  assign retire = commit_valid;
  // Keep a dependent instruction in ID until the load reaches WB.
  assign load_use = idex_valid && idex_is_load && (idex_rd != 5'd0) && if_valid &&
                    ((dec_use_rs1 && dec_rs1 == idex_rd) ||
                     (dec_use_rs2 && dec_rs2 == idex_rd));
  assign if_consume = if_valid && !stall && !load_use && !ex_redirect_en && !mem_redirect;
  assign ex_lu_hit = mmu_d_hit && dmem_lu_hit;
  assign dmem_lu_valid = ex_lu_valid && mmu_d_hit;
  assign dmem_lu_addr = mmu_d_paddr[31:2];
  assign dmem_lu_stall = ex_lu_valid && !mmu_d_fault && !ex_lu_hit;
  assign stall = dmem_lu_stall || fence_req;
  assign priv_data = mstatus_mprv ? mstatus_mpp : priv;
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
      // Queue capacity, not backend readiness, throttles instruction fetch.
      .stall(1'b0),
      .flush(ex_redirect_en || mem_redirect),
      .pred_taken(pred_taken),
      .pred_target(pred_target),
      .if_consume(if_consume),
      .redirect_pc(mem_redirect ? (exmem_pc + 32'd4) : ex_redirect_pc),
      .imem_req(if_imem_req),
      .imem_addr(if_imem_addr),
      .imem_rsp_valid(if_imem_rsp_valid),
      .imem_rsp_addr(if_imem_rsp_addr),
      .imem_rsp_data(if_imem_rsp_data),
      .imem_miss(if_imem_miss),
      .imem_busy(if_imem_busy),
      .imem_fault(if_imem_fault),
      .imem_fault_addr(if_imem_fault_addr),
      .if_valid(if_valid),
      .if_pc(if_pc),
      .if_instr(if_instr),
      .if_fault(if_fault),
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
      .if_fault(if_fault),
      .if_pred_taken(if_pred_taken),
      .if_pred_target(if_pred_target),
      .hold(stall),
      .bubble(load_use),
      .flush(ex_redirect_en || mem_redirect),
      .exmem_valid(exmem_valid),
      .exmem_regwrite(exmem_regwrite),
      .exmem_rd(exmem_rd),
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
      .idex_rs1_from_mem(idex_rs1_from_mem),
      .idex_rs2_from_mem(idex_rs2_from_mem),
      .idex_rs1_from_wb(idex_rs1_from_wb),
      .idex_rs2_from_wb(idex_rs2_from_wb),
      .idex_rs1_from_rf(idex_rs1_from_rf),
      .idex_rs2_from_rf(idex_rs2_from_rf),
      .idex_imm(idex_imm),
      .idex_rs1(idex_rs1),
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
      .idex_ifault(idex_ifault),
      .idex_mret(idex_mret),
      .idex_sret(idex_sret),
      .idex_is_sfence(idex_is_sfence),
      .idex_is_fence_i(idex_is_fence_i)
  );

  rv32_ex_stage u_ex (
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .lu_stall(dmem_lu_stall),
      .retire(retire),
      .idex_valid(idex_valid),
      .idex_pc(idex_pc),
      .idex_instr(idex_instr),
      .idex_pred_taken(idex_pred_taken),
      .idex_pred_target(idex_pred_target),
      .idex_rs1_val(idex_rs1_val),
      .idex_rs2_val(idex_rs2_val),
      .idex_rs1_from_mem(idex_rs1_from_mem),
      .idex_rs2_from_mem(idex_rs2_from_mem),
      .idex_rs1_from_wb(idex_rs1_from_wb),
      .idex_rs2_from_wb(idex_rs2_from_wb),
      .idex_rs1_from_rf(idex_rs1_from_rf),
      .idex_rs2_from_rf(idex_rs2_from_rf),
      .idex_imm(idex_imm),
      .idex_rs1(idex_rs1),
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
      .idex_ifault(idex_ifault),
      .idex_mret(idex_mret),
      .idex_sret(idex_sret),
      .idex_is_sfence(idex_is_sfence),
      .idex_is_fence_i(idex_is_fence_i),
      .fence_hold(fence_req),
      .wb_data(wb_data),
      .dmem_lu_fault(mmu_d_fault),
      .dmem_lu_fault_cause(mmu_d_fault_cause),
      .dmem_lu_paddr(mmu_d_paddr),
      .ex_redirect_en(ex_redirect_en),
      .ex_redirect_pc(ex_redirect_pc),
      .btb_update(btb_update),
      .btb_is_branch(btb_is_branch),
      .btb_is_jal(btb_is_jal),
      .btb_is_jalr(btb_is_jalr),
      .btb_taken(btb_taken),
      .btb_target(btb_target),
      .ex_lu_valid(ex_lu_valid),
      .ex_lu_vaddr(ex_lu_vaddr),
      .ex_lu_we(ex_lu_we),
      .priv(priv),
      .satp(satp),
      .satp_write(satp_write),
      .mstatus_mprv(mstatus_mprv),
      .mstatus_sum(mstatus_sum),
      .mstatus_mxr(mstatus_mxr),
      .mstatus_tvm(mstatus_tvm),
      .mstatus_tsr(mstatus_tsr),
      .mstatus_mpp(mstatus_mpp),
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
      .exmem_is_sfence(exmem_is_sfence),
      .exmem_is_fence_i(exmem_is_fence_i)
  );

  rv32_mmu u_mmu (
      .clk(clk),
      .rst(rst),
      .flush(mmu_flush),
      .iflush(ex_redirect_en || mem_redirect),
      .satp(satp),
      .priv_fetch(priv),
      .priv_data(priv_data),
      .mstatus_sum(mstatus_sum),
      .mstatus_mxr(mstatus_mxr),
      .i_req(if_imem_req),
      .i_vaddr(if_imem_addr),
      .i_hit(mmu_i_hit),
      .i_miss(mmu_i_miss),
      .i_busy(mmu_i_busy),
      .i_fault(mmu_i_fault),
      .i_fault_addr(mmu_i_fault_addr),
      .ic_req(mmu_ic_req),
      .ic_addr(mmu_ic_addr),
      .ic_rsp_valid(imem_rsp_valid),
      .ic_rsp_data(imem_rsp_data),
      .i_rsp_valid(mmu_i_rsp_valid),
      .i_rsp_addr(mmu_i_rsp_addr),
      .i_rsp_data(mmu_i_rsp_data),
      .d_req(ex_lu_valid),
      .d_vaddr(ex_lu_vaddr),
      .d_we(ex_lu_we),
      .d_hit(mmu_d_hit),
      .d_fault(mmu_d_fault),
      .d_fault_cause(mmu_d_fault_cause),
      .d_paddr(mmu_d_paddr),
      .p_req(ptw_req),
      .p_word_addr(ptw_word_addr),
      .p_ready(ptw_ready),
      .p_rvalid(ptw_rvalid),
      .p_rdata(ptw_rdata),
      .p_rlast(ptw_rlast)
  );

  // The external instruction port is physical; the MMU owns virtual
  // fetch responses and page-fault reporting.
  assign mmu_sfence = mem_redirect && exmem_is_sfence;
  assign mmu_flush = mmu_sfence || satp_write;
  assign imem_req = mmu_ic_req;
  assign imem_addr = mmu_ic_addr;
  assign if_imem_rsp_valid = mmu_i_rsp_valid;
  assign if_imem_rsp_addr = mmu_i_rsp_addr;
  assign if_imem_rsp_data = mmu_i_rsp_data;
  assign if_imem_miss = imem_miss || mmu_i_miss;
  assign if_imem_busy = mmu_i_busy || imem_busy;
  assign if_imem_fault = mmu_i_fault;
  assign if_imem_fault_addr = mmu_i_fault_addr;

  rv32_branch_predictor u_bp (
      .clk(clk),
      .rst(rst),
      .flush(fence_req),
      .if_pc(fetch_pc),
      .if_pred_taken(pred_taken),
      .if_pred_target(pred_target),
      .ex_pc(idex_pc[31:2]),
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
      .exmem_is_sfence(exmem_is_sfence),
      .exmem_is_fence_i(exmem_is_fence_i),
      .dmem_req(dmem_req),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_be(dmem_be),
      .dmem_rsp_data(dmem_rsp_data),
      .fence_req(fence_req),
      .mem_redirect(mem_redirect),
      .commit_valid(commit_valid),
      .commit_pc(commit_pc),
      .commit_instr(commit_instr),
      .commit_rd(commit_rd),
      .commit_wdata(commit_wdata),
      .memwb_valid(memwb_valid),
      .memwb_data(memwb_data),
      .memwb_rd(memwb_rd),
      .memwb_regwrite(memwb_regwrite)
  );

  rv32_wb_stage u_wb (
      .halt(halt),
      .memwb_valid(memwb_valid),
      .memwb_regwrite(memwb_regwrite),
      .memwb_rd(memwb_rd),
      .memwb_data(memwb_data),
      .wb_we(wb_we),
      .wb_rd(wb_rd),
      .wb_data(wb_data)
  );



endmodule
