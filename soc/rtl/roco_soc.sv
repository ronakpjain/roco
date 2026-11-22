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
    /* Power-up delay for the SDRAM controller, in clock cycles. Shortened by
       formal cover runs so the CPU reaches running traffic inside the bound. */
    parameter int SDRAM_POWERUP = CLK_HZ / 5000,
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
`ifdef ROCO_SOC_SDRAM_MEMORY_FORMAL
  `include "axi_sdram_state.svh"
  logic f_ctrl_busy, f_ctrl_read_owned, f_ctrl_we;
  logic [22:0] f_ctrl_addr;
  logic [3:0] f_ctrl_len;
  logic [4:0] f_ctrl_read_count, f_ctrl_write_count, f_ctrl_pins_written;
  logic [14:0] f_pin_row;
`endif

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
  logic dmem_amo_read;
`ifdef ROCO_SOC_RAM_FORMAL
  logic f_mem_packet;
`endif
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
  logic boot_cache_maintenance, cache_rst;
  logic boot_axi_ready;
`ifdef ROCO_SOC_DCACHE_MEMORY_FORMAL
  logic [22:0] f_dc_beat_word;
  logic f_dc_memory_active, f_dc_memory_write;
  logic [4:0] f_dc_write_left, f_dc_cache_read_left;
  logic f_dc_checker_pending, f_dc_checker_abandoned;
  logic [22:0] f_dc_checker_cpu_word;
  logic [31:0] f_dc_arch_data;
`endif
`ifdef ROCO_SOC_ICACHE_MEMORY_FORMAL
  logic f_instruction_coherent;
  always_ff @(posedge clk) begin
    if (rst) f_instruction_coherent <= 1'b1;
    else if (dmem_req && dmem_in_sdram && dmem_we && dmem_addr[24:2] == cell_addr)
      f_instruction_coherent <= 1'b0;
    else if (icache_flush) f_instruction_coherent <= 1'b1;
    if (!rst && f_instruction_coherent) assert (f_dc_arch_data == native_cell);
    if (!rst && core_rst && !boot_cache_maintenance) assert (f_instruction_coherent);
    if (!rst && icache_flush) begin
      assert (!dmem_req);
      assert (f_dc_arch_data == native_cell);
    end
  end
`endif
`ifdef ROCO_SOC_FENCE_FORMAL
  logic f_dc_idle, f_dc_lookup_pending;
`endif

  logic imem_in_sdram;
  logic dmem_in_sdram;
  logic dmem_lu_in_sdram;
  logic i_unc_req;
  logic i_unc_rsp;
  logic imem_rsp_in_sdram;
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
  logic irq_timer;
  logic [31:0] mmio_rdata;

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
  assign core_rst = rst || !boot_release || boot_cache_maintenance;
  // A replacement image may overwrite cached instructions and data. Drain
  // committed dirty stores first, then cancel old lookup/refill metadata.
  // The AXI masters keep running so accepted transactions always drain.
  assign cache_rst = rst || (boot_cache_maintenance && icache_flush);
  assign boot_mem_ready = boot_axi_ready && !boot_cache_maintenance;

  // ---------------------------------------------------------------- CPU
`ifdef ROCO_SOC_GPR_FORMAL
  (* anyconst *) logic [4:0] f_gpr_watch_addr;
`endif
  roco_cpu u_cpu (
`ifdef ROCO_SOC_GPR_FORMAL
      .rvfi_gpr_watch_addr(f_gpr_watch_addr),
      .rvfi_gpr_watch_value(),
`endif
`ifdef ROCO_SOC_FETCH_MEMORY_FORMAL
      .formal_watch_word(cell_addr),
      .formal_watch_data(f_dc_arch_data),
      .formal_instruction_coherent(f_instruction_coherent),
`endif
      .clk(clk),
      .rst(core_rst),
      .boot_addr(BOOT_OVERRIDE ? 32'h1000_0000 : boot_addr),
      .halt(halted),
      .irq_timer(irq_timer),
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
      .dmem_amo_read(dmem_amo_read),
`ifdef ROCO_SOC_RAM_FORMAL
      .f_mem_packet(f_mem_packet),
`endif
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_be(dmem_be),
      .dmem_rsp_data(dmem_rsp_data),
      .dmem_forward_data(dmem_forward_data),
      .ptw_bus_rst(rst),
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
`ifdef ROCO_SOC_ICACHE_MEMORY_FORMAL
      .formal_watch_word(cell_addr),
      .formal_watch_data(f_dc_arch_data),
      .formal_backing_data(native_cell),
      .formal_coherent(f_instruction_coherent),
      .formal_boot_loading(core_rst && !boot_cache_maintenance),
      .formal_ram_word(ic_read_word),
      .formal_read_left(f_ic_read_left),
`endif
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
`ifdef ROCO_SOC_DCACHE_MEMORY_FORMAL
      .formal_memory_addr(cell_addr),
      .formal_initial_word(rst ? initial_cell : native_cell),
      .formal_backing_word(native_cell),
      .formal_cancel(core_rst),
      .formal_boot_loading(core_rst && !boot_cache_maintenance),
      .formal_global_reset(rst),
      .formal_flush_clean(fence_state == F_DRAIN || fence_state == F_ICACHE),
      .formal_external_write(boot_write_fire && boot_write_word == cell_addr),
      .formal_external_data(boot_mem_wdata),
      .formal_external_be(boot_mem_wbe),
      .formal_beat_word(f_dc_beat_word),
      .formal_memory_active(f_dc_memory_active),
      .formal_memory_write(f_dc_memory_write),
      .formal_write_left(f_dc_write_left),
      .formal_read_left(f_dc_cache_read_left),
      .formal_pending(f_dc_checker_pending),
      .formal_abandoned(f_dc_checker_abandoned),
      .formal_cpu_word(f_dc_checker_cpu_word),
      .formal_arch_data(f_dc_arch_data),
`endif
`ifdef ROCO_SOC_FENCE_FORMAL
      .f_idle(f_dc_idle),
      .f_lookup_pending(f_dc_lookup_pending),
`endif
      .clk(clk),
      .rst(cache_rst),
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
`ifdef ROCO_SOC_RAM_FORMAL
  logic [4:0] f_d_write_left, f_boot_write_left;
  logic f_boot_write_owned;
  logic f_ram_wphase, f_ram_wowner_boot;
`endif
`ifdef ROCO_SOC_DC_CLIENT_FORMAL
  logic f_ram_read_d, f_ram_read_i;
  logic [8:0] f_adapter_read_left;
`endif
  logic unused_boot_rvalid, unused_boot_rlast, unused_ptw_awready, unused_ptw_wready;
  logic [31:0] unused_boot_rdata;
  logic unused_mmio_accept, mmio_read_done, mmio_write_done, unused_mmio_wready, unused_mmio_rlast;
  logic psel, penable, pwrite, pready;
  logic [31:0] paddr, pwdata;
  logic [3:0] pstrb;
  logic [2:0] unused_pprot;

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
`ifdef ROCO_SOC_RAM_FORMAL
      .f_write_left(),
`endif
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
`ifdef ROCO_SOC_RAM_FORMAL
      .f_write_left(f_d_write_left),
`endif
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
      .req(boot_mem_req && !boot_cache_maintenance),
      .we(1'b1),
      .addr({7'd8, boot_mem_word_addr, 2'b00}),
      .len(4'd0),
      .ready(boot_axi_ready),
      .wvalid(boot_mem_wvalid),
      .wready(boot_mem_wready),
      .wdata(boot_mem_wdata),
      .wbe(boot_mem_wbe),
      .rvalid(unused_boot_rvalid),
      .rdata(unused_boot_rdata),
      .rlast(unused_boot_rlast),
      .write_done(unused_boot_done),
`ifdef ROCO_SOC_RAM_FORMAL
      .f_write_left(f_boot_write_left),
`endif
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
      // An uncached atomic reads its old value here; the cached path is
      // already served by the EX lookup, so only this port reads first.
      .req((dmem_valid || dmem_amo_read) && !dmem_in_sdram),
      .we(dmem_we && !dmem_amo_read),
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
`ifdef ROCO_SOC_RAM_FORMAL
      .f_write_left(),
`endif
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
`ifdef ROCO_SOC_DC_CLIENT_FORMAL
      .f_ram_read_d(f_ram_read_d),
      .f_ram_read_i(f_ram_read_i),
`endif
      .s0_ar_ready(ram_arready),
      .s0_r(ram_r),
      .s0_r_ready(ram_rready),
`ifdef ROCO_SOC_RAM_FORMAL
      .f_ram_wphase(f_ram_wphase),
      .f_ram_wowner_boot(f_ram_wowner_boot),
`endif
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
`ifdef ROCO_SOC_SDRAM_MEMORY_FORMAL
      .f_watch(f_watch),
      .f_phase(f_phase),
      .f_captured(f_captured),
      .f_beat(f_beat),
      .f_len(f_len),
      .f_id(f_id),
      .f_addr(f_addr),
      .f_write(f_write),
      .f_error(f_error),
      .f_read_word(f_read_word),
`endif
`ifdef ROCO_SOC_DC_CLIENT_FORMAL
      .f_read_left(f_adapter_read_left),
`endif
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
      .T_POWERUP(SDRAM_POWERUP),
      .CL(3)
  ) u_sdram (
`ifdef ROCO_SOC_SDRAM_MEMORY_FORMAL
      .f_ctrl_busy(f_ctrl_busy),
      .f_ctrl_read_owned(f_ctrl_read_owned),
      .f_ctrl_we(f_ctrl_we),
      .f_ctrl_addr(f_ctrl_addr),
      .f_ctrl_len(f_ctrl_len),
      .f_ctrl_read_count(f_ctrl_read_count),
      .f_ctrl_write_count(f_ctrl_write_count),
      .f_ctrl_pins_written(f_ctrl_pins_written),
      .f_pin_row(f_pin_row),
`endif
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
`ifdef ROCO_SOC_RAM_FORMAL
      .f_write_owned(f_boot_write_owned),
`endif
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
  roco_apb_peripherals u_peripherals (
      .clk(clk),
      .rst(rst),
      .psel(psel),
      .penable(penable),
      .pwrite(pwrite),
      .paddr(paddr[15:0]),
      .pwdata(pwdata),
      .pstrb(pstrb),
      .pready(pready),
      .prdata(mmio_rdata),
      .uart_rx_data(uart_rx_data),
      .uart_rx_valid(uart_rx_valid),
      .uart_rx_overflow(uart_rx_overflow),
      .uart_tx_ready(uart_tx_ready),
      .boot_tx_valid(boot_tx_valid),
      .uart_tx_push(mmio_tx_push),
      .uart_rx_pop(mmio_rx_pop),
      .uart_rx_clear(uart_rx_clear),
      .uart_tx_byte(mmio_tx_byte),
      .buttons(buttons),
      .leds(leds),
      .irq_timer(irq_timer),
      .ic_hit(ic_hit),
      .ic_miss(ic_miss),
      .dc_hit(dc_hit),
      .dc_miss(dc_miss),
      .boot_status({sdram_init_done, boot_error, boot_busy, boot_done_eff}),
      .boot_addr(boot_addr),
      .mmio_commit(dmem_req && !dmem_in_sdram),
      .boot_restart(boot_restart),
      .halted(halted),
      .exit_code(exit_code)
  );

  // The response-valid flop publishes this payload one cycle after the
  // request. Capturing unconditionally keeps late fetch/MMU qualification
  // off the address register enables; invalid responses are ignored.
  always_ff @(posedge clk) begin
    i_unc_rsp_addr <= imem_addr;
    imem_rsp_in_sdram <= imem_in_sdram;
  end
  assign i_unc_rsp_data = 32'd0;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) i_unc_rsp <= 1'b0;
    else i_unc_rsp <= i_unc_req;
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
      boot_cache_maintenance <= 1'b0;
    end else begin
      icache_flush <= 1'b0;
      if (boot_restart && !BOOT_OVERRIDE) begin
        boot_cache_maintenance <= 1'b1;
        dcache_flush <= 1'b1;
        fence_done <= 1'b0;
        fence_state <= F_DCACHE;
      end else
        case (fence_state)
          F_IDLE: begin
            if (core_fence_req) begin
              fence_done <= 1'b0;
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
            boot_cache_maintenance <= 1'b0;
          end
          default: begin
            fence_state <= F_IDLE;
          end
        endcase
    end
  end

  // ------------------------------------------------------- Response muxing
  // Both paths reply to the previous cycle's lookup. A new speculative
  // address may already select the other region while that reply arrives.
  assign imem_rsp_valid = imem_rsp_in_sdram ? ic_cpu_rsp : i_unc_rsp;
  assign imem_rsp_addr = imem_rsp_in_sdram ? ic_cpu_rsp_addr : i_unc_rsp_addr;
  assign imem_rsp_data = imem_rsp_in_sdram ? ic_cpu_rsp_data : i_unc_rsp_data;
  assign dmem_rsp_data = dmem_in_sdram ? dc_cm_rdata : mmio_rsp_data;
  // Only cached reads use immediate MEM-to-EX forwarding. Uncached
  // dependencies wait for WB, keeping peripheral decode off the early bus.
  assign dmem_forward_data = dc_forward_data;

`ifdef ROCO_SOC_CONTROL_FORMAL
  `include "soc_control_checks.svh"
`endif
`ifdef ROCO_SOC_MMIO_FORMAL
  `include "soc_mmio_checks.svh"
`endif
`ifdef ROCO_SOC_FENCE_FORMAL
  `include "soc_fence_checks.svh"
`endif
`ifdef ROCO_SOC_RAM_FORMAL
  `include "soc_ram_checks.svh"
`endif
`ifdef ROCO_SOC_SDRAM_MEMORY_FORMAL
  `include "soc_sdram_memory_checks.svh"
`endif

endmodule
