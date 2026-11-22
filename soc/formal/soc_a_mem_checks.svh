// verilog_syntax: parse-as-module-body
// Reservation history is physical: aliases in different virtual pages
// reserve the same word. Any committed store (including a vector element)
// can invalidate it, not just an instruction reported by scalar RVFI.
logic f_reservation, f_old_sampled;
logic [29:0] f_reserved_word;
logic [31:0] f_old_word, f_old_addr, f_amo_result;
logic f_lr_word, f_sc_word, f_sc_match;
assign f_lr_word = exmem_instr[6:0] == 7'h2f && exmem_instr[31:27] == 5'd2;
assign f_sc_word = exmem_instr[6:0] == 7'h2f && exmem_instr[31:27] == 5'd3;
assign f_sc_match = f_reservation && dmem_addr[31:2] == f_reserved_word;

always_ff @(posedge clk or posedge rst) begin
  if (rst) begin
    f_reservation <= 1'b0;
    f_reserved_word <= '0;
    f_old_sampled <= 1'b0;
    f_old_word <= '0;
    f_old_addr <= '0;
  end else begin
    if (trap_taken) f_reservation <= 1'b0;
    else if (commit_valid && f_lr_word) begin
      f_reservation <= 1'b1;
      f_reserved_word <= dmem_addr[31:2];
    end else if ((commit_valid && f_sc_word) || (dmem_req && dmem_we && f_sc_match)) begin
      f_reservation <= 1'b0;
    end
    if (dmem_amo_read && dmem_ready) begin
      f_old_sampled <= 1'b1;
      f_old_word <= dmem_rsp_data;
      f_old_addr <= dmem_addr;
    end else if (commit_valid) begin
      f_old_sampled <= 1'b0;
    end
  end
end

always_comb begin
  case (exmem_instr[31:27])
    5'd0: f_amo_result = f_old_word + exmem_store_data;
    5'd1: f_amo_result = exmem_store_data;
    5'd4: f_amo_result = f_old_word ^ exmem_store_data;
    5'd8: f_amo_result = f_old_word | exmem_store_data;
    5'd12: f_amo_result = f_old_word & exmem_store_data;
    5'd16:
    f_amo_result = $signed(f_old_word) < $signed(exmem_store_data) ? f_old_word : exmem_store_data;
    5'd20:
    f_amo_result = $signed(f_old_word) > $signed(exmem_store_data) ? f_old_word : exmem_store_data;
    5'd24: f_amo_result = f_old_word < exmem_store_data ? f_old_word : exmem_store_data;
    5'd28: f_amo_result = f_old_word > exmem_store_data ? f_old_word : exmem_store_data;
    default: f_amo_result = '0;
  endcase
end

always_ff @(posedge clk) begin
  if (!rst) begin
    assert (res_valid == f_reservation);
    if (f_reservation) assert (res_addr == f_reserved_word);
    assert (amo_ready == f_old_sampled);
    if (f_old_sampled) begin
      assert (exmem_valid && exmem_is_amo && dmem_addr == f_old_addr);
      assert (amo_old_q == f_old_word && !dmem_amo_read);
    end
    if (lookup_valid && lookup_sc) begin
      // An SC cannot sample before an older reservation change applies.
      assert (!trap_taken && !(commit_valid && (f_lr_word || f_sc_word || store_now)));
    end
    if (exmem_valid && exmem_is_sc) assert (sc_ok == f_sc_match);
    if (dmem_req && exmem_is_lr) assert (!dmem_we && commit_wdata == dmem_rsp_data);
    if (dmem_req && exmem_is_sc) begin
      assert (dmem_we == f_sc_match && commit_wdata == {31'd0, !f_sc_match});
      assert (dmem_valid == f_sc_match);
      if (f_sc_match) assert (dmem_wdata == exmem_store_data && dmem_be == 4'hf);
    end
    if (dmem_req && exmem_is_amo) begin
      assert (f_old_sampled && dmem_we && dmem_be == 4'hf);
      assert (commit_wdata == f_old_word && dmem_wdata == f_amo_result);
    end
  end
end
