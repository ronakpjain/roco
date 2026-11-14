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
`include "rv32_defs.svh"

module rv32_ex_stage (
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
  input logic [31:0] idex_pc,
  input logic [31:0] idex_instr,
  input logic [31:0] idex_rs1_val,
  input logic [31:0] idex_rs2_val,
  input logic idex_rs1_from_mem,
  input logic idex_rs2_from_mem,
  input logic idex_rs1_from_wb,
  input logic idex_rs2_from_wb,
  input logic idex_rs1_from_rf,
  input logic idex_rs2_from_rf,
  input logic [31:0] idex_imm,
  input logic [4:0] idex_rs1,
  input logic [4:0] idex_rd,
  input logic [2:0] idex_funct3,
  input logic [3:0] idex_alu_op,
  input logic idex_is_muldiv,
  input logic [2:0] idex_md_op,
  input logic idex_alu_b_imm,
  input logic idex_alu_a_pc,
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
  input logic [31:0] idex_pred_jalr_next,
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
  output logic [31:0] ex_redirect_pc,
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
  output logic exmem_is_fence_i
);

  logic vec_ex_we;
  logic [127:0] vec_ex_wdata;
  logic [31:0] rs1_fwd;
  logic [31:0] rs2_fwd;
  logic [31:0] ex_alu_a;
  logic [31:0] ex_alu_b;
  logic [31:0] alu_result;
  logic [31:0] mul_p0;
  logic [33:0] mul_p1;
  logic [33:0] mul_p2;
  logic [33:0] mul_p3;
  logic [31:0] mul_data;
  logic [31:0] md_div_result;
  logic [31:0] ex_alu_result;
  logic idex_is_div;
  logic idex_is_mul;
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
  logic trap_pending;
  logic cancel_ex;
  logic trap_capture;
  logic [31:0] csr_trap_pc;
  logic [31:0] csr_trap_cause;
  logic [31:0] csr_trap_tval;
  logic branch_mispredict;
  logic stall_active;
  logic [31:0] stall_alu;
  logic [31:0] stall_store_data;
  logic [3:0] stall_be;
  logic [31:0] ex_addr;
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
  logic [31:0] csr_wdata;
  logic csr_wr_en;
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
  logic [31:0] unused_vstart;
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
  logic [127:0] vec_alu_b;
  logic [127:0] vec_bcast;
  logic [127:0] vec_raw;
  logic [127:0] vec_reduce_sum;
  logic vec_ex_we_int;
  logic [127:0] vec_ex_wdata_int;
  logic vec_scalar_wb;
  logic [31:0] vec_scalar_wdata;
  logic [4:0] vec_wr_vl;
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
  logic [2:0] vec_elem_sew;

  // ------------------------------------------------------------- Forwarding
  assign rs1_fwd = ({32{idex_rs1_from_mem}} & mem_data) |
                   ({32{idex_rs1_from_wb}} & wb_data) |
                   ({32{idex_rs1_from_rf}} & idex_rs1_val);
  assign rs2_fwd = ({32{idex_rs2_from_mem}} & mem_data) |
                   ({32{idex_rs2_from_wb}} & wb_data) |
                   ({32{idex_rs2_from_rf}} & idex_rs2_val);

  // ------------------------------------------------------------------- ALU
  assign ex_alu_a = idex_alu_a_pc ? idex_pc : rs1_fwd;
  assign ex_alu_b = idex_alu_b_imm ? idex_imm : rs2_fwd;

  rv32_alu u_alu (
      .a(ex_alu_a),
      .b(ex_alu_b),
      .op(idex_alu_op),
      .result(alu_result)
  );

  assign idex_is_div = idex_is_muldiv && idex_md_op[2];
  assign idex_is_mul = idex_is_muldiv && !idex_md_op[2];
  assign div_start = idex_valid && idex_is_div && !div_busy && !fence_hold && !halt && !rst &&
                     !cancel_ex;

  rv32_divider u_divider (
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
  rv32_mul_prod u_mul_prod (
      .a(rs1_fwd),
      .b(rs2_fwd),
      .variant(idex_md_op),
      .p0(mul_p0),
      .p1(mul_p1),
      .p2(mul_p2),
      .p3(mul_p3)
  );

  rv32_mul_finish u_mul_finish (
      .p0(mul_p0),
      .p1(mul_p1),
      .p2(mul_p2),
      .p3(mul_p3),
      .variant(idex_md_op),
      .result(mul_data)
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
  assign div_wb_en = (div_wb_en_raw || div_write_pending) && (div_rd_q != 5'd0) &&
                     !wb_we && !halt && !rst;
  always_ff @(posedge clk) begin
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

  always_ff @(posedge clk) begin
    if (rst) begin
      div_rd_q <= '0;
    end else if (div_start) begin
      div_rd_q <= idex_rd;
    end
  end

  assign ex_branch_target = idex_pc + idex_imm;
  // JALR clears bit zero of its scalar addition result.
  assign ex_jump_target = {ex_alu_result[31:1], 1'b0};

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
  assign memory_addr_held = stall_active ? stall_alu : memory_addr;
  assign mem_access_addr = is_vec_mem ? vmem_addr : memory_addr_held;
  assign ex_addr =
      (idex_is_load || idex_is_store || idex_is_amo || idex_is_lr || idex_is_sc) ?
      dmem_lu_paddr : is_vec_mem ? dmem_lu_paddr : ex_alu_result;
  assign ex_st = is_vec_mem ? vmem_store_data : stall_active ? stall_store_data : ex_store_data;
  assign ex_be = is_vec_mem ? vmem_be : stall_active ? stall_be : ex_store_be;
  assign ex_wbval = (idex_is_jal || idex_is_jalr) ? (idex_pc + 32'd4) :
                    idex_is_csr ? csr_rdata : vec_scalar_wb ? vec_scalar_wdata :
                    idex_is_mul ? mul_data : ex_addr;

  // -------------------------------------------------- CSR file (EX and WB)
  rv32_csr u_csr (
      .clk(clk),
      .rst(rst),
      .raddr(idex_csr_addr),
      .rdata(csr_rdata),
      .exists(csr_exists),
      .read_ok(csr_read_ok),
      .write_ok(csr_write_ok),
      .wr_en(csr_wr_en),
      .wr_addr(idex_csr_addr),
      .wr_data(csr_wdata),
      .trap_en(trap_pending && !halt && !rst),
      .trap_pc(csr_trap_pc),
      .trap_cause(csr_trap_cause),
      .trap_tval(csr_trap_tval),
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
      .vstart_out(unused_vstart),
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
  assign csr_mret_en = ex_redirect_int && idex_mret && !ex_trap;
  assign csr_sret_en = ex_redirect_int && idex_sret && !ex_trap;

  assign csr_src = idex_csr_uimm ? {27'd0, idex_rs1} : rs1_fwd;
  // Zicsr suppresses CSRRS/CSRRC writes for encoded x0 (or uimm=0),
  // not for a non-x0 register whose value happens to be zero.
  assign csr_write_intent = idex_is_csr && ((idex_csr_op == `RV32_CSR_RW) || (idex_rs1 != 5'd0));
  assign ex_csr_illegal = idex_is_csr &&
                          (!csr_exists || !csr_read_ok ||
                           (csr_write_intent && !csr_write_ok));
  // CSR instructions cannot branch or access memory. Qualify their
  // own traps directly so branch comparison and alignment do not feed
  // satp writes and the TLB flush/write-enable path.
  assign csr_wr_en = idex_valid && idex_is_csr && csr_write_intent && csr_exists &&
                     csr_read_ok && csr_write_ok && !idex_illegal && !idex_ifault &&
                     !dmem_lu_fault && !fence_hold && !halt && !rst && !cancel_ex;

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
            ex_branch_taken = (rs1_fwd == rs2_fwd);
          end
          3'b001: begin
            ex_branch_taken = (rs1_fwd != rs2_fwd);
          end
          3'b100: begin
            ex_branch_taken = ($signed(rs1_fwd) < $signed(rs2_fwd));
          end
          3'b101: begin
            ex_branch_taken = ($signed(rs1_fwd) >= $signed(rs2_fwd));
          end
          3'b110: begin
            ex_branch_taken = (rs1_fwd < rs2_fwd);
          end
          3'b111: begin
            ex_branch_taken = (rs1_fwd >= rs2_fwd);
          end
          default: begin
            ex_branch_taken = 1'b0;
          end
        endcase
      end

      if (idex_is_load || idex_is_store || idex_is_amo || idex_is_lr || idex_is_sc ||
          is_vec_mem) begin
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

      if (idex_ifault) begin
        ex_trap = 1'b1;
        ex_trap_cause = `RV32_CAUSE_INSTR_PAGE_FAULT;
        ex_trap_tval = idex_pc;
      end else if (idex_illegal || ex_csr_illegal || ex_priv_illegal) begin
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
                            ((rs1_fwd != idex_pred_jalr_base) &&
                             (rs1_fwd != idex_pred_jalr_next));
      end

      ex_redirect = ex_trap || idex_mret || idex_sret || branch_mispredict;
    end
  end

  // Ordinary control transfers retain their EX resolution. Trap payload
  // and entry are delayed one cycle, keeping forwarded load data off CSR
  // state updates and the trap-vector selection/redirect payload mux.
  assign cancel_ex = redirect_from_mem || trap_pending;
  assign ex_redirect_int = ex_redirect && !ex_trap && !fence_hold && !halt && !rst && !cancel_ex;
  assign irq_take = irq_req && !ex_redirect &&
                    !(idex_valid && (idex_is_load || idex_is_store || idex_is_amo ||
                                     idex_is_lr || idex_is_sc || is_vec_mem)) &&
                    !fence_hold && !halt && !rst && !cancel_ex;
  assign trap_capture = (irq_take || ex_trap) && !fence_hold && !halt && !rst && !cancel_ex;
  always_ff @(posedge clk) begin
    if (rst) trap_pending <= 1'b0;
    else trap_pending <= trap_capture;
    // Payload does not need the late trap-valid enable. Only pending
    // makes it visible, and younger EX side effects are canceled then.
    csr_trap_pc <= ex_trap ? idex_pc : irq_next_pc;
    csr_trap_cause <= ex_trap ? ex_trap_cause : {1'b1, 26'd0, irq_code};
    csr_trap_tval <= ex_trap ? ex_trap_tval : 32'd0;
  end
  assign ex_redirect_en = (ex_redirect_int || trap_pending) && !halt && !rst;
  // Select the payload by instruction class, independently of prediction
  // correctness and current trap validity. Pending traps have priority.
  assign ex_redirect_pc = trap_pending ? csr_trap_vector :
                          idex_mret ? csr_mepc : idex_sret ? csr_sepc :
                          idex_is_branch ? (ex_branch_taken ? ex_branch_target : (idex_pc + 32'd4)) :
                          idex_is_jal ? ex_branch_target : ex_jump_target;
  assign ex_trap_taken = trap_pending;
  assign vec_fault = idex_ifault || idex_illegal || dmem_lu_fault ||
                     (is_vec_mem && ex_mem_misaligned);
  assign vec_mem_hold = vmem_hold && !vec_fault && !cancel_ex;
  // The decoder makes memory operations mutually exclusive with branches,
  // CSR accesses and system instructions. Only illegal decode and memory
  // alignment can trap a load/store; keep unrelated trap paths off lookup.
  assign ex_lu_present = idex_valid &&
                       (idex_is_load || idex_is_store || idex_is_amo || idex_is_lr ||
                        idex_is_sc || (is_vec_mem && !vmem_done)) &&
                       !idex_illegal && !idex_ifault && !ex_mem_misaligned &&
                       !rst && !halt && !cancel_ex;
  assign ex_lu_valid = ex_lu_present && !fence_hold;
  assign ex_lu_vaddr = mem_access_addr;
  assign ex_lu_we = idex_is_store || idex_is_amo || idex_is_sc || idex_is_vstore;
  assign btb_update = idex_valid && !ex_trap && !fence_hold && !halt && !rst && !cancel_ex &&
                      (idex_is_branch || idex_is_jal || idex_is_jalr);
  assign btb_is_branch = idex_is_branch;
  assign btb_is_jal = idex_is_jal;
  assign btb_is_jalr = idex_is_jalr;
  assign btb_taken = (idex_is_branch && ex_branch_taken) || idex_is_jal || idex_is_jalr;
  assign btb_target = idex_is_jalr ? ex_jump_target : ex_branch_target;

  always_ff @(posedge clk) begin
    if (rst) begin
      stall_active <= 1'b0;
      stall_alu <= '0;
      stall_store_data <= '0;
      stall_be <= '0;
    end else begin
      stall_active <= lu_stall;
      // Capture the first lookup's operands before a miss can remove a
      // forwarding source. Only the valid bit depends on the cache hit.
      if (!stall_active) begin
        stall_alu <= memory_addr;
        stall_store_data <= ex_store_data;
        stall_be <= ex_store_be;
      end
    end
  end

  // Only LMUL=1 is supported: VLMAX is VLEN/SEW elements, which for the
  // 128-bit register file is 16 lanes at e8, 8 at e16 and 4 at e32.

  assign vec_sew_cur = vec_vtype_sew;
  assign vec_vta_cur = vec_vtype_vta;
  assign is_vec_mem = idex_is_vload || idex_is_vstore;

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
  // Scalar operands broadcast at the element width, not at XLEN.
  always_comb begin
    case (vec_sew_cur)
      3'd0: begin
        vec_bcast = {16{vec_scalar_b[7:0]}};
      end
      3'd1: begin
        vec_bcast = {8{vec_scalar_b[15:0]}};
      end
      default: begin
        vec_bcast = {4{vec_scalar_b}};
      end
    endcase
  end
  assign vec_alu_b = (idex_instr[14:12] == 3'b000) ? vec_vs1_data : vec_bcast;

  rv32_vec_alu u_vec_alu (
      .a(vec_vs2_data),
      .b(vec_alu_b),
      .sew(vec_sew_cur),
      .op(idex_vec_funct6),
      .result(vec_raw)
  );

  rv32_vec_reduce u_vec_reduce (
      .source(vec_vs2_data),
      .seed(vec_vs1_data[31:0]),
      .vl(vec_vl),
      .sew(vec_sew_cur),
      .result(vec_reduce_sum[31:0])
  );
  assign vec_reduce_sum[127:32] = '0;

  assign vec_wr_vl = (idex_vec_funct6 == `RV32_VOP_SCALAR) && (idex_instr[14:12] == 3'b110) ?
                     5'd1 : vec_vl;

  // Select scalar vector results by instruction class, without the
  // fault/hold write-enable cone. EX/MEM validity qualifies their commit.
  assign vec_scalar_wb = idex_is_vset ||
                        (idex_is_vec && !is_vec_mem &&
                         (idex_vec_funct6 == `RV32_VOP_SCALAR) && (idex_instr[14:12] == 3'b010));
  assign vec_scalar_wdata = idex_is_vset ? vset_new_vl :
                            (vec_sew_cur == 3'd0) ?
                            {{24{vec_vs2_data[7]}}, vec_vs2_data[7:0]} :
                            (vec_sew_cur == 3'd1) ?
                            {{16{vec_vs2_data[15]}}, vec_vs2_data[15:0]} : vec_vs2_data[31:0];

  always_comb begin
    vec_ex_we_int = 1'b0;
    vec_ex_wdata_int = vec_raw;
    vec_vset_en = 1'b0;
    vec_vset_vl = vset_new_vl[4:0];
    vec_vset_vtype = vset_new_vtype;
    // Arithmetic/configuration instructions never issue a data lookup.
    // Their write enable must not depend on the memory hit/stall path.
    if (idex_valid && idex_is_vec && !idex_ifault && !idex_illegal && !dmem_lu_fault &&
        !fence_hold && !halt && !rst && !cancel_ex) begin
      if (idex_is_vset) begin
        vec_vset_en = 1'b1;
      end else if (!is_vec_mem) begin
        if (idex_vec_funct6 == `RV32_VOP_MOVE) begin
          vec_ex_we_int = 1'b1;
          vec_ex_wdata_int = (idex_instr[14:12] == 3'b000) ? vec_vs2_data : vec_bcast;
        end else if (idex_vec_funct6 == `RV32_VOP_SCALAR) begin
          if (idex_instr[14:12] == 3'b010) begin
            // Scalar result selection is independent of write eligibility.
          end else begin
            // vmv.s.x: the scalar becomes element 0.
            vec_ex_we_int = 1'b1;
            vec_ex_wdata_int = {128{1'b0}} | {vec_vd_data[127:32], rs1_fwd};
          end
        end else if (idex_instr[14:12] == 3'b010) begin
          // vredsum.vs
          vec_ex_we_int = 1'b1;
          vec_ex_wdata_int = vec_reduce_sum;
        end else begin
          vec_ex_we_int = 1'b1;
        end
        // Tail policy for everything that writes a whole register.
        for (int k = 0; k < 16; k = k + 1) begin
          if (k >= vec_wr_vl) begin
            case (vec_sew_cur)
              3'd0: begin
                vec_ex_wdata_int[8*k+:8] = vec_vta_cur ? 8'hff : vec_vd_data[8*k+:8];
              end
              3'd1: begin
                if (k < 8) begin
                  vec_ex_wdata_int[16*k+:16] = vec_vta_cur ? 16'hffff : vec_vd_data[16*k+:16];
                end
              end
              default: begin
                if (k < 4) begin
                  vec_ex_wdata_int[32*k+:32] = vec_vta_cur ? 32'hffff_ffff : vec_vd_data[32*k+:32];
                end
              end
            endcase
          end
        end
      end
    end
  end

  assign vec_ex_we = vec_ex_we_int;
  assign vec_ex_wdata = vec_ex_wdata_int;

  // ----------------------------------------- Vector memory sequencing
  // One element per cycle. The execute stage keeps the instruction while
  // the pipeline is held, and the memory stage commits one element per
  // cycle behind it. The last cycle issues nothing so that the next
  // instruction cannot reach EX while MEM is still writing the final
  // element.
  assign vmem_idx = vmem_active ? vmem_k : 5'd0;
  assign vmem_total = vec_vl;
  assign vmem_done = (vmem_total == 5'd0) || (vmem_active && (vmem_k >= vmem_total));
  assign vmem_issue = is_vec_mem && idex_valid && !vmem_done && !vec_fault && !rst && !halt &&
                      !fence_hold;
  assign vmem_hold = is_vec_mem && idex_valid && !vmem_done;

  // Element size in bytes: e8, e16 or e32.
  assign vmem_shift = (idex_instr[14:12] == 3'b000) ? 2'd0 :
                      (idex_instr[14:12] == 3'b101) ? 2'd1 : 2'd2;
  assign vmem_stride = 32'd1 << vmem_shift;
  // Keep the current element address in a register. Increment it only
  // after a successful lookup, keeping carry propagation off the cache
  // lookup path and preserving the address across misses.
  assign vmem_addr = vmem_active ? vmem_base : memory_addr;

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
        vec_store_elem = {24'd0, vec_vd_data[8*vmem_idx+:8]};
      end
      3'b101: begin
        vec_store_elem = {16'd0, vec_vd_data[16*vmem_idx[2:0]+:16]};
      end
      default: begin
        vec_store_elem = vec_vd_data[32*vmem_idx[1:0]+:32];
      end
    endcase
  end

  assign vmem_store_data = vec_store_elem << {vmem_addr[1:0], 3'b000};
  assign vec_elem_sew = (idex_instr[14:12] == 3'b000) ? 3'd0 :
                        (idex_instr[14:12] == 3'b101) ? 3'd1 : 3'd2;

  always_ff @(posedge clk) begin
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
        // Latch forwarding once, but retry element zero after a miss.
        vmem_k <= lu_stall ? 5'd0 : 5'd1;
        vmem_base <= lu_stall ? memory_addr : (memory_addr + vmem_stride);
      end else if (!lu_stall) begin
        vmem_k <= vmem_idx + 5'd1;
        vmem_base <= vmem_base + vmem_stride;
      end
    end
  end

  // Vector payload advances independently of the late memory hold. It is
  // visible only when the matching EX/MEM valid and vector-write bits set.
  always_ff @(posedge clk) exmem_vec_data <= vec_ex_wdata;

  // ------------------------------------------------------ EX/MEM register
  always_ff @(posedge clk) begin
    if (rst) begin
      exmem_valid <= 1'b0;
      exmem_vec_we <= 1'b0;
      exmem_vec_last <= 1'b0;
      exmem_pc <= '0;
      exmem_instr <= 32'h0000_0013;
      exmem_alu <= '0;
      exmem_wbval <= '0;
      exmem_store_data <= '0;
      exmem_be <= '0;
      exmem_rd <= '0;
      exmem_funct3 <= '0;
      exmem_regwrite <= 1'b0;
      exmem_is_load <= 1'b0;
      exmem_is_store <= 1'b0;
      exmem_is_amo <= 1'b0;
      exmem_is_lr <= 1'b0;
      exmem_is_sc <= 1'b0;
      exmem_amo_op <= '0;
      exmem_is_sfence <= 1'b0;
      exmem_is_fence_i <= 1'b0;
    end else if (halt || fence_hold) begin
      // Hold while a FENCE.I wait is active.
    end else if (is_vec_mem && idex_valid) begin
      exmem_vec_we <= 1'b0;
      // One element per cycle; the last cycle issues nothing.
      // VL zero still retires one no-op instruction without a memory
      // request. Nonzero vectors retire only with their final element.
      exmem_valid <= ((vmem_issue && !lu_stall) || (vmem_total == 5'd0)) && !cancel_ex;
      exmem_vec_last <= (vmem_total == 5'd0) || (vmem_idx + 5'd1 == vmem_total);
      exmem_pc <= idex_pc;
      exmem_instr <= idex_instr;
      exmem_alu <= dmem_lu_paddr;
      exmem_wbval <= '0;
      exmem_store_data <= ex_st;
      exmem_be <= ex_be;
      exmem_rd <= idex_instr[11:7];
      exmem_funct3 <= idex_funct3;
      exmem_regwrite <= 1'b0;
      exmem_is_load <= 1'b0;
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
    end else begin
      // Invalid payload may advance during a lookup miss or the first
      // reduction cycle. Miss operands are already saved separately;
      // only validity needs the late cache-hit signal.
      exmem_valid <= idex_valid && !ex_trap && !lu_stall && !cancel_ex;
      exmem_vec_we <= vec_ex_we;
      exmem_pc <= idex_pc;
      exmem_instr <= idex_instr;
      exmem_alu <= ex_addr;
      exmem_wbval <= ex_wbval;
      exmem_store_data <= ex_st;
      exmem_be <= ex_be;
      exmem_rd <= idex_rd;
      exmem_funct3 <= idex_funct3;
      // A divide retires without writing: the divider port supplies
      // the value when it completes.
      exmem_regwrite <= idex_regwrite && !idex_is_div && (!idex_is_vec || vec_scalar_wb);
      exmem_is_load <= idex_is_load;
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

endmodule
