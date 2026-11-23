// roco_cpu: pipelined RV32I processor core.
//
// Five stages, each in its own module:
//   roco_cpu_if_stage   program counter, fetch handshake, IF/ID register
//   roco_cpu_id_stage   decode, register file, ID/EX register
//   roco_cpu_ex_stage   ALU, forwarding, branches, traps, CSR file, EX/MEM
//   roco_cpu_mem_stage  data memory request, load alignment, MEM/WB register
//   roco_cpu_wb_stage   register-file write data and retire trace
//   roco_cpu_branch_predictor  bimodal predictor and BTB
//   roco_cpu_mmu        Sv32 TLBs and hardware page-table walker
//
// Branches and jumps resolve in EX. A registered redirect reaches fetch
// one cycle later and cancels the younger EX instruction. Full EX/MEM
// and MEM/WB forwarding is used. Data lookups occur in EX and commit in
// MEM; cache misses hold MEM until the requested word is ready. Fetch
// responses carry addresses so redirected stale responses are ignored.
//
// Implemented: RV32I base integer instructions, Zicsr, M/S/U privilege
// modes, trap delegation, Sv32 virtual memory, and traps for illegal
// instructions, ECALL/EBREAK, misaligned addresses and page faults.
// Machine timer/external and software interrupts are supported.

`include "axi4_defs.svh"
`include "roco_rvfi.svh"
`default_nettype none

module roco_cpu #(
    parameter int HART_ID = 0
) (
`ifdef ROCO_SOC_FETCH_MEMORY_FORMAL
  input logic [22:0] formal_watch_word,
  input logic [31:0] formal_watch_data,
  input logic formal_instruction_coherent,
`endif
`ifdef ROCO_VECTOR_MEM_STREAM
  input logic [1:0] formal_vec_width,
`endif
`ifdef ROCO_RVFI
  output logic rvfi_valid,
  output logic [63:0] rvfi_order,
  output logic [31:0] rvfi_insn,
  output logic rvfi_trap,
  rvfi_halt,
  rvfi_intr,
  output logic [1:0] rvfi_mode,
  rvfi_ixl,
  output logic [4:0] rvfi_rs1_addr,
  rvfi_rs2_addr,
  rvfi_rd_addr,
  output logic [31:0] rvfi_rs1_rdata,
  rvfi_rs2_rdata,
  rvfi_rd_wdata,
  output logic [31:0] rvfi_pc_rdata,
  rvfi_pc_wdata,
  output logic [31:0] rvfi_mem_addr,
  rvfi_mem_rdata,
  rvfi_mem_wdata,
  output logic [3:0] rvfi_mem_rmask,
  rvfi_mem_wmask,
`ifdef ROCO_RVFI_GPR_STATE
  input logic [4:0] rvfi_gpr_watch_addr,
  output logic [31:0] rvfi_gpr_watch_value,
`ifdef ROCO_RVFI_FORWARD_CHECKS
  output logic [31:0] rvfi_gpr_hist_value,
`endif
`endif
`ifdef ROCO_ATOMIC_STREAM_CHECKS
  output logic formal_res_valid,
  output logic [29:0] formal_res_word,
  output logic formal_amo_ready,
`endif
`ifdef ROCO_RVFI_DIV_CHECKS
  output logic rvfi_div_start,
  rvfi_div_wb_valid,
  output logic [2:0] rvfi_div_op,
  output logic [4:0] rvfi_div_wb_rd,
  output logic [31:0] rvfi_div_a,
  rvfi_div_b,
  rvfi_div_wb_data,
`endif
`ifdef ROCO_RVFI_PC_CHECKS
  output logic [31:0] rvfi_oldest_pc,
  output logic rvfi_mem_regwrite,
`endif
`ifdef ROCO_RVFI_INSN_CHECKS
  output logic rvfi_fwd_trap_pending,
  output logic [3:0] rvfi_queue_live,
  output logic [127:0] rvfi_queue_insn,
  output logic rvfi_fwd_idex_valid,
  output logic rvfi_fwd_exmem_valid,
  output logic [31:0] rvfi_fwd_idex_instr,
  rvfi_fwd_exmem_instr,
  rvfi_fwd_exc_instr,
`endif
`endif
  input logic clk,
  input logic rst,
  input logic [31:0] boot_addr,
  input logic halt,
  /* Platform interrupt lines: machine timer and machine external. */
  input logic irq_timer,
  input logic irq_external,
  /* Physical instruction memory port: hold req/addr until rsp_valid. */
  output logic imem_req,
  output logic [31:0] imem_addr,
  input logic imem_rsp_valid,
  input logic [31:0] imem_rsp_addr,
  input logic [31:0] imem_rsp_data,
  input logic imem_miss,
  input logic imem_busy,
  /* Physical data memory: lookup in EX, commit in MEM. */
  output logic dmem_lu_valid,
  output logic [31:2] dmem_lu_addr,
  output logic [1:0] dmem_lu_offset,
  output logic [2:0] dmem_lu_funct3,
  input logic dmem_ready,
  output logic dmem_req,  // Ready-qualified commit strobe.
  output logic dmem_valid,  // In-order read/write validity, excluding failed SC.
  output logic dmem_amo_read,  // Atomic read phase for uncached targets.
`ifdef ROCO_SOC_RAM_FORMAL
  output logic f_mem_packet,
`endif
  output logic dmem_we,
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0] dmem_be,
  input logic [31:0] dmem_rsp_data,
  /* Already aligned cached-load value, registered with the EX lookup. */
  input logic [31:0] dmem_forward_data,
  /* Physical page-table walker port. */
  input logic ptw_bus_rst,
  output axi4_ar_t ptw_ar,
  input logic ptw_ready,
  input axi4_r_t ptw_r,
  output logic ptw_r_ready,
  /* Retire trace, for simulation only. */
  output logic trace_valid,
  output logic [31:0] trace_pc,
  output logic [31:0] trace_instr,
  output logic [4:0] trace_rd,
  output logic [31:0] trace_wdata,
  output logic fence_req,
  input logic fence_done,
  /* SMP reservation snooping: publish committed stores, accept remote clear. */
  output logic res_store_valid,
  output logic [29:0] res_store_addr,
  input logic res_remote_valid,
  input logic [29:0] res_remote_addr
);

  logic if_valid;
  logic [31:0] if_pc;
  logic [31:0] if_instr;
  logic if_pred_taken;
  logic [31:0] if_pred_target;
  logic if_pred_direct;
  logic [20:0] if_pred_imm;
  logic [31:0] fetch_pc;
  logic pred_taken;
  logic [31:0] pred_target;
  logic pred_direct;
  logic [20:0] pred_imm;
  logic idex_pred_taken;
  logic idex_pred_target_match;
  logic [31:0] idex_pred_jalr_base;
  logic [31:0] idex_pred_jalr_carry;
  logic idex_pred_jalr_aligned;
  logic btb_update;
  logic btb_is_branch;
  logic btb_is_jal;
  logic btb_is_jalr;
  logic btb_taken;
  logic [31:0] btb_target;

  logic [4:0] dec_rs1;
  logic [4:0] dec_rs2;
  logic [4:0] dec_rd;
  logic dec_use_rs1;
  logic dec_use_rs2;
  logic dec_regwrite;
  logic dec_is_div;

  logic idex_valid;
  logic [3:0] idex_wb_select;
  logic [31:0] idex_pc;
  logic [31:0] idex_instr;
  logic [31:0] idex_rs1_val;
  logic [31:0] idex_rs2_val;
  logic idex_rs1_from_mem;
  logic idex_rs2_from_mem;
  logic idex_rs1_from_wb;
  logic idex_rs1_from_rf;
  logic [31:0] idex_imm;
  logic [4:0] idex_rs1;
  logic [4:0] idex_rd;
  logic [2:0] idex_funct3;
  logic [3:0] idex_alu_op;
  logic idex_is_muldiv;
  logic [2:0] idex_md_op;
  logic idex_is_div;
  logic [31:0] idex_alu_a_val, idex_alu_b_val;
  logic idex_alu_a_from_mem, idex_alu_b_from_mem;
  logic idex_regwrite;
  logic idex_is_load;
  logic idex_is_store;
  logic idex_is_amo;
  logic idex_is_lr;
  logic idex_is_sc;
  logic [4:0] idex_amo_op;
  logic idex_is_vec;
  logic idex_is_vset;
  logic idex_is_vload;
  logic idex_is_vstore;
  logic [5:0] idex_vec_funct6;
  logic idex_is_branch;
  logic idex_is_jal;
  logic idex_is_jalr;
  logic idex_is_csr;
  logic idex_csr_uimm;
  logic [1:0] idex_csr_op;
  logic [11:0] idex_csr_addr;
  logic idex_illegal;
  logic idex_ecall;
  logic idex_ebreak;
  logic idex_mret;
  logic idex_sret;
  logic idex_is_sfence;
  logic idex_is_fence_i;
  logic idex_ifault;
  logic if_fault;
  logic [1:0] priv;
  logic [31:0] satp;
  logic satp_write;
  logic [31:0] unused_imem_rsp_addr;
  assign unused_imem_rsp_addr = imem_rsp_addr;

  logic mmu_flush;
  logic mstatus_mprv;
  logic mstatus_sum;
  logic mstatus_mxr;
  logic unused_mstatus_tvm;
  logic unused_mstatus_tsr;
  logic [1:0] mstatus_mpp;
  logic mmu_sfence;

  // IF-side translation.
  logic if_imem_req;
  logic [31:0] if_imem_addr;
  logic if_imem_rsp_valid;
  logic [31:0] if_imem_rsp_addr;
  logic [31:0] if_imem_rsp_data;
  logic if_imem_miss;
  logic cache_request_live_q, cache_miss_live;
  logic if_imem_busy;
  logic if_imem_fault;
  logic [31:0] if_imem_fault_addr;
  logic mmu_ic_req;
  logic [31:0] mmu_ic_addr;
  logic mmu_i_hit;
  logic mmu_i_miss;
  logic mmu_i_busy;
  logic mmu_i_fault;
  logic [31:0] mmu_i_fault_addr;
  logic mmu_i_rsp_valid;
  logic [31:0] mmu_i_rsp_addr;
  logic [31:0] mmu_i_rsp_data;

  // Data-side translation.
  logic [31:0] ex_lu_vaddr;
  logic ex_lu_we;
  logic mmu_d_hit;
  logic mmu_d_fault;
  logic d_fault_q;
  logic [3:0] d_fault_cause_q;
  logic [3:0] mmu_d_fault_cause;
  logic [31:0] mmu_d_paddr;
  logic ex_lu_hit;
  logic [1:0] priv_data;

  logic ex_redirect_en, ex_redirect_raw;
  logic [31:0] ex_redirect_pc, redirect_base_raw, redirect_offset_raw;
  logic [31:0] redirect_base_q, redirect_offset_q, redirect_sum;
  logic redirect_fallthrough_raw, redirect_mask_raw;
  logic redirect_fallthrough_q, redirect_mask_q;


  logic exmem_valid;
  logic [31:0] exmem_pc;
  logic [31:0] exmem_instr;
  logic [31:0] exmem_alu;
  logic [31:0] exmem_wbval;
  logic [31:0] exmem_store_data;
  logic [3:0] exmem_be;
  logic [4:0] exmem_rd;
  logic [2:0] exmem_funct3;
  logic exmem_regwrite;
  logic exmem_is_load;
  logic exmem_forward_cache, exmem_forward_wbval;
  logic exmem_is_store;
  logic exmem_is_amo;
  logic exmem_is_lr;
  logic exmem_is_sc;
  logic [4:0] exmem_amo_op;
  logic ex_trap_taken;
  logic vec_mem_hold;
  logic exmem_is_mul;
  logic exmem_mul_hi;
  logic [63:0] exmem_mul_sum;
  logic [63:0] exmem_mul_carry;
  logic idex_is_mul;
  logic mul_conflict;
  logic exmem_vec_we;
  logic [127:0] exmem_vec_data;
  logic vec_full_write;
  logic [127:0] vec_rf_vs1_data, vec_rf_vs2_data, vec_rf_vd_data;
  logic [127:0] vec_vs1_data;
  logic [127:0] vec_vs2_data;
  logic [127:0] vec_vd_data;
  logic exmem_is_vload;
  logic exmem_is_vstore;
  logic [3:0] exmem_vec_elem;
  logic exmem_vec_last;
  logic [2:0] exmem_vec_sew;
  logic vec_mem_we;
  logic [4:0] vec_mem_wd;
  logic [3:0] vec_mem_elem;
  logic [2:0] vec_mem_sew;
  logic [31:0] vec_mem_wdata;
  logic vec_element_commit;
  logic exmem_is_sfence;
  logic exmem_is_fence_i;

  logic memwb_valid;
  logic [31:0] memwb_data;
  logic [4:0] memwb_rd;
  logic memwb_regwrite;

  logic wb_we;
  logic [4:0] wb_rd;
  logic [31:0] wb_data;

  logic div_busy;
  logic div_conflict;
  logic bubble;
  logic load_dependency;
  logic [4:0] div_rd;
  logic [4:0] div_pending_rd;
  logic div_wb_en;
  logic [4:0] div_wb_rd;
  logic [31:0] div_wb_data;
  logic dmem_lu_stall;
  logic mem_wait;
  logic stall;
  logic ex_lu_valid;
  logic ex_lu_present;
  logic mem_redirect;
  logic retire;
  logic if_consume;
  logic commit_valid;
  logic [31:0] commit_pc;
  logic [31:0] commit_instr;
  logic [4:0] commit_rd;
  logic [31:0] commit_wdata;
  logic [31:0] mem_forward_data;

  assign retire = commit_valid && !vec_element_commit;
  // Registered EX results forward into EX. Memory results interlock
  // in ID so cache read and alignment routing end at the ID/EX register.
  // Register EX redirects before distributing them through the front end.
  // The pending redirect cancels the one younger EX instruction below.
  always_ff @(posedge clk) begin
    redirect_base_q <= redirect_base_raw;
    redirect_offset_q <= redirect_offset_raw;
    redirect_fallthrough_q <= redirect_fallthrough_raw;
    redirect_mask_q <= redirect_mask_raw;
  end
  roco_cpu_addsub u_redirect_add (
      .a(redirect_base_q),
      .b(redirect_fallthrough_q ? 32'd4 : redirect_offset_q),
      .subtract(1'b0),
      .result(redirect_sum)
  );
  assign ex_redirect_pc = {redirect_sum[31:1], redirect_sum[0] && !redirect_mask_q};

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      ex_redirect_en <= 1'b0;
    end else if (mem_redirect) begin
      ex_redirect_en <= 1'b0;
    end else begin
      ex_redirect_en <= ex_redirect_raw;
    end
  end

  assign if_consume = if_valid && !stall && !bubble && !ex_redirect_en && !mem_redirect;
  // One translation token separates TLB lookup from cache lookup. EX
  // retains its request until consuming the token, including each vector
  // element, so no wide address comparison belongs on frontend hold.
  logic translated_valid_q, lookup_translate_q;
  logic [31:0] translated_paddr_q, lookup_paddr;
  // Address preparation already supplies a register boundary in bare/M
  // mode. Capture the translation mode with that preparation and only
  // require a token when Sv32 permissions/PPN selection are active.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) lookup_translate_q <= 1'b0;
    else lookup_translate_q <= satp[31] && (priv_data != 2'b11);
  end
  always_ff @(posedge clk) begin
    if (!translated_valid_q) translated_paddr_q <= mmu_d_paddr;
  end
  always_ff @(posedge clk or posedge rst) begin
    if (rst) translated_valid_q <= 1'b0;
    else if (!lookup_translate_q || mmu_flush || ex_redirect_en || mem_redirect)
      translated_valid_q <= 1'b0;
    else if (translated_valid_q) begin
      if (ex_lu_valid && !d_fault_q) translated_valid_q <= 1'b0;
    end else translated_valid_q <= ex_lu_valid && mmu_d_hit;
  end
  assign ex_lu_hit = !lookup_translate_q || translated_valid_q;
  // Sv32 translates the page number, not the page offset. Take the
  // offset directly from the prepared EX address in both modes.
  assign lookup_paddr = {
    lookup_translate_q ? translated_paddr_q[31:12] : ex_lu_vaddr[31:12], ex_lu_vaddr[11:0]
  };
  assign dmem_lu_valid = ex_lu_valid && ex_lu_hit;
  assign dmem_lu_addr = lookup_paddr[31:2];
  assign dmem_lu_offset = lookup_paddr[1:0];
  assign dmem_lu_funct3 = idex_funct3;
`ifdef ROCO_SOC_MMIO_FORMAL
  // A held SC cannot turn into a different kind of memory transaction.
  always_ff @(posedge clk) begin
    if (!rst && idex_valid && idex_is_sc)
      assert (!(idex_is_store || idex_is_amo || idex_is_vstore));
    if (!rst && exmem_valid && exmem_is_sc)
      assert (!(exmem_is_store || exmem_is_amo || exmem_is_vstore));
  end
`endif
`ifdef ROCO_SOC_DC_CLIENT_FORMAL
  // Decode classes must remain exclusive even when ID/EX is held for an
  // arbitrarily long translation or memory wait. Assert these facts rather
  // than constraining the pipeline state at the induction boundary.
  always_ff @(posedge clk) begin
    if (!rst && idex_valid && (idex_is_vload || idex_is_vstore))
      assert (!(idex_is_load || idex_is_store || idex_is_amo || idex_is_lr || idex_is_sc));
    if (!rst && idex_valid && (idex_is_load || idex_is_store || idex_is_amo ||
        idex_is_lr || idex_is_sc || idex_is_vload || idex_is_vstore)) begin
      assert (!(idex_is_branch || idex_is_jal || idex_is_jalr || idex_is_csr ||
                idex_ecall || idex_ebreak || idex_mret || idex_sret ||
                idex_is_sfence || idex_is_fence_i || idex_is_vec));
    end
  end
`endif
`ifdef ROCO_SOC_RAM_FORMAL
  // Observe the owning MEM packet even on cycles when AMO preparation or
  // a core halt suppresses the externally visible dmem_valid.
  assign f_mem_packet = exmem_valid && (exmem_is_load || exmem_is_store || exmem_is_amo ||
                        exmem_is_lr || exmem_is_sc || exmem_is_vload || exmem_is_vstore);
  always_ff @(posedge clk) begin
    if (!rst && exmem_valid && (exmem_is_fence_i || exmem_is_sfence)) assert (!f_mem_packet);
  end
`endif
  // Hold the faulting instruction while registering the MMU response.
  // Trap delegation and fetch redirection then start from a register.
  // MEM holds already stall the pipeline directly. Qualify an EX
  // translation wait without routing that same hold through lookup enable.
  assign dmem_lu_stall = ex_lu_present && !d_fault_q && !ex_lu_hit;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      d_fault_q <= 1'b0;
      d_fault_cause_q <= '0;
    end else begin
      // Only a request still waiting for a translation can take a data
      // fault on the next cycle. A completed lookup releases ID/EX.
      d_fault_q <= mmu_d_fault && !ex_lu_hit;
      d_fault_cause_q <= mmu_d_fault_cause;
    end
  end
  // The divider runs decoupled: only an instruction that needs the
  // pending destination register waits for it, and a second divide waits
  // in ID so the execute stage never has to stall on the divider.
  assign div_pending_rd = div_busy ? div_rd : idex_rd;
  assign div_conflict = if_valid && (div_busy || (idex_valid && idex_is_div)) &&
                        (dec_is_div ||
                         ((div_pending_rd != 5'd0) &&
                          ((dec_use_rs1 && (dec_rs1 == div_pending_rd)) ||
                           (dec_use_rs2 && (dec_rs2 == div_pending_rd)) ||
                           (dec_regwrite && (dec_rd == div_pending_rd)))));
  // Wait one cycle for memory producers before decoding a dependent
  // instruction. ID captures the final MEM value; EX forwarding then
  // starts at EX/MEM flops instead of the cache read and alignment muxes.
  assign load_dependency = idex_valid &&
                               (idex_is_load || idex_is_lr || idex_is_amo || idex_is_sc) &&
                               (idex_rd != 5'd0) && if_valid &&
                               ((dec_use_rs1 && dec_rs1 == idex_rd) ||
                                (dec_use_rs2 && dec_rs2 == idex_rd));
  // A multiply keeps only the carry-save terms in EX; the 64-bit carry
  // propagation completes in MEM. A dependent instruction therefore waits
  // one cycle and then bypasses the MEM result from ID. Only an immediate
  // dependency needs the bubble.
  assign mul_conflict = if_valid && idex_valid && idex_is_mul && (idex_rd != 5'd0) &&
                        ((dec_use_rs1 && (dec_rs1 == idex_rd)) ||
                         (dec_use_rs2 && (dec_rs2 == idex_rd)));
  // CSR writes apply with their MEM packet. Leave one bubble before a
  // younger instruction can consume privilege/vector/CSR state.
  logic csr_write_conflict;
  assign csr_write_conflict = if_valid && idex_valid && idex_is_csr &&
                              ((idex_csr_op == 2'd0) || (idex_rs1 != 5'd0));
  logic instret_decode, instret_conflict;
  assign instret_decode = (if_instr[6:0] == 7'b1110011) && (if_instr[14:12] != 3'd0) &&
                           ((if_instr[31:20] == 12'hb02) ||
                            (if_instr[31:20] == 12'hb82) ||
                            (if_instr[31:20] == 12'hc02));
  // Read the retirement counter only after all older MEM events have
  // updated it. Other CSR accesses retain their normal issue timing.
  assign instret_conflict = if_valid && instret_decode && (idex_valid || exmem_valid);
  logic mem_result_late, mem_result_dependency;
  assign mem_result_late = exmem_is_load || exmem_is_lr || exmem_is_amo || exmem_is_sc || exmem_is_mul;
  assign mem_result_dependency = if_valid && exmem_valid && exmem_regwrite &&
                                  mem_result_late && (exmem_rd != 5'd0) &&
                                  ((dec_use_rs1 && dec_rs1 == exmem_rd) ||
                                   (dec_use_rs2 && dec_rs2 == exmem_rd));
  assign bubble = div_conflict || load_dependency || mul_conflict || csr_write_conflict ||
                  instret_conflict || mem_result_dependency;
  assign stall = dmem_lu_stall || fence_req || mem_wait || vec_mem_hold;
  assign priv_data = mstatus_mprv ? mstatus_mpp : priv;
  assign idex_is_div = idex_is_muldiv && idex_md_op[2];
  assign idex_is_mul = idex_is_muldiv && !idex_md_op[2];
`ifdef ROCO_SOC_FENCE_FORMAL
  function automatic logic fence_i_word(input logic [31:0] instr);
    fence_i_word = instr[6:0] == 7'h0f && instr[14:12] == 3'd1;
  endfunction
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (idex_valid) begin
        assert (idex_is_fence_i == fence_i_word(idex_instr));
        if (idex_is_fence_i) assert (!(idex_is_vload || idex_is_vstore));
      end
      if (exmem_valid) assert (exmem_is_fence_i == fence_i_word(exmem_instr));
    end
  end
`endif
  assign trace_valid = retire;
  assign trace_pc = commit_pc;
  assign trace_instr = commit_instr;
  assign trace_rd = commit_rd;
  assign trace_wdata = commit_wdata;

  logic [31:0] fetch_oldest_pc;
`ifdef ROCO_SOC_RETIRE_MEMORY_FORMAL
  logic f_head_watch, f_sync_capture, f_sync_pending;
`endif
  roco_cpu_if_stage u_if (
`ifdef ROCO_SOC_RETIRE_MEMORY_FORMAL
      .formal_head_watch(f_head_watch),
`endif
`ifdef ROCO_SOC_FETCH_MEMORY_FORMAL
      .formal_response_watch(if_imem_rsp_valid && imem_rsp_addr[31:2] == {7'd8, formal_watch_word}),
      .formal_watch_data(formal_watch_data),
      .formal_coherent(f_fetch_coherent),
`endif
`ifdef ROCO_VECTOR_MEM_STREAM
      .formal_vec_width(formal_vec_width),
`endif
      .oldest_pc(fetch_oldest_pc),
`ifdef ROCO_RVFI_INSN_CHECKS
      .rvfi_queue_live(rvfi_queue_live),
      .rvfi_queue_insn(rvfi_queue_insn),
`endif
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .boot_addr(boot_addr),
      // Queue capacity, not backend readiness, throttles instruction fetch.
      .stall(1'b0),
      .flush(ex_redirect_en || mem_redirect),
      .pred_taken(pred_taken),
      .pred_target(pred_target),
      .pred_direct(pred_direct),
      .pred_imm(pred_imm),
      .if_consume(if_consume),
      .redirect_pc(mem_redirect ? (exmem_pc + 32'd4) : ex_redirect_pc),
      .imem_req(if_imem_req),
      .imem_addr(if_imem_addr),
      .imem_rsp_valid(if_imem_rsp_valid),
      .imem_rsp_addr(if_imem_rsp_addr),
      .imem_rsp_data(if_imem_rsp_data),
      .imem_miss(if_imem_miss),
      .imem_retry_previous(cache_miss_live),
      .imem_miss_addr(mmu_i_rsp_addr),
      .imem_busy(if_imem_busy),
      .imem_fault(if_imem_fault),
      .imem_fault_addr(if_imem_fault_addr),
      .if_valid(if_valid),
      .if_pc(if_pc),
      .if_instr(if_instr),
      .if_fault(if_fault),
      .if_pred_taken(if_pred_taken),
      .if_pred_target(if_pred_target),
      .if_pred_direct(if_pred_direct),
      .if_pred_imm(if_pred_imm),
      .fetch_pc(fetch_pc)
  );

  roco_cpu_id_stage u_id (
`ifdef ROCO_RVFI_PC_CHECKS
      .rvfi_idex_rs1(rvfi_idex_rs1),
      .rvfi_idex_rs2(rvfi_idex_rs2),
`elsif ROCO_M_STREAM_CHECKS
      .rvfi_idex_rs1(rvfi_idex_rs1),
      .rvfi_idex_rs2(rvfi_idex_rs2),
`elsif ROCO_SOC_ISA_MEMORY_FORMAL
      .rvfi_idex_rs1(rvfi_idex_rs1),
      .rvfi_idex_rs2(rvfi_idex_rs2),
`elsif ROCO_SOC_GPR_FORWARD_FORMAL
      .rvfi_idex_rs1(rvfi_idex_rs1),
      .rvfi_idex_rs2(rvfi_idex_rs2),
`endif
`ifdef ROCO_RVFI_GPR_STATE
      .rvfi_gpr_watch_addr(rvfi_gpr_watch_addr),
      .rvfi_gpr_watch_value(rvfi_gpr_watch_value),
`endif
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .if_valid(if_valid),
      .if_pc(if_pc),
      .if_instr(if_instr),
      .if_fault(if_fault),
      .if_pred_taken(if_pred_taken),
      .if_pred_target(if_pred_target),
      .if_pred_direct(if_pred_direct),
      .if_pred_imm(if_pred_imm),
      .hold(stall),
      .bubble(bubble),
      .flush(ex_redirect_en || mem_redirect),
      .exmem_valid(exmem_valid),
      .exmem_regwrite(exmem_regwrite && !mem_result_late),
      .exmem_rd(exmem_rd),
      .mem_wb_data(exmem_wbval),
      .wb_we(wb_we),
      .wb_rd(wb_rd),
      .wb_data(wb_data),
      .div_we(div_wb_en),
      .div_rd(div_wb_rd),
      .div_data(div_wb_data),
      .dec_rs1(dec_rs1),
      .dec_rs2(dec_rs2),
      .dec_rd(dec_rd),
      .dec_use_rs1(dec_use_rs1),
      .dec_use_rs2(dec_use_rs2),
      .dec_regwrite(dec_regwrite),
      .dec_is_div(dec_is_div),
      .idex_valid(idex_valid),
      .idex_wb_select(idex_wb_select),
      .idex_pc(idex_pc),
      .idex_instr(idex_instr),
      .idex_pred_taken(idex_pred_taken),
      .idex_pred_target_match(idex_pred_target_match),
      .idex_pred_jalr_base(idex_pred_jalr_base),
      .idex_pred_jalr_carry(idex_pred_jalr_carry),
      .idex_pred_jalr_aligned(idex_pred_jalr_aligned),
      .idex_rs1_val(idex_rs1_val),
      .idex_rs2_val(idex_rs2_val),
      .idex_rs1_from_mem(idex_rs1_from_mem),
      .idex_rs2_from_mem(idex_rs2_from_mem),
      .idex_rs1_from_wb(idex_rs1_from_wb),
      .idex_rs1_from_rf(idex_rs1_from_rf),
      .idex_imm(idex_imm),
      .idex_rs1(idex_rs1),
      .idex_rd(idex_rd),
      .idex_funct3(idex_funct3),
      .idex_alu_op(idex_alu_op),
      .idex_is_muldiv(idex_is_muldiv),
      .idex_md_op(idex_md_op),
      .idex_alu_a_val(idex_alu_a_val),
      .idex_alu_b_val(idex_alu_b_val),
      .idex_alu_a_from_mem(idex_alu_a_from_mem),
      .idex_alu_b_from_mem(idex_alu_b_from_mem),
      .idex_regwrite(idex_regwrite),
      .idex_is_load(idex_is_load),
      .idex_is_store(idex_is_store),
      .idex_is_amo(idex_is_amo),
      .idex_is_lr(idex_is_lr),
      .idex_is_sc(idex_is_sc),
      .idex_amo_op(idex_amo_op),
      .idex_is_vec(idex_is_vec),
      .idex_is_vset(idex_is_vset),
      .idex_is_vload(idex_is_vload),
      .idex_is_vstore(idex_is_vstore),
      .idex_vec_funct6(idex_vec_funct6),
      .idex_is_branch(idex_is_branch),
      .idex_is_jal(idex_is_jal),
      .idex_is_jalr(idex_is_jalr),
      .idex_is_csr(idex_is_csr),
      .idex_csr_uimm(idex_csr_uimm),
      .idex_csr_op(idex_csr_op),
      .idex_csr_addr(idex_csr_addr),
      .idex_illegal(idex_illegal),
      .idex_ecall(idex_ecall),
      .idex_ebreak(idex_ebreak),
      .idex_ifault(idex_ifault),
      .idex_mret(idex_mret),
      .idex_sret(idex_sret),
      .idex_is_sfence(idex_is_sfence),
      .idex_is_fence_i(idex_is_fence_i)
  );

`ifdef ROCO_RVFI
  logic [4:0] rvfi_idex_rs1, rvfi_idex_rs2;
  logic rvfi_trap_entry, rvfi_sync_exception, rvfi_handler_pending;
  logic [31:0] rvfi_trap_vector;
  roco_rvfi_meta_t rvfi_exmem, rvfi_exception, rvfi_report;

  // Mirror ID/EX advancement. Bubbles and flushes invalidate the payload.
  // Reset like the ID/EX payload: without it an arbitrary induction state
  // can surface stale indices when reset drops while stalled.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      rvfi_idex_rs1 <= 5'd0;
      rvfi_idex_rs2 <= 5'd0;
    end else if (!halt && !stall) begin
      rvfi_idex_rs1 <= dec_use_rs1 ? dec_rs1 : 5'd0;
      rvfi_idex_rs2 <= dec_use_rs2 ? dec_rs2 : 5'd0;
    end
  end

  // Exceptions enter after older MEM work drains. IRQ entry itself is not
  // an instruction; flag the first subsequent event instead.
  assign rvfi_valid = !rst && (retire || rvfi_sync_exception);
  assign rvfi_report = rvfi_sync_exception ? rvfi_exception : rvfi_exmem;
  assign rvfi_trap = rvfi_sync_exception;
  assign rvfi_halt = 1'b0;  // External halt pauses, rather than terminates, execution.
  assign rvfi_intr = rvfi_handler_pending;
  assign rvfi_mode = rvfi_report.mode;
  assign rvfi_ixl = 2'd1;
  assign rvfi_insn = rvfi_sync_exception ? rvfi_exception.instr : commit_instr;
  assign rvfi_pc_rdata = rvfi_sync_exception ? rvfi_exception.pc : commit_pc;
  assign rvfi_pc_wdata = rvfi_sync_exception ? rvfi_trap_vector : rvfi_report.next_pc;
  assign rvfi_rs1_addr = rvfi_report.rs1;
  assign rvfi_rs2_addr = rvfi_report.rs2;
  assign rvfi_rs1_rdata = rvfi_report.rs1_data;
  assign rvfi_rs2_rdata = rvfi_report.rs2_data;
  assign rvfi_rd_addr = retire && !rvfi_trap && exmem_regwrite ? commit_rd : 5'd0;
  assign rvfi_rd_wdata = rvfi_rd_addr != 0 ? commit_wdata : 32'd0;

  // Aligned RVFI convention: virtual word address with native byte lanes.
  // Vector memory spans multiple transactions and is outside this interface's
  // scalar memory contract. An unsuccessful SC has no memory effect.
  assign rvfi_mem_addr = {rvfi_report.vaddr[31:2], 2'b00};
  always_comb begin
    rvfi_mem_rmask = 4'd0;
    if (!rvfi_trap && dmem_req) begin
      if (exmem_is_load) begin
        case (exmem_funct3[1:0])
          2'd0: rvfi_mem_rmask = 4'b0001 << rvfi_report.vaddr[1:0];
          2'd1: rvfi_mem_rmask = 4'b0011 << rvfi_report.vaddr[1:0];
          default: rvfi_mem_rmask = 4'b1111;
        endcase
      end else if (exmem_is_lr || exmem_is_amo) rvfi_mem_rmask = 4'b1111;
    end
  end
  assign rvfi_mem_wmask = !rvfi_trap && dmem_req && dmem_we &&
                         (exmem_is_store || exmem_is_sc || exmem_is_amo) ? dmem_be : 4'd0;
  assign rvfi_mem_rdata = rvfi_mem_rmask == 0 ? 32'd0 : exmem_is_amo ? commit_wdata : dmem_rsp_data;
  assign rvfi_mem_wdata = rvfi_mem_wmask == 0 ? 32'd0 : dmem_wdata;

`ifdef ROCO_RVFI_DIV_CHECKS
  assign rvfi_div_op = idex_md_op;
  assign rvfi_div_wb_valid = div_wb_en;
  assign rvfi_div_wb_rd = div_wb_rd;
  assign rvfi_div_wb_data = div_wb_data;
`endif

`ifdef ROCO_RVFI_FORWARD_CHECKS
  logic rvfi_fwd_mem_ready;
  logic rvfi_fwd_cancel;
  logic [31:0] rvfi_fwd_held_rs1, rvfi_fwd_held_rs2;
`endif

`ifdef ROCO_RVFI_PC_CHECKS
  logic [31:0] saved_target, idex_successor, frontend_pc, after_mem_pc;
  always @(posedge clk) begin
    if (if_consume) saved_target <= if_pred_target;
  end
  assign rvfi_mem_regwrite = exmem_regwrite;
  assign idex_successor = idex_pred_taken ? saved_target : idex_pc + 32'd4;
  assign frontend_pc = ex_redirect_en ? ex_redirect_pc : fetch_oldest_pc;
  assign after_mem_pc = !ex_redirect_en && idex_valid ? idex_pc : frontend_pc;
  assign rvfi_oldest_pc = rvfi_fwd_trap_pending ? rvfi_exception.pc :
                          exmem_valid ? exmem_pc : after_mem_pc;
  always @(posedge clk) begin
    if (!rst) begin
      assert (!mem_redirect && !d_fault_q);
      assert (retire == (exmem_valid && !mem_wait));
      assert (!(rvfi_fwd_trap_pending && ex_redirect_en));
      if (ex_redirect_en) assert (ex_redirect_pc[1:0] == 0);
      if (idex_valid) begin
        assert (!idex_ifault && !idex_is_csr);
        assert (idex_pc[1:0] == 0);
        if ((idex_is_branch || idex_is_jal) && idex_pred_taken && idex_pred_target_match)
          assert (saved_target == idex_pc + idex_imm);
        if (idex_pred_jalr_aligned) begin
          assert (!saved_target[0]);
          assert (idex_pred_jalr_base[30:0] == saved_target[31:1] - idex_imm[31:1]);
          assert (idex_pred_jalr_carry[30:0] == idex_pred_jalr_base[30:0] - 31'd1);
        end
        if (!ex_redirect_en && !rvfi_fwd_trap_pending) begin
          assert (idex_successor == fetch_oldest_pc);
          // EX cannot depend on the live data of a long-latency MEM
          // producer; ID must have inserted the dependency bubble.
          if (!rvfi_fwd_mem_ready && (idex_rs1_from_mem || idex_rs2_from_mem))
            assert (exmem_valid && exmem_regwrite && !mem_result_late);
        end
      end
      if (exmem_valid) begin
        assert (rvfi_exmem.next_pc == after_mem_pc);
        if (rvfi_exmem.rs1 == 0) assert (rvfi_exmem.rs1_data == 0);
        if (rvfi_exmem.rs2 == 0) assert (rvfi_exmem.rs2_data == 0);
        assert (exmem_is_load == (exmem_instr[6:0] == 7'h03));
        assert (exmem_is_store == (exmem_instr[6:0] == 7'h23));
`ifdef ROCO_ATOMIC_STREAM_CHECKS
        assert (exmem_is_lr == (exmem_instr[6:0] == 7'h2f && exmem_instr[31:27] == 2));
        assert (exmem_is_sc == (exmem_instr[6:0] == 7'h2f && exmem_instr[31:27] == 3));
        assert (exmem_is_amo == (exmem_instr[6:0] == 7'h2f && !exmem_is_lr && !exmem_is_sc));
        if (exmem_is_lr || exmem_is_sc || exmem_is_amo) begin
          assert (exmem_alu == rvfi_exmem.vaddr && exmem_alu[1:0] == 0);
          assert (exmem_funct3 == 2 && exmem_be == 4'hf);
          assert (exmem_amo_op == exmem_instr[31:27]);
        end
`endif
        if (exmem_is_load || exmem_is_store) begin
          // Preserve the subword offset and access width even while the
          // packet waits; the ISA model's reported address is word-aligned.
          assert (exmem_alu == rvfi_exmem.vaddr);
          assert (exmem_funct3 == exmem_instr[14:12]);
          assert (exmem_alu[1:0] == rvfi_exmem.rs1_data[1:0] +
                  (exmem_is_load ? exmem_instr[21:20] : exmem_instr[8:7]));
        end
      end
      // Exercise recovery from a stale taken prediction on a store.
      cover (rvfi_valid && ex_redirect_en && $past(
          idex_pred_taken && idex_is_store
      ) && |rvfi_mem_wmask);
`ifdef ROCO_RVFI_STALL_CHECKS
      cover ($past(ex_redirect_en && mem_wait && exmem_is_store) && retire && dmem_req);
`endif
    end
  end
`endif

`ifdef ROCO_RVFI_GPR_WRITEBACK_CHECKS
  // In the always-running RV32I harness, each reported write matches the
  // scalar WB-stage output on the next cycle. Check that the divider
  // cannot take the shared register-file port on that cycle.
  logic writes_gpr;
  assign writes_gpr = rvfi_valid && !rvfi_trap && rvfi_rd_addr != 0;
  always @(posedge clk) begin
    if (!rst && !$past(rst)) begin
      assert (!(wb_we && div_wb_en));
      assert ((wb_we && wb_rd != 0) == $past(writes_gpr));
      if ($past(writes_gpr))
        assert (wb_rd == $past(rvfi_rd_addr) && wb_data == $past(rvfi_rd_wdata));
    end
  end
`endif

`ifdef ROCO_RVFI_FORWARD_CHECKS
`ifndef ROCO_SOC_GPR_FORWARD_FORMAL
  // Inductive operand invariants for one watched architectural register.
  // All are asserted, never assumed, so the reachability engine proves them
  // together with the retirement property they support. fwd_hist0 is the
  // value after the most recent retirement; fwd_hist1 the value before it.
  // A live EX packet that captured its operand without the MEM-forwarding
  // flag matches fwd_hist0, and the packet then in MEM cannot write the
  // watched register: the ID hazard logic bubbles or flags every such pair.
  // Held lookup operands and the EX/MEM and exception reports inherit the
  // same relation, and the physical file lags one retirement behind WB.
  logic [31:0] fwd_hist0, fwd_hist1;
  logic fwd_watched_write, fwd_mem_w, fwd_watch_nonzero;
  assign fwd_watched_write = rvfi_valid && !rvfi_trap && rvfi_rd_addr != 0 &&
                             rvfi_rd_addr == rvfi_gpr_watch_addr;
  assign fwd_mem_w = exmem_valid && exmem_regwrite && exmem_rd == rvfi_gpr_watch_addr;
  assign fwd_watch_nonzero = rvfi_gpr_watch_addr != 0;
  assign rvfi_gpr_hist_value = fwd_hist0;
`ifdef ROCO_M_STREAM_CHECKS
  logic fwd_div_write;
  assign fwd_div_write = div_wb_en && div_wb_rd == rvfi_gpr_watch_addr;
  `include "m_stream_checks.svh"
`endif
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      fwd_hist0 <= '0;
      fwd_hist1 <= '0;
    end else begin
`ifdef ROCO_M_STREAM_CHECKS
      fwd_hist1 <= fwd_div_write ? div_wb_data : fwd_hist0;
      if (fwd_div_write) fwd_hist0 <= div_wb_data;
      else if (fwd_watched_write) fwd_hist0 <= rvfi_rd_wdata;
`else
      fwd_hist1 <= fwd_hist0;
      if (fwd_watched_write) fwd_hist0 <= rvfi_rd_wdata;
`endif
    end
  end
  always @(posedge clk) begin
    if (!rst) begin
      // Under the restricted fetch set this job uses, the translation base
      // and mode registers cannot enable translation, and only plain
      // FENCE appears. No translation retry or FENCE.I/SFENCE hold occurs.
      assert (!dmem_lu_stall && !fence_req);
      // The fetch set contains no privilege return and no CSR access to the
      // translation base or mode registers, so the core stays in M mode and
      // data translation stays disabled. The divider never launches, so its
      // destination tag stays at zero and a stale completion cannot take the
      // shared register-file port.
      assert (priv == 2'b11);
      assert (!(satp[31] && priv_data != 2'b11));
`ifndef ROCO_M_STREAM_CHECKS
      assert (div_rd == 0);
`endif
      // The excluded encoding classes cannot appear in live pipeline state
      // either: the queue invariants hold for accepted fetch words, and the
      // stage registers inherit them one edge later.
      if (idex_valid) begin
        assert (!idex_is_vec && !idex_is_vset && !idex_is_vload && !idex_is_vstore);
`ifndef ROCO_M_STREAM_CHECKS
        assert (!idex_is_mul);
`endif
`ifndef ROCO_ATOMIC_STREAM_CHECKS
        assert (!idex_is_amo && !idex_is_lr && !idex_is_sc);
`endif
        assert (!idex_is_sfence && !idex_is_fence_i && !idex_mret && !idex_sret);
        assert (!(idex_is_csr &&
                  (idex_csr_addr == 12'h180 || idex_csr_addr == 12'h300 ||
                   idex_csr_addr == 12'h302 || idex_csr_addr == 12'h303 ||
                   idex_csr_addr == 12'h304 || idex_csr_addr == 12'h344)));
      end
      if (exmem_valid) begin
        assert (!exmem_is_vload && !exmem_is_vstore);
`ifndef ROCO_M_STREAM_CHECKS
        assert (!exmem_is_mul);
`endif
`ifndef ROCO_ATOMIC_STREAM_CHECKS
        assert (!exmem_is_amo && !exmem_is_lr && !exmem_is_sc);
`endif
      end
      if (wb_we && fwd_watch_nonzero && wb_rd == rvfi_gpr_watch_addr) assert (wb_data == fwd_hist0);
      assert (rvfi_gpr_watch_value == fwd_hist1);
      // The scoreboard advanced past hist1 only through a retirement whose
      // write is landing at the WB port right now. This alignment closes
      // the storage invariant's own inductive step.
      assert (fwd_hist0 == fwd_hist1 ||
              (wb_we && fwd_watch_nonzero && wb_rd == rvfi_gpr_watch_addr));
      if (idex_valid && fwd_watch_nonzero && !idex_rs1_from_mem &&
          rvfi_idex_rs1 == rvfi_gpr_watch_addr) begin
        assert (idex_rs1_val == fwd_hist0);
        assert (!fwd_mem_w);
      end
      if (idex_valid && fwd_watch_nonzero && !idex_rs2_from_mem &&
          rvfi_idex_rs2 == rvfi_gpr_watch_addr) begin
        assert (idex_rs2_val == fwd_hist0);
        assert (!fwd_mem_w);
      end
      if (idex_valid && fwd_watch_nonzero && idex_rs1_from_mem && fwd_mem_w &&
          rvfi_idex_rs1 == rvfi_gpr_watch_addr)
        assert (mem_forward_data == commit_wdata);
      if (idex_valid && fwd_watch_nonzero && idex_rs2_from_mem && fwd_mem_w &&
          rvfi_idex_rs2 == rvfi_gpr_watch_addr)
        assert (mem_forward_data == commit_wdata);
      // A from-MEM capture reads its producer live out of MEM. While that
      // consumer is not itself waiting on a data lookup, the producer is
      // still the valid MEM packet: only the consumer's own lookup miss,
      // which switches it to its saved operands, can let MEM drain first.
      if (idex_valid && fwd_watch_nonzero && idex_rs1_from_mem &&
          !rvfi_fwd_mem_ready && !rvfi_fwd_cancel &&
          rvfi_idex_rs1 == rvfi_gpr_watch_addr)
        assert (fwd_mem_w);
      if (idex_valid && fwd_watch_nonzero && idex_rs2_from_mem &&
          !rvfi_fwd_mem_ready && !rvfi_fwd_cancel &&
          rvfi_idex_rs2 == rvfi_gpr_watch_addr)
        assert (fwd_mem_w);
      if (idex_valid && rvfi_fwd_mem_ready && !rvfi_fwd_cancel) begin
        // Scalar preparation waits for the previous MEM packet to drain.
        // This also holds when the prepared address will take a trap.
        assert (!exmem_valid);
        if (fwd_watch_nonzero && rvfi_idex_rs1 == rvfi_gpr_watch_addr)
          assert (rvfi_fwd_held_rs1 == fwd_hist0);
        if (fwd_watch_nonzero && rvfi_idex_rs2 == rvfi_gpr_watch_addr)
          assert (rvfi_fwd_held_rs2 == fwd_hist0);
      end
      if (exmem_valid && fwd_watch_nonzero && rvfi_exmem.rs1 == rvfi_gpr_watch_addr)
        assert (rvfi_exmem.rs1_data == fwd_hist0);
      if (exmem_valid && fwd_watch_nonzero && rvfi_exmem.rs2 == rvfi_gpr_watch_addr)
        assert (rvfi_exmem.rs2_data == fwd_hist0);
      if (rvfi_sync_exception && fwd_watch_nonzero && rvfi_exception.rs1 == rvfi_gpr_watch_addr)
        assert (rvfi_exception.rs1_data == fwd_hist0);
      if (rvfi_sync_exception && fwd_watch_nonzero && rvfi_exception.rs2 == rvfi_gpr_watch_addr)
        assert (rvfi_exception.rs2_data == fwd_hist0);
      cover (idex_valid && idex_rs1_from_mem && rvfi_idex_rs1 == rvfi_gpr_watch_addr);
      cover (idex_valid && !idex_rs1_from_mem && rvfi_idex_rs1 == rvfi_gpr_watch_addr &&
             fwd_hist0 != 0);
      cover (idex_valid && rvfi_fwd_mem_ready && rvfi_idex_rs1 == rvfi_gpr_watch_addr);
      cover (exmem_valid && rvfi_exmem.rs1 == rvfi_gpr_watch_addr && rvfi_exmem.rs1_data != 0);
      cover (rvfi_sync_exception && rvfi_exception.rs1 == rvfi_gpr_watch_addr);
    end
  end
`endif
`endif

`ifdef ROCO_RVFI_INSN_CHECKS
  // Instruction-identity chain for the semantic job: every live pipeline
  // word stays within the fetch set the harness assumes at the response
  // interface, so the upstream models can decode each retirement.
  assign rvfi_fwd_idex_valid = idex_valid;
  assign rvfi_fwd_exmem_valid = exmem_valid;
  assign rvfi_fwd_idex_instr = idex_instr;
  assign rvfi_fwd_exmem_instr = exmem_instr;
  assign rvfi_fwd_exc_instr = rvfi_exception.instr;
`endif

`ifdef ROCO_RVFI_NO_DIV_INDUCTION
  always @(posedge clk) begin
    if (!rst) begin
      assert (!satp[31]);
      assert (!satp_write);
    end
  end
`endif

`ifdef ROCO_RVFI_NO_DIV_CHECKS
`ifndef ROCO_M_STREAM_CHECKS
  always @(posedge clk) begin
    if (!rst) begin
      if (if_imem_rsp_valid)
        assert (!(if_imem_rsp_data[6:0] == 7'h33 && if_imem_rsp_data[31:25] == 1 &&
                  if_imem_rsp_data[14]));
      if (idex_valid) begin
        assert (!(idex_instr[6:0] == 7'h33 && idex_instr[31:25] == 1 && idex_instr[14]));
        assert (!idex_is_div);
      end
      assert (!div_busy && !div_wb_en);
    end
  end
`endif
`endif

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      rvfi_order <= 64'd0;
      rvfi_handler_pending <= 1'b0;
    end else begin
      if (rvfi_valid) rvfi_order <= rvfi_order + 64'd1;
      if (rvfi_trap_entry) rvfi_handler_pending <= 1'b1;
      else if (rvfi_valid) rvfi_handler_pending <= 1'b0;
    end
  end
`endif

`ifdef ROCO_RVFI_IRQ_METADATA
  logic formal_irq_pending, formal_trap_pending;
  logic [31:0] formal_irq_epc, formal_trap_cause;
`endif
`ifdef ROCO_IRQ_PIPELINE_CHECKS
  `include "irq_pipeline_checks.svh"
`endif
`ifdef ROCO_SOC_PC_FORMAL
  `include "soc_pc_checks.svh"
`endif
`ifdef ROCO_VECTOR_MEM_STREAM
  `include "vector_mem_commit_checks.svh"
`endif
`ifdef ROCO_SOC_VECTOR_MEMORY_FORMAL
  `include "soc_vector_memory_checks.svh"
`endif
  roco_cpu_ex_stage #(
      .HART_ID(HART_ID)
  ) u_ex (
`ifdef ROCO_SOC_RETIRE_MEMORY_FORMAL
      .formal_sync_capture(f_sync_capture),
      .formal_sync_pending(f_sync_pending),
`endif
`ifdef ROCO_VECTOR_MEM_STREAM
      .formal_vec_width(formal_vec_width),
`endif
`ifdef ROCO_VECTOR_REG_STATE
      .formal_vec_reg(formal_vec_reg),
      .formal_vec_byte(formal_vec_byte),
      .reference_vec_byte(reference_vec_byte),
`endif
`ifdef ROCO_RVFI_IRQ_METADATA
      .formal_irq_pending(formal_irq_pending),
      .formal_trap_pending(formal_trap_pending),
      .formal_irq_epc(formal_irq_epc),
      .formal_trap_cause(formal_trap_cause),
`endif
`ifdef ROCO_RVFI
      .rvfi_idex_rs1(rvfi_idex_rs1),
      .rvfi_idex_rs2(rvfi_idex_rs2),
      .rvfi_exmem(rvfi_exmem),
      .rvfi_exception(rvfi_exception),
      .rvfi_trap_entry(rvfi_trap_entry),
      .rvfi_sync_exception(rvfi_sync_exception),
      .rvfi_trap_vector(rvfi_trap_vector),
`ifdef ROCO_RVFI_DIV_CHECKS
      .rvfi_div_start(rvfi_div_start),
      .rvfi_div_a(rvfi_div_a),
      .rvfi_div_b(rvfi_div_b),
`endif
`ifdef ROCO_RVFI_FORWARD_CHECKS
      .rvfi_fwd_mem_ready(rvfi_fwd_mem_ready),
      .rvfi_fwd_cancel(rvfi_fwd_cancel),
`ifdef ROCO_RVFI_INSN_CHECKS
      .rvfi_fwd_trap_pending(rvfi_fwd_trap_pending),
`endif
      .rvfi_fwd_held_rs1(rvfi_fwd_held_rs1),
      .rvfi_fwd_held_rs2(rvfi_fwd_held_rs2),
`endif
`endif
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .lu_stall(dmem_lu_stall),
      .retire(retire),
      .div_busy(div_busy),
      .div_rd(div_rd),
      .div_wb_en(div_wb_en),
      .div_wb_rd(div_wb_rd),
      .div_wb_data(div_wb_data),
      .idex_valid(idex_valid),
      .idex_wb_select(idex_wb_select),
      .idex_pc(idex_pc),
      .idex_instr(idex_instr),
      .idex_pred_taken(idex_pred_taken),
      .idex_pred_target_match(idex_pred_target_match),
      .idex_pred_jalr_base(idex_pred_jalr_base),
      .idex_pred_jalr_carry(idex_pred_jalr_carry),
      .idex_pred_jalr_aligned(idex_pred_jalr_aligned),
      .idex_rs1_val(idex_rs1_val),
      .idex_rs2_val(idex_rs2_val),
      .idex_rs1_from_mem(idex_rs1_from_mem),
      .idex_rs2_from_mem(idex_rs2_from_mem),
      .idex_rs1_from_wb(idex_rs1_from_wb),
      .idex_rs1_from_rf(idex_rs1_from_rf),
      .idex_imm(idex_imm),
      .idex_rs1(idex_rs1),
      .idex_rd(idex_rd),
      .idex_funct3(idex_funct3),
      .idex_alu_op(idex_alu_op),
      .idex_is_muldiv(idex_is_muldiv),
      .idex_md_op(idex_md_op),
      .idex_alu_a_val(idex_alu_a_val),
      .idex_alu_b_val(idex_alu_b_val),
      .idex_alu_a_from_mem(idex_alu_a_from_mem),
      .idex_alu_b_from_mem(idex_alu_b_from_mem),
      .idex_regwrite(idex_regwrite),
      .idex_is_load(idex_is_load),
      .idex_is_store(idex_is_store),
      .idex_is_amo(idex_is_amo),
      .idex_is_lr(idex_is_lr),
      .idex_is_sc(idex_is_sc),
      .idex_amo_op(idex_amo_op),
      .idex_is_vec(idex_is_vec),
      .idex_is_vset(idex_is_vset),
      .idex_is_vload(idex_is_vload),
      .idex_is_vstore(idex_is_vstore),
      .idex_vec_funct6(idex_vec_funct6),
      .vec_vs1_data(vec_vs1_data),
      .vec_vs2_data(vec_vs2_data),
      .vec_vd_data(vec_vd_data),
      .exmem_vec_we(exmem_vec_we),
      .exmem_vec_data(exmem_vec_data),
      .idex_is_branch(idex_is_branch),
      .idex_is_jal(idex_is_jal),
      .idex_is_jalr(idex_is_jalr),
      .idex_is_csr(idex_is_csr),
      .idex_csr_uimm(idex_csr_uimm),
      .idex_csr_op(idex_csr_op),
      .idex_csr_addr(idex_csr_addr),
      .idex_illegal(idex_illegal),
      .idex_ecall(idex_ecall),
      .idex_ebreak(idex_ebreak),
      .idex_ifault(idex_ifault),
      .idex_mret(idex_mret),
      .idex_sret(idex_sret),
      .idex_is_sfence(idex_is_sfence),
      .idex_is_fence_i(idex_is_fence_i),
      .fence_hold(fence_req || mem_wait),
      .irq_next_pc(fetch_oldest_pc),
      .irq_timer(irq_timer),
      .irq_external(irq_external),
      .redirect_from_mem(mem_redirect || ex_redirect_en),
      .mem_data(mem_forward_data),
      .wb_data(wb_data),
      .wb_we(wb_we),
      .dmem_lu_fault(d_fault_q),
      .dmem_lu_fault_cause(d_fault_cause_q),
      .dmem_lu_paddr(lookup_paddr),
      .ex_trap_taken(ex_trap_taken),
      .vec_mem_hold(vec_mem_hold),
      .ex_redirect_en(ex_redirect_raw),
      .ex_redirect_base(redirect_base_raw),
      .ex_redirect_offset(redirect_offset_raw),
      .ex_redirect_fallthrough(redirect_fallthrough_raw),
      .ex_redirect_mask_lsb(redirect_mask_raw),
      .btb_update(btb_update),
      .btb_is_branch(btb_is_branch),
      .btb_is_jal(btb_is_jal),
      .btb_is_jalr(btb_is_jalr),
      .btb_taken(btb_taken),
      .btb_target(btb_target),
      .ex_lu_valid(ex_lu_valid),
      .ex_lu_present(ex_lu_present),
      .ex_lu_vaddr(ex_lu_vaddr),
      .ex_lu_we(ex_lu_we),
      .priv(priv),
      .satp(satp),
      .satp_write(satp_write),
      .mstatus_mprv(mstatus_mprv),
      .mstatus_sum(mstatus_sum),
      .mstatus_mxr(mstatus_mxr),
      .mstatus_tvm(unused_mstatus_tvm),
      .mstatus_tsr(unused_mstatus_tsr),
      .mstatus_mpp(mstatus_mpp),
      .exmem_valid(exmem_valid),
      .exmem_pc(exmem_pc),
      .exmem_instr(exmem_instr),
      .exmem_alu(exmem_alu),
      .exmem_wbval(exmem_wbval),
      .exmem_store_data(exmem_store_data),
      .exmem_be(exmem_be),
      .exmem_rd(exmem_rd),
      .exmem_funct3(exmem_funct3),
      .exmem_regwrite(exmem_regwrite),
      .exmem_is_load(exmem_is_load),
      .exmem_forward_cache(exmem_forward_cache),
      .exmem_forward_wbval(exmem_forward_wbval),
      .exmem_is_store(exmem_is_store),
      .exmem_is_amo(exmem_is_amo),
      .exmem_is_lr(exmem_is_lr),
      .exmem_is_sc(exmem_is_sc),
      .exmem_amo_op(exmem_amo_op),
      .exmem_is_vload(exmem_is_vload),
      .exmem_is_vstore(exmem_is_vstore),
      .exmem_vec_elem(exmem_vec_elem),
      .exmem_vec_last(exmem_vec_last),
      .exmem_vec_sew(exmem_vec_sew),
      .exmem_is_sfence(exmem_is_sfence),
      .exmem_is_fence_i(exmem_is_fence_i),
      .exmem_is_mul(exmem_is_mul),
      .exmem_mul_hi(exmem_mul_hi),
      .exmem_mul_sum(exmem_mul_sum),
      .exmem_mul_carry(exmem_mul_carry)
  );

  // Arithmetic and load elements share the MEM write boundary. A full
  // result forwards to all three EX vector reads before register commit.
  logic vec_forward_valid;
  // Reset/hold qualify the physical write. The bypass payload is only
  // observed by a valid EX instruction, so use registered producer bits
  // here to keep global reset and halt off all 384 forwarding mux inputs.
  assign vec_forward_valid = exmem_valid && exmem_vec_we;
  assign vec_full_write = vec_forward_valid && !halt;
  assign vec_vs1_data = (vec_forward_valid && (exmem_rd == idex_instr[19:15])) ?
                        exmem_vec_data : vec_rf_vs1_data;
  assign vec_vs2_data = (vec_forward_valid && (exmem_rd == idex_instr[24:20])) ?
                        exmem_vec_data : vec_rf_vs2_data;
  assign vec_vd_data = (vec_forward_valid && (exmem_rd == idex_instr[11:7])) ?
                      exmem_vec_data : vec_rf_vd_data;

  roco_cpu_vec u_vec (
`ifdef ROCO_VECTOR_REG_STATE
      .formal_vec_reg(formal_vec_reg),
      .formal_vec_byte(formal_vec_byte),
      .formal_vec_stored(formal_vec_stored),
`endif
      .clk(clk),
      .rst(rst),
      .vs1(idex_instr[19:15]),
      .vs2(idex_instr[24:20]),
      .vd(idex_instr[11:7]),
      .vs1_data(vec_rf_vs1_data),
      .vs2_data(vec_rf_vs2_data),
      .vd_data(vec_rf_vd_data),
      .ex_we(vec_full_write),
      .ex_wd(exmem_rd),
      .ex_wdata(exmem_vec_data),
      .mem_we(vec_mem_we),
      .mem_wd(vec_mem_wd),
      .mem_elem(vec_mem_elem),
      .mem_sew(vec_mem_sew),
      .mem_wdata(vec_mem_wdata)
  );

  // Warm CPU reset invalidates translations but cannot withdraw an AXI
  // address or orphan a read. Only a shared fabric reset resets the walker.
  roco_cpu_mmu u_mmu (
      .clk(clk),
      .rst(ptw_bus_rst),
      .flush(mmu_flush || rst),
      .iflush(ex_redirect_en || mem_redirect),
      .satp(satp),
      .priv_fetch(priv),
      .priv_data(priv_data),
      .mstatus_sum(mstatus_sum),
      .mstatus_mxr(mstatus_mxr),
      .i_req(if_imem_req && !imem_busy),
      .i_vaddr(if_imem_addr),
      .i_hit(mmu_i_hit),
      .i_miss(mmu_i_miss),
      .i_busy(mmu_i_busy),
      .i_fault(mmu_i_fault),
      .i_fault_addr(mmu_i_fault_addr),
      .ic_req(mmu_ic_req),
      .ic_addr(mmu_ic_addr),
      .ic_rsp_valid(imem_rsp_valid),
      .ic_rsp_data(imem_rsp_data),
      .i_rsp_valid(mmu_i_rsp_valid),
      .i_rsp_addr(mmu_i_rsp_addr),
      .i_rsp_data(mmu_i_rsp_data),
      .d_req(ex_lu_valid),
      .d_vaddr(ex_lu_vaddr),
      .d_we(ex_lu_we),
      .d_hit(mmu_d_hit),
      .d_fault(mmu_d_fault),
      .d_fault_cause(mmu_d_fault_cause),
      .d_paddr(mmu_d_paddr),
      .ptw_ar(ptw_ar),
      .p_ready(ptw_ready),
      .ptw_r(ptw_r),
      .ptw_r_ready(ptw_r_ready)
  );

  // The external instruction port is physical; the MMU owns virtual
  // fetch responses and page-fault reporting.
  assign mmu_sfence = mem_redirect && exmem_is_sfence;
  assign mmu_flush = mmu_sfence || satp_write;
  // The I-cache can reject a request on its own busy cycle. Also respect
  // the MMU's fetch hold: a discarded page walk can still be draining
  // after the new context already has a translation (or runs bare).
  assign imem_req = if_imem_req && mmu_i_hit && !mmu_i_busy;
  assign imem_addr = mmu_ic_addr;
  assign if_imem_rsp_valid = mmu_i_rsp_valid;
  assign if_imem_rsp_addr = mmu_i_rsp_addr;
  assign if_imem_rsp_data = mmu_i_rsp_data;
`ifdef ROCO_SOC_FETCH_MEMORY_FORMAL
  `include "soc_fetch_link_checks.svh"
`endif
`ifdef ROCO_SOC_RETIRE_MEMORY_FORMAL
  `include "soc_retire_memory_checks.svh"
`endif
`ifdef ROCO_SOC_ISA_MEMORY_FORMAL
  `include "soc_isa_memory_checks.svh"
`endif
`ifdef ROCO_SOC_GPR_FORMAL
  `include "soc_gpr_checks.svh"
`endif
`ifdef ROCO_SOC_GPR_FORWARD_FORMAL
  `include "soc_gpr_forward_checks.svh"
`endif
`ifdef ROCO_SOC_M_FORMAL
  `include "soc_m_checks.svh"
`endif
`ifdef ROCO_SOC_A_FORMAL
  `include "soc_a_checks.svh"
`endif
`ifdef ROCO_SOC_TRAP_FORMAL
  `include "soc_trap_checks.svh"
`endif
  always_ff @(posedge clk or posedge rst) begin
    if (rst) cache_request_live_q <= 1'b0;
    else cache_request_live_q <= mmu_ic_req && !ex_redirect_en && !mem_redirect && !mmu_flush;
  end
  assign cache_miss_live = imem_miss && cache_request_live_q;
  assign if_imem_miss = cache_miss_live || mmu_i_miss;
  assign if_imem_busy = mmu_i_busy || imem_busy;
  assign if_imem_fault = mmu_i_fault;
  assign if_imem_fault_addr = mmu_i_fault_addr;
`ifdef ROCO_SOC_PC_FORMAL
  always_ff @(posedge clk) if (!rst && satp_write) assert (ex_redirect_en);
`endif

  // Train the predictor one cycle after resolution. Capture payload
  // unconditionally so only one validity flop sees late branch control.
  logic bp_update_valid;
  logic [31:2] bp_update_pc;
  logic [31:0] bp_update_target;
  logic [20:0] bp_update_imm;
  logic bp_update_branch, bp_update_jal, bp_update_jalr, bp_update_taken;
  // Payload flops carry no reset value; only bp_update_valid gates their
  // visibility, which keeps them out of the asynchronous reset cone.
  always_ff @(posedge clk) begin
    bp_update_pc <= idex_pc[31:2];
    bp_update_target <= btb_target;
    bp_update_imm <= idex_imm[20:0];
    bp_update_branch <= btb_is_branch;
    bp_update_jal <= btb_is_jal;
    bp_update_jalr <= btb_is_jalr;
    bp_update_taken <= btb_taken;
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      bp_update_valid <= 1'b0;
    end else if (mem_redirect || satp_write) begin
      bp_update_valid <= 1'b0;
    end else begin
      bp_update_valid <= btb_update;
    end
  end

  roco_cpu_branch_predictor u_bp (
      .clk(clk),
      .rst(rst),
      .flush(fence_req),
      .if_pc(fetch_pc),
      .if_pred_taken(pred_taken),
      .if_pred_target(pred_target),
      .if_pred_direct(pred_direct),
      .if_pred_imm(pred_imm),
      .ex_pc(bp_update_pc),
      .ex_update(bp_update_valid && !halt),
      .ex_is_branch(bp_update_branch),
      .ex_is_jal(bp_update_jal),
      .ex_is_jalr(bp_update_jalr),
      .ex_taken(bp_update_taken),
      .ex_target(bp_update_target),
      .ex_imm(bp_update_imm)
  );

  roco_cpu_mem_stage u_mem (
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .fence_done(fence_done),
      .lookup_valid(dmem_lu_valid),
      .lookup_addr(lookup_paddr[31:2]),
      .lookup_sc(idex_is_sc),
      .exmem_valid(exmem_valid),
      .exmem_pc(exmem_pc),
      .exmem_instr(exmem_instr),
      .exmem_alu(exmem_alu),
      .exmem_wbval(exmem_wbval),
      .exmem_store_data(exmem_store_data),
      .exmem_be(exmem_be),
      .exmem_rd(exmem_rd),
      .exmem_funct3(exmem_funct3),
      .exmem_regwrite(exmem_regwrite),
      .exmem_is_load(exmem_is_load),
      .exmem_forward_cache(exmem_forward_cache),
      .exmem_forward_wbval(exmem_forward_wbval),
      .exmem_is_store(exmem_is_store),
      .exmem_is_amo(exmem_is_amo),
      .exmem_is_lr(exmem_is_lr),
      .exmem_is_sc(exmem_is_sc),
      .exmem_amo_op(exmem_amo_op),
      .exmem_is_vload(exmem_is_vload),
      .exmem_is_vstore(exmem_is_vstore),
      .exmem_vec_elem(exmem_vec_elem),
      .exmem_vec_last(exmem_vec_last),
      .exmem_vec_sew(exmem_vec_sew),
      .exmem_is_sfence(exmem_is_sfence),
      .exmem_is_fence_i(exmem_is_fence_i),
      .exmem_is_mul(exmem_is_mul),
      .exmem_mul_hi(exmem_mul_hi),
      .exmem_mul_sum(exmem_mul_sum),
      .exmem_mul_carry(exmem_mul_carry),
`ifdef ROCO_ATOMIC_STREAM_CHECKS
      .formal_res_valid(formal_res_valid),
      .formal_res_word(formal_res_word),
      .formal_amo_ready(formal_amo_ready),
`endif
      .trap_taken(ex_trap_taken || satp_write),
      .res_remote_valid(res_remote_valid),
      .res_remote_addr(res_remote_addr),
      .res_store_valid(res_store_valid),
      .res_store_addr(res_store_addr),
      .vec_mem_we(vec_mem_we),
      .vec_mem_wd(vec_mem_wd),
      .vec_mem_elem(vec_mem_elem),
      .vec_mem_sew(vec_mem_sew),
      .vec_mem_wdata(vec_mem_wdata),
      .vec_element_commit(vec_element_commit),
      .dmem_req(dmem_req),
      .dmem_valid(dmem_valid),
      .dmem_amo_read(dmem_amo_read),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_be(dmem_be),
      .dmem_rsp_data(dmem_rsp_data),
      .dmem_forward_data(dmem_forward_data),
      .dmem_ready(dmem_ready),
      .mem_wait(mem_wait),
      .fence_req(fence_req),
      .mem_redirect(mem_redirect),
      .commit_valid(commit_valid),
      .commit_pc(commit_pc),
      .commit_instr(commit_instr),
      .commit_rd(commit_rd),
      .commit_wdata(commit_wdata),
      .forward_data(mem_forward_data),
      .memwb_valid(memwb_valid),
      .memwb_data(memwb_data),
      .memwb_rd(memwb_rd),
      .memwb_regwrite(memwb_regwrite)
  );

  roco_cpu_wb_stage u_wb (
      .halt(halt),
      .memwb_valid(memwb_valid),
      .memwb_regwrite(memwb_regwrite),
      .memwb_rd(memwb_rd),
      .memwb_data(memwb_data),
      .wb_we(wb_we),
      .wb_rd(wb_rd),
      .wb_data(wb_data)
  );



`ifndef SYNTHESIS
  // The token replaces an address comparator in hardware. Verify the
  // producer contract while exercising stalls, redirects and vector steps.
  logic [31:0] translated_vaddr_check;
  always_ff @(posedge clk) begin
    if (!translated_valid_q) translated_vaddr_check <= ex_lu_vaddr;
  end
  always @(negedge clk) begin
    if (!rst && lookup_translate_q && translated_valid_q && ex_lu_valid)
      assert (ex_lu_vaddr === translated_vaddr_check)
      else $fatal(1, "EX changed its request before consuming translation");
  end
`endif

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (!rst && pred_taken && pred_direct &&
        (pred_target != fetch_pc + {{11{pred_imm[20]}}, pred_imm}))
      $fatal(1, "direct BTB immediate does not describe its target");
    if (!rst && idex_valid && idex_is_csr &&
        ((idex_csr_addr == 12'hb02) || (idex_csr_addr == 12'hb82) || (idex_csr_addr == 12'hc02)) &&
        retire)
      $fatal(1, "minstret read overlapped an older retirement");
  end
`endif
endmodule
