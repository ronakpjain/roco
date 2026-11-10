// Memory access stage.
//
// Issues the single blocking data-memory request, extracts the requested
// lane from the returned word, and owns the MEM/WB pipeline register.
// Stores are complete when the response returns, so a store miss in the
// D-cache simply stretches mem_wait.

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
  input logic exmem_is_fence_i,
  /* Data memory: request held until rsp_valid. */
  output logic dmem_req,
  output logic dmem_we,
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0] dmem_be,
  input logic dmem_rsp_valid,
  input logic [31:0] dmem_rsp_addr,
  input logic [31:0] dmem_rsp_data,
  output logic mem_wait,
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
  output logic [31:0] memwb_wbval,
  output logic [31:0] memwb_load_data,
  output logic [4:0] memwb_rd,
  output logic memwb_regwrite,
  output logic memwb_is_load
);

  logic [7:0] load_byte;
  logic [15:0] load_half;
  logic [31:0] load_data;
  logic dmem_done;
  logic is_memory_op;

  assign is_memory_op = exmem_is_load || exmem_is_store;
  assign dmem_addr = exmem_alu;
  assign dmem_we = exmem_is_store;
  assign dmem_wdata = exmem_store_data;
  assign dmem_be = exmem_be;
  assign dmem_done = dmem_rsp_valid && (dmem_rsp_addr == exmem_alu);
  assign dmem_req = !rst && !halt && exmem_valid && is_memory_op && !dmem_done;
  assign mem_wait = !rst && !halt && exmem_valid && is_memory_op && !dmem_done;
  assign commit_valid = !rst && !halt && exmem_valid && !mem_wait;
  assign commit_pc = exmem_pc;
  assign commit_instr = exmem_instr;
  assign commit_rd = exmem_rd;
  assign commit_wdata = exmem_is_load ? load_data : exmem_wbval;
  assign fence_req = exmem_valid && exmem_is_fence_i && !fence_done;
  assign mem_redirect = exmem_valid && exmem_is_fence_i && fence_done;

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

  always_ff @(posedge clk) begin
    if (rst) begin
      memwb_valid <= 1'b0;
      memwb_wbval <= '0;
      memwb_load_data <= '0;
      memwb_rd <= '0;
      memwb_regwrite <= 1'b0;
      memwb_is_load <= 1'b0;
    end else if (halt || mem_wait || fence_req) begin
      // Wait for the memory response or the FENCE.I cache flush.
    end else begin
      memwb_valid <= exmem_valid;
      memwb_wbval <= exmem_wbval;
      memwb_load_data <= load_data;
      memwb_rd <= exmem_rd;
      memwb_regwrite <= exmem_regwrite;
      memwb_is_load <= exmem_is_load;
    end
  end

endmodule
