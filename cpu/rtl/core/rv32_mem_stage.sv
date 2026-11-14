// Memory access stage.
//
// Issues the single blocking data-memory request, extracts the requested
// lane from the returned word, and owns the MEM/WB pipeline register.
// Stores are complete when the response returns, so a store miss in the
// D-cache simply stretches mem_wait. FENCE.I and SFENCE.VMA hold the
// pipeline here while the SoC flushes the caches and the MMU.

`default_nettype none

module rv32_mem_stage (
  input logic clk,
  input logic rst,
  input logic halt,
  input logic fence_done,
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
  input logic exmem_is_store,
  input logic exmem_is_amo,
  input logic exmem_is_lr,
  input logic exmem_is_sc,
  input logic [4:0] exmem_amo_op,
  /* Any trap this cycle cancels a reservation. */
  input logic trap_taken,
  input logic exmem_is_sfence,
  input logic exmem_is_fence_i,
  /* Multiply partial products completed here. */
  input logic [31:0] exmem_mul_p0,
  input logic [31:0] exmem_mul_p1,
  input logic [31:0] exmem_mul_p2,
  input logic [31:0] exmem_mul_p3,
  input logic [31:0] exmem_mul_sub_a,
  input logic [31:0] exmem_mul_sub_b,
  input logic [2:0] exmem_mul_variant,
  input logic exmem_from_mul,
  /* Data memory: request held until rsp_valid. */
  output logic dmem_req,
  output logic dmem_we,
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0] dmem_be,
  input logic [31:0] dmem_rsp_data,
  output logic fence_req,
  output logic mem_redirect,
  /* One-cycle commit strobe for minstret and the retire trace. */
  output logic commit_valid,
  output logic [31:0] commit_pc,
  output logic [31:0] commit_instr,
  output logic [4:0] commit_rd,
  output logic [31:0] commit_wdata,
  /* MEM/WB pipeline register. */
  output logic memwb_valid,
  output logic [31:0] memwb_data,
  output logic [4:0] memwb_rd,
  output logic memwb_regwrite
);

  logic [7:0] load_byte;
  logic [15:0] load_half;
  logic [31:0] load_data;
  logic [31:0] mul_data;
  logic [31:0] result_data;
  logic is_memory_op;
  logic [31:0] amo_data;
  logic sc_ok;
  logic [31:0] sc_result;
  logic res_valid;
  logic [29:0] res_addr;
  logic commit_now;
  logic store_now;

  rv32_mul_finish u_mul_finish (
      .p0(exmem_mul_p0),
      .p1(exmem_mul_p1),
      .p2(exmem_mul_p2),
      .p3(exmem_mul_p3),
      .sub_a(exmem_mul_sub_a),
      .sub_b(exmem_mul_sub_b),
      .variant(exmem_mul_variant),
      .result(mul_data)
  );

  // Atomic memory operations read the word the EX lookup fetched and
  // write the computed result in the same memory cycle, which is atomic
  // for a single hart with no interrupts in flight.
  always_comb begin
    case (exmem_amo_op)
      5'b00000: begin  // AMOADD
        amo_data = dmem_rsp_data + exmem_store_data;
      end
      5'b00001: begin  // AMOSWAP
        amo_data = exmem_store_data;
      end
      5'b00100: begin  // AMOXOR
        amo_data = dmem_rsp_data ^ exmem_store_data;
      end
      5'b01000: begin  // AMOOR
        amo_data = dmem_rsp_data | exmem_store_data;
      end
      5'b01100: begin  // AMOAND
        amo_data = dmem_rsp_data & exmem_store_data;
      end
      5'b10000: begin  // AMOMIN
        amo_data = ($signed(dmem_rsp_data) < $signed(exmem_store_data)) ? dmem_rsp_data :
            exmem_store_data;
      end
      5'b10100: begin  // AMOMAX
        amo_data = ($signed(dmem_rsp_data) > $signed(exmem_store_data)) ? dmem_rsp_data :
            exmem_store_data;
      end
      5'b11000: begin  // AMOMINU
        amo_data = (dmem_rsp_data < exmem_store_data) ? dmem_rsp_data : exmem_store_data;
      end
      default: begin  // AMOMAXU
        amo_data = (dmem_rsp_data > exmem_store_data) ? dmem_rsp_data : exmem_store_data;
      end
    endcase
  end

  assign result_data = exmem_is_sc ? sc_result :
                       (exmem_is_load || exmem_is_lr || exmem_is_amo) ? load_data :
                       exmem_from_mul ? mul_data : exmem_wbval;

  assign is_memory_op = exmem_is_load || exmem_is_store || exmem_is_amo || exmem_is_lr ||
                        exmem_is_sc;
  assign dmem_addr = exmem_alu;
  assign sc_ok = res_valid && (res_addr == exmem_alu[31:2]);
  assign sc_result = {31'd0, !sc_ok};
  assign dmem_we = exmem_is_store || exmem_is_amo || (exmem_is_sc && sc_ok);
  assign dmem_wdata = exmem_is_amo ? amo_data : exmem_store_data;
  assign dmem_be = exmem_is_amo ? 4'hf : exmem_be;
  assign dmem_req = !rst && !halt && exmem_valid && is_memory_op;
  assign commit_valid = !rst && !halt && exmem_valid && !fence_req;
  assign commit_now = commit_valid;
  assign store_now = commit_valid && exmem_valid && dmem_we && is_memory_op;
  assign commit_pc = exmem_pc;
  assign commit_instr = exmem_instr;
  assign commit_rd = exmem_rd;
  assign commit_wdata = result_data;
  assign fence_req = exmem_valid && (exmem_is_fence_i || exmem_is_sfence) && !fence_done;
  assign mem_redirect = exmem_valid && (exmem_is_fence_i || exmem_is_sfence) && fence_done;

  assign load_byte = 8'(dmem_rsp_data >> {exmem_alu[1:0], 3'b000});
  assign load_half = 16'(dmem_rsp_data >> {exmem_alu[1], 4'b0000});

  always_comb begin
    case (exmem_funct3)
      3'b000: begin
        load_data = {{24{load_byte[7]}}, load_byte[7:0]};
      end
      3'b001: begin
        load_data = {{16{load_half[15]}}, load_half[15:0]};
      end
      3'b010: begin
        load_data = dmem_rsp_data;
      end
      3'b100: begin
        load_data = {24'd0, load_byte[7:0]};
      end
      3'b101: begin
        load_data = {16'd0, load_half[15:0]};
      end
      default: begin
        load_data = dmem_rsp_data;
      end
    endcase
  end

  // Load-reserved / store-conditional reservation. The set is one word
  // wide: any store to it, any store-conditional and any trap clears it.
  always_ff @(posedge clk) begin
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

  always_ff @(posedge clk) begin
    if (rst) begin
      memwb_valid <= 1'b0;
      memwb_data <= '0;
      memwb_rd <= '0;
      memwb_regwrite <= 1'b0;
    end else if (halt || fence_req) begin
      // Hold for the FENCE.I cache flush.
    end else begin
      memwb_valid <= exmem_valid;
      // Register the selected result so WB forwarding starts at a flop.
      memwb_data <= commit_wdata;
      memwb_rd <= exmem_rd;
      memwb_regwrite <= exmem_regwrite;
    end
  end

endmodule
