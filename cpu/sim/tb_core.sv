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
  logic dmem_lu_valid;
  logic [31:2] dmem_lu_addr;
  logic dmem_lu_hit;
  logic dmem_req;
  logic dmem_we;
  logic [31:0] dmem_addr;
  logic [31:0] dmem_wdata;
  logic [3:0] dmem_be;
  logic [31:0] dmem_rsp_data;
  logic trace_valid;
  logic [31:0] trace_pc;
  logic [31:0] trace_instr;
  logic [4:0] trace_rd;
  logic [31:0] trace_wdata;

  logic [31:0] mem[0:MEM_WORDS-1];
  logic [31:0] imem_rdata;
  logic [31:0] dmem_rdata;

  logic im_rsp_valid_q;
  logic [31:0] im_rsp_addr_q;
  logic [31:0] im_rsp_data_q;

  logic [31:0] d_lu_data;
  logic [31:0] st_addr_q, st_data_q;
  logic [3:0] st_be_q;
  logic st_valid_q;
  logic [31:0] st_merged;

  logic [31:0] exit_code;
  int unsigned cycles;
  int unsigned max_cycles;
  int unsigned i;
  string hexfile;
  integer hex_fd;
  integer hex_matched;
  logic trace_on;
  logic debug_on;
  integer dbg_cnt = 0;

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
      .imem_miss(1'b0),
      .imem_busy(1'b0),
      .dmem_lu_valid(dmem_lu_valid),
      .dmem_lu_addr(dmem_lu_addr),
      .dmem_lu_hit(dmem_lu_hit),
      .dmem_req(dmem_req),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_be(dmem_be),
      .dmem_rsp_data(dmem_rsp_data),
      .trace_valid(trace_valid),
      .trace_pc(trace_pc),
      .trace_instr(trace_instr),
      .trace_rd(trace_rd),
      .trace_wdata(trace_wdata),
      .fence_req(),
      .fence_done(1'b1)
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
  always @(posedge clk) begin
    if (rst) begin
      im_rsp_valid_q <= 1'b0;
      im_rsp_addr_q <= '0;
      im_rsp_data_q <= '0;
    end else begin
      im_rsp_valid_q <= imem_req;
      im_rsp_addr_q <= imem_addr;
      im_rsp_data_q <= imem_rdata;
    end
  end

  assign imem_rsp_valid = im_rsp_valid_q;
  assign imem_rsp_addr = im_rsp_addr_q;
  assign imem_rsp_data = im_rsp_data_q;

  // --------------------------------------------------------- D memory model
  assign dmem_lu_hit = 1'b1;
  assign st_merged[7:0] = st_be_q[0] ? st_data_q[7:0] : d_lu_data[7:0];
  assign st_merged[15:8] = st_be_q[1] ? st_data_q[15:8] : d_lu_data[15:8];
  assign st_merged[23:16] = st_be_q[2] ? st_data_q[23:16] : d_lu_data[23:16];
  assign st_merged[31:24] = st_be_q[3] ? st_data_q[31:24] : d_lu_data[31:24];
  assign dmem_rsp_data = (st_valid_q && (st_addr_q[31:2] == dmem_addr[31:2])) ? st_merged : d_lu_data;

  always @(posedge clk) begin
    if (dmem_lu_addr[31:16] == 16'h1000) begin
      d_lu_data <= mem[dmem_lu_addr[15:2]];
    end else begin
      d_lu_data <= 32'd0;
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      st_valid_q <= 1'b0;
      st_addr_q <= '0;
      st_data_q <= '0;
      st_be_q <= '0;
    end else begin
      st_valid_q <= dmem_req && dmem_we;
      if (dmem_req && dmem_we) begin
        st_addr_q <= dmem_addr;
        st_data_q <= dmem_wdata;
        st_be_q <= dmem_be;
      end
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      exit_code <= '0;
    end else if (dmem_req && dmem_we) begin
      if (dmem_addr[31:16] == 16'h1000) begin
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
    end
  end

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
      hex_fd = $fopen(hexfile, "r");
      if (hex_fd == 0) begin
        $display("tb_core: cannot open %s", hexfile);
        $finish;
      end
      i = 0;
      hex_matched = 1;
      while ((hex_matched == 1) && (i < MEM_WORDS)) begin
        hex_matched = $fscanf(hex_fd, "%h", mem[i]);
        if (hex_matched == 1) begin
          i = i + 1;
        end
      end
      $fclose(hex_fd);
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
  always @(posedge clk) begin
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

  always @(posedge clk) begin
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
