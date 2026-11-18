`include "axi4_defs.svh"
`default_nettype none

module rvfi_rv32i (
  input logic clk
);
  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;

  localparam logic [31:0] BootAddr = 32'h1000_0000;
  logic imem_req, imem_rsp_valid;
  logic [31:0] imem_addr, imem_rsp_addr, imem_rsp_data;
  (* anyseq *) logic [31:0] fetch_word;
  (* anyseq *) logic [31:0] load_word;
  axi4_r_t ptw_r;
  assign ptw_r = '0;

  logic rvfi_valid, rvfi_trap, rvfi_intr;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn, rvfi_pc_rdata, rvfi_pc_wdata;
  logic [4:0] rvfi_rs1_addr, rvfi_rs2_addr, rvfi_rd_addr;
  logic [31:0] rvfi_rs1_rdata, rvfi_rs2_rdata, rvfi_rd_wdata;
  logic [31:0] rvfi_mem_addr, rvfi_mem_rdata, rvfi_mem_wdata;
  logic [3:0] rvfi_mem_rmask, rvfi_mem_wmask;
  logic [1:0] rvfi_mode, rvfi_ixl;

  roco_cpu dut (
      .clk(clk),
      .rst(rst),
      .boot_addr(BootAddr),
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
      .dmem_req(),
      .dmem_valid(),
      .dmem_we(),
      .dmem_addr(),
      .dmem_wdata(),
      .dmem_be(),
      .dmem_rsp_data(load_word),
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
      .rvfi_halt(),
      .rvfi_valid(rvfi_valid),
      .rvfi_order(rvfi_order),
      .rvfi_insn(rvfi_insn),
      .rvfi_trap(rvfi_trap),
      .rvfi_intr(rvfi_intr),
      .rvfi_mode(rvfi_mode),
      .rvfi_ixl(rvfi_ixl),
      .rvfi_rs1_addr(rvfi_rs1_addr),
      .rvfi_rs2_addr(rvfi_rs2_addr),
      .rvfi_rd_addr(rvfi_rd_addr),
      .rvfi_rs1_rdata(rvfi_rs1_rdata),
      .rvfi_rs2_rdata(rvfi_rs2_rdata),
      .rvfi_rd_wdata(rvfi_rd_wdata),
      .rvfi_pc_rdata(rvfi_pc_rdata),
      .rvfi_pc_wdata(rvfi_pc_wdata),
      .rvfi_mem_addr(rvfi_mem_addr),
      .rvfi_mem_rdata(rvfi_mem_rdata),
      .rvfi_mem_wdata(rvfi_mem_wdata),
      .rvfi_mem_rmask(rvfi_mem_rmask),
      .rvfi_mem_wmask(rvfi_mem_wmask)
  );

  // Restrict the *environment's fetch words*, not what the DUT retires.
  // Include a few exception cases absent from the upstream instruction model.
  function automatic logic extra_trap(input logic [31:0] word);
    extra_trap = word == 32'h0000_0073 || word == 32'h0010_0073 || word == 0;
  endfunction

  logic fetch_rv32i;
  rvfi_isa_rv32i fetch_decode (
      .rvfi_valid(1'b1),
      .rvfi_insn(fetch_word),
      .rvfi_pc_rdata(32'd0),
      .rvfi_rs1_rdata(32'd0),
      .rvfi_rs2_rdata(32'd0),
      .rvfi_mem_rdata(32'd0),
      .spec_valid(fetch_rv32i),
      .spec_trap(),
      .spec_rs1_addr(),
      .spec_rs2_addr(),
      .spec_rd_addr(),
      .spec_rd_wdata(),
      .spec_pc_wdata(),
      .spec_mem_addr(),
      .spec_mem_rmask(),
      .spec_mem_wmask(),
      .spec_mem_wdata()
  );

  always @(posedge clk) begin
    imem_rsp_valid <= !rst && imem_req;
    imem_rsp_addr <= imem_addr;
    imem_rsp_data <= fetch_word;
    if (!rst && imem_req) assume (fetch_rv32i || extra_trap(fetch_word));
  end

  logic spec_valid, spec_trap;
  logic [4:0] spec_rs1, spec_rs2, spec_rd;
  logic [31:0] spec_rd_data, spec_pc, spec_addr, spec_wdata;
  logic [3:0] spec_rmask, spec_wmask;
  rvfi_isa_rv32i spec_model (
      .rvfi_valid(rvfi_valid),
      .rvfi_insn(rvfi_insn),
      .rvfi_pc_rdata(rvfi_pc_rdata),
      .rvfi_rs1_rdata(rvfi_rs1_rdata),
      .rvfi_rs2_rdata(rvfi_rs2_rdata),
      .rvfi_mem_rdata(rvfi_mem_rdata),
      .spec_valid(spec_valid),
      .spec_trap(spec_trap),
      .spec_rs1_addr(spec_rs1),
      .spec_rs2_addr(spec_rs2),
      .spec_rd_addr(spec_rd),
      .spec_rd_wdata(spec_rd_data),
      .spec_pc_wdata(spec_pc),
      .spec_mem_addr(spec_addr),
      .spec_mem_rmask(spec_rmask),
      .spec_mem_wmask(spec_wmask),
      .spec_mem_wdata(spec_wdata)
  );

  (* anyconst *) logic [4:0] tracked_reg;
  logic [31:0] tracked_value, expected_pc;
  logic [63:0] expected_order;
  logic expected_handler;
  always @(posedge clk) begin
    if (rst) begin
      tracked_value <= 0;
      expected_order <= 0;
      expected_pc <= BootAddr;
      expected_handler <= 0;
    end else if (rvfi_valid) begin
      assert (rvfi_order == expected_order);
      assert (rvfi_pc_rdata == expected_pc);
      assert (rvfi_intr == expected_handler);
      assert (rvfi_mode == 3 && rvfi_ixl == 1);
      assert (spec_valid || extra_trap(rvfi_insn));
      assert (rvfi_trap == (spec_trap || extra_trap(rvfi_insn)));
      if (rvfi_rs1_addr == tracked_reg) assert (rvfi_rs1_rdata == tracked_value);
      if (rvfi_rs2_addr == tracked_reg) assert (rvfi_rs2_rdata == tracked_value);
      if (rvfi_trap) begin
        assert (rvfi_rd_addr == 0 && rvfi_rd_wdata == 0);
        assert (rvfi_mem_rmask == 0 && rvfi_mem_wmask == 0);
        // mtvec is reset to zero, with no CSR writes or interrupts in this harness.
        assert (rvfi_pc_wdata == 0);
      end else begin
        assert (rvfi_rs1_addr == spec_rs1 && rvfi_rs2_addr == spec_rs2);
        assert (rvfi_rd_addr == spec_rd && rvfi_rd_wdata == spec_rd_data);
        assert (rvfi_pc_wdata == spec_pc);
        assert (rvfi_mem_rmask == spec_rmask && rvfi_mem_wmask == spec_wmask);
        if (|spec_rmask || |spec_wmask) assert (rvfi_mem_addr == spec_addr);
        for (integer i = 0; i < 4; i = i + 1)
        if (spec_wmask[i]) assert (rvfi_mem_wdata[8*i+:8] == spec_wdata[8*i+:8]);
        if (rvfi_rd_addr == tracked_reg && tracked_reg != 0) tracked_value <= rvfi_rd_wdata;
      end
      expected_pc <= rvfi_pc_wdata;
      expected_order <= expected_order + 1;
      expected_handler <= rvfi_trap;
    end
    if (!rst) begin
      cover (rvfi_valid && rvfi_order == 3);
      cover (rvfi_valid && rvfi_trap);
      cover (rvfi_valid && rvfi_intr);
      cover (rvfi_valid && |rvfi_mem_rmask);
      cover (rvfi_valid && |rvfi_mem_wmask);
      cover (rvfi_valid && !rvfi_trap && rvfi_pc_wdata != rvfi_pc_rdata + 4);
    end
  end
endmodule
