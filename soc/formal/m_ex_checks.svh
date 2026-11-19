// Connect the multiplier's separately verified partial-product and
// recombination units to the ages and destinations of the core packets.
always @(posedge clk) begin
  if (!rst) begin
    if (div_start) assert (!div_engine_busy && idex_md_op[2]);
    if (div_write_pending) assert (div_rd_q != 0 && !div_engine_busy);
    if (!$past(rst)) begin
      if ($past((div_wb_en_raw || div_write_pending) && div_rd_q != 0 && wb_we))
        assert (div_write_pending && div_wb_data == $past(md_div_result));
      if ($past(div_wb_en)) assert (!div_write_pending);
    end
    if (exmem_valid && exmem_is_mul && !$past(rst)) begin
      assert ($past(idex_valid && idex_is_mul && !cancel_ex && !fence_hold));
      assert (exmem_rd == $past(idex_rd) && exmem_regwrite);
      assert ({exmem_mul_sum, exmem_mul_carry} == $past({mul_sum1, mul_carry1}));
      assert (exmem_mul_hi == ($past(idex_md_op) != `RV32_MD_MUL));
      assert (exmem_instr == $past(idex_instr) && exmem_pc == $past(idex_pc));
    end
  end
end
