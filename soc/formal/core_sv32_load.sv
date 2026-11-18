`include "axi4_defs.svh"
`default_nettype none

module core_sv32_load (
  input logic clk
);
  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;
  localparam logic [31:0] Boot = 32'h1000_0000, Handler = Boot + 32'h80;
  localparam logic [31:0] Virtual = 32'h2000_0040, Physical = 32'h1000_0040;
  (* anyconst *) logic readable;
  (* anyconst *) logic [31:0] loaded;

  logic imem_req, imem_rsp_valid;
  logic [31:0] imem_addr, imem_rsp_addr, imem_rsp_data;
  always @(posedge clk) begin
    imem_rsp_valid <= !rst && imem_req;
    imem_rsp_addr <= imem_addr;
    case (imem_addr)
      Boot: imem_rsp_data <= 32'h1000_00b7;  // lui x1, 0x10000
      Boot + 4: imem_rsp_data <= 32'h0800_8093;  // addi x1, x1, 0x80
      Boot + 8: imem_rsp_data <= 32'h3050_9073;  // csrw mtvec, x1
      Boot + 12: imem_rsp_data <= 32'h8001_00b7;  // lui x1, 0x80010
      Boot + 16: imem_rsp_data <= 32'h0010_8093;  // addi x1, x1, 1
      Boot + 20: imem_rsp_data <= 32'h1800_9073;  // csrw satp, x1
      Boot + 24: imem_rsp_data <= 32'h0002_00b7;  // lui x1, 0x20 (MPRV)
      Boot + 28: imem_rsp_data <= 32'h3000_9073;  // csrw mstatus, x1
      Boot + 32: imem_rsp_data <= 32'h2000_00b7;  // lui x1, 0x20000
      Boot + 36: imem_rsp_data <= 32'h0400_a103;  // lw x2, 0x40(x1)
      Boot + 40: imem_rsp_data <= 32'h0011_0193;  // addi x3, x2, 1
      Handler: imem_rsp_data <= 32'h3420_21f3;  // csrr x3, mcause
      Handler + 4: imem_rsp_data <= 32'h3430_2273;  // csrr x4, mtval
      default: imem_rsp_data <= 32'h0000_006f;  // jal x0, 0
    endcase
  end

  axi4_ar_t ptw_ar;
  axi4_r_t ptw_r;
  logic ptw_ready, ptw_r_ready, reply, walked;
  logic [3:0] reply_id;
  assign ptw_ready = !reply;
  assign ptw_r.valid = reply;
  assign ptw_r.id = reply_id;
  assign ptw_r.data = readable ? 32'h0400_00d7 : 32'h0400_00d9;
  assign ptw_r.resp = `AXI4_RESP_OKAY;
  assign ptw_r.last = 1'b1;
  always @(posedge clk) begin
    if (rst) begin
      reply <= 0;
      walked <= 0;
      reply_id <= 0;
    end else begin
      if (reply && ptw_r_ready) reply <= 0;
      if (ptw_ar.valid && ptw_ready) begin
        assert (!walked);
        assert (ptw_ar.addr == 32'h1000_1200 && ptw_ar.len == 0 && ptw_ar.size == 2);
        walked <= 1;
        reply <= 1;
        reply_id <= ptw_ar.id;
      end
    end
  end

  logic dmem_req, dmem_we;
  logic [31:0] dmem_addr;
  logic rvfi_valid, rvfi_trap, rvfi_intr;
  logic [31:0] rvfi_pc, rvfi_next_pc, rvfi_rd_data, rvfi_mem_addr;
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
      .dmem_rsp_data(loaded),
      .dmem_forward_data(32'd0),
      .ptw_bus_rst(rst),
      .ptw_ar(ptw_ar),
      .ptw_ready(ptw_ready),
      .ptw_r(ptw_r),
      .ptw_r_ready(ptw_r_ready),
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
      .rvfi_mem_addr(rvfi_mem_addr),
      .rvfi_mem_rmask(),
      .rvfi_mem_wmask(),
      .rvfi_mem_rdata(),
      .rvfi_mem_wdata()
  );

  logic [3:0] retired, last_phase;
  logic [5:0] elapsed;
  logic [31:0] expected_pc;
  assign last_phase = readable ? 4'd11 : 4'd12;
  assign expected_pc = readable || retired <= 9 ? Boot + (32'(retired) << 2) :
                                                   Handler + ((32'(retired) - 10) << 2);
  always @(posedge clk) begin
    if (rst) begin
      retired <= 0;
      elapsed <= 0;
    end else begin
      if (elapsed == 52)
        assert (retired == last_phase);
        else elapsed <= elapsed + 1'b1;
      if (dmem_req) begin
        assert (!dmem_we && readable && walked && rvfi_valid && retired == 9);
        assert (dmem_addr == Physical);
      end
      if (rvfi_valid) begin
        assert (rvfi_mode == 3 && rvfi_pc == expected_pc);
        assert (rvfi_trap == (!readable && retired == 9));
        assert (rvfi_intr == (!readable && retired == 10));
        if (retired == 9) begin
          assert (walked);
          if (readable) begin
            assert (dmem_req && rvfi_mem_addr == Virtual);
            assert (rvfi_rd == 2 && rvfi_rd_data == loaded);
          end else begin
            assert (!dmem_req && rvfi_next_pc == Handler && rvfi_rd == 0);
          end
        end
        if (retired == 10) begin
          assert (rvfi_rd == 3);
          assert (rvfi_rd_data == (readable ? loaded + 1 : 13));
        end
        if (!readable && retired == 11) assert (rvfi_rd == 4 && rvfi_rd_data == Virtual);
        if (retired != last_phase) retired <= retired + 1;
      end
      cover (retired == last_phase && readable);
      cover (retired == last_phase && !readable);
    end
  end
endmodule
