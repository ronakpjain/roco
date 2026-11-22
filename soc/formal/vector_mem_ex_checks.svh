`include "vector_mem_filter.svh"
logic [4:0] model_vl, max_vl, avl;
logic model_active, want_mem, want_set, load_insn, advance;
logic [4:0] elem;
logic [31:0] base, expected_addr, owner_pc, owner_word;
logic [31:0] natural_mask;
logic aligned, send_element, send_empty, group_ok;
assign load_insn = idex_instr[6:0] == 7'h07;
assign want_mem = idex_valid && (load_insn || idex_instr[6:0] == 7'h27);
assign want_set = idex_valid && idex_instr[6:0] == 7'h57;
assign avl = idex_instr[19:15];
assign max_vl = 5'd16 >> formal_vec_width;
assign natural_mask = (32'd1 << formal_vec_width) - 1;
assign aligned = (base & natural_mask) == 0;
assign group_ok = model_vl == 0 || formal_vec_width == vec_vtype_sew;
assign expected_addr = base + (32'(elem) << formal_vec_width);
assign advance = !halt && !fence_hold && !cancel_ex;
assign send_element = want_mem && model_active && advance && aligned && elem < model_vl && group_ok;
assign send_empty = want_mem && !model_active && advance && model_vl == 0;

logic packet, packet_mem, packet_load, packet_last, packet_set;
logic [31:0] packet_addr, packet_pc, packet_insn;
logic [4:0] packet_elem;
logic [3:0] packet_be;
always @(posedge clk) begin
  if (rst) begin
    model_vl <= 0;
    model_active <= 0;
    elem <= 0;
    packet <= 0;
    packet_set <= 0;
  end else begin
    if (want_set && advance) model_vl <= avl > max_vl ? max_vl : avl;
    if (cancel_ex) model_active <= 0;
    else if (!halt && !fence_hold) begin
      if (!want_mem || (model_active && elem == model_vl)) model_active <= 0;
      else if (!model_active && model_vl != 0) begin
        model_active <= 1;
        elem <= 0;
        base <= rs1_fwd;
        owner_pc <= idex_pc;
        owner_word <= idex_instr;
      end else if (send_element) elem <= elem + 1'b1;
    end
    if (!halt && !fence_hold) begin
      packet <= send_element || send_empty;
      packet_set <= want_set && advance;
      packet_mem <= send_element;
      packet_load <= load_insn;
      packet_last <= send_empty || elem + 1 == model_vl;
      packet_addr <= expected_addr;
      packet_pc <= idex_pc;
      packet_insn <= idex_instr;
      packet_elem <= elem;
      packet_be <= (formal_vec_width == 0 ? 4'h1 : formal_vec_width == 1 ? 4'h3 : 4'hf)
                   << expected_addr[1:0];
    end
  end
end

always @(posedge clk) begin
  if (!rst) begin
    assert (model_vl == vec_vl && model_vl <= max_vl && vec_vstart == 0);
    // vtype only changes through the program's matching vsets. Before the
    // first vset it holds reset; vill would also satisfy the empty case.
    assert (vec_vtype_sew == formal_vec_width || (vec_vl == 0 && vec_vtype_sew == 0));
    assert (csr_priv == `RV32_PRIV_M && satp == 0 && !irq_req);
    assert (!csr_wr_en && !lu_stall && !dmem_lu_fault);
    assert (vec_vset_en == (want_set && advance));
    if (want_set) begin
      // ex_wbval is an OR-mux of the registered wb_select bits; pin the
      // select itself so a fabricated combination cannot OR a live ALU
      // value into the vset result while idex is held.
      assert (idex_wb_select == 4'b0010);
      assert (idex_rd == idex_instr[11:7] && idex_regwrite);
      if (advance) begin
        assert (vec_vset_vl == (avl > max_vl ? max_vl : avl));
        assert (vec_vset_vtype == {24'd0, idex_instr[27:20]});
      end
    end
    if (idex_valid) begin
      assert (stream_vector_word(idex_instr, formal_vec_width));
      assert (!scalar_is_mem && !idex_ifault && !idex_illegal && !idex_is_csr);
      assert (!idex_is_muldiv && !idex_is_branch && !idex_is_jal && !idex_is_jalr);
      assert (!idex_mret && !idex_sret && !idex_is_sfence && !idex_is_fence_i);
      assert (!idex_ecall && !idex_ebreak);
      assert (want_mem == is_vec_mem);
      assert (idex_is_vload == load_insn);
      assert (idex_is_vstore == (idex_instr[6:0] == 7'h27));
      // EX keys the misalignment case and lookup size on the registered
      // funct3; tie it to the word so induction cannot mix the two.
      assert (idex_funct3 == idex_instr[14:12]);
      assert (idex_is_vset == want_set && idex_is_vec == want_set);
      if (want_mem) assert (!idex_rs1_from_wb && idex_rs1_from_rf == !idex_rs1_from_mem);
      // ID zeroes the captured rs1 when the live MEM producer forwards;
      // keep that fact explicit so rs1_fwd and vmem_start_addr cannot
      // disagree through a stale captured value.
      if (idex_rs1_from_mem) assert (idex_rs1_val == '0);
    end
    assert (!vec_arith_prepare && !vec_operand_ready && !div_busy);
    // Cancellation immediately follows an exception or a redirect. A
    // younger speculative packet on that edge is not a valid owner.
    if (!cancel_ex) begin
      assert (vmem_active == model_active);
      if (model_active) begin
        assert (want_mem && idex_pc == owner_pc && idex_instr == owner_word);
        assert (elem <= model_vl);
        assert (vmem_k == elem && vmem_addr == expected_addr && lookup_is_vec_q);
        if (elem != 0) assert (aligned);
        if (!load_insn && idex_instr[11:7] == formal_vec_reg)
          assert (vec_vd_q[8*formal_vec_byte+:8] == reference_vec_byte);
      end
    end
    if (advance && want_mem) begin
      assert (ex_lu_present == send_element);
      assert (ex_trap == ((model_active && elem < model_vl && !aligned) ||
                          (model_vl != 0 && !group_ok)));
      if (ex_trap) begin
        if (model_vl != 0 && !group_ok) begin
          assert (ex_trap_cause == `RV32_CAUSE_ILLEGAL && ex_trap_tval == idex_instr);
        end else begin
          assert (ex_trap_tval == expected_addr && elem == 0);
          assert (ex_trap_cause == (load_insn ? 32'd4 : 32'd6));
        end
      end
    end
    if (exmem_valid && (exmem_instr[6:0] == 7'h07 || exmem_instr[6:0] == 7'h27)) assert (packet);
    if (packet) begin
      assert (exmem_valid && exmem_pc == packet_pc && exmem_instr == packet_insn);
      assert (exmem_is_vload == (packet_mem && packet_load));
      assert (exmem_is_vstore == (packet_mem && !packet_load));
      assert (exmem_vec_last == packet_last && !exmem_regwrite && !exmem_vec_we);
      if (packet_mem) begin
        // ID/EX owns the instruction until its final element leaves MEM.
        assert (model_active && packet_insn == owner_word && packet_pc == owner_pc);
        assert (exmem_alu == packet_addr && exmem_be == packet_be);
        assert (packet_elem < max_vl && (packet_addr & natural_mask) == 0);
        assert (exmem_vec_elem == packet_elem[3:0] && exmem_vec_sew == {1'b0, formal_vec_width});
        assert (exmem_rd == packet_insn[11:7]);
      end
    end
    assert (packet_set == (exmem_valid && exmem_instr[6:0] == 7'h57));
    if (packet_set) begin
      assert (exmem_pc == packet_pc && exmem_instr == packet_insn);
      assert (exmem_rd == packet_insn[11:7] && exmem_regwrite);
      assert (exmem_wbval == 32'(model_vl));
    end
    cover (send_element && elem == 1 && formal_vec_width == 0);
    cover (send_element && elem == 1 && formal_vec_width == 1);
    cover (send_element && elem == 1 && formal_vec_width == 2);
    cover (advance && want_mem && ex_trap);
    cover (send_empty);
  end
end
