// Memory access stage.
//
// Issues the single blocking data-memory request, extracts the requested
// lane from the returned word, and owns the MEM/WB pipeline register.
// Stores are complete when the response returns, so a store miss in the
// D-cache simply stretches mem_wait. FENCE.I and SFENCE.VMA hold the
// pipeline here while the SoC flushes the caches and the MMU.

`default_nettype none

module roco_cpu_mem_stage (
  input logic clk,
  input logic rst,
  input logic halt,
  input logic fence_done,
  input logic lookup_valid,
  input logic [29:0] lookup_addr,
  input logic lookup_sc,
  /* EX/MEM pipeline register. */
  input logic exmem_valid,
  input logic [31:0] exmem_pc,
  input logic [31:0] exmem_instr,
  input logic [31:0] exmem_alu,
  input logic [31:0] exmem_wbval,
  input logic [31:0] exmem_store_data,
  input logic [3:0] exmem_be,
  input logic [4:0] exmem_rd,
  input logic [2:0] exmem_funct3,
  input logic exmem_regwrite,
  input logic exmem_is_load,
  input logic exmem_forward_cache,
  input logic exmem_forward_wbval,
  input logic exmem_is_store,
  input logic exmem_is_amo,
  input logic exmem_is_lr,
  input logic exmem_is_sc,
  input logic [4:0] exmem_amo_op,
  input logic exmem_is_vload,
  input logic exmem_is_vstore,
  input logic [3:0] exmem_vec_elem,
  input logic exmem_vec_last,
  input logic [2:0] exmem_vec_sew,
  /* Element write port into the vector register file. */
  output logic vec_mem_we,
  output logic [4:0] vec_mem_wd,
  output logic [3:0] vec_mem_elem,
  output logic [2:0] vec_mem_sew,
  output logic [31:0] vec_mem_wdata,
  output logic vec_element_commit,
`ifdef ROCO_ATOMIC_STREAM_CHECKS
  output logic formal_res_valid,
  output logic [29:0] formal_res_word,
  output logic formal_amo_ready,
`endif
  /* Any trap this cycle cancels a reservation. */
  input logic trap_taken,
  input logic exmem_is_sfence,
  input logic exmem_is_fence_i,
  /* Multiply carry-save terms registered at EX/MEM. */
  input logic exmem_is_mul,
  input logic exmem_mul_hi,
  input logic [63:0] exmem_mul_sum,
  input logic [63:0] exmem_mul_carry,
  /* Data memory: request held until rsp_valid. */
  output logic dmem_req,
  output logic dmem_valid,
  /* Atomic read phase: an uncached target needs a real read transaction
     here, while a cached target already answered the EX lookup. */
  output logic dmem_amo_read,
  output logic dmem_we,
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0] dmem_be,
  input logic [31:0] dmem_rsp_data,
  input logic [31:0] dmem_forward_data,
  input logic dmem_ready,
  output logic mem_wait,
  output logic fence_req,
  output logic mem_redirect,
  /* One-cycle commit strobe for minstret and the retire trace. */
  output logic commit_valid,
  output logic [31:0] commit_pc,
  output logic [31:0] commit_instr,
  output logic [4:0] commit_rd,
  output logic [31:0] commit_wdata,
  output logic [31:0] forward_data,
  /* MEM/WB pipeline register. */
  output logic memwb_valid,
  output logic [31:0] memwb_data,
  output logic [4:0] memwb_rd,
  output logic memwb_regwrite
);

  logic [31:0] load_data;
  logic [31:0] mul_result;
  logic [31:0] result_data;
  logic is_memory_op;
  logic [31:0] amo_data;
  logic [31:0] amo_old_q, amo_sum;
  logic amo_staged, amo_ready, amo_prepare;
  assign amo_staged = exmem_is_amo;
  assign amo_prepare = exmem_valid && amo_staged && !amo_ready;
  // Register the EBR output before arithmetic. The following cycle can
  // calculate and commit directly, avoiding a separate result-only cycle.
  always_ff @(posedge clk) begin
    if (!amo_ready) amo_old_q <= dmem_rsp_data;
  end
  always_ff @(posedge clk or posedge rst) begin
    if (rst) amo_ready <= 1'b0;
    else if (!halt && !fence_req) begin
      if (!exmem_valid || !amo_staged) amo_ready <= 1'b0;
      else if (dmem_ready) amo_ready <= !amo_ready;
    end
  end
  roco_cpu_addsub u_amo_add (
      .a(amo_old_q),
      .b(exmem_store_data),
      .subtract(1'b0),
      .result(amo_sum)
  );
  logic [3:0] amo_lt;
  logic [3:1] amo_eq;
  logic amo_unsigned_lt, amo_less;
  for (genvar b = 0; b < 4; b = b + 1) begin : g_amo_lt
    assign amo_lt[b] = amo_old_q[8*b+:8] < exmem_store_data[8*b+:8];
  end
  for (genvar b = 1; b < 4; b = b + 1) begin : g_amo_eq
    assign amo_eq[b] = amo_old_q[8*b+:8] == exmem_store_data[8*b+:8];
  end
  assign amo_unsigned_lt = amo_lt[3] || (amo_eq[3] && amo_lt[2]) ||
                           (amo_eq[3] && amo_eq[2] && amo_lt[1]) ||
                           (amo_eq[3] && amo_eq[2] && amo_eq[1] && amo_lt[0]);
  assign amo_less = (!exmem_amo_op[3] && (amo_old_q[31] != exmem_store_data[31])) ?
                    amo_old_q[31] : amo_unsigned_lt;
  logic sc_ok;
  logic [31:0] sc_result;
  logic res_valid;
  logic [29:0] res_addr;
  logic commit_now;
  logic store_now;
`ifdef ROCO_ATOMIC_STREAM_CHECKS
  assign formal_res_valid = res_valid;
  assign formal_res_word = res_addr;
  assign formal_amo_ready = amo_ready;
  always @(posedge clk) begin
    if (!rst && amo_ready) assert (exmem_valid && exmem_is_amo);
  end
`endif

  // The EX lookup supplies the old word at the start of MEM. Compute the
  // RMW value here and commit its one write on the same edge as retirement.
  // A miss holds MEM; no request or side effect occurs before data is ready.
  always_comb begin
    case (exmem_amo_op)
      5'b00000: begin  // AMOADD
        amo_data = amo_sum;
      end
      5'b00001: begin  // AMOSWAP
        amo_data = exmem_store_data;
      end
      5'b00100: begin  // AMOXOR
        amo_data = amo_old_q ^ exmem_store_data;
      end
      5'b01000: begin  // AMOOR
        amo_data = amo_old_q | exmem_store_data;
      end
      5'b01100: begin  // AMOAND
        amo_data = amo_old_q & exmem_store_data;
      end
      default: begin  // Signed/unsigned MIN/MAX share the same comparison.
        amo_data = (amo_less ^ exmem_amo_op[2]) ? amo_old_q : exmem_store_data;
      end
    endcase
  end

  // The multiply's 64-bit carry propagation gets its own cycle here. An
  // ECP5 carry chain cannot cross a PFU column, so completing it in EX made
  // the multiply the longest path in the design.
  roco_cpu_mul_sum u_mul_sum (
      .sum1(exmem_mul_sum),
      .carry1(exmem_mul_carry),
      .hi(exmem_mul_hi),
      .result(mul_result)
  );

  // Decode mutually exclusive result classes in parallel. The load path
  // feeds EX directly, so it must not traverse a priority mux of all the
  // unrelated producers before reaching the next instruction.
  assign result_data =
      ({32{exmem_is_sc}} & sc_result) |
      ({32{exmem_is_amo}} & amo_old_q) |
      ({32{exmem_is_load || exmem_is_lr}} & load_data) |
      ({32{exmem_is_mul}} & mul_result) |
      ({32{!(exmem_is_sc || exmem_is_amo || exmem_is_load || exmem_is_lr ||
             exmem_is_mul)}} & exmem_wbval);

  assign is_memory_op = exmem_is_load || exmem_is_store || exmem_is_amo || exmem_is_lr ||
                        exmem_is_sc || exmem_is_vload || exmem_is_vstore;
  assign dmem_addr = exmem_alu;
  logic sc_match_q;
  // Scalar address preparation drains older memory operations before
  // this lookup. Keep the reservation comparison before EX/MEM, alongside
  // the cache lookup, instead of in MEM write enables and result data.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) sc_match_q <= 1'b0;
    else if (lookup_valid) sc_match_q <= res_valid && (res_addr == lookup_addr);
  end
  assign sc_ok = sc_match_q;
  assign sc_result = {31'd0, !sc_ok};
  assign dmem_we = exmem_is_store || exmem_is_amo || (exmem_is_sc && sc_ok) || exmem_is_vstore;
  assign dmem_wdata = exmem_is_amo ? amo_data : exmem_store_data;
  assign dmem_be = exmem_is_amo ? 4'hf : exmem_be;
  // Requests become observable only at in-order commit. A pending memory
  // operation holds EX (including cache lookups) until it completes, and
  // there is no posted store buffer. This uniformly enforces both acquire
  // and release ordering; aq/rl do not need additional stalls or flushes.
  // A failed SC still completes its cache lookup, but must not start
  // a bus transaction: an MMIO read can itself have side effects.
  assign dmem_valid = !halt && exmem_valid && !fence_req && is_memory_op && !amo_prepare &&
                      !(exmem_is_sc && !sc_ok);
  // The atomic's old value comes from the cache lookup for a cached target.
  // Any other target must read first, so name that phase for the bus side.
  assign dmem_amo_read = !halt && !fence_req && amo_prepare;
  assign dmem_req = commit_valid && is_memory_op;
  assign mem_wait = !halt && exmem_valid && is_memory_op && (!dmem_ready || amo_prepare);
  assign commit_valid = !halt && exmem_valid && !fence_req && !mem_wait;
  assign commit_now = commit_valid;
  // Element writes are internal micro-operations. Only the final element
  // retires the architectural vector instruction and increments minstret.
  assign vec_element_commit = commit_valid && (exmem_is_vload || exmem_is_vstore) && !exmem_vec_last;
  assign vec_mem_we = commit_valid && exmem_is_vload;
  assign vec_mem_wd = exmem_rd;
  assign vec_mem_elem = exmem_vec_elem;
  assign vec_mem_sew = exmem_vec_sew;
  assign vec_mem_wdata = dmem_rsp_data >> {exmem_alu[1:0], 3'b000};
  assign store_now = commit_valid && exmem_valid && dmem_we && is_memory_op;
  assign commit_pc = exmem_pc;
  assign commit_instr = exmem_instr;
  assign commit_rd = exmem_rd;
  assign commit_wdata = result_data;
  assign fence_req = exmem_valid && (exmem_is_fence_i || exmem_is_sfence) && !fence_done;
  assign mem_redirect = exmem_valid && (exmem_is_fence_i || exmem_is_sfence) && fence_done;

  function automatic [31:0] align_load(input logic [31:0] word_data, input logic [1:0] offset,
                                       input logic [2:0] funct3);
    logic [7:0] byte_data;
    logic [15:0] half_data;
    byte_data = 8'(word_data >> {offset, 3'b000});
    half_data = 16'(word_data >> {offset[1], 4'b0000});
    case (funct3)
      3'b000: align_load = {{24{byte_data[7]}}, byte_data};
      3'b001: align_load = {{16{half_data[15]}}, half_data};
      3'b100: align_load = {24'd0, byte_data};
      3'b101: align_load = {16'd0, half_data};
      default: align_load = word_data;
    endcase
  endfunction
  assign load_data = align_load(dmem_rsp_data, exmem_alu[1:0], exmem_funct3);
  // Memory results bypass into ID after one dependency bubble. EX only
  // consumes results produced by EX/MEM registers, keeping cache read,
  // alignment and forwarding routing off the next address calculation.
  assign forward_data = exmem_wbval;

  // Load-reserved / store-conditional reservation. The set is one word
  // wide: any store to it, any store-conditional and any trap clears it.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      res_valid <= 1'b0;
      res_addr <= '0;
    end else if (trap_taken) begin
      res_valid <= 1'b0;
    end else if (commit_now) begin
      if (exmem_is_lr) begin
        res_valid <= 1'b1;
        res_addr <= dmem_addr[31:2];
      end else if (exmem_is_sc) begin
        res_valid <= 1'b0;
      end else if (store_now && (dmem_addr[31:2] == res_addr)) begin
        res_valid <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      memwb_valid <= 1'b0;
      memwb_data <= '0;
      memwb_rd <= '0;
      memwb_regwrite <= 1'b0;
    end else if (halt || fence_req) begin
      // Hold for the FENCE.I cache flush.
    end else if (mem_wait) begin
      // Preserve the previous WB value for the younger EX instruction
      // while it is held, without repeating its register-file write.
      memwb_valid <= 1'b0;
    end else begin
      memwb_valid <= commit_valid;
      // Register the selected result so WB forwarding starts at a flop.
      memwb_data <= commit_wdata;
      memwb_rd <= exmem_rd;
      memwb_regwrite <= exmem_regwrite;
    end
  end

`ifdef ROCO_M_STREAM_CHECKS
  always @(posedge clk) begin
    if (!rst && !halt && exmem_valid && exmem_is_mul) begin
      assert (commit_valid && !dmem_req && commit_wdata == mul_result);
    end
  end
`endif
`ifdef ROCO_SOC_A_FORMAL
  `include "soc_a_mem_checks.svh"
`endif
`ifdef ROCO_RVFI_RV32A_CHECKS
  // Discharge the SC lookup precondition used by the standalone MEM proof
  // when this stage is driven by the real pipeline.
  always @(posedge clk) begin
    if (!rst && lookup_valid && lookup_sc)
      assert (!trap_taken && !(commit_now && (exmem_is_lr || exmem_is_sc || store_now)));
    if (!rst && exmem_valid && exmem_is_sc)
      assert (sc_ok == (res_valid && res_addr == exmem_alu[31:2]));
  end
`endif

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (!rst && lookup_valid && lookup_sc &&
        (trap_taken || (commit_now && (exmem_is_lr || exmem_is_sc || store_now))))
      $fatal(1, "SC lookup raced an older reservation update");
    if (!rst && exmem_valid && exmem_is_sc &&
        (sc_ok !== (res_valid && (res_addr == exmem_alu[31:2]))))
      $fatal(1, "SC lookup lost its reservation/address association");
  end
`endif
endmodule
