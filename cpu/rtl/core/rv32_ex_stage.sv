// Execute stage.
//
// Owns operand forwarding, the ALU, branch/jump resolution, trap
// detection, the machine/supervisor CSR file and the EX/MEM pipeline
// register. A redirect is emitted only when the pipeline is not stalled,
// so older instructions always commit first. The CSR file is written from
// WB; trap entry, MRET and SRET use the redirect this stage generates.
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
  /* Vector register write port (EX). */
  output logic vec_ex_we,
  output logic [4:0] vec_ex_wd,
  output logic [127:0] vec_ex_wdata,

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
  input logic [31:0] idex_pred_target,
  /* Writeback forwarding. */
  input logic [31:0] wb_data,
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
  /* Multiply partial products, completed in MEM. */
  output logic [31:0] exmem_mul_p0,
  output logic [31:0] exmem_mul_p1,
  output logic [31:0] exmem_mul_p2,
  output logic [31:0] exmem_mul_p3,
  output logic [31:0] exmem_mul_sub_a,
  output logic [31:0] exmem_mul_sub_b,
  output logic [2:0] exmem_mul_variant,
  output logic exmem_from_mul,
  /* EX/MEM pipeline register. */
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
  output logic [2:0] exmem_vec_sew,
  output logic exmem_is_sfence,
  output logic exmem_is_fence_i
);

  logic [31:0] rs1_fwd;
  logic [31:0] rs2_fwd;
  logic [31:0] ex_alu_a;
  logic [31:0] ex_alu_b;
  logic [31:0] alu_result;
  logic [31:0] mul_p0;
  logic [31:0] mul_p1;
  logic [31:0] mul_p2;
  logic [31:0] mul_p3;
  logic [2:0] mul_variant;
  logic [31:0] mul_sub_a;
  logic [31:0] mul_sub_b;
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
  logic [31:0] ex_redirect_pc_int;
  logic [31:0] ex_redirect_pc_stage;
  logic irq_take;
  logic csr_trap_irq;
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

  // Only LMUL=1 is supported: VLMAX is VLEN/SEW elements, which for the
  // 128-bit register file is 16 lanes at e8, 8 at e16 and 4 at e32.
  logic [2:0] vec_sew_cur;
  logic vec_vta_cur;
  logic is_vec_mem;
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
  logic [31:0] vmem_offset;
  logic [31:0] vec_store_elem;
  logic [3:0] vmem_be;
  logic [31:0] vmem_store_data;
  logic [2:0] vec_elem_sew;

  // ------------------------------------------------------------- Forwarding
  assign rs1_fwd = ({32{idex_rs1_from_mem}} & exmem_wbval) |
                   ({32{idex_rs1_from_wb}} & wb_data) |
                   ({32{idex_rs1_from_rf}} & idex_rs1_val);
  assign rs2_fwd = ({32{idex_rs2_from_mem}} & exmem_wbval) |
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
  assign div_start = idex_valid && idex_is_div && !div_busy && !fence_hold && !halt && !rst;

  rv32_divider u_divider (
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .op(idex_md_op),
      .a(rs1_fwd),
      .b(rs2_fwd),
      .start(div_start),
      .busy(div_busy),
      .done(div_wb_en_raw),
      .div_result(md_div_result)
  );

  // The multiplier only produces partial products here; the sum is
  // completed in MEM, so multiply retires like a load.
  rv32_mul_prod u_mul_prod (
      .a(rs1_fwd),
      .b(rs2_fwd),
      .p0(mul_p0),
      .p1(mul_p1),
      .p2(mul_p2),
      .p3(mul_p3),
      .sub_a(mul_sub_a),
      .sub_b(mul_sub_b)
  );

  assign mul_variant = idex_md_op;

  // A divide leaves the pipeline immediately and writes the register
  // file later through the divider port.
  assign ex_alu_result = idex_is_div ? md_div_result : alu_result;
  assign div_rd = div_rd_q;
  assign div_wb_rd = div_rd_q;
  assign div_wb_data = md_div_result;
  assign div_wb_en = div_wb_en_raw && (div_rd_q != 5'd0);

  always_ff @(posedge clk) begin
    if (rst) begin
      div_rd_q <= '0;
    end else if (div_start) begin
      div_rd_q <= idex_rd;
    end
  end

  assign ex_branch_target = idex_pc + idex_imm;
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
      ({32{idex_rs1_from_mem}} & (exmem_wbval + idex_imm)) |
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
                    idex_is_csr ? csr_rdata : vec_scalar_wb ? vec_scalar_wdata : ex_addr;

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
      .trap_en(csr_trap_irq || (ex_redirect_int && ex_trap)),
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
  assign csr_mret_en = ex_redirect_en && idex_mret && !ex_trap;
  assign csr_sret_en = ex_redirect_en && idex_sret && !ex_trap;

  assign csr_src = idex_csr_uimm ? {27'd0, idex_rs1} : rs1_fwd;
  assign csr_write_intent = idex_is_csr && ((idex_csr_op == `RV32_CSR_RW) || (csr_src != 32'd0));
  assign ex_csr_illegal = idex_is_csr &&
                          (!csr_exists || !csr_read_ok ||
                           (csr_write_intent && !csr_write_ok));
  assign csr_wr_en = idex_valid && idex_is_csr && csr_write_intent && csr_exists &&
                     csr_write_ok && !ex_trap && !fence_hold && !halt && !rst;

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
    ex_redirect_pc_stage = 32'd0;
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
        ex_trap_tval = ex_branch_target;
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
                            (ex_branch_taken && (ex_branch_target != idex_pred_target));
      end else if (idex_is_jal) begin
        branch_mispredict = !(idex_pred_taken && (idex_pred_target == ex_branch_target));
      end else if (idex_is_jalr) begin
        branch_mispredict = 1'b1;
      end

      if (ex_trap) begin
        ex_redirect = 1'b1;
        ex_redirect_pc_stage = csr_trap_vector;
      end else if (idex_mret) begin
        ex_redirect = 1'b1;
        ex_redirect_pc_stage = csr_mepc;
      end else if (idex_sret) begin
        ex_redirect = 1'b1;
        ex_redirect_pc_stage = csr_sepc;
      end else if (branch_mispredict) begin
        ex_redirect = 1'b1;
        if (idex_is_branch) begin
          ex_redirect_pc_stage = ex_branch_taken ? ex_branch_target : (idex_pc + 32'd4);
        end else if (idex_is_jal) begin
          ex_redirect_pc_stage = ex_branch_target;
        end else begin
          ex_redirect_pc_stage = ex_jump_target;
        end
      end
    end
  end

  // A redirecting instruction cannot issue a cache lookup. Only an older
  // FENCE.I can hold it; do not feed the data-cache hit path into redirects.
  assign ex_redirect_int = ex_redirect && !fence_hold && !halt && !rst;
  assign ex_redirect_pc_int = ex_redirect_pc_stage;

  // Take interrupts at a non-memory instruction boundary. Decode these
  // boundaries early instead of feeding cache-hit timing into redirects;
  // this also lets a vector memory sequence finish before taking a trap.
  // The saved PC is the instruction that would have executed next.
  assign irq_take = irq_req && !ex_redirect_int &&
                    !(idex_valid && (idex_is_load || idex_is_store || idex_is_amo ||
                                     idex_is_lr || idex_is_sc || is_vec_mem)) &&
                    !fence_hold && !halt && !rst && !redirect_from_mem;
  assign ex_redirect_en = (ex_redirect_int || irq_take) && !fence_hold && !halt && !rst;
  assign ex_redirect_pc = irq_take ? csr_trap_vector : ex_redirect_pc_int;
  assign csr_trap_irq = irq_take;
  assign ex_trap_taken = csr_trap_irq || (ex_redirect_int && ex_trap);
  assign vec_mem_hold = vmem_hold && !ex_trap;
  assign csr_trap_pc = irq_take ? irq_next_pc : idex_pc;
  assign csr_trap_cause = irq_take ? {1'b1, 26'd0, irq_code} : ex_trap_cause;
  assign csr_trap_tval = irq_take ? 32'd0 : ex_trap_tval;
  // The decoder makes memory operations mutually exclusive with branches,
  // CSR accesses and system instructions. Only illegal decode and memory
  // alignment can trap a load/store; keep unrelated trap paths off lookup.
  assign ex_lu_valid = idex_valid &&
                       (idex_is_load || idex_is_store || idex_is_amo || idex_is_lr ||
                        idex_is_sc || is_vec_mem) &&
                       !idex_illegal && !idex_ifault && !ex_mem_misaligned &&
                       !rst && !halt && !fence_hold;
  assign ex_lu_vaddr = mem_access_addr;
  assign ex_lu_we = idex_is_store || idex_is_amo || idex_is_sc || idex_is_vstore;
  assign btb_update = idex_valid && !ex_trap && !fence_hold && !halt && !rst &&
                      (idex_is_branch || idex_is_jal || idex_is_jalr);
  assign btb_is_branch = idex_is_branch;
  assign btb_is_jal = idex_is_jal;
  assign btb_is_jalr = idex_is_jalr;
  assign btb_taken = (idex_is_branch && ex_branch_taken) || idex_is_jal;
  assign btb_target = ex_branch_target;

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

  // Compress the reduction operands without propagating carry between
  // bits. Only the final addition uses a full-width carry chain.
  wire [31:0] reduce_terms[0:6][0:16];
  for (genvar k = 0; k < 16; k = k + 1) begin : g_reduce_lane
    wire [31:0] element_value;
    assign element_value = (vec_sew_cur == 3'd0) ? {24'd0, vec_vs2_data[8*k+:8]} :
                           (vec_sew_cur == 3'd1) ? {16'd0, vec_vs2_data[16*(k%8)+:16]} :
                           vec_vs2_data[32*(k%4)+:32];
    assign reduce_terms[0][k] = (5'(k) < vec_vl) ? element_value : 32'd0;
  end
  assign reduce_terms[0][16] = vec_vs1_data[31:0];
  for (genvar level = 0; level < 6; level = level + 1) begin : g_reduce_level
    localparam int INPUTS = (level == 0) ? 17 : (level == 1) ? 12 :
                            (level == 2) ? 8 : (level == 3) ? 6 : (level == 4) ? 4 : 3;
    localparam int GROUPS = INPUTS / 3;
    localparam int OUTPUTS = 2 * GROUPS + INPUTS % 3;
    for (genvar g = 0; g < GROUPS; g = g + 1) begin : g_compress
      wire [31:0] a = reduce_terms[level][3*g];
      wire [31:0] b = reduce_terms[level][3*g+1];
      wire [31:0] c = reduce_terms[level][3*g+2];
      assign reduce_terms[level+1][2*g] = a ^ b ^ c;
      assign reduce_terms[level+1][2*g+1] = ((a & b) | (a & c) | (b & c)) << 1;
    end
    for (genvar k = 0; k < INPUTS % 3; k = k + 1) begin : g_remainder
      assign reduce_terms[level+1][2*GROUPS+k] = reduce_terms[level][3*GROUPS+k];
    end
    for (genvar k = OUTPUTS; k < 17; k = k + 1) begin : g_unused
      assign reduce_terms[level+1][k] = 32'd0;
    end
  end
  assign vec_reduce_sum = {96'd0, (reduce_terms[6][0] + reduce_terms[6][1])};

  assign vec_wr_vl = (idex_vec_funct6 == `RV32_VOP_SCALAR) && (idex_instr[14:12] == 3'b110) ?
                     5'd1 : vec_vl;

  always_comb begin
    vec_ex_we_int = 1'b0;
    vec_ex_wdata_int = vec_raw;
    vec_scalar_wb = 1'b0;
    vec_scalar_wdata = '0;
    vec_vset_en = 1'b0;
    vec_vset_vl = vset_new_vl[4:0];
    vec_vset_vtype = vset_new_vtype;
    if (idex_valid && idex_is_vec && !idex_illegal && !fence_hold && !halt && !rst && !lu_stall) begin
      if (idex_is_vset) begin
        vec_vset_en = 1'b1;
        vec_scalar_wb = 1'b1;
        vec_scalar_wdata = vset_new_vl;
      end else if (!is_vec_mem) begin
        if (idex_vec_funct6 == `RV32_VOP_MOVE) begin
          vec_ex_we_int = 1'b1;
          vec_ex_wdata_int = (idex_instr[14:12] == 3'b000) ? vec_vs2_data : vec_bcast;
        end else if (idex_vec_funct6 == `RV32_VOP_SCALAR) begin
          if (idex_instr[14:12] == 3'b010) begin
            // vmv.x.s: element 0 to the scalar destination.
            vec_scalar_wb = 1'b1;
            vec_scalar_wdata = vec_vs2_data[31:0];
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
  assign vec_ex_wd = idex_instr[11:7];
  assign vec_ex_wdata = vec_ex_wdata_int;

  // ----------------------------------------- Vector memory sequencing
  // One element per cycle. The execute stage keeps the instruction while
  // the pipeline is held, and the memory stage commits one element per
  // cycle behind it. The last cycle issues nothing so that the next
  // instruction cannot reach EX while MEM is still writing the final
  // element.
  assign vmem_idx = vmem_active ? vmem_k : 5'd0;
  assign vmem_total = vec_vl;
  assign vmem_done = vmem_active && (vmem_k >= vmem_total);
  assign vmem_issue = is_vec_mem && idex_valid && !vmem_done && !ex_trap && !rst && !halt &&
                      !fence_hold;
  assign vmem_hold = is_vec_mem && idex_valid && !vmem_done;

  // Element size in bytes: e8, e16 or e32.
  assign vmem_shift = (idex_instr[14:12] == 3'b000) ? 2'd0 :
                      (idex_instr[14:12] == 3'b101) ? 2'd1 : 2'd2;
  assign vmem_offset = {27'd0, vmem_idx} << vmem_shift;
  // The base address is latched on the first cycle: forwarding sources
  // change while the sequence holds the pipeline.
  // The first element has offset zero. Select it after the incrementer
  // so the scalar address adder never feeds a second carry chain.
  assign vmem_addr = vmem_active ? (vmem_base + vmem_offset) : memory_addr;

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
    end else if (!halt && !fence_hold) begin
      if (!is_vec_mem || !idex_valid || vmem_done) begin
        vmem_active <= 1'b0;
        vmem_k <= '0;
        vmem_base <= memory_addr;
      end else if (!vmem_active) begin
        vmem_active <= 1'b1;
        vmem_k <= 5'd1;
        vmem_base <= memory_addr;
      end else if (!lu_stall) begin
        vmem_k <= vmem_idx + 5'd1;
      end
    end
  end

  // ------------------------------------------------------ EX/MEM register
  always_ff @(posedge clk) begin
    if (rst) begin
      exmem_valid <= 1'b0;
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
      exmem_mul_p0 <= '0;
      exmem_mul_p1 <= '0;
      exmem_mul_p2 <= '0;
      exmem_mul_p3 <= '0;
      exmem_mul_sub_a <= '0;
      exmem_mul_sub_b <= '0;
      exmem_mul_variant <= `RV32_MD_MUL;
      exmem_from_mul <= 1'b0;
    end else if (halt || fence_hold) begin
      // Hold while a FENCE.I wait is active.
    end else if (lu_stall) begin
      exmem_valid <= 1'b0;
    end else if (is_vec_mem && idex_valid) begin
      // One element per cycle; the last cycle issues nothing.
      exmem_valid <= vmem_issue;
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
      exmem_mul_p0 <= '0;
      exmem_mul_p1 <= '0;
      exmem_mul_p2 <= '0;
      exmem_mul_p3 <= '0;
      exmem_mul_sub_a <= '0;
      exmem_mul_sub_b <= '0;
      exmem_mul_variant <= `RV32_MD_MUL;
      exmem_from_mul <= 1'b0;
    end else begin
      exmem_valid <= idex_valid && !ex_trap;
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
      exmem_vec_sew <= '0;
      exmem_is_sfence <= idex_is_sfence;
      exmem_is_fence_i <= idex_is_fence_i;
      exmem_mul_p0 <= mul_p0;
      exmem_mul_p1 <= mul_p1;
      exmem_mul_p2 <= mul_p2;
      exmem_mul_p3 <= mul_p3;
      exmem_mul_sub_a <= mul_sub_a;
      exmem_mul_sub_b <= mul_sub_b;
      exmem_mul_variant <= mul_variant;
      exmem_from_mul <= idex_valid && idex_is_mul;
    end
  end

endmodule
