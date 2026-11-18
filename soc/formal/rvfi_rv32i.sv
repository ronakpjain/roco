`include "axi4_defs.svh"
`default_nettype none
`ifdef ROCO_FORMAL_MULTIPLY
`define ROCO_FORMAL_ISA_MODEL rvfi_isa_rv32i_mul
`else
`define ROCO_FORMAL_ISA_MODEL rvfi_isa_rv32i
`endif

module rvfi_rv32i #(
    parameter bit AccountingOnly = 1'b0,
    parameter bit CoherentMemory = 1'b0,
    parameter bit Atomics = 1'b0,
    parameter bit RegisterOnly = 1'b0,
    parameter bit StorageOnly = 1'b0
) (
  input logic clk
);
  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;

  localparam logic [31:0] BootAddr = 32'h1000_0000;
  logic imem_req, imem_rsp_valid;
  logic [31:0] imem_addr, imem_rsp_addr, imem_rsp_data;
  (* anyseq *) logic [31:0] fetch_word;
  (* anyseq *) logic [31:0] other_load_word;
  logic [31:0] load_word, dmem_addr, dmem_wdata;
  logic [3:0] dmem_be;
  logic dmem_req, dmem_we;
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
  logic trace_valid;
  logic [31:0] trace_pc, trace_instr;
  (* anyconst *) logic [4:0] tracked_reg;
`ifdef ROCO_RVFI_GPR_STATE
  logic [31:0] tracked_physical_value;
`endif

  roco_cpu dut (
`ifdef ROCO_RVFI_GPR_STATE
      .rvfi_gpr_watch_addr(tracked_reg),
      .rvfi_gpr_watch_value(tracked_physical_value),
`endif
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
      .dmem_req(dmem_req),
      .dmem_valid(),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_be(dmem_be),
      .dmem_rsp_data(load_word),
      .dmem_forward_data(32'd0),
      .ptw_bus_rst(rst),
      .ptw_ar(),
      .ptw_ready(1'b0),
      .ptw_r(ptw_r),
      .ptw_r_ready(),
      .trace_valid(trace_valid),
      .trace_pc(trace_pc),
      .trace_instr(trace_instr),
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

  if (CoherentMemory) begin : g_memory
    (* anyconst *) logic [29:0] watched_addr;
    (* anyconst *) logic [31:0] initial_word;
    logic [31:0] physical_word, architectural_word;
    logic [3:0] written_lanes;
    logic rvfi_access, failed_sc;
    // MEM may issue a cache access for a failed SC but may not write to it.
    assign failed_sc = Atomics && rvfi_valid && !rvfi_trap &&
                       rvfi_insn[6:0] == 7'h2f && rvfi_insn[31:27] == 5'd3 &&
                       rvfi_mem_wmask == 0;
    assign rvfi_access = rvfi_valid && !rvfi_trap && (|rvfi_mem_rmask || |rvfi_mem_wmask);
    assign load_word = dmem_addr[31:2] == watched_addr ? physical_word : other_load_word;

    always @(posedge clk) begin
      if (rst) begin
        physical_word <= initial_word;
        architectural_word <= initial_word;
        written_lanes <= 0;
      end else begin
        assert (physical_word == architectural_word);
        // Check the actual side effect, not just the RVFI metadata. Bare
        // M-mode makes the physical and architectural addresses identical.
        assert (dmem_req == (rvfi_access || failed_sc));
        if (dmem_req) begin
          assert (dmem_addr[31:2] == rvfi_mem_addr[31:2]);
          assert (dmem_we == (|rvfi_mem_wmask));
          if (dmem_we) assert (dmem_be == rvfi_mem_wmask);
        end
        for (integer i = 0; i < 4; i = i + 1) begin
          if (dmem_req && dmem_we && dmem_be[i]) begin
            assert (dmem_wdata[8*i+:8] == rvfi_mem_wdata[8*i+:8]);
            if (dmem_addr[31:2] == watched_addr) physical_word[8*i+:8] <= dmem_wdata[8*i+:8];
          end
          if (rvfi_access && rvfi_mem_addr[31:2] == watched_addr) begin
            if (rvfi_mem_wmask[i]) begin
              architectural_word[8*i+:8] <= rvfi_mem_wdata[8*i+:8];
              written_lanes[i] <= 1;
            end
            if (rvfi_mem_rmask[i]) assert (rvfi_mem_rdata[8*i+:8] == architectural_word[8*i+:8]);
          end
        end
        cover (rvfi_access && rvfi_mem_addr[31:2] == watched_addr &&
               |(rvfi_mem_rmask & written_lanes) && architectural_word != initial_word);
      end
    end
  end else begin : g_unconstrained_memory
    assign load_word = other_load_word;
  end

  // Restrict the *environment's fetch words*, not what the DUT retires.
  // Include a few exception cases absent from the upstream instruction model.
  function automatic logic extra_trap(input logic [31:0] word);
    extra_trap = word == 32'h0000_0073 || word == 32'h0010_0073 || word == 0;
  endfunction

  function automatic logic atomic_fetch(input logic [31:0] word);
    atomic_fetch = 0;
    if (word[6:0] == 7'h2f && word[14:12] == 3'd2) begin
      case (word[31:27])
        2: atomic_fetch = word[24:20] == 0;
        0, 1, 3, 4, 8, 12, 16, 20, 24, 28: atomic_fetch = 1;
        default: atomic_fetch = 0;
      endcase
    end
  endfunction

  logic fetch_supported;
  `ROCO_FORMAL_ISA_MODEL fetch_decode (
      .rvfi_valid(1'b1),
      .rvfi_insn(fetch_word),
      .rvfi_pc_rdata(32'd0),
      .rvfi_rs1_rdata(32'd0),
      .rvfi_rs2_rdata(32'd0),
      .rvfi_mem_rdata(32'd0),
      .spec_valid(fetch_supported),
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
    if (!rst && imem_req) begin
      assume (fetch_supported || extra_trap(fetch_word) || (Atomics && atomic_fetch(fetch_word)));
`ifdef ROCO_RVFI_NO_DIV_CHECKS
      // Redundant with the RV32I decoder above. Keep the one forbidden
      // encoding class explicit so the frontend invariant has a small cone.
      assume (!(fetch_word[6:0] == 7'h33 && fetch_word[31:25] == 1 && fetch_word[14]));
`endif
    end
  end

  // Keep these assertions independent of the ISA model so PDR can prove them
  // without tracking the register file or predicting the next retired PC.
  always @(posedge clk) begin
    if (!rst) begin
      assert (!(trace_valid && rvfi_trap));
      assert (rvfi_valid == (trace_valid || rvfi_trap));
      if (trace_valid) assert (rvfi_pc_rdata == trace_pc && rvfi_insn == trace_instr);
      if (rvfi_valid && rvfi_trap) begin
        assert (rvfi_rd_addr == 0 && rvfi_rd_wdata == 0);
        assert (rvfi_mem_rmask == 0 && rvfi_mem_wmask == 0);
      end
      if ($past(rst)) assert (rvfi_order == 0);
    end
  end

  // Prove the increment bitwise: bit n toggles iff all lower bits carry.
  // This is equivalent to a 64-bit increment modulo 2**64, without asking
  // the reachability engine to learn relationships between whole counters.
  for (genvar bit_idx = 0; bit_idx < 64; bit_idx++) begin : g_order
    logic toggle;
    if (bit_idx == 0) assign toggle = rvfi_valid;
    else assign toggle = rvfi_valid && (&rvfi_order[bit_idx-1:0]);
    always @(posedge clk) begin
      if (!rst && !$past(rst))
        assert (rvfi_order[bit_idx] == ($past(rvfi_order[bit_idx]) ^ $past(toggle)));
    end
  end

  if (!AccountingOnly || RegisterOnly) begin : g_registers
    // This check is independent of instruction semantics: every reported
    // operand must reflect the newest architectural write to that register.
    logic [31:0] tracked_value;
    always @(posedge clk) begin
      if (rst) tracked_value <= 0;
      else begin
`ifdef ROCO_RVFI_GPR_STATE
        // Retirement drives MEM/WB first; the array receives it one edge
        // later. Writeback bypass supplies the current value before that.
        if (!$past(rst)) begin
          assert (tracked_physical_value == $past(tracked_value));
        end else begin
          assert (tracked_physical_value == 0);
        end
`endif
        if (rvfi_valid) begin
          if (!StorageOnly) begin
            if (rvfi_rs1_addr == tracked_reg) assert (rvfi_rs1_rdata == tracked_value);
            if (rvfi_rs2_addr == tracked_reg) assert (rvfi_rs2_rdata == tracked_value);
          end
          if (!rvfi_trap && rvfi_rd_addr == tracked_reg && tracked_reg != 0)
            tracked_value <= rvfi_rd_wdata;
        end
      end
    end
  end

  if (!AccountingOnly) begin : g_isa
    typedef struct packed {
      logic valid, trap;
      logic [4:0] rs1, rs2, rd;
      logic [31:0] rd_data, pc, addr, wdata;
      logic [3:0] rmask, wmask;
    } expected_t;
    expected_t base_spec, atomic_spec, spec;
    assign spec = atomic_spec.valid ? atomic_spec : base_spec;
    `ROCO_FORMAL_ISA_MODEL spec_model (
        .rvfi_valid(rvfi_valid),
        .rvfi_insn(rvfi_insn),
        .rvfi_pc_rdata(rvfi_pc_rdata),
        .rvfi_rs1_rdata(rvfi_rs1_rdata),
        .rvfi_rs2_rdata(rvfi_rs2_rdata),
        .rvfi_mem_rdata(rvfi_mem_rdata),
        .spec_valid(base_spec.valid),
        .spec_trap(base_spec.trap),
        .spec_rs1_addr(base_spec.rs1),
        .spec_rs2_addr(base_spec.rs2),
        .spec_rd_addr(base_spec.rd),
        .spec_rd_wdata(base_spec.rd_data),
        .spec_pc_wdata(base_spec.pc),
        .spec_mem_addr(base_spec.addr),
        .spec_mem_rmask(base_spec.rmask),
        .spec_mem_wmask(base_spec.wmask),
        .spec_mem_wdata(base_spec.wdata)
    );
    if (Atomics) begin : g_atomic
      rvfi_rv32a_model atomic_model (
          .clk(clk),
          .rst(rst),
          .rvfi_valid(rvfi_valid),
          .rvfi_trap(rvfi_trap),
          .rvfi_insn(rvfi_insn),
          .rvfi_pc_rdata(rvfi_pc_rdata),
          .rvfi_rs1_rdata(rvfi_rs1_rdata),
          .rvfi_rs2_rdata(rvfi_rs2_rdata),
          .rvfi_mem_addr(rvfi_mem_addr),
          .rvfi_mem_rdata(rvfi_mem_rdata),
          .rvfi_mem_wmask(rvfi_mem_wmask),
          .spec_valid(atomic_spec.valid),
          .spec_trap(atomic_spec.trap),
          .spec_rs1(atomic_spec.rs1),
          .spec_rs2(atomic_spec.rs2),
          .spec_rd(atomic_spec.rd),
          .spec_rd_data(atomic_spec.rd_data),
          .spec_pc(atomic_spec.pc),
          .spec_addr(atomic_spec.addr),
          .spec_wdata(atomic_spec.wdata),
          .spec_rmask(atomic_spec.rmask),
          .spec_wmask(atomic_spec.wmask)
      );
    end else begin : g_no_atomic
      assign atomic_spec = '0;
    end

    logic [31:0] expected_pc;
    logic expected_handler;
    always @(posedge clk) begin
      if (rst) begin
        expected_pc <= BootAddr;
        expected_handler <= 0;
      end else if (rvfi_valid) begin
        assert (rvfi_pc_rdata == expected_pc);
        assert (rvfi_intr == expected_handler);
        assert (rvfi_mode == 3 && rvfi_ixl == 1);
        assert (spec.valid || extra_trap(rvfi_insn));
        assert (rvfi_trap == (spec.trap || extra_trap(rvfi_insn)));
        if (rvfi_trap) begin
          // mtvec is reset to zero, with no CSR writes or interrupts in this harness.
          assert (rvfi_pc_wdata == 0);
        end else begin
          assert (rvfi_rs1_addr == spec.rs1 && rvfi_rs2_addr == spec.rs2);
          assert (rvfi_rd_addr == spec.rd && rvfi_rd_wdata == spec.rd_data);
          assert (rvfi_pc_wdata == spec.pc);
          assert (rvfi_mem_rmask == spec.rmask && rvfi_mem_wmask == spec.wmask);
          if (|spec.rmask || |spec.wmask) assert (rvfi_mem_addr == spec.addr);
          for (integer i = 0; i < 4; i = i + 1)
          if (spec.wmask[i]) assert (rvfi_mem_wdata[8*i+:8] == spec.wdata[8*i+:8]);
        end
        expected_pc <= rvfi_pc_wdata;
        expected_handler <= rvfi_trap;
      end
    end
  end

`ifdef ROCO_FORMAL_MULTIPLY
  for (genvar op = 0; op < 4; op++) begin : g_mul_cover
    always @(posedge clk) begin
      if (!rst)
        cover (rvfi_valid && !rvfi_trap && rvfi_insn[31:25] == 7'd1 &&
                       rvfi_insn[6:0] == 7'h33 && rvfi_insn[14:12] == 3'(op) &&
                       rvfi_rd_addr != 0 && rvfi_rd_wdata != 0);
    end
  end
`endif

  always @(posedge clk) begin
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
`undef ROCO_FORMAL_ISA_MODEL
