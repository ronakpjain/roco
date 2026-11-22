// Execute stage.
//
// Owns operand forwarding, the ALU, branch/jump resolution, trap
// detection, the machine/supervisor CSR file and the EX/MEM pipeline
// register. A redirect is emitted only when the pipeline is not stalled,
// so older instructions always commit first. Software CSR writes occur in
// EX; registered trap entry, MRET and SRET use redirects from this stage.
// Data-cache lookup addresses come from the MMU translation of the
// virtual address computed here; a page fault is resolved as a trap.

`default_nettype none
`include "roco_cpu_defs.svh"

`include "roco_rvfi.svh"

module roco_cpu_ex_stage (
`ifdef ROCO_SOC_RETIRE_MEMORY_FORMAL
  output logic formal_sync_capture,
  output logic formal_sync_pending,
`endif
`ifdef ROCO_VECTOR_MEM_STREAM
  input logic [1:0] formal_vec_width,
  input logic [4:0] formal_vec_reg,
  input logic [3:0] formal_vec_byte,
  input logic [7:0] reference_vec_byte,
`endif
`ifdef ROCO_RVFI
  input logic [4:0] rvfi_idex_rs1,
  input logic [4:0] rvfi_idex_rs2,
  output roco_rvfi_meta_t rvfi_exmem,
  output roco_rvfi_meta_t rvfi_exception,
`ifdef ROCO_IRQ_PIPELINE_CHECKS
  output logic formal_irq_pending,
  formal_trap_pending,
  output logic [31:0] formal_irq_epc,
`endif
  output logic rvfi_trap_entry,
  output logic rvfi_sync_exception,
  output logic [31:0] rvfi_trap_vector,
`ifdef ROCO_RVFI_FORWARD_CHECKS
  output logic rvfi_fwd_mem_ready,
  output logic rvfi_fwd_cancel,
`ifdef ROCO_RVFI_INSN_CHECKS
  output logic rvfi_fwd_trap_pending,
`endif
  output logic [31:0] rvfi_fwd_held_rs1,
  rvfi_fwd_held_rs2,
`endif
`ifdef ROCO_RVFI_DIV_CHECKS
  output logic rvfi_div_start,
  output logic [31:0] rvfi_div_a,
  rvfi_div_b,
`endif
`endif
  input logic clk,
  input logic rst,
  input logic halt,
  input logic lu_stall,
  input logic retire,
  /* Decoupled divide scoreboard and writeback port. */
  output logic div_busy,
  output logic [4:0] div_rd,
  output logic div_wb_en,
  output logic [4:0] div_wb_rd,
  output logic [31:0] div_wb_data,
  /* ID/EX pipeline register. */
  input logic idex_valid,
  input logic [3:0] idex_wb_select,
  input logic [31:0] idex_pc,
  input logic [31:0] idex_instr,
  input logic [31:0] idex_rs1_val,
  input logic [31:0] idex_rs2_val,
  input logic idex_rs1_from_mem,
  input logic idex_rs2_from_mem,
  input logic idex_rs1_from_wb,
  input logic idex_rs1_from_rf,
  input logic [31:0] idex_imm,
  input logic [4:0] idex_rs1,
  input logic [4:0] idex_rd,
  input logic [2:0] idex_funct3,
  input logic [3:0] idex_alu_op,
  input logic idex_is_muldiv,
  input logic [2:0] idex_md_op,
  input logic [31:0] idex_alu_a_val,
  input logic [31:0] idex_alu_b_val,
  input logic idex_alu_a_from_mem,
  input logic idex_alu_b_from_mem,
  input logic idex_regwrite,
  input logic idex_is_load,
  input logic idex_is_store,
  input logic idex_is_amo,
  input logic idex_is_lr,
  input logic idex_is_sc,
  input logic [4:0] idex_amo_op,
  input logic idex_is_vec,
  input logic idex_is_vset,
  input logic idex_is_vload,
  input logic idex_is_vstore,
  input logic [5:0] idex_vec_funct6,
  /* Vector unit read data and configuration. */
  input logic [127:0] vec_vs1_data,
  input logic [127:0] vec_vs2_data,
  input logic [127:0] vec_vd_data,

  input logic idex_is_branch,
  input logic idex_is_jal,
  input logic idex_is_jalr,
  input logic idex_is_csr,
  input logic idex_csr_uimm,
  input logic [1:0] idex_csr_op,
  input logic [11:0] idex_csr_addr,
  input logic idex_illegal,
  input logic idex_ecall,
  input logic idex_ebreak,
  input logic idex_ifault,
  input logic idex_mret,
  input logic idex_sret,
  input logic idex_is_sfence,
  input logic idex_is_fence_i,
  input logic fence_hold,
  input logic idex_pred_taken,
  input logic idex_pred_target_match,
  input logic [31:0] idex_pred_jalr_base,
  input logic [31:0] idex_pred_jalr_carry,
  input logic idex_pred_jalr_aligned,
  /* Final MEM result and registered WB forwarding. */
  input logic [31:0] mem_data,
  input logic [31:0] wb_data,
  input logic wb_we,
  /* Data translation result from the MMU. */
  input logic dmem_lu_fault,
  input logic [3:0] dmem_lu_fault_cause,
  input logic [31:0] dmem_lu_paddr,
  /* Interrupt request from the CSR file. */
  input logic [31:0] irq_next_pc,
  input logic irq_timer,
  input logic irq_external,
  input logic redirect_from_mem,
  /* Trap entry this cycle, used to drop a reservation. */
  output logic ex_trap_taken,
  /* Vector memory sequencing holds the front end. */
  output logic vec_mem_hold,
  /* Redirect to fetch. */
  output logic ex_redirect_en,
  output logic [31:0] ex_redirect_base,
  output logic [31:0] ex_redirect_offset,
  output logic ex_redirect_fallthrough,
  output logic ex_redirect_mask_lsb,
  output logic btb_update,
  output logic btb_is_branch,
  output logic btb_is_jal,
  output logic btb_is_jalr,
  output logic btb_taken,
  output logic [31:0] btb_target,
  output logic ex_lu_valid,
  output logic ex_lu_present,
  output logic [31:0] ex_lu_vaddr,
  output logic ex_lu_we,
  /* Privilege and translation state. */
  output logic [1:0] priv,
  output logic [31:0] satp,
  output logic satp_write,
  output logic mstatus_mprv,
  output logic mstatus_sum,
  output logic mstatus_mxr,
  output logic mstatus_tvm,
  output logic mstatus_tsr,
  output logic [1:0] mstatus_mpp,
  /* EX/MEM pipeline register. */
  output logic exmem_vec_we,
  output logic [127:0] exmem_vec_data,
  output logic exmem_valid,
  output logic [31:0] exmem_pc,
  output logic [31:0] exmem_instr,
  output logic [31:0] exmem_alu,
  output logic [31:0] exmem_wbval,
  output logic [31:0] exmem_store_data,
  output logic [3:0] exmem_be,
  output logic [4:0] exmem_rd,
  output logic [2:0] exmem_funct3,
  output logic exmem_regwrite,
  output logic exmem_is_load,
  output logic exmem_forward_cache,
  output logic exmem_forward_wbval,
  output logic exmem_is_store,
  output logic exmem_is_amo,
  output logic exmem_is_lr,
  output logic exmem_is_sc,
  output logic [4:0] exmem_amo_op,
  output logic exmem_is_vload,
  output logic exmem_is_vstore,
  output logic [3:0] exmem_vec_elem,
  output logic exmem_vec_last,
  output logic [2:0] exmem_vec_sew,
  output logic exmem_is_sfence,
  output logic exmem_is_fence_i,
  /* Multiply carry-save terms complete in MEM. */
  output logic exmem_is_mul,
  output logic exmem_mul_hi,
  output logic [63:0] exmem_mul_sum,
  output logic [63:0] exmem_mul_carry
);

  logic vec_ex_we;
  logic [31:0] rs1_fwd;
  logic [31:0] rs2_fwd;
  logic [31:0] ex_alu_a;
  logic [31:0] ex_alu_b;
  logic [31:0] alu_result;
  logic [31:0] mul_p0;
  logic [33:0] mul_p1;
  logic [33:0] mul_p2;
  logic [31:0] mul_p3;
  logic [63:0] mul_sum1;
  logic [63:0] mul_carry1;
  logic idex_is_mul;
  logic [31:0] md_div_result;
  logic [31:0] ex_alu_result;
  logic idex_is_div;
  logic div_start;
  logic [4:0] div_rd_q;
  logic [31:0] ex_store_data;
  logic [3:0] ex_store_be;
  logic [31:0] ex_branch_target;
  logic [31:0] ex_jump_target;
  logic ex_branch_taken;
  logic ex_mem_misaligned;
  logic ex_target_misaligned;
  logic ex_trap;
  logic [31:0] ex_trap_cause;
  logic ex_redirect;
  logic ex_redirect_int;
  logic irq_take;
  logic trap_pending, trap_commit;
  logic cancel_ex;
  logic trap_capture;
  logic [31:0] csr_trap_pc;
  logic [31:0] csr_trap_cause;
  logic [31:0] csr_trap_tval;
  logic branch_mispredict;
  logic scalar_mem_ready;
  logic scalar_is_mem;
  logic scalar_mem_prepare;
  logic lookup_is_vec_q;
  logic [31:0] stall_alu;
  logic [31:0] stall_store_data;
  logic [3:0] stall_be;
  logic [31:0] memory_addr;
  logic [31:0] memory_addr_held;
  logic [31:0] mem_access_addr;
  logic [31:0] ex_st;
  logic [3:0] ex_be;
  logic [31:0] ex_trap_tval;
  logic ex_csr_illegal;
  logic [31:0] ex_wbval;
  logic [31:0] csr_rdata;
  logic csr_exists;
  logic csr_read_ok;
  logic csr_write_ok;
  logic [31:0] csr_src;
  logic csr_write_intent;
  logic is_satp_write;
  logic [31:0] csr_wdata;
  logic csr_wr_en, csr_issue, csr_commit_q;
  logic [11:0] csr_commit_addr_q;
  logic [31:0] csr_commit_data_q;
  logic trap_is_irq_q;
  logic [31:0] csr_sync_pc_q, csr_irq_pc_q, csr_sync_cause_q;
  logic [4:0] csr_irq_code_q;
  logic [31:0] sync_cause_candidate, sync_tval_candidate;
  logic sync_target_candidate, trap_target_q, trap_target_mask_q;
  logic [31:0] trap_target_base_q, trap_target_offset_q, trap_target_sum, csr_entry_tval;
  logic [31:0] csr_trap_vector;
  logic [31:0] unused_csr_mtvec;
  logic [31:0] unused_csr_stvec;
  logic [31:0] csr_mepc;
  logic [31:0] csr_sepc;
  logic [1:0] csr_priv;
  logic csr_mprv;
  logic csr_sum;
  logic csr_mxr;
  logic csr_tvm;
  logic csr_tsr;
  logic [1:0] csr_mpp;
  logic ex_priv_illegal;
  logic [31:0] ex_ecall_cause;
  logic csr_mret_en;
  logic csr_sret_en;
  logic [4:0] vec_vl;
  logic vec_vtype_vta;
  logic [2:0] vec_vtype_sew;
  logic [31:0] vec_vstart;
  logic vec_vstart_we;
  logic [4:0] vec_vstart_data;
  logic vec_start_illegal;
  logic vec_vset_en;
  logic [4:0] vec_vset_vl;
  logic [31:0] vec_vset_vtype;
  logic irq_req;
  logic [4:0] irq_code;
  logic div_wb_en_raw;
  logic div_engine_busy;
  logic div_write_pending;

  // Only LMUL=1 is supported: VLMAX is VLEN/SEW elements, which for the
  // 128-bit register file is 16 lanes at e8, 8 at e16 and 4 at e32.
  logic [2:0] vec_sew_cur;
  logic vec_vta_cur;
  logic is_vec_mem;
  logic vec_fault;
  logic [7:0] vset_vt;
  logic vset_rsvd;
  logic [31:0] vset_new_vtype;
  logic [31:0] vset_new_vl;
  logic [31:0] vset_avl;
  logic [4:0] vset_vlmax;
  logic vset_vill;
  logic vset_reg_form;
  logic [31:0] vec_scalar_b;
  logic vec_exec_eligible;
  logic vec_operand_ready;
  logic vec_arith_work;
  logic vec_arith_prepare;
  logic [127:0] vec_pipeline_result;
  logic [127:0] vec_vs1_q, vec_vs2_q, vec_vd_q;
  logic [31:0] vec_scalar_q;
  logic [4:0] vec_write_vl;
  logic [15:0] vec_active_bytes, vec_fill_bytes, vec_active_q, vec_fill_q;
  logic [127:0] vec_reduce_input, vec_reduce_q;
  logic [2:0] vec_sew_q;

  logic vec_scalar_wb;
  logic [31:0] vec_scalar_wdata;
  logic [4:0] vmem_idx;
  logic [4:0] vmem_total;
  logic [4:0] vmem_k;
  logic [1:0] vmem_shift;
  logic vmem_active;
  logic vmem_issue;
  logic vmem_hold;
  logic vmem_done;
  logic [31:0] vmem_addr;
  logic [31:0] vmem_base;
  logic [31:0] vmem_stride;
  logic [31:0] vec_store_elem;
  logic [3:0] vmem_be;
  logic [31:0] vmem_store_data;
  logic [31:0] vmem_start_addr;
  logic vmem_noop;
  logic [2:0] vec_elem_sew;

  // ------------------------------------------------------------- Forwarding
  // ID captured RF/WB sources and zeroed MEM-dependent operands.
  assign rs1_fwd = ({32{idex_rs1_from_mem}} & mem_data) | idex_rs1_val;
  assign rs2_fwd = ({32{idex_rs2_from_mem}} & mem_data) | idex_rs2_val;

  logic branch_equal, branch_signed_lt, branch_unsigned_lt;
  roco_cpu_compare u_branch_compare (
      .a(rs1_fwd),
      .b(rs2_fwd),
      .equal(branch_equal),
      .signed_lt(branch_signed_lt),
      .unsigned_lt(branch_unsigned_lt)
  );

  // ------------------------------------------------------------------- ALU
  assign ex_alu_a = idex_alu_a_val | ({32{idex_alu_a_from_mem}} & mem_data);
  assign ex_alu_b = idex_alu_b_val | ({32{idex_alu_b_from_mem}} & mem_data);

  roco_cpu_alu u_alu (
      .a(ex_alu_a),
      .b(ex_alu_b),
      .op(idex_alu_op),
      .result(alu_result)
  );

  assign idex_is_div = idex_is_muldiv && idex_md_op[2];
  assign idex_is_mul = idex_is_muldiv && !idex_md_op[2];
  assign div_start = idex_valid && idex_is_div && !div_busy && !fence_hold && !halt && !cancel_ex;
`ifdef ROCO_RVFI_DIV_CHECKS
  assign rvfi_div_start = div_start;
  assign rvfi_div_a = rs1_fwd;
  assign rvfi_div_b = rs2_fwd;
`endif

  roco_cpu_divider u_divider (
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .op(idex_md_op),
      .a(rs1_fwd),
      .b(rs2_fwd),
      .start(div_start),
      .busy(div_engine_busy),
      .done(div_wb_en_raw),
      .div_result(md_div_result)
  );

  // Explicit parallel DSP products plus a carry-save tree complete in EX.
  // MEM forwards the registered product, keeping carry propagation off a
  // dependent cache lookup's address path.
  roco_cpu_mul_prod u_mul_prod (
      .a(rs1_fwd),
      .b(rs2_fwd),
      .variant(idex_md_op),
      .p0(mul_p0),
      .p1(mul_p1),
      .p2(mul_p2),
      .p3(mul_p3)
  );

  roco_cpu_mul_term u_mul_term (
      .p0(mul_p0),
      .p1(mul_p1),
      .p2(mul_p2),
      .p3(mul_p3),
      .sum1(mul_sum1),
      .carry1(mul_carry1)
  );

  // A divide leaves the pipeline immediately and writes the register
  // file later through the divider port.
  assign ex_alu_result = idex_is_div ? md_div_result : alu_result;
  assign div_rd = div_rd_q;
  assign div_wb_rd = div_rd_q;
  assign div_wb_data = md_div_result;
  // The physical register file has one write port. Keep the completion
  // pending while normal WB owns it, and keep the scoreboard busy until
  // the divider result is actually written.
  assign div_busy = div_engine_busy || div_write_pending;
  assign div_wb_en = (div_wb_en_raw || div_write_pending) && (div_rd_q != 5'd0) && !wb_we && !halt;
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      div_write_pending <= 1'b0;
    end else if (!halt) begin
      if (div_wb_en_raw && (div_rd_q != 5'd0)) begin
        div_write_pending <= wb_we;
      end else if (!wb_we) begin
        div_write_pending <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      div_rd_q <= '0;
    end else if (div_start) begin
      div_rd_q <= idex_rd;
    end
  end

  assign ex_branch_target = idex_pc + idex_imm;
  // Reuse parallel address sums to keep ALU selection off JALR targets.
  assign ex_jump_target = {memory_addr[31:1], 1'b0};

  always_comb begin
    case (idex_funct3)
      3'b000: begin
        ex_store_be = 4'b0001 << memory_addr[1:0];
      end
      3'b001: begin
        ex_store_be = 4'b0011 << memory_addr[1:0];
      end
      default: begin
        ex_store_be = 4'b1111;
      end
    endcase
    ex_store_data = rs2_fwd << {memory_addr[1:0], 3'b000};
  end

  // Loads and stores always add rs1 and the immediate. Keep their address
  // path independent of the ALU and compare forwarding registers in ID.
  assign memory_addr =
      ({32{idex_rs1_from_mem}} & (mem_data + idex_imm)) |
      ({32{idex_rs1_from_wb}} & (wb_data + idex_imm)) |
      ({32{idex_rs1_from_rf}} & (idex_rs1_val + idex_imm));
  assign scalar_is_mem = idex_is_load || idex_is_store || idex_is_amo || idex_is_lr || idex_is_sc;
  assign scalar_mem_prepare = idex_valid && scalar_is_mem && !scalar_mem_ready;
  assign memory_addr_held = stall_alu;
  // Both scalar and vector memory operations have a setup cycle. Stage
  // lookup selectors too, so live decode flags cannot bypass the address
  // register through MMU permission/hold logic.
  always_ff @(posedge clk) begin
    lookup_is_vec_q <= is_vec_mem;
    ex_lu_we <= idex_is_store || idex_is_amo || idex_is_sc || idex_is_vstore;
  end
  assign mem_access_addr = lookup_is_vec_q ? vmem_addr : memory_addr_held;
  assign ex_st = is_vec_mem ? vmem_store_data : stall_store_data;
  assign ex_be = is_vec_mem ? vmem_be : stall_be;
  // Decode the mutually exclusive writeback producers in ID. EX data
  // meets one parallel merge instead of a priority chain after multiply.
  // Loads, SC and AMOs select their value in MEM. The scalar writeback
  // word need not traverse the memory-address/translation mux.
  assign ex_wbval = ({32{idex_wb_select[3]}} & (idex_pc + 32'd4)) |
                    ({32{idex_wb_select[2]}} & csr_rdata) |
                    ({32{idex_wb_select[1]}} & vec_scalar_wdata) |
                    ({32{idex_wb_select[0]}} & ex_alu_result);

  // -------------------------------------------------- CSR file (EX and WB)
  roco_cpu_csr u_csr (
      .clk(clk),
      .rst(rst),
      .raddr(idex_csr_addr),
      .rdata(csr_rdata),
      .exists(csr_exists),
      .read_ok(csr_read_ok),
      .write_ok(csr_write_ok),
      .wr_en(csr_wr_en),
      .wr_addr(csr_commit_addr_q),
      .wr_data(csr_commit_data_q),
      .trap_en(trap_commit && !halt),
      .trap_pc(csr_trap_pc),
      .trap_cause(csr_trap_cause),
      .trap_tval(csr_entry_tval),
      .irq_timer(irq_timer),
      .irq_external(irq_external),
      .irq_req(irq_req),
      .irq_code(irq_code),
      .mret_en(csr_mret_en),
      .sret_en(csr_sret_en),
      .retire(retire),
      .priv(csr_priv),
      .mtvec(unused_csr_mtvec),
      .stvec(unused_csr_stvec),
      .trap_vector(csr_trap_vector),
      .mepc(csr_mepc),
      .sepc(csr_sepc),
      .satp(satp),
      .satp_write(satp_write),
      .vset_en(vec_vset_en),
      .vset_vl(vec_vset_vl),
      .vset_vtype(vec_vset_vtype),
      .vl(vec_vl),
      .vtype_vta(vec_vtype_vta),
      .vtype_sew(vec_vtype_sew),
      .vstart_out(vec_vstart),
      .vstart_we(vec_vstart_we),
      .vstart_data(vec_vstart_data),
      .mstatus_mprv(csr_mprv),
      .mstatus_sum(csr_sum),
      .mstatus_mxr(csr_mxr),
      .mstatus_tvm(csr_tvm),
      .mstatus_tsr(csr_tsr),
      .mstatus_mpp(csr_mpp)
  );

  assign priv = csr_priv;
  assign mstatus_mprv = csr_mprv;
  assign mstatus_sum = csr_sum;
  assign mstatus_mxr = csr_mxr;
  assign mstatus_tvm = csr_tvm;
  assign mstatus_tsr = csr_tsr;
  assign mstatus_mpp = csr_mpp;
  // Return instructions cannot also branch or access data memory.
  // Authorize their own legal event directly, keeping branch/JALR
  // operand comparison out of privilege-state register enables.
  assign csr_mret_en = idex_valid && idex_mret && (csr_priv == `RV32_PRIV_M) &&
                       !idex_illegal && !idex_ifault && !dmem_lu_fault &&
                       !fence_hold && !halt && !cancel_ex;
  assign csr_sret_en = idex_valid && idex_sret && (csr_priv != `RV32_PRIV_U) &&
                       !((csr_priv == `RV32_PRIV_S) && csr_tsr) &&
                       !idex_illegal && !idex_ifault && !dmem_lu_fault &&
                       !fence_hold && !halt && !cancel_ex;

  assign csr_src = idex_csr_uimm ? {27'd0, idex_rs1} : rs1_fwd;
  // Zicsr suppresses CSRRS/CSRRC writes for encoded x0 (or uimm=0),
  // not for a non-x0 register whose value happens to be zero.
  assign is_satp_write = idex_is_csr && csr_write_intent && (idex_csr_addr == 12'h180);
  assign csr_write_intent = idex_is_csr && ((idex_csr_op == `RV32_CSR_RW) || (idex_rs1 != 5'd0));
  assign ex_csr_illegal = idex_is_csr &&
                          (!csr_exists || !csr_read_ok ||
                           (csr_write_intent && !csr_write_ok));
  // CSR instructions cannot branch or access memory. Qualify their
  // own traps directly so branch comparison and alignment do not feed
  // satp writes and the TLB flush/write-enable path.
  assign csr_issue = idex_valid && idex_is_csr && csr_write_intent && csr_exists &&
                     csr_read_ok && csr_write_ok && !idex_illegal && !idex_ifault &&
                     !dmem_lu_fault && !fence_hold && !halt && !cancel_ex;

  // Only this packet-valid bit sees backend readiness. The CSR bank
  // write ports start at registers, rather than the memory-ready cone.
  always_ff @(posedge clk) begin
    csr_commit_addr_q <= idex_csr_addr;
    csr_commit_data_q <= csr_wdata;
  end
  always_ff @(posedge clk or posedge rst) begin
    if (rst) csr_commit_q <= 1'b0;
    else csr_commit_q <= csr_issue;
  end
  assign csr_wr_en = csr_commit_q && !halt;

  always_comb begin
    case (idex_csr_op)
      `RV32_CSR_RW: begin
        csr_wdata = csr_src;
      end
      `RV32_CSR_RS: begin
        csr_wdata = csr_rdata | csr_src;
      end
      default: begin
        csr_wdata = csr_rdata & ~csr_src;
      end
    endcase
  end

  // ------------------------------------ Privilege and exception selection
  always_comb begin
    ex_priv_illegal = 1'b0;
    ex_ecall_cause = `RV32_CAUSE_ECALL_M;
    if (idex_valid) begin
      if (idex_mret && (csr_priv != `RV32_PRIV_M)) begin
        ex_priv_illegal = 1'b1;
      end
      if (idex_sret &&
          ((csr_priv == `RV32_PRIV_U) || ((csr_priv == `RV32_PRIV_S) && csr_tsr))) begin
        ex_priv_illegal = 1'b1;
      end
      if (idex_is_sfence &&
          ((csr_priv == `RV32_PRIV_U) || ((csr_priv == `RV32_PRIV_S) && csr_tvm))) begin
        ex_priv_illegal = 1'b1;
      end
      case (csr_priv)
        `RV32_PRIV_U: begin
          ex_ecall_cause = `RV32_CAUSE_ECALL_U;
        end
        `RV32_PRIV_S: begin
          ex_ecall_cause = `RV32_CAUSE_ECALL_S;
        end
        default: begin
          ex_ecall_cause = `RV32_CAUSE_ECALL_M;
        end
      endcase
    end
  end

  // ---------------------------------------- Branch, trap, redirect, MRET
  always_comb begin
    ex_branch_taken = 1'b0;
    ex_mem_misaligned = 1'b0;
    ex_target_misaligned = 1'b0;
    ex_trap = 1'b0;
    ex_trap_cause = 32'd0;
    ex_trap_tval = 32'd0;
    ex_redirect = 1'b0;
    branch_mispredict = 1'b0;
    if (idex_valid) begin
      if (idex_is_branch) begin
        case (idex_funct3)
          3'b000: begin
            ex_branch_taken = branch_equal;
          end
          3'b001: begin
            ex_branch_taken = !branch_equal;
          end
          3'b100: begin
            ex_branch_taken = branch_signed_lt;
          end
          3'b101: begin
            ex_branch_taken = !branch_signed_lt;
          end
          3'b110: begin
            ex_branch_taken = branch_unsigned_lt;
          end
          3'b111: begin
            ex_branch_taken = !branch_unsigned_lt;
          end
          default: begin
            ex_branch_taken = 1'b0;
          end
        endcase
      end

      if ((scalar_is_mem && scalar_mem_ready) || (is_vec_mem && vmem_active && !vmem_done)) begin
        case (idex_funct3 == 3'b110 ? 3'b010 : idex_funct3)
          3'b001, 3'b101: begin
            ex_mem_misaligned = mem_access_addr[0];
          end
          3'b010: begin
            ex_mem_misaligned = |mem_access_addr[1:0];
          end
          default: begin
            ex_mem_misaligned = 1'b0;
          end
        endcase
      end

      if (idex_is_branch && ex_branch_taken) begin
        ex_target_misaligned = |ex_branch_target[1:0];
      end else if (idex_is_jal) begin
        ex_target_misaligned = |ex_branch_target[1:0];
      end else if (idex_is_jalr) begin
        ex_target_misaligned = ex_jump_target[1];
      end

      // A branch can also have a misaligned fall-through address. Check
      // its origin without involving the late branch direction compare.
      if (idex_is_branch && (|idex_pc[1:0])) begin
        ex_trap = 1'b1;
        ex_trap_cause = `RV32_CAUSE_INSTR_MISALIGNED;
        ex_trap_tval = idex_pc;
      end else if (idex_ifault) begin
        ex_trap = 1'b1;
        ex_trap_cause = `RV32_CAUSE_INSTR_PAGE_FAULT;
        ex_trap_tval = idex_pc;
      end else if (idex_illegal || ex_csr_illegal || ex_priv_illegal || vec_start_illegal) begin
        ex_trap = 1'b1;
        ex_trap_cause = `RV32_CAUSE_ILLEGAL;
        ex_trap_tval = idex_instr;
      end else if (idex_ebreak) begin
        ex_trap = 1'b1;
        ex_trap_cause = `RV32_CAUSE_BREAKPOINT;
      end else if (idex_ecall) begin
        ex_trap = 1'b1;
        ex_trap_cause = ex_ecall_cause;
      end else if (ex_target_misaligned) begin
        ex_trap = 1'b1;
        ex_trap_cause = `RV32_CAUSE_INSTR_MISALIGNED;
        ex_trap_tval = idex_is_jalr ? ex_jump_target : ex_branch_target;
      end else if (dmem_lu_fault) begin
        ex_trap = 1'b1;
        ex_trap_cause = {28'd0, dmem_lu_fault_cause};
        ex_trap_tval = mem_access_addr;
      end else if (ex_mem_misaligned) begin
        ex_trap = 1'b1;
        ex_trap_cause = (idex_is_store || idex_is_amo || idex_is_sc || idex_is_vstore) ?
                        `RV32_CAUSE_STORE_MISALIGNED : `RV32_CAUSE_LOAD_MISALIGNED;
        ex_trap_tval = mem_access_addr;
      end

      if (idex_is_branch) begin
        branch_mispredict = (ex_branch_taken != idex_pred_taken) ||
                            (ex_branch_taken && !idex_pred_target_match);
      end else if (idex_is_jal) begin
        branch_mispredict = !(idex_pred_taken && idex_pred_target_match);
      end else if (idex_is_jalr) begin
        branch_mispredict = !idex_pred_taken || !idex_pred_jalr_aligned ||
                            ((rs1_fwd[0] && idex_imm[0]) ?
                             (rs1_fwd[31:1] != idex_pred_jalr_carry[30:0]) :
                             (rs1_fwd[31:1] != idex_pred_jalr_base[30:0]));
      end else begin
        // A stale taken prediction must also be repaired if the fetched
        // word is no longer a control transfer (e.g. after an alias).
        branch_mispredict = idex_pred_taken && !lu_stall && !vec_mem_hold;
      end

      ex_redirect = ex_trap || is_satp_write || idex_mret || idex_sret || branch_mispredict;
    end
  end

  // Ordinary control transfers retain their EX resolution. Trap payload
  // and entry are delayed one cycle, keeping forwarded load data off CSR
  // state updates and the trap-vector selection/redirect payload mux.
  assign cancel_ex = redirect_from_mem || trap_pending;
  assign ex_redirect_int = ex_redirect && !ex_trap && !fence_hold && !halt && !cancel_ex;
  // Sample eligibility after older CSR writes and deferred divider writes.
  // Taking the interrupt after EX must not leave an architectural effect
  // from before the saved EPC outstanding in the handler.
  assign irq_take = irq_req && !csr_issue && !csr_commit_q && !div_busy &&
                    !(idex_valid && idex_is_div) && !ex_redirect && !vec_arith_prepare &&
                    !(idex_valid && (idex_is_load || idex_is_store || idex_is_amo ||
                                     idex_is_lr || idex_is_sc || is_vec_mem)) &&
                    !fence_hold && !halt && !rst && !cancel_ex;
  assign trap_capture = (irq_take || ex_trap) && !fence_hold && !halt && !rst && !cancel_ex;
`ifdef ROCO_SOC_RETIRE_MEMORY_FORMAL
  assign formal_sync_capture = trap_capture && ex_trap;
  assign formal_sync_pending = trap_pending && !trap_is_irq_q;
`endif
  always_ff @(posedge clk or posedge rst) begin
    if (rst) trap_pending <= 1'b0;
    else if (!(trap_pending && csr_commit_q)) trap_pending <= trap_capture;
  end

  // Payload class is known independently of exception validity. Capture
  // synchronous and interrupt candidates before the late branch/target
  // decision; one registered event-kind bit selects them during entry.
  always_comb begin
    sync_cause_candidate = (idex_is_store || idex_is_amo || idex_is_sc || idex_is_vstore) ?
                           `RV32_CAUSE_STORE_MISALIGNED : `RV32_CAUSE_LOAD_MISALIGNED;
    sync_tval_candidate = mem_access_addr;
    sync_target_candidate = 1'b0;
    if (idex_is_branch && (|idex_pc[1:0])) begin
      sync_cause_candidate = `RV32_CAUSE_INSTR_MISALIGNED;
      sync_tval_candidate = idex_pc;
    end else if (idex_ifault) begin
      sync_cause_candidate = `RV32_CAUSE_INSTR_PAGE_FAULT;
      sync_tval_candidate = idex_pc;
    end else if (idex_illegal || ex_csr_illegal || ex_priv_illegal || vec_start_illegal) begin
      sync_cause_candidate = `RV32_CAUSE_ILLEGAL;
      sync_tval_candidate = idex_instr;
    end else if (idex_ebreak || idex_ecall) begin
      sync_cause_candidate = idex_ebreak ? `RV32_CAUSE_BREAKPOINT : ex_ecall_cause;
      sync_tval_candidate = 32'd0;
    end else if (idex_is_branch || idex_is_jal || idex_is_jalr) begin
      sync_cause_candidate = `RV32_CAUSE_INSTR_MISALIGNED;
      sync_tval_candidate = 32'd0;
      sync_target_candidate = 1'b1;
    end else if (dmem_lu_fault) begin
      sync_cause_candidate = {28'd0, dmem_lu_fault_cause};
    end
  end
  always_ff @(posedge clk) begin
    if (!trap_pending) begin
      trap_is_irq_q <= irq_take;
      csr_sync_pc_q <= idex_pc;
      csr_irq_pc_q <= irq_next_pc;
      csr_sync_cause_q <= sync_cause_candidate;
      csr_irq_code_q <= irq_code;
      csr_trap_tval <= sync_tval_candidate;
      trap_target_q <= sync_target_candidate;
      trap_target_base_q <= idex_is_jalr ? rs1_fwd : idex_pc;
      trap_target_offset_q <= idex_imm;
      trap_target_mask_q <= idex_is_jalr;
    end
  end
  // Trap entry already follows capture by one cycle. Finish a faulting
  // branch/jump address here instead of adding before the payload flops.
  roco_cpu_addsub u_trap_target_add (
      .a(trap_target_base_q),
      .b(trap_target_offset_q),
      .subtract(1'b0),
      .result(trap_target_sum)
  );
  assign csr_entry_tval = trap_is_irq_q ? 32'd0 : trap_target_q ?
                          {trap_target_sum[31:1], trap_target_sum[0] && !trap_target_mask_q} :
                          csr_trap_tval;
  assign csr_trap_pc = trap_is_irq_q ? csr_irq_pc_q : csr_sync_pc_q;
  assign csr_trap_cause = trap_is_irq_q ? {1'b1, 26'd0, csr_irq_code_q} : csr_sync_cause_q;

  // A trap captured with a CSR write must enter after that write applies,
  // so saved status and trap-vector selection see the architectural state.
  assign trap_commit = trap_pending && !csr_commit_q;
  assign ex_redirect_en = (ex_redirect_int || trap_commit) && !halt;
  // Select the payload by instruction class, independently of prediction
  // correctness and current trap validity. Pending traps have priority.
  // Register the operands, then add during the existing redirect cycle.
  // Taken/fall-through selection is one bit of metadata, not a late wide
  // mux behind branch comparison in front of the payload register.
  assign ex_redirect_base = trap_pending ? csr_trap_vector :
                            idex_mret ? csr_mepc : idex_sret ? csr_sepc :
                            idex_is_jalr ? rs1_fwd : idex_pc;
  assign ex_redirect_offset = (trap_pending || idex_mret || idex_sret || is_satp_write) ?
                              32'd0 : idex_imm;
  assign ex_redirect_fallthrough = !trap_pending && !idex_mret && !idex_sret &&
                                  !(idex_is_jal || idex_is_jalr || (idex_is_branch && ex_branch_taken));
  assign ex_redirect_mask_lsb = !trap_pending && idex_is_jalr;
  assign ex_trap_taken = trap_commit;
  assign vec_fault = idex_ifault || idex_illegal || vec_start_illegal || dmem_lu_fault ||
                     (is_vec_mem && ex_mem_misaligned);
  assign vec_arith_work = idex_is_vec && !idex_is_vset && !is_vec_mem;
  assign vec_arith_prepare = idex_valid && vec_arith_work && !vec_operand_ready;
  assign vec_mem_hold = (vmem_hold || scalar_mem_prepare || vec_arith_prepare) &&
                        !vec_fault && !cancel_ex;
  // The decoder makes memory operations mutually exclusive with branches,
  // CSR accesses and system instructions. Only illegal decode and memory
  // alignment can trap a load/store; keep unrelated trap paths off lookup.
  assign ex_lu_present = idex_valid &&
                       ((scalar_is_mem && scalar_mem_ready) ||
                        (is_vec_mem && vmem_active && !vmem_done)) &&
                       !idex_illegal && !idex_ifault && !ex_mem_misaligned &&
                       !halt && !cancel_ex;
  assign ex_lu_valid = ex_lu_present && !fence_hold;
  assign ex_lu_vaddr = mem_access_addr;
  assign btb_update = idex_valid && !ex_trap && !fence_hold && !halt && !cancel_ex &&
                      (idex_is_branch || idex_is_jal || idex_is_jalr);
  assign btb_is_branch = idex_is_branch;
  assign btb_is_jal = idex_is_jal;
  assign btb_is_jalr = idex_is_jalr;
  assign btb_taken = (idex_is_branch && ex_branch_taken) || idex_is_jal || idex_is_jalr;
  assign btb_target = idex_is_jalr ? ex_jump_target : ex_branch_target;

  // Resolve forwarding and address generation before entering the MMU
  // and cache lookup network. Keep the captured operands across retries.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      scalar_mem_ready <= 1'b0;
      stall_alu <= '0;
      stall_store_data <= '0;
      stall_be <= '0;
    end else if (cancel_ex) begin
      scalar_mem_ready <= 1'b0;
    end else if (!halt && !fence_hold) begin
      if (!idex_valid || !scalar_is_mem) begin
        scalar_mem_ready <= 1'b0;
      end else if (!scalar_mem_ready) begin
        scalar_mem_ready <= 1'b1;
        stall_alu <= memory_addr;
        stall_store_data <= ex_store_data;
        stall_be <= ex_store_be;
      end else if (!lu_stall) begin
        scalar_mem_ready <= 1'b0;
      end
    end
  end

  // Only LMUL=1 is supported: VLMAX is VLEN/SEW elements, which for the
  // 128-bit register file is 16 lanes at e8, 8 at e16 and 4 at e32.

  assign vec_sew_cur = vec_vtype_sew;
  assign vec_vta_cur = vec_vtype_vta;
  assign is_vec_mem = idex_is_vload || idex_is_vstore;
  // Reductions are not restartable; all other implemented vector forms
  // either honor vstart or have the ISA's scalar-element move semantics.
  assign vec_start_illegal = idex_is_vec && !idex_is_vset && !is_vec_mem &&
                             (idex_instr[14:12] == 3'b010) &&
                             (idex_vec_funct6 != `RV32_VOP_SCALAR) && (vec_vstart != 32'd0);
  assign vec_vstart_we = !vec_arith_prepare && idex_valid && (idex_is_vec || is_vec_mem) && !halt && !fence_hold &&
                         !cancel_ex && ((trap_capture && is_vec_mem) ||
                         (!ex_trap && (!is_vec_mem || vmem_done)));
  assign vec_vstart_data = (trap_capture && is_vec_mem) ? vmem_idx : 5'd0;

  // vsetvli / vsetivli / vsetvl. An unsupported SEW or LMUL raises vill
  // and yields vl = 0.
  assign vset_reg_form = (idex_instr[31:25] == 7'b1000000);
  // Only vtype[7:0] carries configuration: the reserved upper bits must
  // be zero, and are reported through vill otherwise.
  assign vset_vt = vset_reg_form ? rs2_fwd[7:0] : idex_instr[27:20];
  assign vset_rsvd = vset_reg_form ? (|rs2_fwd[30:8]) :
                     idex_instr[31] ? (|idex_instr[29:28]) : (|idex_instr[30:28]);
  assign vset_vill = vset_rsvd || (vset_reg_form && rs2_fwd[31]) ||
                     (vset_vt[5:3] > 3'd2) || (vset_vt[2:0] != 3'd0);
  assign vset_new_vtype = vset_vill ? 32'h8000_0000 : {24'd0, vset_vt[7:3], 3'd0};
  assign vset_vlmax = 5'd16 >> vset_vt[5:3];
  assign vset_avl = idex_instr[31] && !vset_reg_form ? {27'd0, idex_instr[19:15]} :
                    (idex_instr[19:15] == 5'd0) ? {27'd0, vset_vlmax} : rs1_fwd;
  assign vset_new_vl = vset_vill ? 32'd0 :
                       (vset_avl > {27'd0, vset_vlmax}) ? {27'd0, vset_vlmax} : vset_avl;

  assign vec_scalar_b = (idex_instr[14:12] == 3'b011) ?
                        {{27{idex_instr[19]}}, idex_instr[19:15]} : rs1_fwd;
  // Select scalar vector results by instruction class, without the
  // fault/hold write-enable cone. EX/MEM validity qualifies their commit.
  assign vec_scalar_wb = idex_is_vset ||
                        (idex_is_vec && !is_vec_mem &&
                         (idex_vec_funct6 == `RV32_VOP_SCALAR) && (idex_instr[14:12] == 3'b010));
  assign vec_scalar_wdata = idex_is_vset ? vset_new_vl :
                            (vec_sew_q == 3'd0) ?
                            {{24{vec_vs2_q[7]}}, vec_vs2_q[7:0]} :
                            (vec_sew_q == 3'd1) ?
                            {{16{vec_vs2_q[15]}}, vec_vs2_q[15:0]} : vec_vs2_q[31:0];

  // The payload register advances every cycle. Cancellation/reset/hold
  // qualify only its write-valid bit, not the wide result selection mux.
  assign vec_exec_eligible = idex_valid && idex_is_vec && !idex_ifault &&
                             !idex_illegal && !dmem_lu_fault && !fence_hold &&
                             !halt && !cancel_ex;
  assign vec_vset_en = vec_exec_eligible && idex_is_vset;

  assign vec_vset_vl = vset_new_vl[4:0];
  assign vec_vset_vtype = vset_new_vtype;
  assign vec_ex_we = vec_exec_eligible && !idex_is_vset && !is_vec_mem &&
                     !vec_start_illegal && (vec_vstart[4:0] < vec_vl) &&
                     !((idex_vec_funct6 == `RV32_VOP_SCALAR) && (idex_instr[14:12] == 3'b010));

  // ----------------------------------------- Vector memory sequencing
  // One element per cycle. The execute stage keeps the instruction while
  // the pipeline is held, and the memory stage commits one element per
  // cycle behind it. The last cycle issues nothing so that the next
  // instruction cannot reach EX while MEM is still writing the final
  // element.
  assign vmem_idx = vmem_active ? vmem_k : vec_vstart[4:0];
  assign vmem_total = vec_vl;
  assign vmem_noop = !vmem_active && (vec_vstart[4:0] >= vmem_total);
  assign vmem_done = vmem_noop || (vmem_active && (vmem_k >= vmem_total));
  assign vmem_issue = is_vec_mem && idex_valid && vmem_active && !vmem_done && !vec_fault && !halt &&
                      !fence_hold;
  assign vmem_hold = is_vec_mem && idex_valid && !vmem_done;

  // Element size in bytes: e8, e16 or e32.
  assign vmem_shift = (idex_instr[14:12] == 3'b000) ? 2'd0 :
                      (idex_instr[14:12] == 3'b101) ? 2'd1 : 2'd2;
  assign vmem_stride = 32'd1 << vmem_shift;
  // Keep the current element address in a register. Increment it only
  // after a successful lookup, keeping carry propagation off the cache
  // lookup path and preserving the address across misses.
  // Vector unit-stride addresses have no scalar immediate. Add the
  // restart offset in parallel for the two possible EX operand sources.
  assign vmem_start_addr =
      ({32{idex_rs1_from_mem}} & (mem_data + ({27'd0, vec_vstart[4:0]} << vmem_shift))) |
      ({32{idex_rs1_from_rf}} & (idex_rs1_val + ({27'd0, vec_vstart[4:0]} << vmem_shift)));
  // Prepare the initial address in a separate cycle. Only registered
  // addresses drive the MMU/cache's widely distributed lookup network.
  assign vmem_addr = vmem_base;

  always_comb begin
    case (idex_instr[14:12])
      3'b000: begin
        vmem_be = 4'b0001 << vmem_addr[1:0];
      end
      3'b101: begin
        vmem_be = 4'b0011 << vmem_addr[1:0];
      end
      default: begin
        vmem_be = 4'b1111;
      end
    endcase
  end

  always_comb begin
    case (idex_instr[14:12])
      3'b000: begin
        vec_store_elem = {24'd0, vec_vd_q[8*vmem_idx+:8]};
      end
      3'b101: begin
        vec_store_elem = {16'd0, vec_vd_q[16*vmem_idx[2:0]+:16]};
      end
      default: begin
        vec_store_elem = vec_vd_q[32*vmem_idx[1:0]+:32];
      end
    endcase
  end

  assign vmem_store_data = vec_store_elem << {vmem_addr[1:0], 3'b000};
  assign vec_elem_sew = (idex_instr[14:12] == 3'b000) ? 3'd0 :
                        (idex_instr[14:12] == 3'b101) ? 3'd1 : 3'd2;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      vmem_active <= 1'b0;
      vmem_k <= '0;
      vmem_base <= '0;
    end else if (cancel_ex) begin
      vmem_active <= 1'b0;
      vmem_k <= '0;
    end else if (!halt && !fence_hold) begin
      if (!is_vec_mem || !idex_valid || vmem_done) begin
        vmem_active <= 1'b0;
        vmem_k <= '0;
        vmem_base <= memory_addr;
      end else if (!vmem_active) begin
        vmem_active <= 1'b1;
        // Capture the forwarded base and restart offset before any lookup.
        vmem_k <= vec_vstart[4:0];
        vmem_base <= vmem_start_addr;
      end else if (!lu_stall) begin
        vmem_k <= vmem_idx + 5'd1;
        vmem_base <= vmem_base + vmem_stride;
      end
    end
  end

  // Resolve lane masks while preparing operands, before reduction carry
  // compression and result selection. Masks are byte-granular so tail
  // handling does not add an SEW mux after the vector arithmetic.
  assign vec_write_vl = ((idex_instr[31:26] == `RV32_VOP_SCALAR) && (idex_instr[14:12] == 3'b110)) ||
                        ((idex_instr[31:26] != `RV32_VOP_SCALAR) && (idex_instr[14:12] == 3'b010)) ?
                        5'd1 : vec_vl;
  always_comb begin
    for (int byte_index = 0; byte_index < 16; byte_index++) begin
      int element;
      element = byte_index >> ((vec_sew_cur == 0) ? 0 : (vec_sew_cur == 1) ? 1 : 2);
      vec_active_bytes[byte_index] = (element < int'(vec_write_vl)) &&
          ((element >= int'(vec_vstart[4:0])) ||
           ((element == 0) && (idex_instr[31:26] == `RV32_VOP_SCALAR) &&
            (idex_instr[14:12] == 3'b110)));
      vec_fill_bytes[byte_index] = vec_vta_cur && (element >= int'(vec_vstart[4:0]));
      vec_reduce_input[8*byte_index+:8] = (element < int'(vec_vl)) ?
                                         vec_vs2_data[8*byte_index+:8] : 8'd0;
    end
  end

  // Register vector operands before arithmetic, then register the final
  // result before the MEM write port. The preparation cycle separates
  // register-file/forwarding routes from the wide arithmetic datapath.
  always_ff @(posedge clk) begin
    if (!vec_operand_ready) begin
      vec_vs1_q <= vec_vs1_data;
      vec_vs2_q <= vec_vs2_data;
      vec_vd_q <= vec_vd_data;
      vec_scalar_q <= vec_scalar_b;
      vec_active_q <= vec_active_bytes;
      vec_fill_q <= vec_fill_bytes;
      vec_reduce_q <= vec_reduce_input;
      vec_sew_q <= vec_sew_cur;
    end
    exmem_vec_data <= vec_pipeline_result;
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) vec_operand_ready <= 1'b0;
    else if (cancel_ex) vec_operand_ready <= 1'b0;
    else if (!halt && !fence_hold) begin
      if (!idex_valid || !vec_arith_work) vec_operand_ready <= 1'b0;
      else vec_operand_ready <= !vec_operand_ready;
    end
  end

  roco_cpu_vec_execute u_vec_execute (
      .vs1(vec_vs1_q),
      .vs2(vec_vs2_q),
      .old_vd(vec_vd_q),
      .scalar(vec_scalar_q),
      .op(idex_instr[31:26]),
      .form(idex_instr[14:12]),
      .active_bytes(vec_active_q),
      .fill_bytes(vec_fill_q),
      .reduction_source(vec_reduce_q),
      .sew(vec_sew_q),
      .result(vec_pipeline_result)
  );

  // Only non-memory packets consume this word. Memory/fence holds retain
  // the address and transaction metadata, but need not hold an unused
  // scalar result. Keep their late wait signal off scalar feedback.
  always_ff @(posedge clk) begin
    if (!halt) exmem_wbval <= ex_wbval;
  end

  // ------------------------------------------------------ EX/MEM register
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      exmem_valid <= 1'b0;
      exmem_vec_we <= 1'b0;
      exmem_vec_last <= 1'b0;
      exmem_pc <= '0;
      exmem_instr <= 32'h0000_0013;
      exmem_alu <= '0;
      exmem_store_data <= '0;
      exmem_be <= '0;
      exmem_rd <= '0;
      exmem_funct3 <= '0;
      exmem_regwrite <= 1'b0;
      exmem_is_load <= 1'b0;
      exmem_forward_cache <= 1'b0;
      exmem_forward_wbval <= 1'b1;
      exmem_is_store <= 1'b0;
      exmem_is_amo <= 1'b0;
      exmem_is_lr <= 1'b0;
      exmem_is_sc <= 1'b0;
      exmem_amo_op <= '0;
      exmem_is_vload <= 1'b0;
      exmem_is_vstore <= 1'b0;
      exmem_vec_elem <= '0;
      exmem_vec_sew <= '0;
      exmem_is_sfence <= 1'b0;
      exmem_is_fence_i <= 1'b0;
      exmem_is_mul <= 1'b0;
      exmem_mul_hi <= 1'b0;
      exmem_mul_sum <= '0;
      exmem_mul_carry <= '0;
    end else if (halt || fence_hold) begin
      // Hold while a FENCE.I wait is active.
    end else if (is_vec_mem && idex_valid) begin
      exmem_vec_we <= 1'b0;
      // One element per cycle; the last cycle issues nothing.
      // VL zero still retires one no-op instruction without a memory
      // request. Nonzero vectors retire only with their final element.
      exmem_valid <= ((vmem_issue && !lu_stall) || vmem_noop) && !ex_trap && !cancel_ex;
      exmem_vec_last <= vmem_noop || (vmem_idx + 5'd1 == vmem_total);
      exmem_pc <= idex_pc;
      exmem_instr <= idex_instr;
      exmem_alu <= dmem_lu_paddr;
      exmem_store_data <= ex_st;
      exmem_be <= ex_be;
      exmem_rd <= idex_instr[11:7];
      exmem_funct3 <= idex_funct3;
      exmem_regwrite <= 1'b0;
      exmem_is_load <= 1'b0;
      exmem_forward_cache <= 1'b0;
      exmem_forward_wbval <= 1'b1;
      exmem_is_store <= 1'b0;
      exmem_is_amo <= 1'b0;
      exmem_is_lr <= 1'b0;
      exmem_is_sc <= 1'b0;
      exmem_amo_op <= '0;
      exmem_is_vload <= vmem_issue && idex_is_vload;
      exmem_is_vstore <= vmem_issue && idex_is_vstore;
      exmem_vec_elem <= vmem_idx[3:0];
      exmem_vec_sew <= vec_elem_sew;
      exmem_is_sfence <= 1'b0;
      exmem_is_fence_i <= 1'b0;
      exmem_is_mul <= 1'b0;
      exmem_mul_hi <= 1'b0;
      exmem_mul_sum <= '0;
      exmem_mul_carry <= '0;
    end else begin
      // Invalid payload may advance during a lookup miss or the first
      // reduction cycle. Miss operands are already saved separately;
      // only validity needs the late cache-hit signal.
      exmem_valid <= idex_valid && !ex_trap && !lu_stall && !scalar_mem_prepare && !vec_arith_prepare && !cancel_ex;
      exmem_vec_we <= vec_ex_we;
      exmem_pc <= idex_pc;
      exmem_instr <= idex_instr;
      // This packet field is only consumed by memory instructions.
      // Scalar ALU results already have their dedicated writeback word.
      exmem_alu <= dmem_lu_paddr;
      exmem_store_data <= ex_st;
      exmem_be <= ex_be;
      exmem_rd <= idex_rd;
      exmem_funct3 <= idex_funct3;
      // A divide retires without writing: the divider port supplies
      // the value when it completes.
      exmem_regwrite <= idex_regwrite && !idex_is_div && (!idex_is_vec || vec_scalar_wb);
      exmem_is_load <= idex_is_load;
      exmem_forward_cache <= idex_is_load || idex_is_lr || idex_is_amo;
      // A multiply completes in MEM, so it never forwards from the EX/MEM
      // register. mul_conflict adds one bubble to a dependent instruction.
      exmem_forward_wbval <= !(idex_is_load || idex_is_lr || idex_is_amo || idex_is_sc ||
                               idex_is_mul);
      exmem_is_mul <= idex_is_mul && idex_valid;
      exmem_mul_hi <= (idex_md_op != `RV32_MD_MUL);
      exmem_mul_sum <= mul_sum1;
      exmem_mul_carry <= mul_carry1;
      exmem_is_store <= idex_is_store;
      exmem_is_amo <= idex_is_amo;
      exmem_is_lr <= idex_is_lr;
      exmem_is_sc <= idex_is_sc;
      exmem_amo_op <= idex_amo_op;
      exmem_is_vload <= 1'b0;
      exmem_is_vstore <= 1'b0;
      exmem_vec_elem <= '0;
      exmem_vec_last <= 1'b0;
      exmem_vec_sew <= '0;
      exmem_is_sfence <= idex_is_sfence;
      exmem_is_fence_i <= idex_is_fence_i;
    end
  end

`ifdef ROCO_RVFI
  roco_rvfi_meta_t rvfi_ex;
  logic [31:0] rvfi_held_rs1, rvfi_held_rs2;
  logic rvfi_operands_held;
  // After preparation, these instructions use registered operands or
  // an address derived from them. The original MEM producer can be gone.
  assign rvfi_operands_held = (scalar_is_mem && scalar_mem_ready) ||
                              (is_vec_mem && vmem_active) || (vec_arith_work && vec_operand_ready);

  always_comb begin
    rvfi_ex.instr = idex_ifault ? 32'd0 : idex_instr;
    rvfi_ex.pc = idex_pc;
    rvfi_ex.next_pc = idex_mret ? csr_mepc : idex_sret ? csr_sepc :
                      idex_is_jalr ? ex_jump_target :
                      (idex_is_jal || (idex_is_branch && ex_branch_taken)) ?
                      ex_branch_target : idex_pc + 32'd4;
    rvfi_ex.vaddr = mem_access_addr;
    rvfi_ex.rs1 = rvfi_idex_rs1;
    rvfi_ex.rs2 = rvfi_idex_rs2;
    rvfi_ex.rs1_data = rvfi_idex_rs1 == 0 ? 32'd0 : rvfi_operands_held ? rvfi_held_rs1 : rs1_fwd;
    rvfi_ex.rs2_data = rvfi_idex_rs2 == 0 ? 32'd0 : rvfi_operands_held ? rvfi_held_rs2 : rs2_fwd;
    rvfi_ex.mode = csr_priv;
  end

  always_ff @(posedge clk) begin
    if (!halt && !fence_hold) begin
      rvfi_exmem <= rvfi_ex;
      if (idex_valid && !rvfi_operands_held) begin
        rvfi_held_rs1 <= rs1_fwd;
        rvfi_held_rs2 <= rs2_fwd;
      end
    end
    if (trap_capture && ex_trap) rvfi_exception <= rvfi_ex;
  end

`ifdef ROCO_SOC_ISA_MEMORY_FORMAL
  always_ff @(posedge clk) begin
    if (!rst && idex_valid && scalar_is_mem && scalar_mem_ready && !cancel_ex) begin
      assert (!exmem_valid);
      assert (!lookup_is_vec_q);
      assert (memory_addr_held == rvfi_held_rs1 + idex_imm);
      // RVFI reports zero for x0 independently of the setup-time copies.
      if (rvfi_idex_rs1 == 0) assert (rvfi_held_rs1 == 0);
      if (idex_is_store) begin
        if (rvfi_idex_rs2 == 0) assert (rvfi_held_rs2 == 0);
        assert (stall_store_data == (rvfi_held_rs2 << {memory_addr_held[1:0], 3'b000}));
        case (idex_funct3)
          3'b000: assert (stall_be == (4'b0001 << memory_addr_held[1:0]));
          3'b001: assert (stall_be == (4'b0011 << memory_addr_held[1:0]));
          default: assert (stall_be == 4'b1111);
        endcase
      end
    end
  end
`endif

`ifdef ROCO_RVFI_FORWARD_CHECKS
  // Observation points for the whole-core operand invariants: the saved
  // operands and the phase flag that selects them over the live bypass.
  assign rvfi_fwd_mem_ready = rvfi_operands_held;
  assign rvfi_fwd_cancel = cancel_ex;
`ifdef ROCO_RVFI_INSN_CHECKS
  assign rvfi_fwd_trap_pending = trap_pending;
`endif
  assign rvfi_fwd_held_rs1 = rvfi_held_rs1;
  assign rvfi_fwd_held_rs2 = rvfi_held_rs2;
`endif

`ifdef ROCO_VECTOR_MEM_STREAM
  `include "vector_mem_ex_checks.svh"
`endif
`ifdef ROCO_M_STREAM_CHECKS
  `include "m_ex_checks.svh"
`endif
`ifdef ROCO_IRQ_PIPELINE_CHECKS
  `include "irq_ex_checks.svh"
`endif
  assign rvfi_trap_entry = trap_commit && !halt;
  assign rvfi_sync_exception = rvfi_trap_entry && !trap_is_irq_q;
  assign rvfi_trap_vector = csr_trap_vector;
`ifdef ROCO_SOC_TRAP_FORMAL
  `include "soc_trap_ex_checks.svh"
`endif
`ifdef ROCO_RVFI_PC_CHECKS
  always @(posedge clk) begin
    if (!rst) begin
      // This fetch set has no CSR writes. The M-mode trap vector stays at
      // reset, including while a synchronous exception is pending.
      assert (!csr_wr_en && unused_csr_mtvec == 0);
      if (trap_pending) assert (!trap_is_irq_q);
      if (idex_valid && btb_update) assert (idex_pc[1:0] == 0);
    end
  end
`endif
`ifdef ROCO_RVFI_NO_DIV_CHECKS
  // The fetch set contains no CSR access to the translation base or mode
  // registers, no interrupt or delegation state, and no instruction that
  // returns from a trap. A committed write can therefore never target satp,
  // mstatus, or the interrupt/delegation registers, which keeps the core in
  // M mode with data translation disabled for the whole run.
  always @(posedge clk) begin
`ifdef ROCO_RVFI_FORWARD_CHECKS
    // Needs the forward job's privilege and translation context: with priv
    // pinned to M mode and the interrupt registers never written, a free
    // mie/mip state stays quiescent.
    if (!rst && csr_priv == `RV32_PRIV_M) assert (!irq_req);
`endif
    if (!rst)
      assert (!(csr_wr_en && (csr_commit_addr_q == 12'h180 || csr_commit_addr_q == 12'h300 ||
                               csr_commit_addr_q == 12'h302 || csr_commit_addr_q == 12'h303 ||
                               csr_commit_addr_q == 12'h304 || csr_commit_addr_q == 12'h344)));
  end
`endif

`ifdef ROCO_RVFI_RV32I_CHECKS
  // The scalar faulting instruction must never produce a MEM packet. If
  // trap entry waits for a CSR commit, cancellation must keep MEM empty.
  always @(posedge clk) begin
    if (!rst && trap_pending && !trap_is_irq_q) assert (!exmem_valid);
  end
`endif
`endif

`ifndef SYNTHESIS
  logic [31:0] expected_trap_cause_q, expected_trap_tval_q;
  always @(posedge clk) begin
    if (!rst && trap_capture && ex_trap) begin
      expected_trap_cause_q <= ex_trap_cause;
      expected_trap_tval_q <= ex_trap_tval;
    end
  end
  always @(negedge clk) begin
    if (!rst && trap_pending && !trap_is_irq_q)
      assert (csr_trap_cause === expected_trap_cause_q && csr_entry_tval === expected_trap_tval_q)
      else $fatal(1, "retimed trap payload differs from synchronous exception");
  end
`endif

endmodule
