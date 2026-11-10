// roco board top level.
//
// 24 MHz reference on ball A4 -> EHXPLLL -> 48 MHz system clock.
// The SoC drives the 16-bit SDRAM, the FT2232H UART, the four user LEDs
// and samples the two user buttons. app_reset_n is the active-low board
// reset; an unsynchronized release is filtered into the 48 MHz domain.
//
// The SDRAM clock is the system clock routed to ball C13. Its
// clock-to-pin delay and the board skew must be checked against the
// IS42S16160J timing at 48 MHz; the clock is not phase shifted.

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
  inout logic [15:0] sdram_dq
);

  logic clk_48;
  logic clk_fb;
  logic pll_locked;

  EHXPLLL #(
      .CLKI_DIV(1),
      .CLKFB_DIV(2),
      .CLKOP_DIV(12),
      .CLKOP_ENABLE("ENABLED"),
      .CLKOP_CPHASE(0),
      .CLKOP_FPHASE(0),
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
      .ENCLKOS(1'b0),
      .ENCLKOS2(1'b0),
      .ENCLKOS3(1'b0),
      .CLKOP(clk_48),
      .CLKOS(),
      .CLKOS2(),
      .CLKOS3(),
      .LOCK(pll_locked),
      .INTLOCK(),
      .REFCLK(),
      .CLKINTFB()
  );

  assign clk_fb = clk_48;

  logic [2:0] rst_sync;
  logic [1:0] btn_meta;
  logic [1:0] btn_sync;

  always_ff @(posedge clk_48) begin
    rst_sync <= {rst_sync[1:0], (app_reset_n && pll_locked)};
    btn_meta <= ~user_button_n;
    btn_sync <= btn_meta;
  end

  logic rst_48;
  assign rst_48 = !rst_sync[2];

  logic [3:0] soc_leds;
  logic soc_halted;
  logic [31:0] soc_exit_code;
  logic [15:0] sdram_dq_out;
  logic sdram_dq_oe;
  logic [15:0] sdram_dq_in;

  roco_soc #(
      .CLK_HZ(48_000_000),
      .BAUD(115200),
      .BOOT_OVERRIDE(1'b0),
      .ICACHE_LINES(128),
      .DCACHE_LINES(256)
  ) u_soc (
      .clk(clk_48),
      .rst(rst_48),
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
      .exit_code(soc_exit_code)
  );

  assign sdram_dq = sdram_dq_oe ? sdram_dq_out : 16'hzzzz;
  assign sdram_dq_in = sdram_dq;

  // A halted program shows 1xxx on the LEDs: the high bit marks halt and
  // the low three bits are the exit code (001 for the usual PASS value).
  assign user_led = soc_halted ? {1'b1, soc_exit_code[2:0]} : soc_leds;

endmodule
