// Standalone core testbench.
//
// Provides a 64 KiB word-addressed memory at 0x1000_0000, a UART byte
// sink at 0x8000_0000, and a halt/exit register at 0x8000_1000. All
// accesses return a response two cycles after the request, which is slow
// enough to exercise the load-use and memory-wait interlocks.
//
// Plusargs:
//   +hex=<file>        word image loaded at 0x1000_0000
//   +trace             print every retired instruction
//   +max_cycles=<n>    timeout, default 2_000_000

`timescale 1ns / 1ps

module tb_core;

  localparam int MEM_WORDS = 16384;
  localparam logic [31:0] MEM_BASE = 32'h1000_0000;
  localparam logic [31:0] UART_ADDR = 32'h8000_0000;
  localparam logic [31:0] EXIT_ADDR = 32'h8000_1000;

  logic clk;
  logic rst;
  logic halt;
  logic [31:0] boot_addr;

  logic imem_req;
  logic [31:0] imem_addr;
  logic imem_rsp_valid;
  logic [31:0] imem_rsp_addr;
  logic [31:0] imem_rsp_data;
  logic dmem_req;
  logic dmem_we;
  logic [31:0] dmem_addr;
  logic [31:0] dmem_wdata;
  logic [3:0] dmem_be;
  logic dmem_rsp_valid;
  logic [31:0] dmem_rsp_addr;
  logic [31:0] dmem_rsp_data;
  logic trace_valid;
  logic [31:0] trace_pc;
  logic [31:0] trace_instr;
  logic [4:0] trace_rd;
  logic [31:0] trace_wdata;

  logic [31:0] mem[0:MEM_WORDS-1];
  logic [31:0] imem_rdata;
  logic [31:0] dmem_rdata;

  logic im_busy;
  logic im_rsp_valid_q;
  logic [31:0] im_rsp_addr_q;
  logic [31:0] im_rsp_data_q;

  logic d_busy;
  logic d_rsp_valid_q;
  logic [31:0] d_rsp_addr_q;
  logic [31:0] d_rsp_data_q;
  logic [31:0] d_addr_q;

  logic [31:0] exit_code;
  int unsigned cycles;
  int unsigned max_cycles;
  int unsigned i;
  string hexfile;
  logic trace_on;

  assign halt = (exit_code != 32'd0);
  assign boot_addr = MEM_BASE;

  rv32_core u_core (
      .clk(clk),
      .rst(rst),
      .boot_addr(boot_addr),
      .halt(halt),
      .imem_req(imem_req),
      .imem_addr(imem_addr),
      .imem_rsp_valid(imem_rsp_valid),
      .imem_rsp_addr(imem_rsp_addr),
      .imem_rsp_data(imem_rsp_data),
      .dmem_req(dmem_req),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_be(dmem_be),
      .dmem_rsp_valid(dmem_rsp_valid),
      .dmem_rsp_addr(dmem_rsp_addr),
      .dmem_rsp_data(dmem_rsp_data),
      .trace_valid(trace_valid),
      .trace_pc(trace_pc),
      .trace_instr(trace_instr),
      .trace_rd(trace_rd),
      .trace_wdata(trace_wdata)
  );

  // ------------------------------------------------------------ Clock/reset
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // ------------------------------------------------------------- Memory read
  always_comb begin
    imem_rdata = 32'h0000_0013;
    if (imem_addr[31:16] == 16'h1000) begin
      imem_rdata = mem[imem_addr[15:2]];
    end
  end

  always_comb begin
    dmem_rdata = 32'd0;
    if (dmem_addr[31:16] == 16'h1000) begin
      dmem_rdata = mem[dmem_addr[15:2]];
    end
  end

  // -------------------------------------------------------------- I-port FSM
  always_ff @(posedge clk) begin
    if (rst) begin
      im_busy <= 1'b0;
      im_rsp_valid_q <= 1'b0;
      im_rsp_addr_q <= '0;
      im_rsp_data_q <= '0;
    end else begin
      im_rsp_valid_q <= 1'b0;
      if (!im_busy && !im_rsp_valid_q && imem_req) begin
        im_busy <= 1'b1;
        im_rsp_addr_q <= imem_addr;
        im_rsp_data_q <= imem_rdata;
      end else if (im_busy) begin
        im_busy <= 1'b0;
        im_rsp_valid_q <= 1'b1;
      end
    end
  end

  assign imem_rsp_valid = im_rsp_valid_q;
  assign imem_rsp_addr = im_rsp_addr_q;
  assign imem_rsp_data = im_rsp_data_q;

  // -------------------------------------------------------------- D-port FSM
  always_ff @(posedge clk) begin
    if (rst) begin
      d_busy <= 1'b0;
      d_rsp_valid_q <= 1'b0;
      d_rsp_addr_q <= '0;
      d_rsp_data_q <= '0;
      d_addr_q <= '0;
      exit_code <= '0;
    end else begin
      d_rsp_valid_q <= 1'b0;
      if (!d_busy && !d_rsp_valid_q && dmem_req) begin
        d_busy <= 1'b1;
        d_addr_q <= dmem_addr;
        if (!dmem_we) begin
          d_rsp_data_q <= dmem_rdata;
        end else if (dmem_addr[31:16] == 16'h1000) begin
          if (dmem_be[0]) begin
            mem[dmem_addr[15:2]][7:0] <= dmem_wdata[7:0];
          end
          if (dmem_be[1]) begin
            mem[dmem_addr[15:2]][15:8] <= dmem_wdata[15:8];
          end
          if (dmem_be[2]) begin
            mem[dmem_addr[15:2]][23:16] <= dmem_wdata[23:16];
          end
          if (dmem_be[3]) begin
            mem[dmem_addr[15:2]][31:24] <= dmem_wdata[31:24];
          end
        end else if (dmem_addr == UART_ADDR) begin
          $write("%c", dmem_wdata[7:0]);
          $fflush();
        end else if (dmem_addr == EXIT_ADDR) begin
          exit_code <= dmem_wdata;
        end
      end else if (d_busy) begin
        d_busy <= 1'b0;
        d_rsp_valid_q <= 1'b1;
        d_rsp_addr_q <= d_addr_q;
      end
    end
  end

  logic debug_on;
  always_ff @(posedge clk) begin
    if (debug_on && dmem_req && !d_busy) begin
      $display("  dmem req addr=%08x we=%0d wdata=%08x be=%b", dmem_addr, dmem_we, dmem_wdata,
               dmem_be);
    end
    if (debug_on && u_core.u_ex.csr_wr_en) begin
      $display("  csr write addr=%03x data=%08x src=%08x rs1f=%08x rs1v=%08x exmem=%08x wb=%08x",
               u_core.u_ex.idex_csr_addr, u_core.u_ex.csr_wdata, u_core.u_ex.csr_src,
               u_core.u_ex.rs1_fwd, u_core.u_ex.idex_rs1_val, u_core.u_ex.exmem_wbval,
               u_core.wb_data);
      $display("    op=%0d instr=%08x", u_core.u_ex.idex_csr_op, u_core.u_ex.idex_instr);
    end
    if (debug_on && u_core.u_ex.idex_valid && u_core.u_ex.idex_mret) begin
      $display("  mret mepc=%08x", u_core.u_ex.mepc);
    end
    if (debug_on && u_core.ex_redirect_en) begin
      $display("  redirect from pc=%08x instr=%08x -> %08x", u_core.u_ex.idex_pc,
               u_core.u_ex.idex_instr, u_core.ex_redirect_pc);
    end
    if (debug_on && imem_rsp_valid) begin
      $display("  ifetch  <- %08x", imem_rsp_addr);
    end
    if (debug_on && exit_code != 32'd0) begin
      $display("  exit_code=%08x", exit_code);
    end
  end

  assign dmem_rsp_valid = d_rsp_valid_q;
  assign dmem_rsp_addr = d_rsp_addr_q;
  assign dmem_rsp_data = d_rsp_data_q;

  // ------------------------------------------------------------- Image load
  initial begin
    if (!$value$plusargs("hex=%s", hexfile)) begin
      $display("tb_core: no +hex image, memory is zero");
    end else begin
      $display("tb_core: loading %s", hexfile);
    end
    for (i = 0; i < MEM_WORDS; i = i + 1) begin
      mem[i] = 32'd0;
    end
    if (hexfile.len() > 0) begin
      $readmemh(hexfile, mem);
    end
    trace_on = $test$plusargs("trace");
    debug_on = $test$plusargs("debug");
    if (!$value$plusargs("max_cycles=%d", max_cycles)) begin
      max_cycles = 2_000_000;
    end
  end

  initial begin
    rst = 1'b1;
    cycles = 0;
    exit_code = 32'd0;
    repeat (5) @(posedge clk);
    rst = 1'b0;
  end

  // ---------------------------------------------------------- Run monitoring
  always_ff @(posedge clk) begin
    if (!rst && !halt) begin
      cycles <= cycles + 1;
      if (cycles > max_cycles) begin
        $display("tb_core: TIMEOUT after %0d cycles", max_cycles);
        $finish;
      end
    end
    if (trace_on && trace_valid) begin
      $display("  retire pc=%08x instr=%08x rd=%0d data=%08x", trace_pc, trace_instr, trace_rd,
               trace_wdata);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst && halt) begin
      if (exit_code == 32'd1) begin
        $display("tb_core: PASS");
      end else begin
        $display("tb_core: FAIL code=%0d", exit_code);
      end
      $finish;
    end
  end

endmodule
