// Instruction decode stage.
//
// Owns the register file and the ID/EX pipeline register. Decode is
// combinational; the register file read port bypasses the writeback
// write in the same cycle. The hazard unit consumes the combinational
// source-register information even while this stage is held.

`default_nettype none
`include "roco_cpu_defs.svh"

`ifdef ROCO_RVFI_PC_CHECKS
`define ROCO_ID_OPERAND_CHECKS
`endif
`ifdef ROCO_M_STREAM_CHECKS
`define ROCO_ID_OPERAND_CHECKS
`endif
`ifdef ROCO_SOC_ISA_MEMORY_FORMAL
`define ROCO_ID_OPERAND_CHECKS
`endif
`ifdef ROCO_SOC_GPR_FORWARD_FORMAL
`define ROCO_ID_OPERAND_CHECKS
`endif
module roco_cpu_id_stage (
`ifdef ROCO_ID_OPERAND_CHECKS
  input logic [4:0] rvfi_idex_rs1,
  rvfi_idex_rs2,
`endif
`ifdef ROCO_RVFI_GPR_STATE
  input logic [4:0] rvfi_gpr_watch_addr,
  output logic [31:0] rvfi_gpr_watch_value,
`endif
  input logic clk,
  input logic rst,
  input logic halt,
  input logic if_valid,
  input logic [31:0] if_pc,
  input logic [31:0] if_instr,
  input logic if_fault,
  input logic if_pred_taken,
  input logic [31:0] if_pred_target,
  input logic if_pred_direct,
  input logic [20:0] if_pred_imm,
  input logic hold,
  input logic flush,
  input logic bubble,
  input logic exmem_valid,
  input logic exmem_regwrite,
  input logic [4:0] exmem_rd,
  input logic [31:0] mem_wb_data,
  /* Writeback port into the register file. */
  input logic wb_we,
  input logic [4:0] wb_rd,
  input logic [31:0] wb_data,
  /* Decoupled divider write port. */
  input logic div_we,
  input logic [4:0] div_rd,
  input logic [31:0] div_data,
  /* Combinational decode, for the hazard unit. */
  output logic [4:0] dec_rs1,
  output logic [4:0] dec_rs2,
  output logic [4:0] dec_rd,
  output logic dec_use_rs1,
  output logic dec_use_rs2,
  output logic dec_regwrite,
  output logic dec_is_div,
  /* ID/EX pipeline register. */
  output logic idex_valid,
  output logic [3:0] idex_wb_select,
  output logic [31:0] idex_pc,
  output logic [31:0] idex_instr,
  output logic idex_ifault,
  output logic idex_pred_taken,
  output logic idex_pred_target_match,
  output logic [30:0] idex_pred_jalr_base,
  output logic [30:0] idex_pred_jalr_carry,
  output logic idex_pred_jalr_aligned,
  output logic [31:0] idex_rs1_val,
  output logic [31:0] idex_rs2_val,
  output logic idex_rs1_from_mem,
  output logic idex_rs2_from_mem,
  output logic idex_rs1_from_wb,
  output logic idex_rs1_from_rf,
  output logic [31:0] idex_imm,
  output logic [4:0] idex_rs1,
  output logic [4:0] idex_rd,
  output logic [2:0] idex_funct3,
  output logic [3:0] idex_alu_op,
  output logic idex_is_muldiv,
  output logic [2:0] idex_md_op,
  output logic [31:0] idex_alu_a_val,
  output logic [31:0] idex_alu_b_val,
  output logic idex_alu_a_from_mem,
  output logic idex_alu_b_from_mem,
  output logic idex_regwrite,
  output logic idex_is_load,
  output logic idex_is_store,
  output logic idex_is_amo,
  output logic idex_is_lr,
  output logic idex_is_sc,
  output logic [4:0] idex_amo_op,
  output logic idex_is_vec,
  output logic idex_is_vset,
  output logic idex_is_vload,
  output logic idex_is_vstore,
  output logic [5:0] idex_vec_funct6,
  output logic idex_is_branch,
  output logic idex_is_jal,
  output logic idex_is_jalr,
  output logic idex_is_csr,
  output logic idex_csr_uimm,
  output logic [1:0] idex_csr_op,
  output logic [11:0] idex_csr_addr,
  output logic idex_illegal,
  output logic idex_ecall,
  output logic idex_ebreak,
  output logic idex_mret,
  output logic idex_sret,
  output logic idex_is_sfence,
  output logic idex_is_fence_i
);

  logic [31:0] dec_imm;
  logic [30:0] pred_jalr_base, pred_jalr_carry;
  logic unused_base_msb, unused_carry_msb;
  roco_cpu_sub_pair u_predicted_base (
      .a({1'b0, if_pred_target[31:1]}),
      .b({1'b0, dec_imm[31:1]}),
      .difference({unused_base_msb, pred_jalr_base}),
      .predecessor({unused_carry_msb, pred_jalr_carry})
  );
  logic [2:0] dec_funct3;
  logic dec_alu_b_imm;
  logic dec_alu_a_pc;
  logic [3:0] dec_alu_op;
  logic dec_is_muldiv;
  logic [2:0] dec_md_op;
  logic dec_is_load;
  logic dec_is_store;
  logic dec_is_amo;
  logic dec_is_lr;
  logic dec_is_sc;
  logic [4:0] dec_amo_op;
  logic dec_is_vec;
  logic dec_is_vset;
  logic dec_is_vload;
  logic dec_is_vstore;
  logic [5:0] dec_vec_funct6;
  logic dec_is_branch;
  logic dec_is_jal;
  logic dec_is_jalr;
  logic dec_is_csr;
  logic dec_csr_uimm;
  logic [1:0] dec_csr_op;
  logic [11:0] dec_csr_addr;
  logic dec_illegal;
  logic dec_ecall;
  logic dec_ebreak;
  logic dec_mret;
  logic dec_sret;
  logic dec_is_sfence;
  logic dec_is_fence_i;
  logic [31:0] rf_rdata1;
  logic [31:0] rf_rdata2;
  logic ex_can_forward;
  logic mem_can_forward;
  logic rs1_from_mem;
  logic rs2_from_mem;
  logic rs1_matches_wb;
  logic rs2_matches_wb;

  // Compare register numbers one stage early. The instructions now in EX
  // and MEM will be in MEM and WB when the decoded instruction executes.
  // A trap in EX flushes that instruction.
  // Loads, multiplies and atomics interlock for one cycle, then ID
  // captures the final MEM result. Only registered EX results bypass
  // directly into the next EX instruction.
  assign dec_is_div = dec_is_muldiv && dec_md_op[2];
  assign ex_can_forward = idex_valid && idex_regwrite &&
                          !idex_is_load && !idex_is_lr && !idex_is_amo && !idex_is_sc &&
                          !idex_is_muldiv && (idex_rd != 5'd0);
  assign mem_can_forward = exmem_valid && exmem_regwrite && (exmem_rd != 5'd0);
  assign rs1_from_mem = ex_can_forward && (dec_rs1 == idex_rd);
  assign rs2_from_mem = ex_can_forward && (dec_rs2 == idex_rd);
  assign rs1_matches_wb = mem_can_forward && (dec_rs1 == exmem_rd);
  assign rs2_matches_wb = mem_can_forward && (dec_rs2 == exmem_rd);

  roco_cpu_decoder u_decoder (
      .instr(if_instr),
      .rs1(dec_rs1),
      .rs2(dec_rs2),
      .rd(dec_rd),
      .funct3(dec_funct3),
      .imm(dec_imm),
      .use_rs1(dec_use_rs1),
      .use_rs2(dec_use_rs2),
      .alu_b_imm(dec_alu_b_imm),
      .alu_a_pc(dec_alu_a_pc),
      .alu_op(dec_alu_op),
      .is_muldiv(dec_is_muldiv),
      .md_op(dec_md_op),
      .regwrite(dec_regwrite),
      .is_load(dec_is_load),
      .is_store(dec_is_store),
      .is_amo(dec_is_amo),
      .is_lr(dec_is_lr),
      .is_sc(dec_is_sc),
      .amo_op(dec_amo_op),
      .is_vec(dec_is_vec),
      .is_vset(dec_is_vset),
      .is_vload(dec_is_vload),
      .is_vstore(dec_is_vstore),
      .vec_funct6(dec_vec_funct6),
      .is_branch(dec_is_branch),
      .is_jal(dec_is_jal),
      .is_jalr(dec_is_jalr),
      .is_csr(dec_is_csr),
      .csr_uimm(dec_csr_uimm),
      .csr_op(dec_csr_op),
      .csr_addr(dec_csr_addr),
      .illegal(dec_illegal),
      .ecall(dec_ecall),
      .ebreak(dec_ebreak),
      .mret(dec_mret),
      .sret(dec_sret),
      .is_sfence(dec_is_sfence),
      .is_fence_i(dec_is_fence_i)
  );

  roco_cpu_regfile u_regfile (
`ifdef ROCO_RVFI_GPR_STATE
      .rvfi_gpr_watch_addr(rvfi_gpr_watch_addr),
      .rvfi_gpr_watch_value(rvfi_gpr_watch_value),
`endif
      .clk(clk),
      .rst(rst),
      .rs1(dec_rs1),
      .rs2(dec_rs2),
      .we(wb_we),
      .rd(wb_rd),
      .wdata(wb_data),
      .dwe(div_we),
      .drd(div_rd),
      .ddata(div_data),
      .rdata1(rf_rdata1),
      .rdata2(rf_rdata2)
  );

  logic wb_jump, wb_csr, wb_vec;
  assign wb_jump = dec_is_jal || dec_is_jalr;
  assign wb_csr = dec_is_csr && !wb_jump;
  assign wb_vec = !wb_jump && !wb_csr &&
                  (dec_is_vset || (dec_is_vec && !dec_is_vload && !dec_is_vstore &&
                   (dec_vec_funct6 == `RV32_VOP_SCALAR) && (if_instr[14:12] == 3'b010)));

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      idex_valid <= 1'b0;
      idex_wb_select <= 4'b0001;
      idex_pc <= '0;
      idex_instr <= 32'h0000_0013;
      idex_ifault <= 1'b0;
      idex_pred_taken <= 1'b0;
      idex_pred_target_match <= 1'b0;
      idex_pred_jalr_base <= '0;
      idex_pred_jalr_carry <= '0;
      idex_pred_jalr_aligned <= 1'b0;
      idex_rs1_val <= '0;
      idex_rs2_val <= '0;
      idex_rs1_from_mem <= 1'b0;
      idex_rs2_from_mem <= 1'b0;
      idex_rs1_from_wb <= 1'b0;
      idex_rs1_from_rf <= 1'b1;
      idex_imm <= '0;
      idex_rs1 <= '0;
      idex_rd <= '0;
      idex_funct3 <= '0;
      idex_alu_op <= `RV32_ALU_ADD;
      idex_is_muldiv <= 1'b0;
      idex_md_op <= `RV32_MD_MUL;
      idex_alu_a_val <= '0;
      idex_alu_b_val <= '0;
      idex_alu_a_from_mem <= 1'b0;
      idex_alu_b_from_mem <= 1'b0;
      idex_regwrite <= 1'b0;
      idex_is_load <= 1'b0;
      idex_is_store <= 1'b0;
      idex_is_amo <= 1'b0;
      idex_is_lr <= 1'b0;
      idex_is_sc <= 1'b0;
      idex_amo_op <= '0;
      idex_is_vec <= 1'b0;
      idex_is_vset <= 1'b0;
      idex_is_vload <= 1'b0;
      idex_is_vstore <= 1'b0;
      idex_vec_funct6 <= '0;
      idex_is_branch <= 1'b0;
      idex_is_jal <= 1'b0;
      idex_is_jalr <= 1'b0;
      idex_is_csr <= 1'b0;
      idex_csr_uimm <= 1'b0;
      idex_csr_op <= `RV32_CSR_RW;
      idex_csr_addr <= '0;
      idex_illegal <= 1'b0;
      idex_ecall <= 1'b0;
      idex_ebreak <= 1'b0;
      idex_mret <= 1'b0;
      idex_sret <= 1'b0;
      idex_is_sfence <= 1'b0;
      idex_is_fence_i <= 1'b0;
    end else if (halt || hold) begin
      // MEM can hold its own packet while a redirect kills the younger
      // EX packet. The payload stays frozen; only its valid bit clears.
      if (!halt && flush) idex_valid <= 1'b0;
    end else begin
      // Only the valid bit needs the flush and bubble controls. Updating
      // the invalid payload keeps those controls off the register enables.
      idex_valid <= if_valid && !flush && !bubble;
      idex_wb_select <= {wb_jump, wb_csr, wb_vec, !(wb_jump || wb_csr || wb_vec)};
      idex_pc <= if_pc;
      idex_instr <= if_instr;
      idex_ifault <= if_fault;
      idex_pred_taken <= if_pred_taken;
      // The BTB tag already matches this PC. A direct prediction has
      // target PC+imm, so matching the trained immediate verifies it.
      // Indirect predictions retain full source/target validation below.
      idex_pred_target_match <= if_pred_direct && (dec_imm[20:0] == if_pred_imm);
      idex_pred_jalr_base <= pred_jalr_base;
      idex_pred_jalr_carry <= pred_jalr_carry;
      idex_pred_jalr_aligned <= !if_pred_target[0];
      // The current MEM producer will be WB when this instruction reaches
      // EX. Resolve that source before ID/EX instead of adding a WB mux
      // ahead of the EX multiplier and memory-address sums.
      idex_rs1_val <= rs1_from_mem ? 32'd0 : rs1_matches_wb ? mem_wb_data : rf_rdata1;
      idex_rs2_val <= rs2_from_mem ? 32'd0 : rs2_matches_wb ? mem_wb_data : rf_rdata2;
      idex_rs1_from_mem <= rs1_from_mem;
      idex_rs2_from_mem <= rs2_from_mem;
      idex_rs1_from_wb <= 1'b0;
      idex_rs1_from_rf <= !rs1_from_mem;
      idex_imm <= dec_imm;
      idex_rs1 <= dec_rs1;
      idex_rd <= dec_rd;
      idex_funct3 <= dec_funct3;
      idex_alu_op <= dec_alu_op;
      idex_is_muldiv <= dec_is_muldiv;
      idex_md_op <= dec_md_op;
      // Select PC/immediate before the execution feedback path.
      idex_alu_a_val <= dec_alu_a_pc ? if_pc :
                       rs1_from_mem ? 32'd0 : rs1_matches_wb ? mem_wb_data : rf_rdata1;
      idex_alu_b_val <= dec_alu_b_imm ? dec_imm :
                       rs2_from_mem ? 32'd0 : rs2_matches_wb ? mem_wb_data : rf_rdata2;
      idex_alu_a_from_mem <= rs1_from_mem && !dec_alu_a_pc;
      idex_alu_b_from_mem <= rs2_from_mem && !dec_alu_b_imm;
      idex_regwrite <= dec_regwrite;
      idex_is_load <= dec_is_load;
      idex_is_store <= dec_is_store;
      idex_is_amo <= dec_is_amo;
      idex_is_lr <= dec_is_lr;
      idex_is_sc <= dec_is_sc;
      idex_amo_op <= dec_amo_op;
      idex_is_vec <= dec_is_vec;
      idex_is_vset <= dec_is_vset;
      idex_is_vload <= dec_is_vload;
      idex_is_vstore <= dec_is_vstore;
      idex_vec_funct6 <= dec_vec_funct6;
      idex_is_branch <= dec_is_branch;
      idex_is_jal <= dec_is_jal;
      idex_is_jalr <= dec_is_jalr;
      idex_is_csr <= dec_is_csr;
      idex_csr_uimm <= dec_csr_uimm;
      idex_csr_op <= dec_csr_op;
      idex_csr_addr <= dec_csr_addr;
      idex_illegal <= dec_illegal;
      idex_ecall <= dec_ecall;
      idex_ebreak <= dec_ebreak;
      idex_mret <= dec_mret;
      idex_sret <= dec_sret;
      idex_is_sfence <= dec_is_sfence;
      idex_is_fence_i <= dec_is_fence_i;
    end
  end

`ifdef ROCO_RVFI_PC_CHECKS
  `define ROCO_ID_REPLAY_CHECKS
`endif
`ifdef ROCO_IRQ_PIPELINE_CHECKS
  `define ROCO_ID_REPLAY_CHECKS
`endif
`ifdef ROCO_M_STREAM_CHECKS
  `define ROCO_ID_REPLAY_CHECKS
`endif
`ifdef ROCO_ATOMIC_STREAM_CHECKS
  `define ROCO_ID_REPLAY_ATOMICS
`endif
`ifdef ROCO_IRQ_PIPELINE_CHECKS
  `define ROCO_ID_REPLAY_ATOMICS
`endif
`ifdef ROCO_SOC_ISA_MEMORY_FORMAL
  `define ROCO_ID_REPLAY_CHECKS
  `define ROCO_ID_REPLAY_ATOMICS
`endif
`ifdef ROCO_SOC_GPR_FORWARD_FORMAL
  `define ROCO_ID_REPLAY_CHECKS
  `define ROCO_ID_REPLAY_ATOMICS
`endif
`ifdef ROCO_ID_REPLAY_CHECKS
  // An arbitrarily long MEM stall can hold EX past the induction window.
  // Relate the registered control bits to their instruction throughout it.
  logic [31:0] replay_imm;
  logic [2:0] replay_funct3;
  logic [3:0] replay_alu_op;
  logic replay_regwrite, replay_load, replay_store, replay_illegal;
`ifdef ROCO_ID_REPLAY_ATOMICS
  logic replay_amo, replay_lr, replay_sc;
  logic [4:0] replay_amo_op;
`endif
  logic replay_branch, replay_jal, replay_jalr, replay_ecall, replay_ebreak;
  logic replay_use_rs1, replay_use_rs2, replay_a_pc, replay_b_imm;
  logic replay_jump;
  logic replay_mret, replay_csr;
`ifdef ROCO_SOC_GPR_FORWARD_FORMAL
  logic replay_muldiv, replay_vec, replay_vset, replay_vload, replay_vstore;
  logic replay_sret, replay_sfence, replay_fence_i;
  logic [2:0] replay_md_op;
  logic [5:0] replay_vec_funct6;
`endif
`ifdef ROCO_SOC_PC_FORMAL
  logic [1:0] replay_csr_op;
  logic [11:0] replay_csr_addr;
`endif
  assign replay_jump = replay_jal || replay_jalr;
  roco_cpu_decoder replay_decode (
      .instr(idex_instr),
      .rs1(),
      .rs2(),
      .rd(),
      .funct3(replay_funct3),
      .imm(replay_imm),
      .use_rs1(replay_use_rs1),
      .use_rs2(replay_use_rs2),
      .alu_b_imm(replay_b_imm),
      .alu_a_pc(replay_a_pc),
      .alu_op(replay_alu_op),
`ifdef ROCO_SOC_GPR_FORWARD_FORMAL
      .is_muldiv(replay_muldiv),
      .md_op(replay_md_op),
`else
      .is_muldiv(),
      .md_op(),
`endif
      .regwrite(replay_regwrite),
      .is_load(replay_load),
      .is_store(replay_store),
`ifdef ROCO_ID_REPLAY_ATOMICS
      .is_amo(replay_amo),
      .is_lr(replay_lr),
      .is_sc(replay_sc),
      .amo_op(replay_amo_op),
`else
      .is_amo(),
      .is_lr(),
      .is_sc(),
      .amo_op(),
`endif
`ifdef ROCO_SOC_GPR_FORWARD_FORMAL
      .is_vec(replay_vec),
      .is_vset(replay_vset),
      .is_vload(replay_vload),
      .is_vstore(replay_vstore),
      .vec_funct6(replay_vec_funct6),
`else
      .is_vec(),
      .is_vset(),
      .is_vload(),
      .is_vstore(),
      .vec_funct6(),
`endif
      .is_branch(replay_branch),
      .is_jal(replay_jal),
      .is_jalr(replay_jalr),
      .is_csr(replay_csr),
      .csr_uimm(),
`ifdef ROCO_SOC_PC_FORMAL
      .csr_op(replay_csr_op),
      .csr_addr(replay_csr_addr),
`else
      .csr_op(),
      .csr_addr(),
`endif
      .illegal(replay_illegal),
      .ecall(replay_ecall),
      .ebreak(replay_ebreak),
      .mret(replay_mret),
`ifdef ROCO_SOC_GPR_FORWARD_FORMAL
      .sret(replay_sret),
      .is_sfence(replay_sfence),
      .is_fence_i(replay_fence_i)
`else
      .sret(),
      .is_sfence(),
      .is_fence_i()
`endif
  );
  always @(posedge clk) begin
    if (!rst && idex_valid) begin
      assert (idex_funct3 == replay_funct3 && idex_imm == replay_imm);
      assert (idex_is_load == replay_load && idex_is_store == replay_store);
`ifdef ROCO_ID_REPLAY_ATOMICS
      assert (idex_is_amo == replay_amo && idex_is_lr == replay_lr && idex_is_sc == replay_sc);
      assert (idex_amo_op == replay_amo_op);
`endif
      assert (idex_is_branch == replay_branch && idex_is_jal == replay_jal && idex_is_jalr == replay_jalr);
      assert (idex_ecall == replay_ecall && idex_ebreak == replay_ebreak && idex_illegal == replay_illegal);
      assert (idex_alu_op == replay_alu_op && idex_regwrite == replay_regwrite);
      assert (idex_rd == idex_instr[11:7]);
`ifdef ROCO_SOC_GPR_FORWARD_FORMAL
      assert (idex_is_muldiv == replay_muldiv && idex_md_op == replay_md_op);
      assert (idex_is_vec == replay_vec && idex_is_vset == replay_vset);
      assert (idex_is_vload == replay_vload && idex_is_vstore == replay_vstore);
      assert (idex_vec_funct6 == replay_vec_funct6);
      assert (idex_mret == replay_mret && idex_sret == replay_sret);
      assert (idex_is_csr == replay_csr);
      assert (idex_is_sfence == replay_sfence && idex_is_fence_i == replay_fence_i);
      if (idex_ifault) assert (idex_instr == 32'h0000_0013);
`endif
`ifdef ROCO_SOC_PC_FORMAL
      assert (idex_csr_op == replay_csr_op && idex_csr_addr == replay_csr_addr);
      assert (idex_rs1 == idex_instr[19:15]);
`endif
`ifdef ROCO_IRQ_PIPELINE_CHECKS
      assert (idex_mret == replay_mret && idex_is_csr == replay_csr);
`endif
`ifdef ROCO_RVFI_PC_CHECKS
      assert (idex_wb_select == {replay_jump, 2'b00, !replay_jump});
`endif
`ifdef ROCO_ID_OPERAND_CHECKS
      assert (rvfi_idex_rs1 == (replay_use_rs1 ? idex_instr[19:15] : 5'd0));
      assert (rvfi_idex_rs2 == (replay_use_rs2 ? idex_instr[24:20] : 5'd0));
`endif
      assert (idex_alu_a_from_mem == (idex_rs1_from_mem && !replay_a_pc));
      assert (idex_alu_b_from_mem == (idex_rs2_from_mem && !replay_b_imm));
      assert (idex_alu_a_val == (replay_a_pc ? idex_pc : idex_rs1_val));
      assert (idex_alu_b_val == (replay_b_imm ? idex_imm : idex_rs2_val));
      assert (!idex_rs1_from_wb && idex_rs1_from_rf == !idex_rs1_from_mem);
      if (idex_instr[19:15] == 0) assert (!idex_rs1_from_mem && idex_rs1_val == 0);
      if (idex_instr[24:20] == 0) assert (!idex_rs2_from_mem && idex_rs2_val == 0);
      if (idex_rs1_from_mem) assert (idex_rs1_val == 0);
      if (idex_rs2_from_mem) assert (idex_rs2_val == 0);
    end
  end
`endif
  `undef ROCO_ID_REPLAY_CHECKS
  `undef ROCO_ID_REPLAY_ATOMICS
  `undef ROCO_ID_OPERAND_CHECKS

endmodule
