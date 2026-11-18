// roco system-on-chip.
//
// RV32I core with an Sv32 MMU + I/D caches + SDRAM controller + UART +
// bootloader + memory-mapped timer, LEDs, buttons, cache counters and
// boot status. AXI4 connects the caches, bootloader, walker and MMIO port.
//
// Memory map
//   0x1000_0000  SDRAM, 32 MiB (cached)
//   0x8000_0000  UART data (R: RX pop, W: TX push)
//   0x8000_0004  UART status: [0] tx_ready [1] rx_valid [3] rx_overflow
//   0x8000_0010  LEDs
//   0x8000_0014  buttons
//   0x8000_0018  mtime low            0x8000_001c  mtime high
//   0x8000_0020  mtimecmp low         0x8000_0024  mtimecmp high
//   0x8000_0028  timer pending
//   0x8000_0030  I-cache hits         0x8000_0034  I-cache misses
//   0x8000_0038  D-cache hits         0x8000_003c  D-cache misses
//   0x8000_0100  boot status: [0] done [1] busy [2] error
//   0x8000_0104  loaded image base
//   0x8000_0108  write to restart the bootloader
//   0x8000_1000  tohost: write halts the core, value is the exit code
//
// Instruction fetch outside SDRAM returns an illegal instruction, which
// traps through mtvec.

`include "axi4_defs.svh"
`default_nettype none

module roco_soc #(
    parameter int CLK_HZ = 96_000_000,
    parameter int BAUD = 115200,
    parameter bit BOOT_OVERRIDE = 1'b0,
    parameter int ICACHE_LINES = 128,
    parameter int DCACHE_LINES = 128
) (
  input logic clk,
  input logic rst,
  input logic [1:0] buttons,
  output logic [3:0] leds,
  input logic uart_rx,
  output logic uart_tx,
  output logic [12:0] sdram_a,
  output logic [1:0] sdram_ba,
  output logic [1:0] sdram_dqm,
  output logic sdram_cs_n,
  output logic sdram_ras_n,
  output logic sdram_cas_n,
  output logic sdram_we_n,
  output logic sdram_cke,
  output logic sdram_clk,
  output logic [15:0] sdram_dq_out,
  output logic sdram_dq_oe,
  input logic [15:0] sdram_dq_in,
  output logic halted,
  output logic [31:0] exit_code,
  /* Retire trace: simulation and debug only, not pinned out on the board. */
  output logic trace_valid,
  output logic [31:0] trace_pc,
  output logic [31:0] trace_instr,
  output logic [4:0] trace_rd,
  output logic [31:0] trace_wdata
);

  // ------------------------------------------------------------- Core buses
  logic imem_req;
  logic [31:0] imem_addr;
  logic imem_rsp_valid;
  logic [31:0] imem_rsp_addr;
  logic [31:0] imem_rsp_data;
  logic dmem_lu_valid;
  logic [31:2] dmem_lu_addr;
  logic [1:0] dmem_lu_offset;
  logic [2:0] dmem_lu_funct3;
  logic dmem_ready;
  logic dmem_req;
  logic dmem_valid;
  logic dmem_we;
  logic [31:0] dmem_addr;
  logic [31:0] dmem_wdata;
  logic [3:0] dmem_be;
  logic [31:0] dmem_rsp_data;
  logic [31:0] dmem_forward_data;
  logic [31:0] dc_forward_data;
  axi4_ar_t ptw_ar;
  axi4_r_t ptw_r;
  logic ptw_r_ready;
  logic ptw_ready;
  logic mmio_done;
  logic [31:0] mmio_rsp_data;
  logic core_fence_req;
  logic fence_done;
  logic dcache_flush;
  logic dcache_flush_done;
  logic icache_flush;
  logic [1:0] fence_state;

  logic imem_in_sdram;
  logic dmem_in_sdram;
  logic dmem_lu_in_sdram;
  logic i_unc_req;
  logic i_unc_rsp;
  logic [31:0] i_unc_rsp_addr;
  logic [31:0] i_unc_rsp_data;
  logic dc_cm_ready;
  logic [31:0] dc_cm_rdata;

  // ----------------------------------------------------------- Cache ports
  logic ic_cpu_rsp;
  logic [31:0] ic_cpu_rsp_addr;
  logic [31:0] ic_cpu_rsp_data;
  logic ic_mem_req;
  logic [22:0] ic_mem_word_addr;
  logic [3:0] ic_mem_len;
  logic ic_mem_ready;
  logic ic_mem_rvalid;
  logic [31:0] ic_mem_rdata;
  logic ic_mem_rlast;
  logic ic_hit;
  logic ic_miss;
  logic ic_cpu_miss;
  logic ic_cpu_busy;
  logic imem_miss;
  logic imem_busy;

  logic dc_mem_req;
  logic dc_mem_we;
  logic [22:0] dc_mem_word_addr;
  logic [3:0] dc_mem_len;
  logic dc_mem_ready;
  logic dc_mem_wvalid;
  logic dc_mem_wready;
  logic [31:0] dc_mem_wdata;
  logic [3:0] dc_mem_wbe;
  logic dc_mem_rvalid;
  logic [31:0] dc_mem_rdata;
  logic dc_mem_rlast;
  logic dc_hit;
  logic dc_miss;

  // ------------------------------------------------------------- Bootloader
  logic boot_rx_ready;
  logic [7:0] boot_tx_data;
  logic boot_tx_valid;
  logic boot_tx_ready;
  logic boot_mem_req;
  logic boot_mem_ready;
  logic boot_mem_wvalid;
  logic boot_mem_wready;
  logic [22:0] boot_mem_word_addr;
  logic [31:0] boot_mem_wdata;
  logic [3:0] boot_mem_wbe;
  logic boot_done;
  logic boot_busy;
  logic boot_error;
  logic [31:0] boot_addr;
  logic boot_restart;
  logic boot_done_eff;
  logic boot_release;
  logic core_rst;

  // ---------------------------------------------------------------- UART
  logic [7:0] uart_tx_data;
  logic uart_tx_valid;
  logic uart_tx_ready;
  logic [7:0] uart_rx_data;
  logic uart_rx_valid;
  logic uart_rx_ready;
  logic uart_rx_overflow;
  logic uart_rx_clear;
  logic mmio_tx_push;
  logic [7:0] mmio_tx_byte;
  logic mmio_rx_pop;

  // ---------------------------------------------------------------- MMIO
  logic [3:0] led_reg;
  logic [63:0] mtime;
  logic [63:0] mtimecmp;
  logic [31:0] ic_hits;
  logic [31:0] ic_misses;
  logic [31:0] dc_hits;
  logic [31:0] dc_misses;
  logic [31:0] mmio_rdata;
  logic [31:0] dbg0;
  logic [31:0] dbg1;

  // ------------------------------------------------------- SDRAM controller
  logic c_req;
  logic c_ready;
  logic c_we;
  logic [22:0] c_word_addr;
  logic [3:0] c_len;
  logic c_wready;
  logic c_wvalid;
  logic [31:0] c_wdata;
  logic [3:0] c_wbe;
  logic c_rvalid;
  logic [31:0] c_rdata;
  logic c_rlast;
  logic sdram_init_done;

  assign imem_in_sdram = (imem_addr[31:25] == 7'd8);
  assign imem_miss = ic_cpu_miss;
  assign imem_busy = ic_cpu_busy;
  // Target classification belongs to the same EX lookup as the cache
  // response. Preserve it while MEM waits; an unrelated ALU payload must
  // not route its address bits through memory readiness and frontend hold.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) dmem_in_sdram <= 1'b0;
    else if (dmem_lu_valid) dmem_in_sdram <= dmem_lu_in_sdram;
  end
  assign dmem_lu_in_sdram = (dmem_lu_addr[31:25] == 7'd8);
  assign i_unc_req = imem_req && !imem_in_sdram && !ic_cpu_busy;
  assign dmem_ready = dmem_in_sdram ? dc_cm_ready : mmio_done;

  assign boot_done_eff = BOOT_OVERRIDE ? 1'b1 : boot_done;
  // Hold the core in reset for one extra cycle after boot_done so that
  // pc_if samples the image base address, not the pre-boot zero value.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      boot_release <= 1'b0;
    end else begin
      boot_release <= boot_done_eff;
    end
  end
  assign core_rst = rst || !boot_release;

  // ---------------------------------------------------------------- CPU
  roco_cpu u_cpu (
      .clk(clk),
      .rst(core_rst),
      .boot_addr(BOOT_OVERRIDE ? 32'h1000_0000 : boot_addr),
      .halt(halted),
      .irq_timer(mtime >= mtimecmp),
      .irq_external(1'b0),
      .imem_req(imem_req),
      .imem_addr(imem_addr),
      .imem_rsp_valid(imem_rsp_valid),
      .imem_rsp_addr(imem_rsp_addr),
      .imem_rsp_data(imem_rsp_data),
      .imem_miss(imem_miss),
      .imem_busy(imem_busy),
      .dmem_lu_valid(dmem_lu_valid),
      .dmem_lu_addr(dmem_lu_addr),
      .dmem_lu_offset(dmem_lu_offset),
      .dmem_lu_funct3(dmem_lu_funct3),
      .dmem_ready(dmem_ready),
      .dmem_req(dmem_req),
      .dmem_valid(dmem_valid),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_be(dmem_be),
      .dmem_rsp_data(dmem_rsp_data),
      .dmem_forward_data(dmem_forward_data),
      .ptw_ar(ptw_ar),
      .ptw_ready(ptw_ready),
      .ptw_r(ptw_r),
      .ptw_r_ready(ptw_r_ready),
      .fence_req(core_fence_req),
      .fence_done(fence_done),
      .trace_valid(trace_valid),
      .trace_pc(trace_pc),
      .trace_instr(trace_instr),
      .trace_rd(trace_rd),
      .trace_wdata(trace_wdata)
  );

  // -------------------------------------------------------------- I-cache
  icache #(
      .LINE_WORDS(4),
      .NUM_LINES(ICACHE_LINES)
  ) u_icache (
      .clk(clk),
      .rst(rst),
      .flush(icache_flush),
      .cpu_req(imem_req && imem_in_sdram),
      .cpu_addr(imem_addr),
      .cpu_rsp_valid(ic_cpu_rsp),
      .cpu_rsp_addr(ic_cpu_rsp_addr),
      .cpu_rsp_data(ic_cpu_rsp_data),
      .cpu_miss(ic_cpu_miss),
      .cpu_busy(ic_cpu_busy),
      .mem_req(ic_mem_req),
      .mem_word_addr(ic_mem_word_addr),
      .mem_len(ic_mem_len),
      .mem_ready(ic_mem_ready),
      .mem_rvalid(ic_mem_rvalid),
      .mem_rdata(ic_mem_rdata),
      .mem_rlast(ic_mem_rlast),
      .hit_pulse(ic_hit),
      .miss_pulse(ic_miss)
  );

  // -------------------------------------------------------------- D-cache
  dcache #(
      .LINE_WORDS(8),
      .NUM_LINES(DCACHE_LINES)
  ) u_dcache (
      .clk(clk),
      .rst(rst),
      .flush(dcache_flush),
      .flush_done(dcache_flush_done),
      .lu_valid(dmem_lu_valid && dmem_lu_in_sdram),
      .lu_addr(dmem_lu_addr[24:2]),
      .lu_offset(dmem_lu_offset),
      .lu_funct3(dmem_lu_funct3),
      .cm_valid(dmem_req && dmem_in_sdram),
      .cm_we(dmem_we),
      .cm_addr(dmem_addr[24:2]),
      .cm_wdata(dmem_wdata),
      .cm_be(dmem_be),
      .cm_rdata(dc_cm_rdata),
      .cm_forward_data(dc_forward_data),
      .cm_ready(dc_cm_ready),
      .mem_req(dc_mem_req),
      .mem_we(dc_mem_we),
      .mem_word_addr(dc_mem_word_addr),
      .mem_len(dc_mem_len),
      .mem_ready(dc_mem_ready),
      .mem_wvalid(dc_mem_wvalid),
      .mem_wready(dc_mem_wready),
      .mem_wdata(dc_mem_wdata),
      .mem_wbe(dc_mem_wbe),
      .mem_rvalid(dc_mem_rvalid),
      .mem_rdata(dc_mem_rdata),
      .mem_rlast(dc_mem_rlast),
      .hit_pulse(dc_hit),
      .miss_pulse(dc_miss)
  );

  // ------------------------------------------------------------- AXI4 fabric
  axi4_ar_t i_ar, d_ar, boot_ar, mmio_ar, ram_ar, periph_ar;
  axi4_aw_t i_aw, d_aw, boot_aw, mmio_aw, ram_aw, periph_aw;
  axi4_w_t i_w, d_w, boot_w, mmio_w, ram_w, periph_w;
  axi4_b_t i_b, d_b, boot_b, mmio_b, ram_b, periph_b, unused_ptw_b;
  axi4_r_t i_r, d_r, boot_r, mmio_r, ram_r, periph_r;
  logic i_arready, d_arready, boot_arready, mmio_arready, ram_arready, periph_arready;
  logic i_awready, d_awready, boot_awready, mmio_awready, ram_awready, periph_awready;
  logic i_wready, d_wready, boot_wready, mmio_wready, ram_wready, periph_wready;
  logic i_rready, d_rready, boot_rready, mmio_rready, ram_rready, periph_rready;
  logic i_bready, d_bready, boot_bready, mmio_bready, ram_bready, periph_bready;
  logic unused_i_wready, unused_i_done, unused_d_done, unused_boot_done;
  logic unused_boot_rvalid, unused_boot_rlast, unused_ptw_awready, unused_ptw_wready;
  logic [31:0] unused_boot_rdata;
  logic unused_mmio_accept, mmio_read_done, mmio_write_done, unused_mmio_wready, unused_mmio_rlast;
  logic psel, penable, pwrite, pready;
  logic [31:0] paddr, pwdata;
  logic [3:0] pstrb;
  logic [2:0] unused_pprot;
  wire apb_read = psel && penable && pready && !pwrite;
  wire apb_write = psel && penable && pready && pwrite && (|pstrb);

  axi4_mem_master u_i_axi (
      .clk(clk),
      .rst(rst),
      .req(ic_mem_req),
      .we(1'b0),
      .addr({7'd8, ic_mem_word_addr, 2'b00}),
      .len(ic_mem_len),
      .ready(ic_mem_ready),
      .wvalid(1'b0),
      .wready(unused_i_wready),
      .wdata(32'd0),
      .wbe(4'd0),
      .rvalid(ic_mem_rvalid),
      .rdata(ic_mem_rdata),
      .rlast(ic_mem_rlast),
      .write_done(unused_i_done),
      .ar(i_ar),
      .ar_ready(i_arready),
      .r(i_r),
      .r_ready(i_rready),
      .aw(i_aw),
      .aw_ready(i_awready),
      .w(i_w),
      .w_ready(i_wready),
      .b(i_b),
      .b_ready(i_bready)
  );
  axi4_mem_master u_d_axi (
      .clk(clk),
      .rst(rst),
      .req(dc_mem_req),
      .we(dc_mem_we),
      .addr({7'd8, dc_mem_word_addr, 2'b00}),
      .len(dc_mem_len),
      .ready(dc_mem_ready),
      .wvalid(dc_mem_wvalid),
      .wready(dc_mem_wready),
      .wdata(dc_mem_wdata),
      .wbe(dc_mem_wbe),
      .rvalid(dc_mem_rvalid),
      .rdata(dc_mem_rdata),
      .rlast(dc_mem_rlast),
      .write_done(unused_d_done),
      .ar(d_ar),
      .ar_ready(d_arready),
      .r(d_r),
      .r_ready(d_rready),
      .aw(d_aw),
      .aw_ready(d_awready),
      .w(d_w),
      .w_ready(d_wready),
      .b(d_b),
      .b_ready(d_bready)
  );
  axi4_mem_master u_boot_axi (
      .clk(clk),
      .rst(rst),
      .req(boot_mem_req),
      .we(1'b1),
      .addr({7'd8, boot_mem_word_addr, 2'b00}),
      .len(4'd0),
      .ready(boot_mem_ready),
      .wvalid(boot_mem_wvalid),
      .wready(boot_mem_wready),
      .wdata(boot_mem_wdata),
      .wbe(boot_mem_wbe),
      .rvalid(unused_boot_rvalid),
      .rdata(unused_boot_rdata),
      .rlast(unused_boot_rlast),
      .write_done(unused_boot_done),
      .ar(boot_ar),
      .ar_ready(boot_arready),
      .r(boot_r),
      .r_ready(boot_rready),
      .aw(boot_aw),
      .aw_ready(boot_awready),
      .w(boot_w),
      .w_ready(boot_wready),
      .b(boot_b),
      .b_ready(boot_bready)
  );
  axi4_mem_master u_mmio_axi (
      .clk(clk),
      .rst(rst),
      .req(dmem_valid && !dmem_in_sdram),
      .we(dmem_we),
      .addr({dmem_addr[31:2], 2'b00}),
      .len(4'd0),
      .ready(unused_mmio_accept),
      .wvalid(1'b1),
      .wready(unused_mmio_wready),
      .wdata(dmem_wdata),
      .wbe(dmem_be),
      .rvalid(mmio_read_done),
      .rdata(mmio_rsp_data),
      .rlast(unused_mmio_rlast),
      .write_done(mmio_write_done),
      .ar(mmio_ar),
      .ar_ready(mmio_arready),
      .r(mmio_r),
      .r_ready(mmio_rready),
      .aw(mmio_aw),
      .aw_ready(mmio_awready),
      .w(mmio_w),
      .w_ready(mmio_wready),
      .b(mmio_b),
      .b_ready(mmio_bready)
  );
  assign mmio_done = mmio_read_done || mmio_write_done;


  axi4_xbar u_xbar (
      .clk(clk),
      .rst(rst),
      .m0_ar(i_ar),
      .m0_ar_ready(i_arready),
      .m0_r(i_r),
      .m0_r_ready(i_rready),
      .m0_aw(i_aw),
      .m0_aw_ready(i_awready),
      .m0_w(i_w),
      .m0_w_ready(i_wready),
      .m0_b(i_b),
      .m0_b_ready(i_bready),
      .m1_ar(d_ar),
      .m1_ar_ready(d_arready),
      .m1_r(d_r),
      .m1_r_ready(d_rready),
      .m1_aw(d_aw),
      .m1_aw_ready(d_awready),
      .m1_w(d_w),
      .m1_w_ready(d_wready),
      .m1_b(d_b),
      .m1_b_ready(d_bready),
      .m2_ar(boot_ar),
      .m2_ar_ready(boot_arready),
      .m2_r(boot_r),
      .m2_r_ready(boot_rready),
      .m2_aw(boot_aw),
      .m2_aw_ready(boot_awready),
      .m2_w(boot_w),
      .m2_w_ready(boot_wready),
      .m2_b(boot_b),
      .m2_b_ready(boot_bready),
      .m3_ar(ptw_ar),
      .m3_ar_ready(ptw_ready),
      .m3_r(ptw_r),
      .m3_r_ready(ptw_r_ready),
      .m3_aw(53'd0),
      .m3_aw_ready(unused_ptw_awready),
      .m3_w(38'd0),
      .m3_w_ready(unused_ptw_wready),
      .m3_b(unused_ptw_b),
      .m3_b_ready(1'b1),
      .m4_ar(mmio_ar),
      .m4_ar_ready(mmio_arready),
      .m4_r(mmio_r),
      .m4_r_ready(mmio_rready),
      .m4_aw(mmio_aw),
      .m4_aw_ready(mmio_awready),
      .m4_w(mmio_w),
      .m4_w_ready(mmio_wready),
      .m4_b(mmio_b),
      .m4_b_ready(mmio_bready),
      .s0_ar(ram_ar),
      .s0_ar_ready(ram_arready),
      .s0_r(ram_r),
      .s0_r_ready(ram_rready),
      .s0_aw(ram_aw),
      .s0_aw_ready(ram_awready),
      .s0_w(ram_w),
      .s0_w_ready(ram_wready),
      .s0_b(ram_b),
      .s0_b_ready(ram_bready),
      .s1_ar(periph_ar),
      .s1_ar_ready(periph_arready),
      .s1_r(periph_r),
      .s1_r_ready(periph_rready),
      .s1_aw(periph_aw),
      .s1_aw_ready(periph_awready),
      .s1_w(periph_w),
      .s1_w_ready(periph_wready),
      .s1_b(periph_b),
      .s1_b_ready(periph_bready)
  );
  axi4_sdram_adapter u_sdram_axi (
      .clk(clk),
      .rst(rst),
      .ar(ram_ar),
      .ar_ready(ram_arready),
      .r(ram_r),
      .r_ready(ram_rready),
      .aw(ram_aw),
      .aw_ready(ram_awready),
      .w(ram_w),
      .w_ready(ram_wready),
      .b(ram_b),
      .b_ready(ram_bready),
      .req_valid(c_req),
      .req_ready(c_ready),
      .req_we(c_we),
      .req_word_addr(c_word_addr),
      .req_len(c_len),
      .wvalid(c_wvalid),
      .wready(c_wready),
      .wdata(c_wdata),
      .wbe(c_wbe),
      .rvalid(c_rvalid),
      .rdata(c_rdata)
  );
  axi4_apb_bridge u_apb (
      .clk(clk),
      .rst(rst),
      .ar(periph_ar),
      .ar_ready(periph_arready),
      .r(periph_r),
      .r_ready(periph_rready),
      .aw(periph_aw),
      .aw_ready(periph_awready),
      .w(periph_w),
      .w_ready(periph_wready),
      .b(periph_b),
      .b_ready(periph_bready),
      .psel(psel),
      .penable(penable),
      .pwrite(pwrite),
      .paddr(paddr),
      .pwdata(pwdata),
      .pstrb(pstrb),
      .pprot(unused_pprot),
      .pready(pready),
      .pslverr(1'b0),
      .prdata(mmio_rdata)
  );

  // ------------------------------------------------------- SDRAM controller
  sdram_ctrl #(
      .CLK_HZ(CLK_HZ),
      .CL(3)
  ) u_sdram (
      .clk(clk),
      .rst(rst),
      .req_valid(c_req),
      .req_ready(c_ready),
      .req_we(c_we),
      .req_word_addr(c_word_addr),
      .req_len(c_len),
      .wvalid(c_wvalid),
      .wready(c_wready),
      .wdata(c_wdata),
      .wbe(c_wbe),
      .rvalid(c_rvalid),
      .rdata(c_rdata),
      .rlast(c_rlast),
      .init_done(sdram_init_done),
      .sd_a(sdram_a),
      .sd_ba(sdram_ba),
      .sd_cs_n(sdram_cs_n),
      .sd_ras_n(sdram_ras_n),
      .sd_cas_n(sdram_cas_n),
      .sd_we_n(sdram_we_n),
      .sd_dqm(sdram_dqm),
      .sd_dq_out(sdram_dq_out),
      .sd_dq_oe(sdram_dq_oe),
      .sd_dq_in(sdram_dq_in)
  );

  assign sdram_cke = 1'b1;
  assign sdram_clk = clk;

  // --------------------------------------------------------------- UART
  assign uart_tx_valid = boot_tx_valid | mmio_tx_push;
  assign uart_tx_data = boot_tx_valid ? boot_tx_data : mmio_tx_byte;
  assign boot_tx_ready = uart_tx_ready;
  assign uart_rx_ready = boot_rx_ready | mmio_rx_pop;
  assign uart_rx_clear = apb_read && (paddr[15:0] == 16'h0004);

  uart #(
      .CLK_HZ(CLK_HZ),
      .BAUD(BAUD)
  ) u_uart (
      .clk(clk),
      .rst(rst),
      .tx_data(uart_tx_data),
      .tx_valid(uart_tx_valid),
      .tx_ready(uart_tx_ready),
      .rx_data(uart_rx_data),
      .rx_valid(uart_rx_valid),
      .rx_ready(uart_rx_ready),
      .rx_overflow(uart_rx_overflow),
      .clear_overflow(uart_rx_clear),
      .uart_rx(uart_rx),
      .uart_tx(uart_tx)
  );

  // ----------------------------------------------------------- Bootloader
  uart_boot u_boot (
      .clk(clk),
      .rst(rst),
      .restart(boot_restart),
      .rx_data(uart_rx_data),
      .rx_valid(uart_rx_valid),
      .rx_ready(boot_rx_ready),
      .tx_data(boot_tx_data),
      .tx_valid(boot_tx_valid),
      .tx_ready(boot_tx_ready),
      .mem_req(boot_mem_req),
      .mem_ready(boot_mem_ready),
      .mem_wvalid(boot_mem_wvalid),
      .mem_wready(boot_mem_wready),
      .mem_word_addr(boot_mem_word_addr),
      .mem_wdata(boot_mem_wdata),
      .mem_wbe(boot_mem_wbe),
      .boot_done(boot_done),
      .boot_addr(boot_addr),
      .boot_busy(boot_busy),
      .boot_error(boot_error)
  );

  // --------------------------------------------------------------- MMIO
  assign pready = !pwrite || (paddr[15:0] != 16'h0000) || !pstrb[0] ||
                  (uart_tx_ready && !boot_tx_valid);
  assign mmio_tx_push = apb_write && pstrb[0] && (paddr[15:0] == 16'h0000);
  assign mmio_tx_byte = pwdata[7:0];
  assign mmio_rx_pop = apb_read && (paddr[15:0] == 16'h0000) && uart_rx_valid;
  // Restart only after the CPU receives B, not during the APB transfer.
  assign boot_restart = dmem_req && dmem_we && !dmem_in_sdram && (dmem_addr[15:0] == 16'h0108);

  logic [17:0] mmio_read_select;
  function automatic logic [17:0] mmio_read_decode(input logic [15:0] address);
    mmio_read_decode = '0;
    case (address)
      16'h0000: mmio_read_decode[0] = 1'b1;
      16'h0004: mmio_read_decode[1] = 1'b1;
      16'h0010: mmio_read_decode[2] = 1'b1;
      16'h0014: mmio_read_decode[3] = 1'b1;
      16'h0018: mmio_read_decode[4] = 1'b1;
      16'h001c: mmio_read_decode[5] = 1'b1;
      16'h0020: mmio_read_decode[6] = 1'b1;
      16'h0024: mmio_read_decode[7] = 1'b1;
      16'h0028: mmio_read_decode[8] = 1'b1;
      16'h0030: mmio_read_decode[9] = 1'b1;
      16'h0034: mmio_read_decode[10] = 1'b1;
      16'h0038: mmio_read_decode[11] = 1'b1;
      16'h003c: mmio_read_decode[12] = 1'b1;
      16'h0048: mmio_read_decode[13] = 1'b1;
      16'h004c: mmio_read_decode[14] = 1'b1;
      16'h0100: mmio_read_decode[15] = 1'b1;
      16'h0104: mmio_read_decode[16] = 1'b1;
      16'h1000: mmio_read_decode[17] = 1'b1;
      default: begin
      end
    endcase
  endfunction

  assign mmio_read_select = mmio_read_decode(paddr[15:0]);

  always_comb begin
    mmio_rdata = '0;
    mmio_rdata |= {32{mmio_read_select[0]}} & {24'd0, uart_rx_data};
    mmio_rdata |= {32{mmio_read_select[1]}} & {28'd0, uart_rx_overflow, 1'b0, uart_rx_valid, uart_tx_ready};
    mmio_rdata |= {32{mmio_read_select[2]}} & {28'd0, led_reg};
    mmio_rdata |= {32{mmio_read_select[3]}} & {30'd0, buttons};
    mmio_rdata |= {32{mmio_read_select[4]}} & mtime[31:0];
    mmio_rdata |= {32{mmio_read_select[5]}} & mtime[63:32];
    mmio_rdata |= {32{mmio_read_select[6]}} & mtimecmp[31:0];
    mmio_rdata |= {32{mmio_read_select[7]}} & mtimecmp[63:32];
    mmio_rdata |= {32{mmio_read_select[8]}} & {31'd0, (mtime >= mtimecmp)};
    mmio_rdata |= {32{mmio_read_select[9]}} & ic_hits;
    mmio_rdata |= {32{mmio_read_select[10]}} & ic_misses;
    mmio_rdata |= {32{mmio_read_select[11]}} & dc_hits;
    mmio_rdata |= {32{mmio_read_select[12]}} & dc_misses;
    mmio_rdata |= {32{mmio_read_select[13]}} & dbg0;
    mmio_rdata |= {32{mmio_read_select[14]}} & dbg1;
    mmio_rdata |= {32{mmio_read_select[15]}} & {28'd0, sdram_init_done, boot_error, boot_busy, boot_done_eff};
    mmio_rdata |= {32{mmio_read_select[16]}} & boot_addr;
    mmio_rdata |= {32{mmio_read_select[17]}} & exit_code;
  end

  function automatic logic [31:0] merge_bytes(input logic [31:0] old_word, new_word,
                                              input logic [3:0] strobes);
    for (int lane = 0; lane < 4; lane++) begin
      merge_bytes[lane*8+:8] = strobes[lane] ? new_word[lane*8+:8] : old_word[lane*8+:8];
    end
  endfunction

  // Capture lookup events before the counter arithmetic. The MMIO value
  // includes the captured event, including when it takes priority over clear.
  logic [31:0] dc_hits_base;
  logic [31:0] dc_misses_base;
  logic dc_hit_q;
  logic dc_miss_q;
  logic dc_clear_q;

  assign dc_hits = dc_hit_q ? dc_hits_base + 32'd1 : dc_clear_q ? 32'd0 : dc_hits_base;
  assign dc_misses = dc_miss_q ? dc_misses_base + 32'd1 : dc_clear_q ? 32'd0 : dc_misses_base;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      dc_hits_base <= '0;
      dc_misses_base <= '0;
      dc_hit_q <= 1'b0;
      dc_miss_q <= 1'b0;
      dc_clear_q <= 1'b0;
    end else begin
      dc_hits_base <= dc_hits;
      dc_misses_base <= dc_misses;
      dc_hit_q <= dc_hit;
      dc_miss_q <= dc_miss;
      dc_clear_q <= apb_write && (paddr[15:0] == 16'h0030);
    end
  end

  logic [31:0] ic_hits_base, ic_misses_base;
  logic ic_hit_q, ic_miss_q, ic_clear_q;
  assign ic_hits = ic_hit_q ? ic_hits_base + 32'd1 : ic_clear_q ? 32'd0 : ic_hits_base;
  assign ic_misses = ic_miss_q ? ic_misses_base + 32'd1 : ic_clear_q ? 32'd0 : ic_misses_base;
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      ic_hits_base <= '0;
      ic_misses_base <= '0;
      ic_hit_q <= 1'b0;
      ic_miss_q <= 1'b0;
      ic_clear_q <= 1'b0;
    end else begin
      ic_hits_base <= ic_hits;
      ic_misses_base <= ic_misses;
      ic_hit_q <= ic_hit;
      ic_miss_q <= ic_miss;
      ic_clear_q <= apb_write && (paddr[15:0] == 16'h0030);
    end
  end

  // The response-valid flop publishes this payload one cycle after the
  // request. Capturing unconditionally keeps late fetch/MMU qualification
  // off the address register enables; invalid responses are ignored.
  always_ff @(posedge clk) i_unc_rsp_addr <= imem_addr;
  assign i_unc_rsp_data = 32'd0;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      i_unc_rsp <= 1'b0;
      led_reg <= 4'd0;
      mtime <= '0;
      mtimecmp <= '0;
      halted <= 1'b0;
      exit_code <= '0;
      dbg0 <= '0;
      dbg1 <= '0;
    end else begin
      i_unc_rsp <= i_unc_req;
      if (apb_write) begin
        case (paddr[15:0])
          16'h0010: if (pstrb[0]) led_reg <= pwdata[3:0];
          16'h0020: mtimecmp[31:0] <= merge_bytes(mtimecmp[31:0], pwdata, pstrb);
          16'h0024: mtimecmp[63:32] <= merge_bytes(mtimecmp[63:32], pwdata, pstrb);
          16'h0048: dbg0 <= merge_bytes(dbg0, pwdata, pstrb);
          16'h004c: dbg1 <= merge_bytes(dbg1, pwdata, pstrb);
          16'h1000: exit_code <= merge_bytes(exit_code, pwdata, pstrb);
          default: begin
          end
        endcase
      end
      if (boot_restart) begin
        halted <= 1'b0;
        exit_code <= '0;
      end else if (dmem_req && dmem_we && !dmem_in_sdram && (dmem_addr[15:0] == 16'h1000)) begin
        halted <= 1'b1;
      end
      mtime <= mtime + 64'd1;
    end
  end

  // ------------------------------------------------------ FENCE.I sequence
  // FENCE.I must make prior stores visible to the instruction stream, so
  // write back the whole D-cache, invalidate the I-cache, then release the
  // stalled FENCE.I instruction. The core holds IF/ID/EX until fence_done.
  localparam logic [1:0] F_IDLE   = 2'd0;
  localparam logic [1:0] F_DCACHE = 2'd1;
  localparam logic [1:0] F_DRAIN  = 2'd2;
  localparam logic [1:0] F_ICACHE = 2'd3;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      fence_state <= F_IDLE;
      dcache_flush <= 1'b0;
      icache_flush <= 1'b0;
      fence_done <= 1'b0;
    end else begin
      icache_flush <= 1'b0;
      case (fence_state)
        F_IDLE: begin
          if (core_fence_req) begin
            dcache_flush <= 1'b1;
            fence_state <= F_DCACHE;
          end else begin
            fence_done <= 1'b0;
          end
        end
        F_DCACHE: begin
          if (dcache_flush_done) begin
            dcache_flush <= 1'b0;
            fence_state <= F_DRAIN;
          end
        end
        F_DRAIN: begin
          if (c_ready) begin
            icache_flush <= 1'b1;
            fence_state <= F_ICACHE;
          end
        end
        F_ICACHE: begin
          fence_done <= 1'b1;
          fence_state <= F_IDLE;
        end
        default: begin
          fence_state <= F_IDLE;
        end
      endcase
    end
  end

  // ------------------------------------------------------- Response muxing
  assign imem_rsp_valid = imem_in_sdram ? ic_cpu_rsp : i_unc_rsp;
  assign imem_rsp_addr = imem_in_sdram ? ic_cpu_rsp_addr : i_unc_rsp_addr;
  assign imem_rsp_data = imem_in_sdram ? ic_cpu_rsp_data : i_unc_rsp_data;
  assign dmem_rsp_data = dmem_in_sdram ? dc_cm_rdata : mmio_rsp_data;
  // Only cached reads use immediate MEM-to-EX forwarding. Uncached
  // dependencies wait for WB, keeping peripheral decode off the early bus.
  assign dmem_forward_data = dc_forward_data;

  assign leds = led_reg;

endmodule
