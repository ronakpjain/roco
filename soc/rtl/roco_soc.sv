// roco dual-hart system-on-chip.
//
// Two RV32I cores (mhartid 0/1) with Sv32 MMUs + I/D caches + SDRAM
// controller (96 MHz memory clock behind an AXI CDC bridge) + UART +
// bootloader + memory-mapped timer, LEDs, buttons, cache counters and
// boot status. AXI4 connects the caches, bootloader, walkers and MMIO
// ports; a snooping hub serializes exclusive D-cache fills (see docs/bus.md).
//
// Hart1 spins in reset until hart0 publishes its entry point at 0x110 and
// writes the release register at 0x114. A boot restart re-parks hart1.
//
// Memory map
//   0x1000_0000  SDRAM, 32 MiB (cached)
//   0x8000_0000  UART data (R: RX pop, W: TX push)
//   0x8000_0004  UART status: [0] tx_ready [1] rx_valid [3] rx_overflow
//   0x8000_0010  LEDs
//   0x8000_0014  buttons
//   0x8000_0018  mtime low            0x8000_001c  mtime high
//   0x8000_0020  hart0 mtimecmp low   0x8000_0024  hart0 mtimecmp high
//   0x8000_0028  hart0 timer pending  0x8000_002c  hart1 timer pending
//   0x8000_0030  I-cache hits         0x8000_0034  I-cache misses
//   0x8000_0038  D-cache hits         0x8000_003c  D-cache misses
//   0x8000_0050  hart0 software IRQ   0x8000_0054  hart1 software IRQ (IPI)
//   0x8000_0060  hart1 mtimecmp low   0x8000_0064  hart1 mtimecmp high
//   0x8000_0100  boot status: [0] done [1] busy [2] error
//   0x8000_0104  loaded image base
//   0x8000_0108  write to restart the bootloader
//   0x8000_0110  hart1 boot address (R/W)
//   0x8000_0114  hart1 release (W releases, R shows status)
//   0x8000_1000  tohost: write halts both cores, value is the exit code
//
// Instruction fetch outside SDRAM returns an illegal instruction, which
// traps through mtvec.

`include "axi4_defs.svh"
`default_nettype none

module roco_soc #(
    parameter int CLK_HZ = 48_000_000,
    /* Memory clock for the SDRAM controller/adapter (e.g. 96 MHz while
       cores run at 48 MHz). An AXI handshake CDC bridges the two. */
    parameter int MEM_CLK_HZ = 96_000_000,
    /* Power-up delay for the SDRAM controller, in memory-clock cycles.
       Shortened by formal cover runs so the CPU reaches running traffic
       inside the bound. */
    parameter int SDRAM_POWERUP = MEM_CLK_HZ / 5000,
    parameter int BAUD = 115200,
    parameter bit BOOT_OVERRIDE = 1'b0,
    parameter int ICACHE_LINES = 128,
    parameter int DCACHE_LINES = 128
) (
  input logic clk,
  input logic rst,
  /* Memory-domain clock/reset for the SDRAM adapter and controller. Tie to
     clk/rst for single-clock simulation and formal. */
  input logic clk_mem,
  input logic rst_mem,
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
  output logic trace0_valid,
  output logic [31:0] trace0_pc,
  output logic [31:0] trace0_instr,
  output logic [4:0] trace0_rd,
  output logic [31:0] trace0_wdata,
  /* Hart1 retire trace (same). */
  output logic trace1_valid,
  output logic [31:0] trace1_pc,
  output logic [31:0] trace1_instr,
  output logic [4:0] trace1_rd,
  output logic [31:0] trace1_wdata
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
  logic imem0_req;
  logic [31:0] imem0_addr;
  logic imem0_rsp_valid;
  logic [31:0] imem0_rsp_addr;
  logic [31:0] imem0_rsp_data;
  logic dmem0_lu_valid;
  logic [31:2] dmem0_lu_addr;
  logic [1:0] dmem0_lu_offset;
  logic [2:0] dmem0_lu_funct3;
  logic dmem0_ready;
  logic dmem0_req;
  logic dmem0_valid;
  logic dmem0_amo_read;
`ifdef ROCO_SOC_RAM_FORMAL
  logic f_mem_packet;
`endif
  logic dmem0_we;
  logic [31:0] dmem0_addr;
  logic [31:0] dmem0_wdata;
  logic [3:0] dmem0_be;
  logic [31:0] dmem0_rsp_data;
  logic [31:0] dmem0_forward_data;
  logic [31:0] dc0_forward_data;
  axi4_ar_t ptw0_ar;
  axi4_r_t ptw0_r;
  logic ptw0_r_ready;
  logic ptw0_ready;
  logic mmio0_done;
  logic [31:0] mmio0_rsp_data;
  // ------------------------------------------------------- Hart1 core buses
  logic imem1_req;
  logic [31:0] imem1_addr;
  logic imem1_rsp_valid;
  logic [31:0] imem1_rsp_addr;
  logic [31:0] imem1_rsp_data;
  logic dmem1_lu_valid;
  logic [31:2] dmem1_lu_addr;
  logic [1:0] dmem1_lu_offset;
  logic [2:0] dmem1_lu_funct3;
  logic dmem1_ready;
  logic dmem1_req;
  logic dmem1_valid;
  logic dmem1_amo_read;
  logic dmem1_we;
  logic [31:0] dmem1_addr;
  logic [31:0] dmem1_wdata;
  logic [3:0] dmem1_be;
  logic [31:0] dmem1_rsp_data;
  logic [31:0] dmem1_forward_data;
  logic [31:0] dc1_forward_data;
  axi4_ar_t ptw1_ar;
  axi4_r_t ptw1_r;
  logic ptw1_r_ready;
  logic ptw1_ready;
  logic mmio1_done;
  logic [31:0] mmio1_rsp_data;
  logic imem1_in_sdram;
  logic dmem1_in_sdram;
  logic dmem1_lu_in_sdram;
  logic i1_unc_req;
  logic i1_unc_rsp;
  logic imem1_rsp_in_sdram;
  logic [31:0] i1_unc_rsp_addr;
  logic [31:0] i1_unc_rsp_data;
  logic dc1_cm_ready;
  logic [31:0] dc1_cm_rdata;
  logic res0_store_valid, res1_store_valid;
  logic [29:0] res0_store_addr, res1_store_addr;
  logic irq_timer1, irq_software0, irq_software1;
  logic core1_rst;
  // Probe, invalidate, and targeted writeback signals to each D-cache.
  logic hub_snoop0_valid, hub_snoop1_valid;
  logic [22:0] hub_snoop0_addr, hub_snoop1_addr;
  logic hub_inv0, hub_inv1;
  logic hub_wb0, hub_wb1, hub_wb_done0, hub_wb_done1;
  logic dc0_amo_retry, dc1_amo_retry;
  logic core0_fence_req, core1_fence_req;
  logic fence_done0, fence_done1;
  logic fence_owner;
  logic remote_tlb_flush0, remote_tlb_flush1;
  logic dcache_flush;
  logic dcache_flush_done0, dcache_flush_done1;
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
    else if (dmem0_req && dmem0_in_sdram && dmem0_we && dmem0_addr[24:2] == cell_addr)
      f_instruction_coherent <= 1'b0;
    else if (icache_flush) f_instruction_coherent <= 1'b1;
    if (!rst && f_instruction_coherent) assert (f_dc_arch_data == native_cell);
    if (!rst && core0_rst && !boot_cache_maintenance) assert (f_instruction_coherent);
    if (!rst && icache_flush) begin
      assert (!dmem0_req);
      assert (f_dc_arch_data == native_cell);
    end
  end
`endif
`ifdef ROCO_SOC_FENCE_FORMAL
  logic f_dc_idle, f_dc_lookup_pending;
`endif

  logic imem0_in_sdram;
  logic dmem0_in_sdram;
  logic dmem0_lu_in_sdram;
  logic i0_unc_req;
  logic i0_unc_rsp;
  logic imem0_rsp_in_sdram;
  logic [31:0] i0_unc_rsp_addr;
  logic [31:0] i0_unc_rsp_data;
  logic dc0_cm_ready;
  logic [31:0] dc0_cm_rdata;

  // ----------------------------------------------------------- Cache ports
  logic ic0_cpu_rsp;
  logic [31:0] ic0_cpu_rsp_addr;
  logic [31:0] ic0_cpu_rsp_data;
  logic ic0_mem_req;
  logic [22:0] ic0_mem_word_addr;
  logic [3:0] ic0_mem_len;
  logic ic0_mem_ready;
  logic ic0_mem_rvalid;
  logic [31:0] ic0_mem_rdata;
  logic ic0_mem_rlast;
  logic ic0_hit;
  logic ic0_miss;
  logic ic0_cpu_miss;
  logic ic0_cpu_busy;
  logic imem0_miss;
  logic imem0_busy;

  logic dc0_mem_req;
  logic dc0_mem_we;
  logic [22:0] dc0_mem_word_addr;
  logic [3:0] dc0_mem_len;
  logic dc0_mem_ready;
  logic dc0_mem_wvalid;
  logic dc0_mem_wready;
  logic [31:0] dc0_mem_wdata;
  logic [3:0] dc0_mem_wbe;
  logic dc0_mem_rvalid;
  logic [31:0] dc0_mem_rdata;
  logic dc0_mem_rlast;
  logic dc0_hit;
  logic dc0_miss;
  logic dc0_snoop_dirty;
  logic dc0_flush_busy, dc1_flush_busy;
  logic [22:0] dc0_miss_line;

  // ------------------------------------------------- Hart1 cache ports
  logic ic1_cpu_rsp;
  logic [31:0] ic1_cpu_rsp_addr;
  logic [31:0] ic1_cpu_rsp_data;
  logic ic1_mem_req;
  logic [22:0] ic1_mem_word_addr;
  logic [3:0] ic1_mem_len;
  logic ic1_mem_ready;
  logic ic1_mem_rvalid;
  logic [31:0] ic1_mem_rdata;
  logic ic1_mem_rlast;
  logic ic1_hit;
  logic ic1_miss;
  logic ic1_cpu_miss;
  logic ic1_cpu_busy;
  logic imem1_miss;
  logic imem1_busy;

  logic dc1_mem_req;
  logic dc1_mem_we;
  logic [22:0] dc1_mem_word_addr;
  logic [3:0] dc1_mem_len;
  logic dc1_mem_ready;
  logic dc1_mem_wvalid;
  logic dc1_mem_wready;
  logic [31:0] dc1_mem_wdata;
  logic [3:0] dc1_mem_wbe;
  logic dc1_mem_rvalid;
  logic [31:0] dc1_mem_rdata;
  logic dc1_mem_rlast;
  logic dc1_hit;
  logic dc1_miss;
  logic dc1_snoop_dirty;
  logic [22:0] dc1_miss_line;

  // Master-side D-cache ports behind the hub (to axi4_mem_master).
  logic mdc0_req, mdc0_we;
  logic [22:0] mdc0_word_addr;
  logic [3:0] mdc0_len;
  logic mdc0_ready;
  logic mdc0_wvalid, mdc0_wready;
  logic [31:0] mdc0_wdata;
  logic [3:0] mdc0_wbe;
  logic mdc0_rvalid;
  logic [31:0] mdc0_rdata;
  logic mdc0_rlast;
  logic mdc1_req, mdc1_we;
  logic [22:0] mdc1_word_addr;
  logic [3:0] mdc1_len;
  logic mdc1_ready;
  logic mdc1_wvalid, mdc1_wready;
  logic [31:0] mdc1_wdata;
  logic [3:0] mdc1_wbe;
  logic mdc1_rvalid;
  logic [31:0] mdc1_rdata;
  logic mdc1_rlast;

  // The hub serializes exclusive D-cache fills, not writebacks.
  typedef enum logic [2:0] {
    H_IDLE,
    H_PROBE,
    H_SAMPLE,
    H_FLUSH,
    H_GRANT,
    H_FILL,
    H_SETTLE
  } hub_state_t;
  hub_state_t hub_state;
  logic hub_owner, hub_rr;
  logic [22:0] hub_addr;

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
  logic core0_rst;

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
  logic irq_timer0;
  logic [31:0] mmio_rdata;
  // SMP boot mailbox (hart1 entry + release); hart1 datapath lands later.
  logic [31:0] hart1_boot_addr;
  logic hart1_release;

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

  assign imem0_in_sdram = (imem0_addr[31:25] == 7'd8);
  assign imem0_miss = ic0_cpu_miss;
  assign imem0_busy = ic0_cpu_busy;
  // Target classification belongs to the same EX lookup as the cache
  // response. Preserve it while MEM waits; an unrelated ALU payload must
  // not route its address bits through memory readiness and frontend hold.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) dmem0_in_sdram <= 1'b0;
    else if (dmem0_lu_valid) dmem0_in_sdram <= dmem0_lu_in_sdram;
  end
  assign dmem0_lu_in_sdram = (dmem0_lu_addr[31:25] == 7'd8);
  assign i0_unc_req = imem0_req && !imem0_in_sdram && !ic0_cpu_busy;
  // An uncached failed SC has no transaction to wait for. Cached SC
  // still waits for its lookup to drain, without committing a write.
  assign dmem0_ready = dmem0_in_sdram ? dc0_cm_ready : (!(dmem0_valid || dmem0_amo_read) || mmio0_done);

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
  assign core0_rst = rst || !boot_release || boot_cache_maintenance;
  // A replacement image may overwrite cached instructions and data. Drain
  // committed dirty stores first, then cancel old lookup/refill metadata.
  // The AXI masters keep running so accepted transactions always drain.
  assign cache_rst = rst || (boot_cache_maintenance && icache_flush);
  assign boot_mem_ready = boot_axi_ready && !boot_cache_maintenance;

  // ------------------------------------------------- Hart1 fetch/data path
  assign imem1_in_sdram = (imem1_addr[31:25] == 7'd8);
  assign imem1_miss = ic1_cpu_miss;
  assign imem1_busy = ic1_cpu_busy;
  // Same EX-lookup classification as hart0, preserved while MEM waits.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) dmem1_in_sdram <= 1'b0;
    else if (dmem1_lu_valid) dmem1_in_sdram <= dmem1_lu_in_sdram;
  end
  assign dmem1_lu_in_sdram = (dmem1_lu_addr[31:25] == 7'd8);
  assign i1_unc_req = imem1_req && !imem1_in_sdram && !ic1_cpu_busy;
  assign dmem1_ready = dmem1_in_sdram ? dc1_cm_ready : (!(dmem1_valid || dmem1_amo_read) || mmio1_done);
  // Hart1 spins in reset until hart0 publishes an entry point and releases
  // it through the SMP boot mailbox.
  assign core1_rst = rst || !boot_release || !hart1_release || boot_cache_maintenance;
  always_ff @(posedge clk) begin
    i1_unc_rsp_addr <= imem1_addr;
    imem1_rsp_in_sdram <= imem1_in_sdram;
  end
  assign i1_unc_rsp_data = 32'd0;
  always_ff @(posedge clk or posedge rst) begin
    if (rst) i1_unc_rsp <= 1'b0;
    else i1_unc_rsp <= i1_unc_req;
  end
  assign imem1_rsp_valid = imem1_rsp_in_sdram ? ic1_cpu_rsp : i1_unc_rsp;
  assign imem1_rsp_addr = imem1_rsp_in_sdram ? ic1_cpu_rsp_addr : i1_unc_rsp_addr;
  assign imem1_rsp_data = imem1_rsp_in_sdram ? ic1_cpu_rsp_data : i1_unc_rsp_data;
  assign dmem1_rsp_data = dmem1_in_sdram ? dc1_cm_rdata : mmio1_rsp_data;
  assign dmem1_forward_data = dc1_forward_data;

  // ----------------------------------------------------- Coherence hub
  // Serialize exclusive fills, including the arbitration cycle. A fill
  // cannot reach AXI before the peer has relinquished its copy. Clean
  // lines are still exclusive, so stores never need a separate grant.
  // Victim and probe writebacks do not acquire the hub. AW reaches the
  // SDRAM adapter before W, and the adapter drains the write before it can
  // service a later read. A peer fill cannot overtake an accepted writeback.
  logic need0_fill, need1_fill, grant0_fill, grant1_fill;
  assign need0_fill = dc0_mem_req && !dc0_mem_we;
  assign need1_fill = dc1_mem_req && !dc1_mem_we;
  assign grant0_fill = hub_state == H_GRANT && !hub_owner;
  assign grant1_fill = hub_state == H_GRANT && hub_owner;
  assign dc0_mem_ready = mdc0_ready && (!need0_fill || grant0_fill);
  assign dc1_mem_ready = mdc1_ready && (!need1_fill || grant1_fill);
  assign mdc0_req = dc0_mem_req && (!need0_fill || grant0_fill);
  assign mdc1_req = dc1_mem_req && (!need1_fill || grant1_fill);
  assign mdc0_we = dc0_mem_we;
  assign mdc0_word_addr = dc0_mem_word_addr;
  assign mdc0_len = dc0_mem_len;
  assign mdc0_wvalid = dc0_mem_wvalid;
  assign dc0_mem_wready = mdc0_wready;
  assign mdc0_wdata = dc0_mem_wdata;
  assign mdc0_wbe = dc0_mem_wbe;
  assign dc0_mem_rvalid = mdc0_rvalid;
  assign dc0_mem_rdata = mdc0_rdata;
  assign dc0_mem_rlast = mdc0_rlast;
  assign mdc1_we = dc1_mem_we;
  assign mdc1_word_addr = dc1_mem_word_addr;
  assign mdc1_len = dc1_mem_len;
  assign mdc1_wvalid = dc1_mem_wvalid;
  assign dc1_mem_wready = mdc1_wready;
  assign mdc1_wdata = dc1_mem_wdata;
  assign mdc1_wbe = dc1_mem_wbe;
  assign dc1_mem_rvalid = mdc1_rvalid;
  assign dc1_mem_rdata = mdc1_rdata;
  assign dc1_mem_rlast = mdc1_rlast;
  // Sample a clean invalidate and the dirty decision on the same edge.
  assign hub_snoop0_valid = hub_owner && (hub_state == H_PROBE || hub_state == H_SAMPLE);
  assign hub_snoop1_valid = !hub_owner && (hub_state == H_PROBE || hub_state == H_SAMPLE);
  assign hub_snoop0_addr = hub_addr;
  assign hub_snoop1_addr = hub_addr;
  assign hub_inv0 = hub_owner && hub_state == H_SAMPLE;
  assign hub_inv1 = !hub_owner && hub_state == H_SAMPLE;
  assign hub_wb0 = hub_owner && hub_state == H_FLUSH;
  assign hub_wb1 = !hub_owner && hub_state == H_FLUSH;
  logic owner_accept, owner_rlast, peer_dirty, peer_wb_done;
  assign owner_accept = hub_owner ? (need1_fill && mdc1_ready) : (need0_fill && mdc0_ready);
  assign owner_rlast = hub_owner ?
      (dc1_mem_rvalid && dc1_mem_rlast) : (dc0_mem_rvalid && dc0_mem_rlast);
  assign peer_dirty = hub_owner ? dc0_snoop_dirty : dc1_snoop_dirty;
  assign peer_wb_done = hub_owner ? hub_wb_done0 : hub_wb_done1;
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      hub_state <= H_IDLE;
      hub_owner <= 1'b0;
      hub_addr <= '0;
      hub_rr <= 1'b0;
    end else begin
      case (hub_state)
        H_IDLE: begin
          if (need0_fill || need1_fill) begin
            if (need0_fill && (!need1_fill || !hub_rr)) begin
              hub_owner <= 1'b0;
              hub_addr <= dc0_miss_line;
            end else begin
              hub_owner <= 1'b1;
              hub_addr <= dc1_miss_line;
            end
            hub_state <= H_PROBE;
          end
        end
        H_PROBE: hub_state <= H_SAMPLE;
        H_SAMPLE: begin
          if (peer_dirty) hub_state <= H_FLUSH;
          else hub_state <= H_GRANT;
        end
        H_FLUSH: begin
          if (peer_wb_done) hub_state <= H_PROBE;
        end
        H_GRANT: if (owner_accept) hub_state <= H_FILL;
        H_FILL: if (owner_rlast) hub_state <= H_SETTLE;
        // Allow the owner's registered RAM read to land before starting
        // another probe. A waiting AMO can then read in IDLE and store in
        // PROBE. This is a fixed delay, never a wait on CPU progress.
        H_SETTLE: begin
          hub_rr <= !hub_owner;
          hub_state <= H_IDLE;
        end
        default: hub_state <= H_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- CPU
`ifdef ROCO_SOC_GPR_FORMAL
  (* anyconst *) logic [4:0] f_gpr_watch_addr;
`endif
  roco_cpu u_cpu0 (
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
      .rst(core0_rst),
      .boot_addr(BOOT_OVERRIDE ? 32'h1000_0000 : boot_addr),
      .halt(halted),
      .irq_timer(irq_timer0),
      .irq_external(1'b0),
      .irq_software(irq_software0),
      .imem_req(imem0_req),
      .imem_addr(imem0_addr),
      .imem_rsp_valid(imem0_rsp_valid),
      .imem_rsp_addr(imem0_rsp_addr),
      .imem_rsp_data(imem0_rsp_data),
      .imem_miss(imem0_miss),
      .imem_busy(imem0_busy),
      .dmem_lu_valid(dmem0_lu_valid),
      .dmem_lu_addr(dmem0_lu_addr),
      .dmem_lu_offset(dmem0_lu_offset),
      .dmem_lu_funct3(dmem0_lu_funct3),
      .dmem_ready(dmem0_ready),
      .dmem_busy(dc0_flush_busy),
      .dmem_req(dmem0_req),
      .dmem_valid(dmem0_valid),
      .dmem_amo_read(dmem0_amo_read),
      .dmem_amo_retry(dmem0_in_sdram && dc0_amo_retry),
`ifdef ROCO_SOC_RAM_FORMAL
      .f_mem_packet(f_mem_packet),
`endif
      .dmem_we(dmem0_we),
      .dmem_addr(dmem0_addr),
      .dmem_wdata(dmem0_wdata),
      .dmem_be(dmem0_be),
      .dmem_rsp_data(dmem0_rsp_data),
      .dmem_forward_data(dmem0_forward_data),
      .ptw_bus_rst(rst),
      .ptw_ar(ptw0_ar),
      .ptw_ready(ptw0_ready),
      .ptw_r(ptw0_r),
      .ptw_r_ready(ptw0_r_ready),
      .fence_req(core0_fence_req),
      .fence_done(fence_done0),
      .res_store_valid(res0_store_valid),
      .res_store_addr(res0_store_addr),
      .res_remote_valid(res1_store_valid),
      .res_remote_addr(res1_store_addr),
      .remote_tlb_flush(remote_tlb_flush0),
      .trace_valid(trace0_valid),
      .trace_pc(trace0_pc),
      .trace_instr(trace0_instr),
      .trace_rd(trace0_rd),
      .trace_wdata(trace0_wdata)
  );

  // -------------------------------------------------------------- I-cache
  icache #(
      .LINE_WORDS(4),
      .NUM_LINES(ICACHE_LINES)
  ) u_icache0 (
`ifdef ROCO_SOC_ICACHE_MEMORY_FORMAL
      .formal_watch_word(cell_addr),
      .formal_watch_data(f_dc_arch_data),
      .formal_backing_data(native_cell),
      .formal_coherent(f_instruction_coherent),
      .formal_boot_loading(core0_rst && !boot_cache_maintenance),
      .formal_ram_word(ic_read_word),
      .formal_read_left(f_ic_read_left),
`endif
      .clk(clk),
      .rst(rst),
      .flush(icache_flush),
      .cpu_req(imem0_req && imem0_in_sdram),
      .cpu_addr(imem0_addr),
      .cpu_rsp_valid(ic0_cpu_rsp),
      .cpu_rsp_addr(ic0_cpu_rsp_addr),
      .cpu_rsp_data(ic0_cpu_rsp_data),
      .cpu_miss(ic0_cpu_miss),
      .cpu_busy(ic0_cpu_busy),
      .mem_req(ic0_mem_req),
      .mem_word_addr(ic0_mem_word_addr),
      .mem_len(ic0_mem_len),
      .mem_ready(ic0_mem_ready),
      .mem_rvalid(ic0_mem_rvalid),
      .mem_rdata(ic0_mem_rdata),
      .mem_rlast(ic0_mem_rlast),
      .hit_pulse(ic0_hit),
      .miss_pulse(ic0_miss)
  );

  // -------------------------------------------------------------- D-cache
  dcache #(
      .LINE_WORDS(8),
      .NUM_LINES(DCACHE_LINES)
  ) u_dcache0 (
`ifdef ROCO_SOC_DCACHE_MEMORY_FORMAL
      .formal_memory_addr(cell_addr),
      .formal_initial_word(rst ? initial_cell : native_cell),
      .formal_backing_word(native_cell),
      .formal_cancel(core0_rst),
      .formal_boot_loading(core0_rst && !boot_cache_maintenance),
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
      .flush_done(dcache_flush_done0),
      .lu_valid(dmem0_lu_valid && dmem0_lu_in_sdram),
      .lu_addr(dmem0_lu_addr[24:2]),
      .lu_offset(dmem0_lu_offset),
      .lu_funct3(dmem0_lu_funct3),
      .cm_valid(dmem0_req && dmem0_in_sdram),
      .cm_amo_read(dmem0_amo_read && dmem0_in_sdram),
      .cm_amo_retry(dc0_amo_retry),
      .cm_we(dmem0_we),
      .cm_addr(dmem0_addr[24:2]),
      .cm_wdata(dmem0_wdata),
      .cm_be(dmem0_be),
      .cm_rdata(dc0_cm_rdata),
      .cm_forward_data(dc0_forward_data),
      .cm_ready(dc0_cm_ready),
      .mem_req(dc0_mem_req),
      .mem_we(dc0_mem_we),
      .mem_word_addr(dc0_mem_word_addr),
      .mem_len(dc0_mem_len),
      .mem_ready(dc0_mem_ready),
      .mem_wvalid(dc0_mem_wvalid),
      .mem_wready(dc0_mem_wready),
      .mem_wdata(dc0_mem_wdata),
      .mem_wbe(dc0_mem_wbe),
      .mem_rvalid(dc0_mem_rvalid),
      .mem_rdata(dc0_mem_rdata),
      .mem_rlast(dc0_mem_rlast),
      .hit_pulse(dc0_hit),
      .miss_pulse(dc0_miss),
      .snoop_valid(hub_snoop0_valid),
      .snoop_addr(hub_snoop0_addr),
      .snoop_dirty(dc0_snoop_dirty),
      .snoop_invalidate(hub_inv0),
      .snoop_writeback(hub_wb0),
      .snoop_writeback_done(hub_wb_done0),
      .miss_line(dc0_miss_line),
      .flush_busy(dc0_flush_busy)
  );

  // ------------------------------------------------------- Hart1 CPU
  roco_cpu #(
      .HART_ID(1)
  ) u_cpu1 (
`ifdef ROCO_SOC_GPR_FORMAL
      .rvfi_gpr_watch_addr(f_gpr_watch_addr),
      .rvfi_gpr_watch_value(),
`endif
      .clk(clk),
      .rst(core1_rst),
      .boot_addr(hart1_boot_addr),
      .halt(halted),
      .irq_timer(irq_timer1),
      .irq_external(1'b0),
      .irq_software(irq_software1),
      .imem_req(imem1_req),
      .imem_addr(imem1_addr),
      .imem_rsp_valid(imem1_rsp_valid),
      .imem_rsp_addr(imem1_rsp_addr),
      .imem_rsp_data(imem1_rsp_data),
      .imem_miss(imem1_miss),
      .imem_busy(imem1_busy),
      .dmem_lu_valid(dmem1_lu_valid),
      .dmem_lu_addr(dmem1_lu_addr),
      .dmem_lu_offset(dmem1_lu_offset),
      .dmem_lu_funct3(dmem1_lu_funct3),
      .dmem_ready(dmem1_ready),
      .dmem_busy(dc1_flush_busy),
      .dmem_req(dmem1_req),
      .dmem_valid(dmem1_valid),
      .dmem_amo_read(dmem1_amo_read),
      .dmem_amo_retry(dmem1_in_sdram && dc1_amo_retry),
      .dmem_we(dmem1_we),
      .dmem_addr(dmem1_addr),
      .dmem_wdata(dmem1_wdata),
      .dmem_be(dmem1_be),
      .dmem_rsp_data(dmem1_rsp_data),
      .dmem_forward_data(dmem1_forward_data),
      .ptw_bus_rst(rst),
      .ptw_ar(ptw1_ar),
      .ptw_ready(ptw1_ready),
      .ptw_r(ptw1_r),
      .ptw_r_ready(ptw1_r_ready),
      .fence_req(core1_fence_req),
      .fence_done(fence_done1),
      .res_store_valid(res1_store_valid),
      .res_store_addr(res1_store_addr),
      .res_remote_valid(res0_store_valid),
      .res_remote_addr(res0_store_addr),
      .remote_tlb_flush(remote_tlb_flush1),
      .trace_valid(trace1_valid),
      .trace_pc(trace1_pc),
      .trace_instr(trace1_instr),
      .trace_rd(trace1_rd),
      .trace_wdata(trace1_wdata)
  );

  // ------------------------------------------------- Hart1 instruction cache
  icache #(
      .LINE_WORDS(4),
      .NUM_LINES(ICACHE_LINES)
  ) u_icache1 (
      .clk(clk),
      .rst(rst),
      .flush(icache_flush),
      .cpu_req(imem1_req && imem1_in_sdram),
      .cpu_addr(imem1_addr),
      .cpu_rsp_valid(ic1_cpu_rsp),
      .cpu_rsp_addr(ic1_cpu_rsp_addr),
      .cpu_rsp_data(ic1_cpu_rsp_data),
      .cpu_miss(ic1_cpu_miss),
      .cpu_busy(ic1_cpu_busy),
      .mem_req(ic1_mem_req),
      .mem_word_addr(ic1_mem_word_addr),
      .mem_len(ic1_mem_len),
      .mem_ready(ic1_mem_ready),
      .mem_rvalid(ic1_mem_rvalid),
      .mem_rdata(ic1_mem_rdata),
      .mem_rlast(ic1_mem_rlast),
      .hit_pulse(ic1_hit),
      .miss_pulse(ic1_miss)
  );

  // ------------------------------------------------------- Hart1 data cache
  dcache #(
      .LINE_WORDS(8),
      .NUM_LINES(DCACHE_LINES)
  ) u_dcache1 (
      .clk(clk),
      .rst(cache_rst),
      .flush(dcache_flush),
      .flush_done(dcache_flush_done1),
      .lu_valid(dmem1_lu_valid && dmem1_lu_in_sdram),
      .lu_addr(dmem1_lu_addr[24:2]),
      .lu_offset(dmem1_lu_offset),
      .lu_funct3(dmem1_lu_funct3),
      .cm_valid(dmem1_req && dmem1_in_sdram),
      .cm_amo_read(dmem1_amo_read && dmem1_in_sdram),
      .cm_amo_retry(dc1_amo_retry),
      .cm_we(dmem1_we),
      .cm_addr(dmem1_addr[24:2]),
      .cm_wdata(dmem1_wdata),
      .cm_be(dmem1_be),
      .cm_rdata(dc1_cm_rdata),
      .cm_forward_data(dc1_forward_data),
      .cm_ready(dc1_cm_ready),
      .mem_req(dc1_mem_req),
      .mem_we(dc1_mem_we),
      .mem_word_addr(dc1_mem_word_addr),
      .mem_len(dc1_mem_len),
      .mem_ready(dc1_mem_ready),
      .mem_wvalid(dc1_mem_wvalid),
      .mem_wready(dc1_mem_wready),
      .mem_wdata(dc1_mem_wdata),
      .mem_wbe(dc1_mem_wbe),
      .mem_rvalid(dc1_mem_rvalid),
      .mem_rdata(dc1_mem_rdata),
      .mem_rlast(dc1_mem_rlast),
      .hit_pulse(dc1_hit),
      .miss_pulse(dc1_miss),
      .snoop_valid(hub_snoop1_valid),
      .snoop_addr(hub_snoop1_addr),
      .snoop_dirty(dc1_snoop_dirty),
      .snoop_invalidate(hub_inv1),
      .snoop_writeback(hub_wb1),
      .snoop_writeback_done(hub_wb_done1),
      .miss_line(dc1_miss_line),
      .flush_busy(dc1_flush_busy)
  );

  // ------------------------------------------------------------- AXI4 fabric
  axi4_ar_t i0_ar, d0_ar, boot_ar, mmio0_ar, ram_ar, periph_ar;
  axi4_aw_t i0_aw, d0_aw, boot_aw, mmio0_aw, ram_aw, periph_aw;
  axi4_w_t i0_w, d0_w, boot_w, mmio0_w, ram_w, periph_w;
  axi4_b_t i0_b, d0_b, boot_b, mmio0_b, ram_b, periph_b, unused_ptw_b;
  axi4_r_t i0_r, d0_r, boot_r, mmio0_r, ram_r, periph_r;
  logic i0_arready, d0_arready, boot_arready, mmio0_arready, ram_arready, periph_arready;
  logic i0_awready, d0_awready, boot_awready, mmio0_awready, ram_awready, periph_awready;
  logic i0_wready, d0_wready, boot_wready, mmio0_wready, ram_wready, periph_wready;
  logic i0_rready, d0_rready, boot_rready, mmio0_rready, ram_rready, periph_rready;
  logic i0_bready, d0_bready, boot_bready, mmio0_bready, ram_bready, periph_bready;
  // Hart1 AXI masters (I$, D$, PTW, MMIO) into xbar m5-m8.
  axi4_ar_t i1_ar, d1_ar, mmio1_ar;
  axi4_aw_t i1_aw, d1_aw, mmio1_aw;
  axi4_w_t i1_w, d1_w, mmio1_w;
  axi4_b_t i1_b, d1_b, mmio1_b;
  axi4_r_t i1_r, d1_r, mmio1_r;
  logic i1_arready, d1_arready, mmio1_arready;
  logic i1_awready, d1_awready, mmio1_awready;
  logic i1_wready, d1_wready, mmio1_wready;
  logic i1_rready, d1_rready, mmio1_rready;
  logic i1_bready, d1_bready, mmio1_bready;
  logic unused_i1_wready, unused_i1_done, unused_d1_done;
  logic
      unused_mmio1_accept,
      mmio1_read_done,
      mmio1_write_done,
      unused_mmio1_wready,
      unused_mmio1_rlast;
  // Memory-domain SDRAM port (fast clock) behind the CDC bridge.
  axi4_ar_t mem_ram_ar;
  axi4_aw_t mem_ram_aw;
  axi4_w_t mem_ram_w;
  axi4_b_t mem_ram_b;
  axi4_r_t mem_ram_r;
  logic mem_ram_arready, mem_ram_awready, mem_ram_wready, mem_ram_rready, mem_ram_bready;
  // Cross-domain status: SDRAM readiness into the core clock.
  logic c_ready_sync0, c_ready_sync1, init_done_sync0, init_done_sync1;
  logic c_ready_synced, init_done_synced;
  logic unused_i0_wready, unused_i0_done, unused_d0_done, unused_boot_done;
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
  logic unused_ptw1_awready, unused_ptw1_wready;
  axi4_b_t unused_ptw1_b;
  logic [31:0] unused_boot_rdata;
  logic
      unused_mmio0_accept,
      mmio0_read_done,
      mmio0_write_done,
      unused_mmio0_wready,
      unused_mmio0_rlast;
  logic psel, penable, pwrite, pready;
  logic [31:0] paddr, pwdata;
  logic [3:0] pstrb;
  logic [2:0] unused_pprot;

  axi4_mem_master u_i0_axi (
      .clk(clk),
      .rst(rst),
      .req(ic0_mem_req),
      .we(1'b0),
      .addr({7'd8, ic0_mem_word_addr, 2'b00}),
      .len(ic0_mem_len),
      .ready(ic0_mem_ready),
      .wvalid(1'b0),
      .wready(unused_i0_wready),
      .wdata(32'd0),
      .wbe(4'd0),
      .rvalid(ic0_mem_rvalid),
      .rdata(ic0_mem_rdata),
      .rlast(ic0_mem_rlast),
      .write_done(unused_i0_done),
`ifdef ROCO_SOC_RAM_FORMAL
      .f_write_left(),
`endif
      .ar(i0_ar),
      .ar_ready(i0_arready),
      .r(i0_r),
      .r_ready(i0_rready),
      .aw(i0_aw),
      .aw_ready(i0_awready),
      .w(i0_w),
      .w_ready(i0_wready),
      .b(i0_b),
      .b_ready(i0_bready)
  );
  axi4_mem_master u_d0_axi (
      .clk(clk),
      .rst(rst),
      .req(mdc0_req),
      .we(mdc0_we),
      .addr({7'd8, mdc0_word_addr, 2'b00}),
      .len(mdc0_len),
      .ready(mdc0_ready),
      .wvalid(mdc0_wvalid),
      .wready(mdc0_wready),
      .wdata(mdc0_wdata),
      .wbe(mdc0_wbe),
      .rvalid(mdc0_rvalid),
      .rdata(mdc0_rdata),
      .rlast(mdc0_rlast),
      .write_done(unused_d0_done),
`ifdef ROCO_SOC_RAM_FORMAL
      .f_write_left(f_d_write_left),
`endif
      .ar(d0_ar),
      .ar_ready(d0_arready),
      .r(d0_r),
      .r_ready(d0_rready),
      .aw(d0_aw),
      .aw_ready(d0_awready),
      .w(d0_w),
      .w_ready(d0_wready),
      .b(d0_b),
      .b_ready(d0_bready)
  );
  axi4_mem_master u_i1_axi (
      .clk(clk),
      .rst(rst),
      .req(ic1_mem_req),
      .we(1'b0),
      .addr({7'd8, ic1_mem_word_addr, 2'b00}),
      .len(ic1_mem_len),
      .ready(ic1_mem_ready),
      .wvalid(1'b0),
      .wready(unused_i1_wready),
      .wdata(32'd0),
      .wbe(4'd0),
      .rvalid(ic1_mem_rvalid),
      .rdata(ic1_mem_rdata),
      .rlast(ic1_mem_rlast),
      .write_done(unused_i1_done),
`ifdef ROCO_SOC_RAM_FORMAL
      .f_write_left(),
`endif
      .ar(i1_ar),
      .ar_ready(i1_arready),
      .r(i1_r),
      .r_ready(i1_rready),
      .aw(i1_aw),
      .aw_ready(i1_awready),
      .w(i1_w),
      .w_ready(i1_wready),
      .b(i1_b),
      .b_ready(i1_bready)
  );
  axi4_mem_master u_d1_axi (
      .clk(clk),
      .rst(rst),
      .req(mdc1_req),
      .we(mdc1_we),
      .addr({7'd8, mdc1_word_addr, 2'b00}),
      .len(mdc1_len),
      .ready(mdc1_ready),
      .wvalid(mdc1_wvalid),
      .wready(mdc1_wready),
      .wdata(mdc1_wdata),
      .wbe(mdc1_wbe),
      .rvalid(mdc1_rvalid),
      .rdata(mdc1_rdata),
      .rlast(mdc1_rlast),
      .write_done(unused_d1_done),
`ifdef ROCO_SOC_RAM_FORMAL
      .f_write_left(),
`endif
      .ar(d1_ar),
      .ar_ready(d1_arready),
      .r(d1_r),
      .r_ready(d1_rready),
      .aw(d1_aw),
      .aw_ready(d1_awready),
      .w(d1_w),
      .w_ready(d1_wready),
      .b(d1_b),
      .b_ready(d1_bready)
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
  axi4_mem_master u_mmio0_axi (
      .clk(clk),
      .rst(rst),
      // An uncached atomic reads its old value here; the cached path is
      // already served by the EX lookup, so only this port reads first.
      .req((dmem0_valid || dmem0_amo_read) && !dmem0_in_sdram),
      .we(dmem0_we && !dmem0_amo_read),
      .addr({dmem0_addr[31:2], 2'b00}),
      .len(4'd0),
      .ready(unused_mmio0_accept),
      .wvalid(1'b1),
      .wready(unused_mmio0_wready),
      .wdata(dmem0_wdata),
      .wbe(dmem0_be),
      .rvalid(mmio0_read_done),
      .rdata(mmio0_rsp_data),
      .rlast(unused_mmio0_rlast),
      .write_done(mmio0_write_done),
`ifdef ROCO_SOC_RAM_FORMAL
      .f_write_left(),
`endif
      .ar(mmio0_ar),
      .ar_ready(mmio0_arready),
      .r(mmio0_r),
      .r_ready(mmio0_rready),
      .aw(mmio0_aw),
      .aw_ready(mmio0_awready),
      .w(mmio0_w),
      .w_ready(mmio0_wready),
      .b(mmio0_b),
      .b_ready(mmio0_bready)
  );
  assign mmio0_done = mmio0_read_done || mmio0_write_done;
  axi4_mem_master u_mmio1_axi (
      .clk(clk),
      .rst(rst),
      // Same split-phase atomic discipline as hart0: cached targets never
      // touch this port; an uncached atomic reads first, then writes once.
      .req((dmem1_valid || dmem1_amo_read) && !dmem1_in_sdram),
      .we(dmem1_we && !dmem1_amo_read),
      .addr({dmem1_addr[31:2], 2'b00}),
      .len(4'd0),
      .ready(unused_mmio1_accept),
      .wvalid(1'b1),
      .wready(unused_mmio1_wready),
      .wdata(dmem1_wdata),
      .wbe(dmem1_be),
      .rvalid(mmio1_read_done),
      .rdata(mmio1_rsp_data),
      .rlast(unused_mmio1_rlast),
      .write_done(mmio1_write_done),
`ifdef ROCO_SOC_RAM_FORMAL
      .f_write_left(),
`endif
      .ar(mmio1_ar),
      .ar_ready(mmio1_arready),
      .r(mmio1_r),
      .r_ready(mmio1_rready),
      .aw(mmio1_aw),
      .aw_ready(mmio1_awready),
      .w(mmio1_w),
      .w_ready(mmio1_wready),
      .b(mmio1_b),
      .b_ready(mmio1_bready)
  );
  assign mmio1_done = mmio1_read_done || mmio1_write_done;


  axi4_xbar u_xbar (
      .clk(clk),
      .rst(rst),
      .m0_ar(i0_ar),
      .m0_ar_ready(i0_arready),
      .m0_r(i0_r),
      .m0_r_ready(i0_rready),
      .m0_aw(i0_aw),
      .m0_aw_ready(i0_awready),
      .m0_w(i0_w),
      .m0_w_ready(i0_wready),
      .m0_b(i0_b),
      .m0_b_ready(i0_bready),
      .m1_ar(d0_ar),
      .m1_ar_ready(d0_arready),
      .m1_r(d0_r),
      .m1_r_ready(d0_rready),
      .m1_aw(d0_aw),
      .m1_aw_ready(d0_awready),
      .m1_w(d0_w),
      .m1_w_ready(d0_wready),
      .m1_b(d0_b),
      .m1_b_ready(d0_bready),
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
      .m3_ar(ptw0_ar),
      .m3_ar_ready(ptw0_ready),
      .m3_r(ptw0_r),
      .m3_r_ready(ptw0_r_ready),
      .m3_aw(53'd0),
      .m3_aw_ready(unused_ptw_awready),
      .m3_w(38'd0),
      .m3_w_ready(unused_ptw_wready),
      .m3_b(unused_ptw_b),
      .m3_b_ready(1'b1),
      .m4_ar(mmio0_ar),
      .m4_ar_ready(mmio0_arready),
      .m4_r(mmio0_r),
      .m4_r_ready(mmio0_rready),
      .m4_aw(mmio0_aw),
      .m4_aw_ready(mmio0_awready),
      .m4_w(mmio0_w),
      .m4_w_ready(mmio0_wready),
      .m4_b(mmio0_b),
      .m4_b_ready(mmio0_bready),
      .m5_ar(i1_ar),
      .m5_ar_ready(i1_arready),
      .m5_r_ready(i1_rready),
      .m5_r(i1_r),
      .m5_aw(i1_aw),
      .m5_aw_ready(i1_awready),
      .m5_w(i1_w),
      .m5_w_ready(i1_wready),
      .m5_b_ready(i1_bready),
      .m5_b(i1_b),
      .m6_ar(d1_ar),
      .m6_ar_ready(d1_arready),
      .m6_r_ready(d1_rready),
      .m6_r(d1_r),
      .m6_aw(d1_aw),
      .m6_aw_ready(d1_awready),
      .m6_w(d1_w),
      .m6_w_ready(d1_wready),
      .m6_b_ready(d1_bready),
      .m6_b(d1_b),
      // Hart1 page-table walker: single-beat SDRAM reads like hart0.
      .m7_ar(ptw1_ar),
      .m7_ar_ready(ptw1_ready),
      .m7_r_ready(ptw1_r_ready),
      .m7_r(ptw1_r),
      .m7_aw(53'd0),
      .m7_aw_ready(unused_ptw1_awready),
      .m7_w(38'd0),
      .m7_w_ready(unused_ptw1_wready),
      .m7_b(unused_ptw1_b),
      .m7_b_ready(1'b1),
      .m8_ar(mmio1_ar),
      .m8_ar_ready(mmio1_arready),
      .m8_r_ready(mmio1_rready),
      .m8_r(mmio1_r),
      .m8_aw(mmio1_aw),
      .m8_aw_ready(mmio1_awready),
      .m8_w(mmio1_w),
      .m8_w_ready(mmio1_wready),
      .m8_b_ready(mmio1_bready),
      .m8_b(mmio1_b),
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
  // CDC: core-domain crossbar port to memory-domain SDRAM adapter.
  // Single-outstanding per direction matches the crossbar's slave model.
  axi_cdc_bridge u_mem_cdc (
      .clk_s(clk),
      .rst_s(rst),
      .s_ar(ram_ar),
      .s_ar_ready(ram_arready),
      .s_r(ram_r),
      .s_r_ready(ram_rready),
      .s_aw(ram_aw),
      .s_aw_ready(ram_awready),
      .s_w(ram_w),
      .s_w_ready(ram_wready),
      .s_b(ram_b),
      .s_b_ready(ram_bready),
      .clk_f(clk_mem),
      .rst_f(rst_mem),
      .m_ar(mem_ram_ar),
      .m_ar_ready(mem_ram_arready),
      .m_r(mem_ram_r),
      .m_r_ready(mem_ram_rready),
      .m_aw(mem_ram_aw),
      .m_aw_ready(mem_ram_awready),
      .m_w(mem_ram_w),
      .m_w_ready(mem_ram_wready),
      .m_b(mem_ram_b),
      .m_b_ready(mem_ram_bready)
  );
  // Synchronize memory-domain readiness back into the core clock.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      c_ready_sync0 <= 1'b0;
      c_ready_sync1 <= 1'b0;
      init_done_sync0 <= 1'b0;
      init_done_sync1 <= 1'b0;
    end else begin
      c_ready_sync0 <= c_ready;
      c_ready_sync1 <= c_ready_sync0;
      init_done_sync0 <= sdram_init_done;
      init_done_sync1 <= init_done_sync0;
    end
  end
  assign c_ready_synced = c_ready_sync1;
  assign init_done_synced = init_done_sync1;
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
      .clk(clk_mem),
      .rst(rst_mem),
      .ar(mem_ram_ar),
      .ar_ready(mem_ram_arready),
      .r(mem_ram_r),
      .r_ready(mem_ram_rready),
      .aw(mem_ram_aw),
      .aw_ready(mem_ram_awready),
      .w(mem_ram_w),
      .w_ready(mem_ram_wready),
      .b(mem_ram_b),
      .b_ready(mem_ram_bready),
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
  // Runs in the memory clock domain behind the CDC bridge.
  sdram_ctrl #(
      .CLK_HZ(MEM_CLK_HZ),
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
      .clk(clk_mem),
      .rst(rst_mem),
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
  assign sdram_clk = clk_mem;

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
      .irq_timer0(irq_timer0),
      .irq_timer1(irq_timer1),
      .irq_software0(irq_software0),
      .irq_software1(irq_software1),
      // Either hart retiring an MMIO access takes the system effect.
      .mmio_commit1(dmem1_req && dmem1_valid && !dmem1_in_sdram && mmio1_done),
      .ic_hit(ic0_hit || ic1_hit),
      .ic_miss(ic0_miss || ic1_miss),
      .dc_hit(dc0_hit || dc1_hit),
      .dc_miss(dc0_miss || dc1_miss),
      .boot_status({init_done_synced, boot_error, boot_busy, boot_done_eff}),
      .boot_addr(boot_addr),
      // dmem0_req is level-held through stalls: commit the system effect
      // only once the MMIO transfer actually completes (the retire cycle).
      .mmio_commit(dmem0_req && dmem0_valid && !dmem0_in_sdram && mmio0_done),
      .boot_restart(boot_restart),
      .hart1_boot_addr(hart1_boot_addr),
      .hart1_release(hart1_release),
      .halted(halted),
      .exit_code(exit_code)
  );

  // The response-valid flop publishes this payload one cycle after the
  // request. Capturing unconditionally keeps late fetch/MMU qualification
  // off the address register enables; invalid responses are ignored.
  always_ff @(posedge clk) begin
    i0_unc_rsp_addr <= imem0_addr;
    imem0_rsp_in_sdram <= imem0_in_sdram;
  end
  assign i0_unc_rsp_data = 32'd0;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) i0_unc_rsp <= 1'b0;
    else i0_unc_rsp <= i0_unc_req;
  end

  // ------------------------------------------- FENCE.I/SFENCE sequence
  // FENCE.I must make prior stores visible to the instruction stream, so
  // write back both D-caches, invalidate both I-caches, then release the
  // stalled FENCE.I instruction. The requesting core holds IF/ID/EX until
  // its fence_done; the other hart keeps running (software must synchronize
  // racing stores). SFENCE.VMA rides the same window and additionally
  // flushes both TLBs via the remote_tlb_flush broadcast below.
  localparam logic [1:0] F_IDLE   = 2'd0;
  localparam logic [1:0] F_DCACHE = 2'd1;
  localparam logic [1:0] F_DRAIN  = 2'd2;
  localparam logic [1:0] F_ICACHE = 2'd3;

  // TLB shootdown: the non-requesting hart flushes its MMU while either
  // fence is in flight. Idempotent for the requesting hart (already
  // flushing through its own mmu_flush).
  assign remote_tlb_flush0 = (fence_state != F_IDLE) && fence_owner == 1'b1;
  assign remote_tlb_flush1 = (fence_state != F_IDLE) && fence_owner == 1'b0;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      fence_state <= F_IDLE;
      fence_owner <= 1'b0;
      dcache_flush <= 1'b0;
      icache_flush <= 1'b0;
      fence_done0 <= 1'b0;
      fence_done1 <= 1'b0;
      boot_cache_maintenance <= 1'b0;
    end else begin
      icache_flush <= 1'b0;
      if (boot_restart && !BOOT_OVERRIDE) begin
        boot_cache_maintenance <= 1'b1;
        dcache_flush <= 1'b1;
        fence_done0 <= 1'b0;
        fence_done1 <= 1'b0;
        fence_state <= F_DCACHE;
      end else
        case (fence_state)
          F_IDLE: begin
            fence_done0 <= 1'b0;
            fence_done1 <= 1'b0;
            if (core0_fence_req || core1_fence_req) begin
              // Hart0 wins ties; the loser stays asserted and is served next.
              fence_owner <= core0_fence_req ? 1'b0 : 1'b1;
              dcache_flush <= 1'b1;
              fence_state <= F_DCACHE;
            end
          end
          F_DCACHE: begin
            if (dcache_flush_done0 && dcache_flush_done1) begin
              dcache_flush <= 1'b0;
              fence_state <= F_DRAIN;
            end
          end
          F_DRAIN: begin
            if (c_ready_synced) begin
              icache_flush <= 1'b1;
              fence_state <= F_ICACHE;
            end
          end
          F_ICACHE: begin
            if (fence_owner == 1'b0) fence_done0 <= 1'b1;
            else fence_done1 <= 1'b1;
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
  assign imem0_rsp_valid = imem0_rsp_in_sdram ? ic0_cpu_rsp : i0_unc_rsp;
  assign imem0_rsp_addr = imem0_rsp_in_sdram ? ic0_cpu_rsp_addr : i0_unc_rsp_addr;
  assign imem0_rsp_data = imem0_rsp_in_sdram ? ic0_cpu_rsp_data : i0_unc_rsp_data;
  assign dmem0_rsp_data = dmem0_in_sdram ? dc0_cm_rdata : mmio0_rsp_data;
  // Only cached reads use immediate MEM-to-EX forwarding. Uncached
  // dependencies wait for WB, keeping peripheral decode off the early bus.
  assign dmem0_forward_data = dc0_forward_data;

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
