// roco board top level.
//
// 24 MHz reference on ball A4 -> EHXPLLL -> 96 MHz SDRAM clock (CLKOP) and
// a phase-aligned 48 MHz core clock (CLKOS, CLKOS_DIV = 2 x CLKOP_DIV).
// The SoC drives the 16-bit SDRAM, the FT2232H UART, the four user LEDs
// and samples the two user buttons. app_reset_n is the active-low board
// reset; an unsynchronized release is filtered into each clock domain.
//
// The SDRAM clock is the 96 MHz output routed to ball C13. Its
// clock-to-pin delay and the board skew must be checked against the
// IS42S16160J timing at 96 MHz; the clock is not phase shifted.

`default_nettype none

module roco_top (
  input logic clk_24,
  input logic app_reset_n,
  input logic [1:0] user_button_n,
  input logic uart_rx,
  output logic uart_tx,
  output logic [3:0] user_led,
  output logic [12:0] sdram_a,
  output logic [1:0] sdram_ba,
  output logic [1:0] sdram_dqm,
  output logic sdram_cs_n,
  output logic sdram_ras_n,
  output logic sdram_cas_n,
  output logic sdram_we_n,
  output logic sdram_cke,
  output logic sdram_clk,
  inout wire [15:0] sdram_dq
);

  localparam int CORE_CLK_HZ = 48_000_000;
  localparam int MEM_CLK_HZ  = 96_000_000;

  logic clk_core;
  logic clk_mem;
  logic clk_fb;
  logic pll_locked;
  logic unused_clk_os2;
  logic unused_clk_os3;
  logic unused_pll_intlock;
  logic unused_pll_refclk;
  logic unused_pll_clkintfb;

  EHXPLLL #(
      .CLKI_DIV(1),
      .CLKFB_DIV(4),
      .CLKOP_DIV(6),
      .CLKOP_ENABLE("ENABLED"),
      .CLKOP_CPHASE(0),
      .CLKOP_FPHASE(0),
      .CLKOS_DIV(12),
      .CLKOS_ENABLE("ENABLED"),
      .CLKOS_CPHASE(0),
      .CLKOS_FPHASE(0),
      .FEEDBK_PATH("CLKOP"),
      .OUTDIVIDER_MUXA("DIVA"),
      .OUTDIVIDER_MUXB("DIVB"),
      .OUTDIVIDER_MUXC("DIVC"),
      .OUTDIVIDER_MUXD("DIVD"),
      .PLLRST_ENA("DISABLED"),
      .STDBY_ENABLE("DISABLED"),
      .DPHASE_SOURCE("DISABLED"),
      .INTFB_WAKE("DISABLED"),
      .REFIN_RESET("DISABLED"),
      .SYNC_ENABLE("DISABLED"),
      .PLL_LOCK_MODE(0),
      .PLL_LOCK_DELAY(200)
  ) u_pll (
      .CLKI(clk_24),
      .CLKFB(clk_fb),
      .RST(1'b0),
      .STDBY(1'b0),
      .PHASESEL0(1'b0),
      .PHASESEL1(1'b0),
      .PHASEDIR(1'b0),
      .PHASESTEP(1'b0),
      .PHASELOADREG(1'b0),
      .PLLWAKESYNC(1'b0),
      .ENCLKOP(1'b1),
      .ENCLKOS(1'b1),
      .ENCLKOS2(1'b0),
      .ENCLKOS3(1'b0),
      .CLKOP(clk_mem),
      .CLKOS(clk_core),
      .CLKOS2(unused_clk_os2),
      .CLKOS3(unused_clk_os3),
      .LOCK(pll_locked),
      .INTLOCK(unused_pll_intlock),
      .REFCLK(unused_pll_refclk),
      .CLKINTFB(unused_pll_clkintfb)
  );

  assign clk_fb = clk_mem;

  logic [2:0] rst_core_sync, rst_mem_sync;
  logic [1:0] btn_meta;
  logic [1:0] btn_sync;

  always_ff @(posedge clk_core) begin
    rst_core_sync <= {rst_core_sync[1:0], (app_reset_n && pll_locked)};
    btn_meta <= ~user_button_n;
    btn_sync <= btn_meta;
  end

  always_ff @(posedge clk_mem) begin
    rst_mem_sync <= {rst_mem_sync[1:0], (app_reset_n && pll_locked)};
  end

  logic rst_core, rst_mem;
  assign rst_core = !rst_core_sync[2];
  assign rst_mem = !rst_mem_sync[2];

  logic [3:0] soc_leds;
  logic soc_halted;
  logic [2:0] soc_exit_code;
  logic [31:3] unused_exit_code;
  logic unused_trace_valid;
  logic [31:0] unused_trace_pc;
  logic [31:0] unused_trace_instr;
  logic [4:0] unused_trace_rd;
  logic [31:0] unused_trace_wdata;
  logic unused_trace1_valid;
  logic [31:0] unused_trace1_pc;
  logic [31:0] unused_trace1_instr;
  logic [4:0] unused_trace1_rd;
  logic [31:0] unused_trace1_wdata;
  logic [15:0] sdram_dq_out;
  logic sdram_dq_oe;
  logic [15:0] sdram_dq_in;

  roco_soc #(
      .CLK_HZ(CORE_CLK_HZ),
      .MEM_CLK_HZ(MEM_CLK_HZ),
      .BAUD(115200),
      .BOOT_OVERRIDE(1'b0),
      // The 85F fits full-size caches for both harts: 2 KiB I$ and
      // 4 KiB D$ per hart. The hub and coherence protocol are
      // geometry-agnostic (see docs/bus.md).
      .ICACHE_LINES(128),
      .DCACHE_LINES(128)
  ) u_soc (
      .clk(clk_core),
      .rst(rst_core),
      .clk_mem(clk_mem),
      .rst_mem(rst_mem),
      .buttons(btn_sync),
      .leds(soc_leds),
      .uart_rx(uart_rx),
      .uart_tx(uart_tx),
      .sdram_a(sdram_a),
      .sdram_ba(sdram_ba),
      .sdram_dqm(sdram_dqm),
      .sdram_cs_n(sdram_cs_n),
      .sdram_ras_n(sdram_ras_n),
      .sdram_cas_n(sdram_cas_n),
      .sdram_we_n(sdram_we_n),
      .sdram_cke(sdram_cke),
      .sdram_clk(sdram_clk),
      .sdram_dq_out(sdram_dq_out),
      .sdram_dq_oe(sdram_dq_oe),
      .sdram_dq_in(sdram_dq_in),
      .halted(soc_halted),
      .exit_code({unused_exit_code, soc_exit_code}),
      .trace0_valid(unused_trace_valid),
      .trace0_pc(unused_trace_pc),
      .trace0_instr(unused_trace_instr),
      .trace0_rd(unused_trace_rd),
      .trace0_wdata(unused_trace_wdata),
      .trace1_valid(unused_trace1_valid),
      .trace1_pc(unused_trace1_pc),
      .trace1_instr(unused_trace1_instr),
      .trace1_rd(unused_trace1_rd),
      .trace1_wdata(unused_trace1_wdata)
  );

  assign sdram_dq = sdram_dq_oe ? sdram_dq_out : 16'hzzzz;
  assign sdram_dq_in = sdram_dq;

  // A halted program shows 1xxx on the LEDs: the high bit marks halt and
  // the low three bits are the exit code (001 for the usual PASS value).
  assign user_led = soc_halted ? {1'b1, soc_exit_code} : soc_leds;

endmodule
