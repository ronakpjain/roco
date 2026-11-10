// Execute stage.
//
// Owns operand forwarding, the ALU, branch/jump resolution, trap
// detection, the machine-mode CSR file and the EX/MEM pipeline register.
// A redirect is emitted only when the pipeline is not stalled, so older
// instructions always commit first. The CSR file is written from WB;
// trap entry and MRET use the redirect that this stage generates.

`default_nettype none
`include "rv32_defs.svh"

module rv32_ex_stage (
  input logic clk,
  input logic rst,
  input logic halt,
  input logic stall,
  input logic lu_stall,
  input logic retire,
  /* ID/EX pipeline register. */
  input logic idex_valid,
  input logic [31:0] idex_pc,
  input logic [31:0] idex_instr,
  input logic [31:0] idex_rs1_val,
  input logic [31:0] idex_rs2_val,
  input logic [31:0] idex_imm,
  input logic [4:0] idex_rs1,
  input logic [4:0] idex_rs2,
  input logic [4:0] idex_rd,
  input logic [2:0] idex_funct3,
  input logic [3:0] idex_alu_op,
  input logic idex_alu_b_imm,
  input logic idex_alu_a_pc,
  input logic idex_regwrite,
  input logic idex_is_load,
  input logic idex_is_store,
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
  input logic idex_mret,
  input logic idex_is_fence_i,
  input logic fence_hold,
  input logic [31:0] mem_load_value,
  input logic idex_pred_taken,
  input logic [31:0] idex_pred_target,
  /* Writeback forwarding and CSR write port. */
  input logic wb_we,
  input logic [4:0] wb_rd,
  input logic [31:0] wb_data,
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
  output logic ex_lu_we,
  output logic [31:0] ex_lu_addr,
  output logic [31:0] ex_lu_wdata,
  output logic [3:0] ex_lu_be,
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
  output logic exmem_is_fence_i
);

  logic [31:0] rs1_fwd;
  logic [31:0] rs2_fwd;
  logic fwd_exmem_a;
  logic fwd_wb_a;
  logic fwd_exmem_b;
  logic fwd_wb_b;
  logic [31:0] ex_alu_a;
  logic [31:0] ex_alu_b;
  logic [31:0] ex_alu_result;
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
  logic branch_mispredict;
  logic stall_active;
  logic [31:0] stall_alu;
  logic [31:0] stall_store_data;
  logic [3:0] stall_be;
  logic [31:0] ex_addr;
  logic [31:0] ex_st;
  logic [3:0] ex_be;
  logic [31:0] ex_trap_tval;
  logic ex_csr_illegal;
  logic [31:0] ex_wbval;
  logic [31:0] csr_rdata;
  logic csr_exists;
  logic csr_writable;
  logic [31:0] csr_src;
  logic csr_write_intent;
  logic [31:0] csr_wdata;
  logic csr_wr_en;
  logic [31:0] mtvec;
  logic [31:0] mepc;

  // ------------------------------------------------------------- Forwarding
  always_comb begin
    fwd_exmem_a = exmem_valid && exmem_regwrite && (exmem_rd != 5'd0) && (exmem_rd == idex_rs1);
    fwd_wb_a = wb_we && (wb_rd != 5'd0) && (wb_rd == idex_rs1);
    fwd_exmem_b = exmem_valid && exmem_regwrite && (exmem_rd != 5'd0) && (exmem_rd == idex_rs2);
    fwd_wb_b = wb_we && (wb_rd != 5'd0) && (wb_rd == idex_rs2);
    rs1_fwd = fwd_exmem_a ? (exmem_is_load ? mem_load_value : exmem_wbval) :
              fwd_wb_a ? wb_data : idex_rs1_val;
    rs2_fwd = fwd_exmem_b ? (exmem_is_load ? mem_load_value : exmem_wbval) :
              fwd_wb_b ? wb_data : idex_rs2_val;
  end

  // ------------------------------------------------------------------- ALU
  assign ex_alu_a = idex_alu_a_pc ? idex_pc : rs1_fwd;
  assign ex_alu_b = idex_alu_b_imm ? idex_imm : rs2_fwd;

  rv32_alu u_alu (
      .a(ex_alu_a),
      .b(ex_alu_b),
      .op(idex_alu_op),
      .result(ex_alu_result)
  );

  assign ex_branch_target = idex_pc + idex_imm;
  assign ex_jump_target = {ex_alu_result[31:1], 1'b0};

  always_comb begin
    case (idex_funct3)
      3'b000: begin
        ex_store_be = 4'b0001 << ex_alu_result[1:0];
      end
      3'b001: begin
        ex_store_be = 4'b0011 << ex_alu_result[1:0];
      end
      default: begin
        ex_store_be = 4'b1111;
      end
    endcase
    ex_store_data = rs2_fwd << {ex_alu_result[1:0], 3'b000};
  end

  assign ex_addr = stall_active ? stall_alu : ex_alu_result;
  assign ex_st = stall_active ? stall_store_data : ex_store_data;
  assign ex_be = stall_active ? stall_be : ex_store_be;
  assign ex_wbval = (idex_is_jal || idex_is_jalr) ? (idex_pc + 32'd4) :
                    idex_is_csr ? csr_rdata : ex_addr;

  // -------------------------------------------------- CSR file (EX and WB)
  rv32_csr u_csr (
      .clk(clk),
      .rst(rst),
      .raddr(idex_csr_addr),
      .rdata(csr_rdata),
      .exists(csr_exists),
      .writable(csr_writable),
      .wr_en(csr_wr_en),
      .wr_addr(idex_csr_addr),
      .wr_data(csr_wdata),
      .trap_en(ex_redirect_en && ex_trap),
      .trap_pc(idex_pc),
      .trap_cause(ex_trap_cause),
      .trap_tval(ex_trap_tval),
      .mret_en(ex_redirect_en && idex_mret),
      .retire(retire),
      .mtvec(mtvec),
      .mepc(mepc)
  );

  assign csr_src = idex_csr_uimm ? {27'd0, idex_rs1} : rs1_fwd;
  assign csr_write_intent = idex_is_csr && ((idex_csr_op == `RV32_CSR_RW) || (csr_src != 32'd0));
  assign ex_csr_illegal = idex_is_csr && (!csr_exists || (csr_write_intent && !csr_writable));
  assign csr_wr_en = idex_valid && idex_is_csr && csr_write_intent && csr_exists &&
                     csr_writable && !ex_trap && !stall && !halt && !rst;

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
    ex_redirect_pc = 32'd0;
    if (idex_valid) begin
      if (idex_is_branch) begin
        case (idex_funct3)
          3'b000: begin
            ex_branch_taken = (ex_alu_result == 32'd0);
          end
          3'b001: begin
            ex_branch_taken = (ex_alu_result != 32'd0);
          end
          3'b100: begin
            ex_branch_taken = ex_alu_result[0];
          end
          3'b101: begin
            ex_branch_taken = !ex_alu_result[0];
          end
          3'b110: begin
            ex_branch_taken = ex_alu_result[0];
          end
          3'b111: begin
            ex_branch_taken = !ex_alu_result[0];
          end
          default: begin
            ex_branch_taken = 1'b0;
          end
        endcase
      end

      if (idex_is_load || idex_is_store) begin
        case (idex_funct3)
          3'b001, 3'b101: begin
            ex_mem_misaligned = ex_addr[0];
          end
          3'b010: begin
            ex_mem_misaligned = |ex_addr[1:0];
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

      if (idex_illegal || ex_csr_illegal) begin
        ex_trap = 1'b1;
        ex_trap_cause = `RV32_CAUSE_ILLEGAL;
        ex_trap_tval = idex_instr;
      end else if (idex_ebreak) begin
        ex_trap = 1'b1;
        ex_trap_cause = `RV32_CAUSE_BREAKPOINT;
      end else if (idex_ecall) begin
        ex_trap = 1'b1;
        ex_trap_cause = `RV32_CAUSE_ECALL_M;
      end else if (ex_target_misaligned) begin
        ex_trap = 1'b1;
        ex_trap_cause = `RV32_CAUSE_INSTR_MISALIGNED;
        ex_trap_tval = ex_branch_target;
      end else if (ex_mem_misaligned) begin
        ex_trap = 1'b1;
        ex_trap_cause = idex_is_store ? `RV32_CAUSE_STORE_MISALIGNED : `RV32_CAUSE_LOAD_MISALIGNED;
        ex_trap_tval = ex_addr;
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
        ex_redirect_pc = mtvec;
      end else if (idex_mret) begin
        ex_redirect = 1'b1;
        ex_redirect_pc = mepc;
      end else if (branch_mispredict) begin
        ex_redirect = 1'b1;
        if (idex_is_branch) begin
          ex_redirect_pc = ex_branch_taken ? ex_branch_target : (idex_pc + 32'd4);
        end else if (idex_is_jal) begin
          ex_redirect_pc = ex_branch_target;
        end else begin
          ex_redirect_pc = ex_jump_target;
        end
      end
    end
  end

  assign ex_redirect_en = ex_redirect && !stall && !halt && !rst;
  assign ex_lu_valid = idex_valid && (idex_is_load || idex_is_store) && !ex_trap &&
                       !rst && !halt && !fence_hold;
  assign ex_lu_we = idex_is_store;
  assign ex_lu_addr = ex_addr;
  assign ex_lu_wdata = ex_st;
  assign ex_lu_be = ex_be;
  assign btb_update = idex_valid && !ex_trap && !stall && !halt && !rst &&
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
    end else if (lu_stall && !stall_active) begin
      stall_active <= 1'b1;
      stall_alu <= ex_alu_result;
      stall_store_data <= ex_store_data;
      stall_be <= ex_store_be;
    end else if (!lu_stall) begin
      stall_active <= 1'b0;
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
      exmem_is_fence_i <= 1'b0;
    end else if (halt || fence_hold) begin
      // Hold while a FENCE.I wait is active.
    end else if (lu_stall) begin
      exmem_valid <= 1'b0;
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
      exmem_regwrite <= idex_regwrite;
      exmem_is_load <= idex_is_load;
      exmem_is_store <= idex_is_store;
      exmem_is_fence_i <= idex_is_fence_i;
    end
  end

endmodule
