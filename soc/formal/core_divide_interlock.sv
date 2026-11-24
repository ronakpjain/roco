`include "axi4_defs.svh"
`default_nettype none

module core_divide_interlock (
  input logic clk
);
  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;
  localparam logic [31:0] Boot = 32'h1000_0000;
  (* anyconst *) logic [31:0] a, b;
  (* anyconst *) logic [1:0] kind;
  logic [2:0] op;
  assign op = {1'b1, kind};

  logic rvfi_div_start, rvfi_div_wb_valid;
  logic [2:0] rvfi_div_op;
  logic [4:0] rvfi_div_wb_rd;
  logic [31:0] rvfi_div_a, rvfi_div_b, rvfi_div_wb_data;
  logic issued, wrote;
  logic [31:0] written_value;
`ifndef ROCO_FORMAL_DIV_CUTPOINT
  logic ref_done, ref_available;
  logic [31:0] ref_result;
  // The divider job proves this unit's arithmetic. Here the reference runs
  // in lockstep with it, and launch operands are checked independently
  // against the program's architectural operands on every launch.
  roco_cpu_divider reference (
      .clk(clk),
      .rst(rst),
      .halt(1'b0),
      .op(rvfi_div_op),
      .a(rvfi_div_a),
      .b(rvfi_div_b),
      .start(rvfi_div_start),
      .busy(),
      .done(ref_done),
      .div_result(ref_result)
  );
`endif

  logic imem_req, imem_rsp_valid;
  logic [31:0] imem_addr, imem_rsp_addr, imem_rsp_data;
  always @(posedge clk) begin
    imem_rsp_valid <= !rst && imem_req;
    imem_rsp_addr <= imem_addr;
    case (imem_addr)
      Boot: imem_rsp_data <= 32'h1000_2083;  // lw x1, 0x100(x0)
      Boot + 4: imem_rsp_data <= 32'h1040_2103;  // lw x2, 0x104(x0)
      Boot + 8: imem_rsp_data <= {7'h01, 5'd2, 5'd1, op, 5'd3, 7'h33};
      Boot + 12: imem_rsp_data <= 32'h0070_0313;  // addi x6, x0, 7 (independent)
      Boot + 16: imem_rsp_data <= 32'h0011_8213;  // addi x4, x3, 1 (dependent)
      Boot + 20: imem_rsp_data <= 32'h00d0_0193;  // addi x3, x0, 13 (overwrite)
      Boot + 24: imem_rsp_data <= 32'h0001_8293;  // addi x5, x3, 0
      default: imem_rsp_data <= 32'h0000_006f;  // jal x0, 0
    endcase
  end

  axi4_r_t ptw_r;
  assign ptw_r = '0;
  logic dmem_req, dmem_we;
  logic [31:0] dmem_addr, load_word;
  assign load_word = dmem_addr[2] ? b : a;
  logic rvfi_valid, rvfi_trap;
  logic [31:0] rvfi_pc, rvfi_rd_data, rvfi_rs1_data, rvfi_rs2_data;
  logic [4:0] rvfi_rd;
  roco_cpu dut (
      .clk(clk),
      .rst(rst),
      .boot_addr(Boot),
      .halt(1'b0),
      .irq_timer(1'b0),
      .irq_external(1'b0),
      .irq_software(1'b0),
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
      .dmem_busy(1'b0),
      .dmem_req(dmem_req),
      .dmem_valid(),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(),
      .dmem_be(),
      .dmem_rsp_data(load_word),
      .dmem_forward_data(32'd0),
      .dmem_amo_retry(1'b0),
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
      .res_remote_valid(1'b0),
      .res_remote_addr(30'd0),
      .remote_tlb_flush(1'b0),
      .rvfi_div_start(rvfi_div_start),
      .rvfi_div_wb_valid(rvfi_div_wb_valid),
      .rvfi_div_op(rvfi_div_op),
      .rvfi_div_wb_rd(rvfi_div_wb_rd),
      .rvfi_div_a(rvfi_div_a),
      .rvfi_div_b(rvfi_div_b),
      .rvfi_div_wb_data(rvfi_div_wb_data),
      .rvfi_valid(rvfi_valid),
      .rvfi_trap(rvfi_trap),
      .rvfi_pc_rdata(rvfi_pc),
      .rvfi_rd_addr(rvfi_rd),
      .rvfi_rd_wdata(rvfi_rd_data),
      .rvfi_rs1_rdata(rvfi_rs1_data),
      .rvfi_rs2_rdata(rvfi_rs2_data),
      .rvfi_order(),
      .rvfi_insn(),
      .rvfi_halt(),
      .rvfi_intr(),
      .rvfi_mode(),
      .rvfi_ixl(),
      .rvfi_rs1_addr(),
      .rvfi_rs2_addr(),
      .rvfi_pc_wdata(),
      .rvfi_mem_addr(),
      .rvfi_mem_rmask(),
      .rvfi_mem_wmask(),
      .rvfi_mem_rdata(),
      .rvfi_mem_wdata()
  );

  logic [2:0] retired;
  logic [5:0] elapsed;
  always @(posedge clk) begin
    if (rst) begin
      retired <= 0;
      issued <= 0;
      wrote <= 0;
      written_value <= 0;
      elapsed <= 0;
`ifndef ROCO_FORMAL_DIV_CUTPOINT
      ref_available <= 0;
`endif
    end else begin
      // The program cannot hang in the deterministic, always-ready setup.
      if (elapsed == 42) begin
        assert (retired == 7);
      end else begin
        elapsed <= elapsed + 1'b1;
      end
      if (rvfi_div_start) begin
        assert (!issued && retired <= 2);
        assert ({rvfi_div_op, rvfi_div_a, rvfi_div_b} == {op, a, b});
        issued <= 1;
      end
`ifndef ROCO_FORMAL_DIV_CUTPOINT
      if (ref_done) ref_available <= 1;
`endif
      if (rvfi_div_wb_valid) begin
        assert (issued && !wrote && rvfi_div_wb_rd == 3);
`ifndef ROCO_FORMAL_DIV_CUTPOINT
        assert ((ref_done || ref_available) && rvfi_div_wb_data == ref_result);
`endif
        written_value <= rvfi_div_wb_data;
        wrote <= 1;
      end
      if (dmem_req) begin
        assert (rvfi_valid && !dmem_we && retired < 2);
        assert (dmem_addr == 32'h100 + (32'(retired) << 2));
      end
      if (rvfi_valid) begin
        assert (!rvfi_trap && rvfi_pc == Boot + (32'(retired) << 2));
        case (retired)
          0: assert (dmem_req && rvfi_rd == 1 && rvfi_rd_data == a);
          1: assert (dmem_req && rvfi_rd == 2 && rvfi_rd_data == b);
          2: assert (issued && rvfi_rs1_data == a && rvfi_rs2_data == b);
          3: assert (rvfi_rd == 6 && rvfi_rd_data == 7);
          4: assert (wrote && rvfi_rd == 4 && rvfi_rd_data == written_value + 32'd1);
          5: assert (rvfi_rd == 3 && rvfi_rd_data == 13);
          6: assert (rvfi_rd == 5 && rvfi_rd_data == 13);
          default: assert (rvfi_rd == 0);
        endcase
        if (retired != 7) retired <= retired + 1;
      end
      for (integer i = 0; i < 4; i = i + 1) cover (retired == 7 && kind == 2'(i));
    end
  end
endmodule
