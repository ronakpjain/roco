// verilog_syntax: parse-as-module-body
// Decode at the retirement boundary independently of the ID/EX controls.
logic f_mem_mul;
assign f_mem_mul = exmem_instr[6:0] == 7'h33 && exmem_instr[31:25] == 7'd1 && !exmem_instr[14];

always_ff @(posedge clk) begin
  if (!rst && !halt && exmem_valid) begin
    assert (exmem_is_mul == f_mem_mul);
    if (f_mem_mul || f_mem_div) begin
      assert (retire && !dmem_req && !rvfi_trap);
      assert (rvfi_insn == exmem_instr && rvfi_pc_wdata == exmem_pc + 32'd4);
      assert (rvfi_rs1_addr == exmem_instr[19:15] && rvfi_rs2_addr == exmem_instr[24:20]);
      assert (exmem_rd == exmem_instr[11:7]);
      assert (rvfi_rd_addr == (f_mem_div ? 5'd0 : exmem_instr[11:7]));
      assert (rvfi_mem_rmask == 0 && rvfi_mem_wmask == 0);
    end
  end
  if (!rst && !halt && !$past(rst || halt)) begin
    assert ((retire && f_mem_div) == $past(rvfi_div_start));
    if ($past(rvfi_div_start)) begin
      assert (rvfi_insn == $past(idex_instr) && rvfi_pc_rdata == $past(idex_pc));
      assert (rvfi_rs1_rdata == $past(rvfi_div_a) && rvfi_rs2_rdata == $past(rvfi_div_b));
    end
  end
end

for (genvar variant = 0; variant < 4; variant++) begin : g_mul_witness
  always_ff @(posedge clk)
    if (!rst)
      cover (retire && f_mem_mul && rvfi_insn[14:12] == 3'(variant) && rvfi_rd_wdata != 0);
end

// The dependent ADDI in the cover program must actually consume a
// completed divide, not the result of one of the multiply witnesses.
logic f_div_x3_complete;
always_ff @(posedge clk or posedge rst) begin
  if (rst) f_div_x3_complete <= 1'b0;
  else if (retire && rvfi_rd_addr == 5'd3) f_div_x3_complete <= 1'b0;
  else if (div_wb_en && div_wb_rd == 5'd3) f_div_x3_complete <= 1'b1;
end
always_ff @(posedge clk) begin
  if (!rst) begin
    cover (div_conflict && div_busy && if_valid && dec_use_rs1 && dec_rs1 == div_rd);
    cover (f_div_x3_complete && retire && rvfi_insn == 32'h00118213 &&
           rvfi_rs1_addr == 5'd3 && rvfi_rs1_rdata != 0);
  end
end
