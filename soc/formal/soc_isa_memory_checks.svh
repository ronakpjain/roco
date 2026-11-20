// verilog_syntax: parse-as-module-body
// Check the effects of every normally retired RV32I instruction using the
// upstream ISA model. Unsupported encodings remain unrestricted in the SoC.
logic isa_valid, isa_trap;
logic [4:0] isa_rs1, isa_rs2, isa_rd;
logic [31:0] isa_result, isa_next_pc, isa_mem_addr, isa_mem_wdata;
logic [3:0] isa_rmask, isa_wmask;
rvfi_isa_rv32i isa_model (
    .rvfi_valid(rvfi_valid),
    .rvfi_insn(rvfi_insn),
    .rvfi_pc_rdata(rvfi_pc_rdata),
    .rvfi_rs1_rdata(rvfi_rs1_rdata),
    .rvfi_rs2_rdata(rvfi_rs2_rdata),
    .rvfi_mem_rdata(rvfi_mem_rdata),
    .spec_valid(isa_valid),
    .spec_trap(isa_trap),
    .spec_rs1_addr(isa_rs1),
    .spec_rs2_addr(isa_rs2),
    .spec_rd_addr(isa_rd),
    .spec_rd_wdata(isa_result),
    .spec_pc_wdata(isa_next_pc),
    .spec_mem_addr(isa_mem_addr),
    .spec_mem_rmask(isa_rmask),
    .spec_mem_wmask(isa_wmask),
    .spec_mem_wdata(isa_mem_wdata)
);
// A MEM packet can remain held longer than the induction window. Assert
// its semantic relation while held, before its retirement strobe is enabled.
logic packet_valid, packet_trap;
logic [4:0] packet_rs1, packet_rs2, packet_rd;
logic [31:0] packet_result, packet_next_pc;
logic [3:0] packet_rmask;
rvfi_isa_rv32i packet_model (
    .rvfi_valid(exmem_valid),
    .rvfi_insn(exmem_instr),
    .rvfi_pc_rdata(exmem_pc),
    .rvfi_rs1_rdata(rvfi_exmem.rs1_data),
    .rvfi_rs2_rdata(rvfi_exmem.rs2_data),
    .rvfi_mem_rdata(dmem_rsp_data),
    .spec_valid(packet_valid),
    .spec_trap(packet_trap),
    .spec_rs1_addr(packet_rs1),
    .spec_rs2_addr(packet_rs2),
    .spec_rd_addr(packet_rd),
    .spec_rd_wdata(packet_result),
    .spec_pc_wdata(packet_next_pc),
    .spec_mem_addr(),
    .spec_mem_rmask(packet_rmask),
    .spec_mem_wmask(),
    .spec_mem_wdata()
);
// Induction linkage: ID/EX and EX/MEM control flags match the decode of
// their instruction words. Without this, induction can invent a valid RV32I
// MEM packet with vector, M-extension or atomic flags set. IDEX copies the
// decoder directly; EX/MEM either copies (scalar) or clears (vector issue
// gating and the mul valid gate), so a set flag implies decode set. The
// converse need not hold for vector flags: a VL-zero no-op retires a valid
// vector packet with its flags clear.
logic isa_idex_muldiv, isa_idex_vload, isa_idex_vstore;
logic [2:0] isa_idex_md_op;
roco_cpu_decoder isa_idex_decode (
    .instr(idex_instr),
    .rs1(),
    .rs2(),
    .rd(),
    .funct3(),
    .imm(),
    .use_rs1(),
    .use_rs2(),
    .alu_b_imm(),
    .alu_a_pc(),
    .alu_op(),
    .is_muldiv(isa_idex_muldiv),
    .md_op(isa_idex_md_op),
    .regwrite(),
    .is_load(),
    .is_store(),
    .is_amo(),
    .is_lr(),
    .is_sc(),
    .amo_op(),
    .is_vec(),
    .is_vset(),
    .is_vload(isa_idex_vload),
    .is_vstore(isa_idex_vstore),
    .vec_funct6(),
    .is_branch(),
    .is_jal(),
    .is_jalr(),
    .is_csr(),
    .csr_uimm(),
    .csr_op(),
    .csr_addr(),
    .illegal(),
    .ecall(),
    .ebreak(),
    .mret(),
    .sret(),
    .is_sfence(),
    .is_fence_i()
);
logic isa_exmem_muldiv, isa_exmem_vload, isa_exmem_vstore;
logic [2:0] isa_exmem_md_op;
logic isa_exmem_load, isa_exmem_store, isa_exmem_amo, isa_exmem_lr, isa_exmem_sc;
logic isa_exmem_sfence;
roco_cpu_decoder isa_exmem_decode (
    .instr(exmem_instr),
    .rs1(),
    .rs2(),
    .rd(),
    .funct3(),
    .imm(),
    .use_rs1(),
    .use_rs2(),
    .alu_b_imm(),
    .alu_a_pc(),
    .alu_op(),
    .is_muldiv(isa_exmem_muldiv),
    .md_op(isa_exmem_md_op),
    .regwrite(),
    .is_load(isa_exmem_load),
    .is_store(isa_exmem_store),
    .is_amo(isa_exmem_amo),
    .is_lr(isa_exmem_lr),
    .is_sc(isa_exmem_sc),
    .amo_op(),
    .is_vec(),
    .is_vset(),
    .is_vload(isa_exmem_vload),
    .is_vstore(isa_exmem_vstore),
    .vec_funct6(),
    .is_branch(),
    .is_jal(),
    .is_jalr(),
    .is_csr(),
    .csr_uimm(),
    .csr_op(),
    .csr_addr(),
    .illegal(),
    .ecall(),
    .ebreak(),
    .mret(),
    .sret(),
    .is_sfence(isa_exmem_sfence),
    .is_fence_i()
);
always_ff @(posedge clk) begin
  if (!rst && idex_valid) begin
    assert (idex_is_muldiv == isa_idex_muldiv);
    assert (idex_md_op == isa_idex_md_op);
    assert (idex_is_vload == isa_idex_vload);
    assert (idex_is_vstore == isa_idex_vstore);
  end
  if (!rst && exmem_valid) begin
    assert (exmem_funct3 == exmem_instr[14:12]);
    assert (exmem_rd == exmem_instr[11:7]);
    assert (exmem_is_load == isa_exmem_load);
    assert (exmem_is_store == isa_exmem_store);
    assert (exmem_is_amo == isa_exmem_amo);
    assert (exmem_is_lr == isa_exmem_lr);
    assert (exmem_is_sc == isa_exmem_sc);
    assert (exmem_is_sfence == isa_exmem_sfence);
    assert (exmem_is_mul == (isa_exmem_muldiv && !isa_exmem_md_op[2]));
    if (exmem_is_vload) assert (isa_exmem_vload);
    if (exmem_is_vstore) assert (isa_exmem_vstore);
  end
end
always_ff @(posedge clk) begin
  if (!rst && exmem_valid) begin
    assert (rvfi_exmem.instr == exmem_instr && rvfi_exmem.pc == exmem_pc);
    if (packet_valid) begin
      assert (!packet_trap);
      assert (rvfi_exmem.rs1 == packet_rs1 && rvfi_exmem.rs2 == packet_rs2);
      assert ((exmem_regwrite ? exmem_rd : 5'd0) == packet_rd);
      if (packet_rd != 0 && (!(|packet_rmask) || !mem_wait)) assert (commit_wdata == packet_result);
      assert (rvfi_exmem.next_pc == packet_next_pc);
      assert (!exmem_is_vload && !exmem_is_vstore && !exmem_is_mul);
      assert (!exmem_is_lr && !exmem_is_sc && !exmem_is_amo);
      assert (!exmem_is_fence_i && !exmem_is_sfence);
      assert (exmem_is_load == (exmem_instr[6:0] == 7'h03));
      assert (exmem_is_store == (exmem_instr[6:0] == 7'h23));
      if (exmem_is_load || exmem_is_store) begin
        assert (exmem_funct3 == exmem_instr[14:12]);
        assert (exmem_alu[1:0] == rvfi_exmem.vaddr[1:0]);
        assert (rvfi_exmem.vaddr == rvfi_exmem.rs1_data +
            (exmem_is_load ? {{20{exmem_instr[31]}}, exmem_instr[31:20]} :
             {{20{exmem_instr[31]}}, exmem_instr[31:25], exmem_instr[11:7]}));
      end
    end
  end
end
always_ff @(posedge clk) begin
  if (!rst && rvfi_valid && !rvfi_trap && isa_valid) begin
    assert (!isa_trap);
    assert (rvfi_rs1_addr == isa_rs1 && rvfi_rs2_addr == isa_rs2);
    assert (rvfi_rd_addr == isa_rd && rvfi_rd_wdata == isa_result);
    assert (rvfi_pc_wdata == isa_next_pc);
    assert (rvfi_mem_rmask == isa_rmask && rvfi_mem_wmask == isa_wmask);
    if (|isa_rmask || |isa_wmask) assert (rvfi_mem_addr == isa_mem_addr);
    for (int lane = 0; lane < 4; lane++)
    if (isa_wmask[lane]) assert (rvfi_mem_wdata[8*lane+:8] == isa_mem_wdata[8*lane+:8]);
  end
end

// Cover each RV32I effect family with concrete external reset-word programs.
for (genvar family = 0; family < 9; family++) begin : g_isa_cover
  localparam logic [6:0] OPCODE = family == 0 ? 7'h13 : family == 1 ? 7'h33 :
      family == 2 ? 7'h37 : family == 3 ? 7'h17 : family == 4 ? 7'h6f :
      family == 5 ? 7'h67 : family == 6 ? 7'h63 : family == 7 ? 7'h03 : 7'h23;
  always_ff @(posedge clk)
    if (!rst)
      cover (rvfi_valid && !rvfi_trap && isa_valid && rvfi_insn[6:0] == OPCODE);
end
