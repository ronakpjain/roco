// roco_cpu: pipelined RV32I processor core.
//
// Five stages, each in its own module:
//   roco_cpu_if_stage   program counter, fetch handshake, IF/ID register
//   roco_cpu_id_stage   decode, register file, ID/EX register
//   roco_cpu_ex_stage   ALU, forwarding, branches, traps, CSR file, EX/MEM
//   roco_cpu_mem_stage  data memory request, load alignment, MEM/WB register
//   roco_cpu_wb_stage   register-file write data and retire trace
//   roco_cpu_branch_predictor  bimodal predictor and BTB
//   roco_cpu_mmu        Sv32 TLBs and hardware page-table walker
//
// Branches and jumps resolve in EX. A registered redirect reaches fetch
// one cycle later and cancels the younger EX instruction. Full EX/MEM
// and MEM/WB forwarding is used. Data lookups occur in EX and commit in
// MEM; cache misses hold MEM until the requested word is ready. Fetch
// responses carry addresses so redirected stale responses are ignored.
//
// Implemented: RV32I base integer instructions, Zicsr, M/S/U privilege
// modes, trap delegation, Sv32 virtual memory, and traps for illegal
// instructions, ECALL/EBREAK, misaligned addresses and page faults.
// Machine timer/external and software interrupts are supported.

`default_nettype none

module roco_cpu (
  input logic clk,
  input logic rst,
  input logic [31:0] boot_addr,
  input logic halt,
  /* Platform interrupt lines: machine timer and machine external. */
  input logic irq_timer,
  input logic irq_external,
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
  output logic [1:0] dmem_lu_offset,
  output logic [2:0] dmem_lu_funct3,
  input logic dmem_ready,
  output logic dmem_req,
  output logic dmem_we,
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0] dmem_be,
  input logic [31:0] dmem_rsp_data,
  /* Already aligned cached-load value, registered with the EX lookup. */
  input logic [31:0] dmem_forward_data,
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
  logic idex_pred_target_match;
  logic [31:0] idex_pred_jalr_base;
  logic [31:0] idex_pred_jalr_next;
  logic idex_pred_jalr_aligned;
  logic btb_update;
  logic btb_is_branch;
  logic btb_is_jal;
  logic btb_is_jalr;
  logic btb_taken;
  logic [31:0] btb_target;

  logic [4:0] dec_rs1;
  logic [4:0] dec_rs2;
  logic [4:0] dec_rd;
  logic dec_use_rs1;
  logic dec_use_rs2;
  logic dec_regwrite;
  logic dec_is_div;

  logic idex_valid;
  logic [3:0] idex_wb_select;
  logic [31:0] idex_pc;
  logic [31:0] idex_instr;
  logic [31:0] idex_rs1_val;
  logic [31:0] idex_rs2_val;
  logic idex_rs1_from_mem;
  logic idex_rs2_from_mem;
  logic idex_rs1_from_wb;
  logic idex_rs1_from_rf;
  logic [31:0] idex_imm;
  logic [4:0] idex_rs1;
  logic [4:0] idex_rd;
  logic [2:0] idex_funct3;
  logic [3:0] idex_alu_op;
  logic idex_is_muldiv;
  logic [2:0] idex_md_op;
  logic idex_is_div;
  logic idex_alu_b_imm;
  logic idex_alu_a_pc;
  logic idex_regwrite;
  logic idex_is_load;
  logic idex_is_store;
  logic idex_is_amo;
  logic idex_is_lr;
  logic idex_is_sc;
  logic [4:0] idex_amo_op;
  logic idex_is_vec;
  logic idex_is_vset;
  logic idex_is_vload;
  logic idex_is_vstore;
  logic [5:0] idex_vec_funct6;
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
  logic [31:0] unused_imem_rsp_addr;
  assign unused_imem_rsp_addr = imem_rsp_addr;

  logic mmu_flush;
  logic mstatus_mprv;
  logic mstatus_sum;
  logic mstatus_mxr;
  logic unused_mstatus_tvm;
  logic unused_mstatus_tsr;
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
  logic unused_mmu_i_hit;
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
  logic d_fault_q;
  logic [3:0] d_fault_cause_q;
  logic [3:0] mmu_d_fault_cause;
  logic [31:0] mmu_d_paddr;
  logic ex_lu_hit;
  logic [1:0] priv_data;

  logic ex_redirect_en, ex_redirect_raw;
  logic [31:0] ex_redirect_pc, ex_redirect_pc_raw;


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
  logic exmem_forward_cache, exmem_forward_wbval;
  logic exmem_is_store;
  logic exmem_is_amo;
  logic exmem_is_lr;
  logic exmem_is_sc;
  logic [4:0] exmem_amo_op;
  logic ex_trap_taken;
  logic vec_mem_hold;
  logic exmem_is_mul;
  logic exmem_mul_hi;
  logic [63:0] exmem_mul_sum;
  logic [63:0] exmem_mul_carry;
  logic idex_is_mul;
  logic mul_conflict;
  logic exmem_vec_we;
  logic [127:0] exmem_vec_data;
  logic vec_full_write;
  logic [127:0] vec_rf_vs1_data, vec_rf_vs2_data, vec_rf_vd_data;
  logic [127:0] vec_vs1_data;
  logic [127:0] vec_vs2_data;
  logic [127:0] vec_vd_data;
  logic exmem_is_vload;
  logic exmem_is_vstore;
  logic [3:0] exmem_vec_elem;
  logic exmem_vec_last;
  logic [2:0] exmem_vec_sew;
  logic vec_mem_we;
  logic [4:0] vec_mem_wd;
  logic [3:0] vec_mem_elem;
  logic [2:0] vec_mem_sew;
  logic [31:0] vec_mem_wdata;
  logic vec_element_commit;
  logic exmem_is_sfence;
  logic exmem_is_fence_i;

  logic memwb_valid;
  logic [31:0] memwb_data;
  logic [4:0] memwb_rd;
  logic memwb_regwrite;

  logic wb_we;
  logic [4:0] wb_rd;
  logic [31:0] wb_data;

  logic div_busy;
  logic div_conflict;
  logic bubble;
  logic load_dependency;
  logic [4:0] div_rd;
  logic [4:0] div_pending_rd;
  logic div_wb_en;
  logic [4:0] div_wb_rd;
  logic [31:0] div_wb_data;
  logic dmem_lu_stall;
  logic mem_wait;
  logic stall;
  logic ex_lu_valid;
  logic ex_lu_present;
  logic mem_redirect;
  logic retire;
  logic if_consume;
  logic commit_valid;
  logic [31:0] commit_pc;
  logic [31:0] commit_instr;
  logic [4:0] commit_rd;
  logic [31:0] commit_wdata;
  logic [31:0] mem_forward_data;

  assign retire = commit_valid && !vec_element_commit;
  // Registered EX results forward into EX. Memory results interlock
  // in ID so cache read and alignment routing end at the ID/EX register.
  // Register EX redirects before distributing them through the front end.
  // The pending redirect cancels the one younger EX instruction below.
  always_ff @(posedge clk) ex_redirect_pc <= ex_redirect_pc_raw;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      ex_redirect_en <= 1'b0;
    end else if (mem_redirect) begin
      ex_redirect_en <= 1'b0;
    end else begin
      ex_redirect_en <= ex_redirect_raw;
    end
  end

  assign if_consume = if_valid && !stall && !bubble && !ex_redirect_en && !mem_redirect;
  assign ex_lu_hit = mmu_d_hit;
  assign dmem_lu_valid = ex_lu_valid && mmu_d_hit;
  assign dmem_lu_addr = mmu_d_paddr[31:2];
  assign dmem_lu_offset = ex_lu_vaddr[1:0];
  assign dmem_lu_funct3 = idex_funct3;
  // Hold the faulting instruction while registering the MMU response.
  // Trap delegation and fetch redirection then start from a register.
  // MEM holds already stall the pipeline directly. Qualify an EX
  // translation wait without routing that same hold through lookup enable.
  assign dmem_lu_stall = ex_lu_present && !d_fault_q && !ex_lu_hit;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      d_fault_q <= 1'b0;
      d_fault_cause_q <= '0;
    end else begin
      d_fault_q <= mmu_d_fault;
      d_fault_cause_q <= mmu_d_fault_cause;
    end
  end
  // The divider runs decoupled: only an instruction that needs the
  // pending destination register waits for it, and a second divide waits
  // in ID so the execute stage never has to stall on the divider.
  assign div_pending_rd = div_busy ? div_rd : idex_rd;
  assign div_conflict = if_valid && (div_busy || (idex_valid && idex_is_div)) &&
                        (dec_is_div ||
                         ((div_pending_rd != 5'd0) &&
                          ((dec_use_rs1 && (dec_rs1 == div_pending_rd)) ||
                           (dec_use_rs2 && (dec_rs2 == div_pending_rd)) ||
                           (dec_regwrite && (dec_rd == div_pending_rd)))));
  // Wait one cycle for memory producers before decoding a dependent
  // instruction. ID captures the final MEM value; EX forwarding then
  // starts at EX/MEM flops instead of the cache read and alignment muxes.
  assign load_dependency = idex_valid &&
                               (idex_is_load || idex_is_lr || idex_is_amo) &&
                               (idex_rd != 5'd0) && if_valid &&
                               ((dec_use_rs1 && dec_rs1 == idex_rd) ||
                                (dec_use_rs2 && dec_rs2 == idex_rd));
  // A multiply keeps only the carry-save terms in EX; the 64-bit carry
  // propagation completes in MEM. A dependent instruction therefore waits
  // one cycle and then bypasses the MEM result from ID. Only an immediate
  // dependency needs the bubble.
  assign mul_conflict = if_valid && idex_valid && idex_is_mul && (idex_rd != 5'd0) &&
                        ((dec_use_rs1 && (dec_rs1 == idex_rd)) ||
                         (dec_use_rs2 && (dec_rs2 == idex_rd)));
  assign bubble = div_conflict || load_dependency || mul_conflict;
  assign stall = dmem_lu_stall || fence_req || mem_wait || vec_mem_hold;
  assign priv_data = mstatus_mprv ? mstatus_mpp : priv;
  assign idex_is_div = idex_is_muldiv && idex_md_op[2];
  assign idex_is_mul = idex_is_muldiv && !idex_md_op[2];
  assign trace_valid = retire;
  assign trace_pc = commit_pc;
  assign trace_instr = commit_instr;
  assign trace_rd = commit_rd;
  assign trace_wdata = commit_wdata;

  roco_cpu_if_stage u_if (
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

  roco_cpu_id_stage u_id (
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
      .bubble(bubble),
      .flush(ex_redirect_en || mem_redirect),
      .exmem_valid(exmem_valid),
      .exmem_regwrite(exmem_regwrite),
      .exmem_rd(exmem_rd),
      .mem_wb_data(commit_wdata),
      .wb_we(wb_we),
      .wb_rd(wb_rd),
      .wb_data(wb_data),
      .div_we(div_wb_en),
      .div_rd(div_wb_rd),
      .div_data(div_wb_data),
      .dec_rs1(dec_rs1),
      .dec_rs2(dec_rs2),
      .dec_rd(dec_rd),
      .dec_use_rs1(dec_use_rs1),
      .dec_use_rs2(dec_use_rs2),
      .dec_regwrite(dec_regwrite),
      .dec_is_div(dec_is_div),
      .idex_valid(idex_valid),
      .idex_wb_select(idex_wb_select),
      .idex_pc(idex_pc),
      .idex_instr(idex_instr),
      .idex_pred_taken(idex_pred_taken),
      .idex_pred_target_match(idex_pred_target_match),
      .idex_pred_jalr_base(idex_pred_jalr_base),
      .idex_pred_jalr_next(idex_pred_jalr_next),
      .idex_pred_jalr_aligned(idex_pred_jalr_aligned),
      .idex_rs1_val(idex_rs1_val),
      .idex_rs2_val(idex_rs2_val),
      .idex_rs1_from_mem(idex_rs1_from_mem),
      .idex_rs2_from_mem(idex_rs2_from_mem),
      .idex_rs1_from_wb(idex_rs1_from_wb),
      .idex_rs1_from_rf(idex_rs1_from_rf),
      .idex_imm(idex_imm),
      .idex_rs1(idex_rs1),
      .idex_rd(idex_rd),
      .idex_funct3(idex_funct3),
      .idex_alu_op(idex_alu_op),
      .idex_is_muldiv(idex_is_muldiv),
      .idex_md_op(idex_md_op),
      .idex_alu_b_imm(idex_alu_b_imm),
      .idex_alu_a_pc(idex_alu_a_pc),
      .idex_regwrite(idex_regwrite),
      .idex_is_load(idex_is_load),
      .idex_is_store(idex_is_store),
      .idex_is_amo(idex_is_amo),
      .idex_is_lr(idex_is_lr),
      .idex_is_sc(idex_is_sc),
      .idex_amo_op(idex_amo_op),
      .idex_is_vec(idex_is_vec),
      .idex_is_vset(idex_is_vset),
      .idex_is_vload(idex_is_vload),
      .idex_is_vstore(idex_is_vstore),
      .idex_vec_funct6(idex_vec_funct6),
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

  roco_cpu_ex_stage u_ex (
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .lu_stall(dmem_lu_stall),
      .retire(retire),
      .div_busy(div_busy),
      .div_rd(div_rd),
      .div_wb_en(div_wb_en),
      .div_wb_rd(div_wb_rd),
      .div_wb_data(div_wb_data),
      .idex_valid(idex_valid),
      .idex_wb_select(idex_wb_select),
      .idex_pc(idex_pc),
      .idex_instr(idex_instr),
      .idex_pred_taken(idex_pred_taken),
      .idex_pred_target_match(idex_pred_target_match),
      .idex_pred_jalr_base(idex_pred_jalr_base),
      .idex_pred_jalr_next(idex_pred_jalr_next),
      .idex_pred_jalr_aligned(idex_pred_jalr_aligned),
      .idex_rs1_val(idex_rs1_val),
      .idex_rs2_val(idex_rs2_val),
      .idex_rs1_from_mem(idex_rs1_from_mem),
      .idex_rs2_from_mem(idex_rs2_from_mem),
      .idex_rs1_from_wb(idex_rs1_from_wb),
      .idex_rs1_from_rf(idex_rs1_from_rf),
      .idex_imm(idex_imm),
      .idex_rs1(idex_rs1),
      .idex_rd(idex_rd),
      .idex_funct3(idex_funct3),
      .idex_alu_op(idex_alu_op),
      .idex_is_muldiv(idex_is_muldiv),
      .idex_md_op(idex_md_op),
      .idex_alu_b_imm(idex_alu_b_imm),
      .idex_alu_a_pc(idex_alu_a_pc),
      .idex_regwrite(idex_regwrite),
      .idex_is_load(idex_is_load),
      .idex_is_store(idex_is_store),
      .idex_is_amo(idex_is_amo),
      .idex_is_lr(idex_is_lr),
      .idex_is_sc(idex_is_sc),
      .idex_amo_op(idex_amo_op),
      .idex_is_vec(idex_is_vec),
      .idex_is_vset(idex_is_vset),
      .idex_is_vload(idex_is_vload),
      .idex_is_vstore(idex_is_vstore),
      .idex_vec_funct6(idex_vec_funct6),
      .vec_vs1_data(vec_vs1_data),
      .vec_vs2_data(vec_vs2_data),
      .vec_vd_data(vec_vd_data),
      .exmem_vec_we(exmem_vec_we),
      .exmem_vec_data(exmem_vec_data),
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
      .fence_hold(fence_req || mem_wait),
      .irq_next_pc(if_valid ? if_pc : fetch_pc),
      .irq_timer(irq_timer),
      .irq_external(irq_external),
      .redirect_from_mem(mem_redirect || ex_redirect_en),
      .mem_data(mem_forward_data),
      .wb_data(wb_data),
      .wb_we(wb_we),
      .dmem_lu_fault(d_fault_q),
      .dmem_lu_fault_cause(d_fault_cause_q),
      .dmem_lu_paddr(mmu_d_paddr),
      .ex_trap_taken(ex_trap_taken),
      .vec_mem_hold(vec_mem_hold),
      .ex_redirect_en(ex_redirect_raw),
      .ex_redirect_pc(ex_redirect_pc_raw),
      .btb_update(btb_update),
      .btb_is_branch(btb_is_branch),
      .btb_is_jal(btb_is_jal),
      .btb_is_jalr(btb_is_jalr),
      .btb_taken(btb_taken),
      .btb_target(btb_target),
      .ex_lu_valid(ex_lu_valid),
      .ex_lu_present(ex_lu_present),
      .ex_lu_vaddr(ex_lu_vaddr),
      .ex_lu_we(ex_lu_we),
      .priv(priv),
      .satp(satp),
      .satp_write(satp_write),
      .mstatus_mprv(mstatus_mprv),
      .mstatus_sum(mstatus_sum),
      .mstatus_mxr(mstatus_mxr),
      .mstatus_tvm(unused_mstatus_tvm),
      .mstatus_tsr(unused_mstatus_tsr),
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
      .exmem_forward_cache(exmem_forward_cache),
      .exmem_forward_wbval(exmem_forward_wbval),
      .exmem_is_store(exmem_is_store),
      .exmem_is_amo(exmem_is_amo),
      .exmem_is_lr(exmem_is_lr),
      .exmem_is_sc(exmem_is_sc),
      .exmem_amo_op(exmem_amo_op),
      .exmem_is_vload(exmem_is_vload),
      .exmem_is_vstore(exmem_is_vstore),
      .exmem_vec_elem(exmem_vec_elem),
      .exmem_vec_last(exmem_vec_last),
      .exmem_vec_sew(exmem_vec_sew),
      .exmem_is_sfence(exmem_is_sfence),
      .exmem_is_fence_i(exmem_is_fence_i),
      .exmem_is_mul(exmem_is_mul),
      .exmem_mul_hi(exmem_mul_hi),
      .exmem_mul_sum(exmem_mul_sum),
      .exmem_mul_carry(exmem_mul_carry)
  );

  // Arithmetic and load elements share the MEM write boundary. A full
  // result forwards to all three EX vector reads before register commit.
  assign vec_full_write = exmem_valid && exmem_vec_we && !halt && !rst;
  assign vec_vs1_data = (vec_full_write && (exmem_rd == idex_instr[19:15])) ?
                        exmem_vec_data : vec_rf_vs1_data;
  assign vec_vs2_data = (vec_full_write && (exmem_rd == idex_instr[24:20])) ?
                        exmem_vec_data : vec_rf_vs2_data;
  assign vec_vd_data = (vec_full_write && (exmem_rd == idex_instr[11:7])) ?
                      exmem_vec_data : vec_rf_vd_data;

  roco_cpu_vec u_vec (
      .clk(clk),
      .rst(rst),
      .vs1(idex_instr[19:15]),
      .vs2(idex_instr[24:20]),
      .vd(idex_instr[11:7]),
      .vs1_data(vec_rf_vs1_data),
      .vs2_data(vec_rf_vs2_data),
      .vd_data(vec_rf_vd_data),
      .ex_we(vec_full_write),
      .ex_wd(exmem_rd),
      .ex_wdata(exmem_vec_data),
      .mem_we(vec_mem_we),
      .mem_wd(vec_mem_wd),
      .mem_elem(vec_mem_elem),
      .mem_sew(vec_mem_sew),
      .mem_wdata(vec_mem_wdata)
  );

  roco_cpu_mmu u_mmu (
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
      .i_hit(unused_mmu_i_hit),
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

  // Train the predictor one cycle after resolution. Capture payload
  // unconditionally so only one validity flop sees late branch control.
  logic bp_update_valid;
  logic [31:2] bp_update_pc;
  logic [31:0] bp_update_target;
  logic bp_update_branch, bp_update_jal, bp_update_jalr, bp_update_taken;
  // Payload flops carry no reset value; only bp_update_valid gates their
  // visibility, which keeps them out of the asynchronous reset cone.
  always_ff @(posedge clk) begin
    bp_update_pc <= idex_pc[31:2];
    bp_update_target <= btb_target;
    bp_update_branch <= btb_is_branch;
    bp_update_jal <= btb_is_jal;
    bp_update_jalr <= btb_is_jalr;
    bp_update_taken <= btb_taken;
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      bp_update_valid <= 1'b0;
    end else if (mem_redirect || satp_write) begin
      bp_update_valid <= 1'b0;
    end else begin
      bp_update_valid <= btb_update;
    end
  end

  roco_cpu_branch_predictor u_bp (
      .clk(clk),
      .rst(rst),
      .flush(fence_req),
      .if_pc(fetch_pc),
      .if_pred_taken(pred_taken),
      .if_pred_target(pred_target),
      .ex_pc(bp_update_pc),
      .ex_update(bp_update_valid && !halt),
      .ex_is_branch(bp_update_branch),
      .ex_is_jal(bp_update_jal),
      .ex_is_jalr(bp_update_jalr),
      .ex_taken(bp_update_taken),
      .ex_target(bp_update_target)
  );

  roco_cpu_mem_stage u_mem (
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
      .exmem_forward_cache(exmem_forward_cache),
      .exmem_forward_wbval(exmem_forward_wbval),
      .exmem_is_store(exmem_is_store),
      .exmem_is_amo(exmem_is_amo),
      .exmem_is_lr(exmem_is_lr),
      .exmem_is_sc(exmem_is_sc),
      .exmem_amo_op(exmem_amo_op),
      .exmem_is_vload(exmem_is_vload),
      .exmem_is_vstore(exmem_is_vstore),
      .exmem_vec_elem(exmem_vec_elem),
      .exmem_vec_last(exmem_vec_last),
      .exmem_vec_sew(exmem_vec_sew),
      .exmem_is_sfence(exmem_is_sfence),
      .exmem_is_fence_i(exmem_is_fence_i),
      .exmem_is_mul(exmem_is_mul),
      .exmem_mul_hi(exmem_mul_hi),
      .exmem_mul_sum(exmem_mul_sum),
      .exmem_mul_carry(exmem_mul_carry),
      .trap_taken(ex_trap_taken || satp_write),
      .vec_mem_we(vec_mem_we),
      .vec_mem_wd(vec_mem_wd),
      .vec_mem_elem(vec_mem_elem),
      .vec_mem_sew(vec_mem_sew),
      .vec_mem_wdata(vec_mem_wdata),
      .vec_element_commit(vec_element_commit),
      .dmem_req(dmem_req),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_be(dmem_be),
      .dmem_rsp_data(dmem_rsp_data),
      .dmem_forward_data(dmem_forward_data),
      .dmem_ready(dmem_ready),
      .mem_wait(mem_wait),
      .fence_req(fence_req),
      .mem_redirect(mem_redirect),
      .commit_valid(commit_valid),
      .commit_pc(commit_pc),
      .commit_instr(commit_instr),
      .commit_rd(commit_rd),
      .commit_wdata(commit_wdata),
      .forward_data(mem_forward_data),
      .memwb_valid(memwb_valid),
      .memwb_data(memwb_data),
      .memwb_rd(memwb_rd),
      .memwb_regwrite(memwb_regwrite)
  );

  roco_cpu_wb_stage u_wb (
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
