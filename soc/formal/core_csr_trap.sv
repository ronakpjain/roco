`include "axi4_defs.svh"
`default_nettype none

// Whole-core M-mode CSR read/write and precise ECALL/MRET integration.
module core_csr_trap (
  input logic clk
);
  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;
  localparam logic [31:0] Boot = 32'h1000_0000, Handler = Boot + 32'h80, EcallPc = Boot + 24;
  (* anyconst *) logic [31:0] scratch;

  function automatic [31:0] csr(input logic [11:0] address, input logic [4:0] rs1,
                                input logic [2:0] funct3, input logic [4:0] rd);
    csr = {address, rs1, funct3, rd, 7'h73};
  endfunction

  logic imem_req, imem_rsp_valid;
  logic [31:0] imem_addr, imem_rsp_addr, imem_rsp_data;
  always @(posedge clk) begin
    imem_rsp_valid <= !rst && imem_req;
    imem_rsp_addr <= imem_addr;
    case (imem_addr)
      Boot: imem_rsp_data <= 32'h1000_00b7;  // lui x1, 0x10000
      Boot + 4: imem_rsp_data <= 32'h0800_8093;  // addi x1, x1, 0x80
      Boot + 8: imem_rsp_data <= csr(12'h305, 5'd1, 3'd1, 5'd0);  // csrw mtvec, x1
      Boot + 12: imem_rsp_data <= 32'h1000_2103;  // lw x2, 0x100(x0)
      Boot + 16: imem_rsp_data <= csr(12'h340, 5'd2, 3'd1, 5'd3);  // csrrw x3, mscratch, x2
      Boot + 20: imem_rsp_data <= csr(12'h340, 5'd0, 3'd2, 5'd4);  // csrr x4, mscratch
      EcallPc: imem_rsp_data <= 32'h0000_0073;
      EcallPc + 4: imem_rsp_data <= 32'h0120_0393;  // addi x7, x0, 0x12
      Handler: imem_rsp_data <= csr(12'h341, 5'd0, 3'd2, 5'd5);  // csrr x5, mepc
      Handler + 4: imem_rsp_data <= csr(12'h342, 5'd0, 3'd2, 5'd6);  // csrr x6, mcause
      Handler + 8: imem_rsp_data <= 32'h0042_8293;  // addi x5, x5, 4
      Handler + 12: imem_rsp_data <= csr(12'h341, 5'd5, 3'd1, 5'd0);  // csrw mepc, x5
      Handler + 16: imem_rsp_data <= 32'h3020_0073;  // mret
      default: imem_rsp_data <= 32'h0000_006f;  // jal x0, 0
    endcase
  end

  axi4_r_t ptw_r;
  assign ptw_r = '0;
  logic dmem_req, dmem_we;
  logic [31:0] dmem_addr;
  logic rvfi_valid, rvfi_trap, rvfi_intr;
  logic [31:0] rvfi_pc, rvfi_next_pc, rvfi_rd_data;
  logic [4:0] rvfi_rd;
  logic [1:0] rvfi_mode;
  roco_cpu dut (
      .clk(clk),
      .rst(rst),
      .boot_addr(Boot),
      .halt(1'b0),
      .irq_timer(1'b0),
      .irq_external(1'b0),
      .imem_req(imem_req),
      .imem_addr(imem_addr),
      .imem_rsp_valid(imem_rsp_valid),
      .imem_rsp_addr(imem_rsp_addr),
      .imem_rsp_data(imem_rsp_data),
      .imem_miss(1'b0),
      .imem_busy(1'b0),
      .dmem_lu_valid(),
      .dmem_lu_addr(),
      .dmem_lu_offset(),
      .dmem_lu_funct3(),
      .dmem_ready(1'b1),
      .dmem_req(dmem_req),
      .dmem_valid(),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(),
      .dmem_be(),
      .dmem_rsp_data(scratch),
      .dmem_forward_data(32'd0),
      .ptw_bus_rst(rst),
      .ptw_ar(),
      .ptw_ready(1'b0),
      .ptw_r(ptw_r),
      .ptw_r_ready(),
      .trace_valid(),
      .trace_pc(),
      .trace_instr(),
      .trace_rd(),
      .trace_wdata(),
      .fence_req(),
      .fence_done(1'b1),
      .rvfi_valid(rvfi_valid),
      .rvfi_trap(rvfi_trap),
      .rvfi_pc_rdata(rvfi_pc),
      .rvfi_pc_wdata(rvfi_next_pc),
      .rvfi_rd_addr(rvfi_rd),
      .rvfi_rd_wdata(rvfi_rd_data),
      .rvfi_intr(rvfi_intr),
      .rvfi_mode(rvfi_mode),
      .rvfi_order(),
      .rvfi_insn(),
      .rvfi_halt(),
      .rvfi_ixl(),
      .rvfi_rs1_addr(),
      .rvfi_rs2_addr(),
      .rvfi_rs1_rdata(),
      .rvfi_rs2_rdata(),
      .rvfi_mem_addr(),
      .rvfi_mem_rmask(),
      .rvfi_mem_wmask(),
      .rvfi_mem_rdata(),
      .rvfi_mem_wdata()
  );

  logic [3:0] retired;
  logic [5:0] elapsed;
  logic [31:0] expected_pc, expected_next_pc;
  always_comb begin
    if (retired <= 6) expected_pc = Boot + (32'(retired) << 2);
    else if (retired <= 11) expected_pc = Handler + ((32'(retired) - 7) << 2);
    else if (retired == 12) expected_pc = EcallPc + 4;
    else expected_pc = EcallPc + 8;
    case (retired)
      6: expected_next_pc = Handler;
      11: expected_next_pc = EcallPc + 4;
      13: expected_next_pc = expected_pc;
      default: expected_next_pc = expected_pc + 4;
    endcase
  end

  always @(posedge clk) begin
    if (rst) begin
      retired <= 0;
      elapsed <= 0;
    end else begin
      if (elapsed == 45) begin
        assert (retired == 13);
      end else begin
        elapsed <= elapsed + 1'b1;
      end
      if (dmem_req) assert (!dmem_we && rvfi_valid && retired == 3 && dmem_addr == 32'h100);
      if (rvfi_valid) begin
        assert (rvfi_trap == (retired == 6));
        assert (rvfi_intr == (retired == 7));
        assert (rvfi_mode == 3 && rvfi_pc == expected_pc && rvfi_next_pc == expected_next_pc);
        case (retired)
          0: assert (rvfi_rd == 1 && rvfi_rd_data == Boot);
          1: assert (rvfi_rd == 1 && rvfi_rd_data == Handler);
          3: assert (dmem_req && rvfi_rd == 2 && rvfi_rd_data == scratch);
          4: assert (rvfi_rd == 3 && rvfi_rd_data == 0);
          5: assert (rvfi_rd == 4 && rvfi_rd_data == scratch);
          7: assert (rvfi_rd == 5 && rvfi_rd_data == EcallPc);
          8: assert (rvfi_rd == 6 && rvfi_rd_data == 11);
          9: assert (rvfi_rd == 5 && rvfi_rd_data == EcallPc + 4);
          12: assert (rvfi_rd == 7 && rvfi_rd_data == 32'h12);
          default: assert (rvfi_rd == 0);
        endcase
        if (retired != 13) retired <= retired + 1;
      end
      cover (retired == 13 && scratch != 0);
    end
  end
endmodule
