// verilog_syntax: parse-as-module-body
// Re-decode every live EX/MEM packet, including packets held indefinitely
// by the cache, MMIO bus or fence service. Vector flags can be clear on
// a zero-length no-op, so a set flag only implies the matching decode.
logic f_packet_load, f_packet_store, f_packet_amo, f_packet_lr, f_packet_sc;
logic f_packet_vload, f_packet_vstore, f_packet_sfence, f_packet_fence_i;
logic f_packet_muldiv;
logic [2:0] f_packet_md;
logic [4:0] f_packet_amo_op;
roco_cpu_decoder f_packet_decoder (
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
    .is_muldiv(f_packet_muldiv),
    .md_op(f_packet_md),
    .regwrite(),
    .is_load(f_packet_load),
    .is_store(f_packet_store),
    .is_amo(f_packet_amo),
    .is_lr(f_packet_lr),
    .is_sc(f_packet_sc),
    .amo_op(f_packet_amo_op),
    .is_vec(),
    .is_vset(),
    .is_vload(f_packet_vload),
    .is_vstore(f_packet_vstore),
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
    .is_sfence(f_packet_sfence),
    .is_fence_i(f_packet_fence_i)
);
always_ff @(posedge clk) begin
  if (!rst && exmem_valid) begin
    assert (exmem_funct3 == exmem_instr[14:12] && exmem_rd == exmem_instr[11:7]);
    assert (rvfi_exmem.instr == exmem_instr && rvfi_exmem.pc == exmem_pc);
    assert (exmem_is_load == f_packet_load && exmem_is_store == f_packet_store);
    assert (exmem_is_amo == f_packet_amo && exmem_is_lr == f_packet_lr && exmem_is_sc == f_packet_sc);
    if (exmem_is_amo) assert (exmem_amo_op == f_packet_amo_op);
    assert (exmem_is_sfence == f_packet_sfence && exmem_is_fence_i == f_packet_fence_i);
    assert (exmem_is_mul == (f_packet_muldiv && !f_packet_md[2]));
    if (exmem_is_vload) assert (f_packet_vload);
    if (exmem_is_vstore) assert (f_packet_vstore);
  end
end
