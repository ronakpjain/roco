`default_nettype none

module rv32a_mem_contract (
  input logic clk
);
  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;

  localparam logic [1:0] Lr = 0, Sc = 1, Amo = 2, Store = 3;
  (* anyseq *) logic issue, ready, trap, bank;
  (* anyseq *) logic [1:0] op;
  (* anyseq *) logic [4:0] amo_op;
  (* anyseq *) logic [31:0] operand;
  (* anyconst *) logic [31:0] initial_low, initial_high;

  logic pending, target, prepared;
  logic [1:0] current_op;
  logic [4:0] current_amo_op;
  logic [31:0] current_operand;
  logic [31:0] low_word, high_word, old_word;
  logic reservation, reservation_bank;
  logic commit, req, valid, we, wait_mem;
  logic [31:0] addr, data, result;
  logic [3:0] be;
  logic launch, sc_succeeds, expected_commit, expected_write;
  logic [31:0] expected_data, expected_result;
  assign launch = !rst && !pending && issue && !trap;
  assign old_word = target ? high_word : low_word;
  assign sc_succeeds = reservation && reservation_bank == target;
  assign expected_commit = pending && ready && (current_op != Amo || prepared);
  assign expected_write = current_op == Amo || current_op == Store ||
                          (current_op == Sc && sc_succeeds);
  assign expected_result = current_op == Sc ? {31'd0, !sc_succeeds} : old_word;

  // Architectural AMO functions; all comparisons are plain word operations.
  always_comb begin
    expected_data = current_operand;
    if (current_op == Amo) begin
      case (current_amo_op)
        5'b00000: expected_data = old_word + current_operand;
        5'b00001: expected_data = current_operand;
        5'b00100: expected_data = old_word ^ current_operand;
        5'b01000: expected_data = old_word | current_operand;
        5'b01100: expected_data = old_word & current_operand;
        5'b10000:
        expected_data = $signed(old_word) < $signed(current_operand) ? old_word : current_operand;
        5'b10100:
        expected_data = $signed(old_word) > $signed(current_operand) ? old_word : current_operand;
        5'b11000: expected_data = old_word < current_operand ? old_word : current_operand;
        5'b11100: expected_data = old_word > current_operand ? old_word : current_operand;
        default: expected_data = '0;
      endcase
    end
  end

  roco_cpu_mem_stage dut (
      .clk(clk),
      .rst(rst),
      .halt(1'b0),
      .fence_done(1'b1),
      .lookup_valid(launch),
      .lookup_addr({29'd0, bank}),
      .lookup_sc(op == Sc),
      .exmem_valid(pending),
      .exmem_pc(32'd0),
      .exmem_instr(32'd0),
      .exmem_alu({29'd0, target, 2'b00}),
      .exmem_wbval(32'd0),
      .exmem_store_data(current_operand),
      .exmem_be(4'hf),
      .exmem_rd(5'd1),
      .exmem_funct3(3'd2),
      .exmem_regwrite(current_op != Store),
      .exmem_is_load(1'b0),
      .exmem_forward_cache(1'b0),
      .exmem_forward_wbval(1'b0),
      .exmem_is_store(current_op == Store),
      .exmem_is_amo(current_op == Amo),
      .exmem_is_lr(current_op == Lr),
      .exmem_is_sc(current_op == Sc),
      .exmem_amo_op(current_amo_op),
      .exmem_is_vload(1'b0),
      .exmem_is_vstore(1'b0),
      .exmem_vec_elem(4'd0),
      .exmem_vec_last(1'b0),
      .exmem_vec_sew(3'd0),
      .vec_mem_we(),
      .vec_mem_wd(),
      .vec_mem_elem(),
      .vec_mem_sew(),
      .vec_mem_wdata(),
      .vec_element_commit(),
      .trap_taken(trap && !pending),
      .exmem_is_sfence(1'b0),
      .exmem_is_fence_i(1'b0),
      .exmem_is_mul(1'b0),
      .exmem_mul_hi(1'b0),
      .exmem_mul_sum(64'd0),
      .exmem_mul_carry(64'd0),
      .dmem_req(req),
      .dmem_valid(valid),
      .dmem_we(we),
      .dmem_addr(addr),
      .dmem_wdata(data),
      .dmem_be(be),
      .dmem_rsp_data(old_word),
      .dmem_forward_data(32'd0),
      .dmem_ready(ready),
      .mem_wait(wait_mem),
      .fence_req(),
      .mem_redirect(),
      .commit_valid(commit),
      .commit_pc(),
      .commit_instr(),
      .commit_rd(),
      .commit_wdata(result),
      .forward_data(),
      .memwb_valid(),
      .memwb_data(),
      .memwb_rd(),
      .memwb_regwrite()
  );

  always @(posedge clk) begin
    if (rst) begin
      pending <= 0;
      prepared <= 0;
      target <= 0;
      current_op <= Lr;
      current_operand <= 0;
      current_amo_op <= 0;
      low_word <= initial_low;
      high_word <= initial_high;
      reservation <= 0;
      reservation_bank <= 0;
    end else begin
      if (launch) begin
        if (op == Amo) begin
          case (amo_op)
            0, 1, 4, 8, 12, 16, 20, 24, 28: begin
            end
            default: assume (1'b0);
          endcase
        end
        pending <= 1;
        target <= bank;
        current_op <= op;
        current_operand <= operand;
        current_amo_op <= amo_op;
      end
      if (pending && current_op == Amo && ready) prepared <= !prepared;
      if (trap && !pending) reservation <= 0;
      if (expected_commit) begin
        pending <= 0;
        if (current_op == Lr) begin
          reservation <= 1;
          reservation_bank <= target;
        end else if (current_op == Sc || (expected_write && reservation_bank == target)) begin
          reservation <= 0;
        end
        if (expected_write) begin
          if (target) high_word <= expected_data;
          else low_word <= expected_data;
        end
      end

      assert (commit == expected_commit && req == expected_commit);
      assert (valid == (pending && (current_op != Amo || prepared)));
      assert (wait_mem == (pending && !expected_commit));
      if (expected_commit) begin
        assert (addr == {29'd0, target, 2'b00});
        assert (we == expected_write);
        if (expected_write) assert (be == 4'hf && data == expected_data);
        if (current_op != Store) assert (result == expected_result);
      end
      cover (expected_commit && current_op == Sc && sc_succeeds);
      cover (expected_commit && current_op == Sc && !sc_succeeds);
      cover (expected_commit && current_op == Amo && current_amo_op == 5'b00000);
      cover (expected_commit && current_op == Store && reservation && target != reservation_bank);
      cover (trap && !pending && reservation);
      cover (pending && current_op == Amo && prepared && !ready);
    end
  end
endmodule
