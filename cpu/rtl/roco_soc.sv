// roco system-on-chip.
//
// RV32I core + I/D caches + SDRAM controller + UART + bootloader +
// memory-mapped timer, LEDs, buttons, cache counters and boot status.
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

`default_nettype none

module roco_soc #(
    parameter int CLK_HZ = 48_000_000,
    parameter int BAUD = 115200,
    parameter bit BOOT_OVERRIDE = 1'b0,
    parameter int ICACHE_LINES = 128,
    parameter int DCACHE_LINES = 256
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
  output logic [31:0] exit_code
);

  // ------------------------------------------------------------- Core buses
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
  logic core_fence_req;
  logic fence_done;
  logic dcache_flush;
  logic dcache_flush_done;
  logic icache_flush;
  logic [1:0] fence_state;

  logic imem_in_sdram;
  logic dmem_in_sdram;
  logic i_unc_req;
  logic d_unc_req;
  logic i_unc_rsp;
  logic d_unc_rsp;
  logic [31:0] i_unc_rsp_addr;
  logic [31:0] i_unc_rsp_data;
  logic [31:0] d_unc_rsp_addr;
  logic [31:0] d_unc_rsp_data;

  // ----------------------------------------------------------- Cache ports
  logic ic_cpu_rsp;
  logic [31:0] ic_cpu_rsp_addr;
  logic [31:0] ic_cpu_rsp_data;
  logic ic_mem_req;
  logic ic_mem_we;
  logic [22:0] ic_mem_word_addr;
  logic [3:0] ic_mem_len;
  logic ic_mem_ready;
  logic ic_mem_wvalid;
  logic ic_mem_wready;
  logic [31:0] ic_mem_wdata;
  logic [3:0] ic_mem_wbe;
  logic ic_mem_rvalid;
  logic [31:0] ic_mem_rdata;
  logic ic_mem_rlast;
  logic ic_hit;
  logic ic_miss;
  logic ic_cpu_miss;
  logic ic_cpu_busy;
  logic imem_miss;
  logic imem_busy;

  logic dc_cpu_rsp;
  logic [31:0] dc_cpu_rsp_addr;
  logic [31:0] dc_cpu_rsp_data;
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
  assign imem_miss = imem_in_sdram ? ic_cpu_miss : 1'b0;
  assign imem_busy = imem_in_sdram ? ic_cpu_busy : 1'b0;
  assign dmem_in_sdram = (dmem_addr[31:25] == 7'd8);
  assign i_unc_req = imem_req && !imem_in_sdram;
  assign d_unc_req = dmem_req && !dmem_in_sdram;

  assign boot_done_eff = BOOT_OVERRIDE ? 1'b1 : boot_done;
  // Hold the core in reset for one extra cycle after boot_done so that
  // pc_if samples the image base address, not the pre-boot zero value.
  always_ff @(posedge clk) begin
    if (rst) begin
      boot_release <= 1'b0;
    end else begin
      boot_release <= boot_done_eff;
    end
  end
  assign core_rst = rst || !boot_release;

  // ---------------------------------------------------------------- CPU
  rv32_core u_cpu (
      .clk(clk),
      .rst(core_rst),
      .boot_addr(BOOT_OVERRIDE ? 32'h1000_0000 : boot_addr),
      .halt(halted),
      .imem_req(imem_req),
      .imem_addr(imem_addr),
      .imem_rsp_valid(imem_rsp_valid),
      .imem_rsp_addr(imem_rsp_addr),
      .imem_rsp_data(imem_rsp_data),
      .imem_miss(imem_miss),
      .imem_busy(imem_busy),
      .dmem_req(dmem_req),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_be(dmem_be),
      .dmem_rsp_valid(dmem_rsp_valid),
      .dmem_rsp_addr(dmem_rsp_addr),
      .dmem_rsp_data(dmem_rsp_data),
      .fence_req(core_fence_req),
      .fence_done(fence_done)
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
      .mem_we(ic_mem_we),
      .mem_word_addr(ic_mem_word_addr),
      .mem_len(ic_mem_len),
      .mem_ready(ic_mem_ready),
      .mem_wvalid(ic_mem_wvalid),
      .mem_wready(ic_mem_wready),
      .mem_wdata(ic_mem_wdata),
      .mem_wbe(ic_mem_wbe),
      .mem_rvalid(ic_mem_rvalid),
      .mem_rdata(ic_mem_rdata),
      .mem_rlast(ic_mem_rlast),
      .hit_pulse(ic_hit),
      .miss_pulse(ic_miss)
  );

  // -------------------------------------------------------------- D-cache
  dcache #(
      .LINE_WORDS(4),
      .NUM_LINES(DCACHE_LINES)
  ) u_dcache (
      .clk(clk),
      .rst(rst),
      .flush(dcache_flush),
      .flush_done(dcache_flush_done),
      .cpu_req(dmem_req && dmem_in_sdram),
      .cpu_we(dmem_we),
      .cpu_addr(dmem_addr),
      .cpu_wdata(dmem_wdata),
      .cpu_be(dmem_be),
      .cpu_rsp(dc_cpu_rsp),
      .cpu_rsp_addr(dc_cpu_rsp_addr),
      .cpu_rsp_data(dc_cpu_rsp_data),
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

  // ------------------------------------------------------------- Arbiter
  mem_arbiter u_arbiter (
      .clk(clk),
      .rst(rst),
      .i_req(ic_mem_req),
      .i_we(ic_mem_we),
      .i_word_addr(ic_mem_word_addr),
      .i_len(ic_mem_len),
      .i_ready(ic_mem_ready),
      .i_wready(ic_mem_wready),
      .i_wvalid(ic_mem_wvalid),
      .i_wdata(ic_mem_wdata),
      .i_wbe(ic_mem_wbe),
      .i_rvalid(ic_mem_rvalid),
      .i_rdata(ic_mem_rdata),
      .i_rlast(ic_mem_rlast),
      .d_req(dc_mem_req),
      .d_we(dc_mem_we),
      .d_word_addr(dc_mem_word_addr),
      .d_len(dc_mem_len),
      .d_ready(dc_mem_ready),
      .d_wready(dc_mem_wready),
      .d_wvalid(dc_mem_wvalid),
      .d_wdata(dc_mem_wdata),
      .d_wbe(dc_mem_wbe),
      .d_rvalid(dc_mem_rvalid),
      .d_rdata(dc_mem_rdata),
      .d_rlast(dc_mem_rlast),
      .b_req(boot_mem_req),
      .b_we(1'b1),
      .b_word_addr(boot_mem_word_addr),
      .b_len(4'd0),
      .b_ready(boot_mem_ready),
      .b_wready(boot_mem_wready),
      .b_wvalid(boot_mem_wvalid),
      .b_wdata(boot_mem_wdata),
      .b_wbe(boot_mem_wbe),
      .b_rvalid(),
      .b_rdata(),
      .b_rlast(),
      .c_req(c_req),
      .c_ready(c_ready),
      .c_we(c_we),
      .c_word_addr(c_word_addr),
      .c_len(c_len),
      .c_wready(c_wready),
      .c_wvalid(c_wvalid),
      .c_wdata(c_wdata),
      .c_wbe(c_wbe),
      .c_rvalid(c_rvalid),
      .c_rdata(c_rdata),
      .c_rlast(c_rlast)
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
  assign uart_rx_clear = d_unc_req && !dmem_we && (dmem_addr[15:0] == 16'h0004);

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
  assign mmio_tx_push = d_unc_req && dmem_we && (dmem_addr[15:0] == 16'h0000);
  assign mmio_tx_byte = dmem_wdata[7:0];
  assign mmio_rx_pop = d_unc_req && !dmem_we && (dmem_addr[15:0] == 16'h0000) && uart_rx_valid;
  assign boot_restart = d_unc_req && dmem_we && (dmem_addr[15:0] == 16'h0108);

  always_comb begin
    mmio_rdata = 32'd0;
    case (dmem_addr[15:0])
      16'h0000: begin
        mmio_rdata = {24'd0, uart_rx_data};
      end
      16'h0004: begin
        mmio_rdata = {28'd0, uart_rx_overflow, 1'b0, uart_rx_valid, uart_tx_ready};
      end
      16'h0010: begin
        mmio_rdata = {28'd0, led_reg};
      end
      16'h0014: begin
        mmio_rdata = {30'd0, buttons};
      end
      16'h0018: begin
        mmio_rdata = mtime[31:0];
      end
      16'h001c: begin
        mmio_rdata = mtime[63:32];
      end
      16'h0020: begin
        mmio_rdata = mtimecmp[31:0];
      end
      16'h0024: begin
        mmio_rdata = mtimecmp[63:32];
      end
      16'h0028: begin
        mmio_rdata = {31'd0, (mtime >= mtimecmp)};
      end
      16'h0030: begin
        mmio_rdata = ic_hits;
      end
      16'h0034: begin
        mmio_rdata = ic_misses;
      end
      16'h0038: begin
        mmio_rdata = dc_hits;
      end
      16'h003c: begin
        mmio_rdata = dc_misses;
      end
      16'h0100: begin
        mmio_rdata = {28'd0, sdram_init_done, boot_error, boot_busy, boot_done_eff};
      end
      16'h0104: begin
        mmio_rdata = boot_addr;
      end
      16'h1000: begin
        mmio_rdata = exit_code;
      end
      default: begin
        mmio_rdata = 32'd0;
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      i_unc_rsp <= 1'b0;
      d_unc_rsp <= 1'b0;
      i_unc_rsp_addr <= '0;
      i_unc_rsp_data <= '0;
      d_unc_rsp_addr <= '0;
      d_unc_rsp_data <= '0;
      led_reg <= 4'd0;
      mtime <= '0;
      mtimecmp <= '0;
      ic_hits <= '0;
      ic_misses <= '0;
      dc_hits <= '0;
      dc_misses <= '0;
      halted <= 1'b0;
      exit_code <= '0;
    end else begin
      i_unc_rsp <= i_unc_req;
      d_unc_rsp <= d_unc_req;
      if (i_unc_req) begin
        i_unc_rsp_addr <= imem_addr;
        i_unc_rsp_data <= 32'h0000_0000;
      end
      if (d_unc_req) begin
        d_unc_rsp_addr <= dmem_addr;
        d_unc_rsp_data <= mmio_rdata;
        if (dmem_we) begin
          case (dmem_addr[15:0])
            16'h0010: begin
              led_reg <= dmem_wdata[3:0];
            end
            16'h0020: begin
              mtimecmp[31:0] <= dmem_wdata;
            end
            16'h0024: begin
              mtimecmp[63:32] <= dmem_wdata;
            end
            16'h0030: begin
              ic_hits <= '0;
              ic_misses <= '0;
              dc_hits <= '0;
              dc_misses <= '0;
            end
            16'h0108: begin
              halted <= 1'b0;
              exit_code <= '0;
            end
            16'h1000: begin
              halted <= 1'b1;
              exit_code <= dmem_wdata;
            end
            default: begin
            end
          endcase
        end
      end
      mtime <= mtime + 64'd1;
      if (ic_hit) begin
        ic_hits <= ic_hits + 32'd1;
      end
      if (ic_miss) begin
        ic_misses <= ic_misses + 32'd1;
      end
      if (dc_hit) begin
        dc_hits <= dc_hits + 32'd1;
      end
      if (dc_miss) begin
        dc_misses <= dc_misses + 32'd1;
      end
    end
  end

  // ------------------------------------------------------ FENCE.I sequence
  // FENCE.I must make prior stores visible to the instruction stream, so
  // write back the whole D-cache, invalidate the I-cache, then release the
  // stalled FENCE.I instruction. The core holds IF/ID/EX until fence_done.
  localparam logic [1:0] F_IDLE   = 2'd0;
  localparam logic [1:0] F_DCACHE = 2'd1;
  localparam logic [1:0] F_ICACHE = 2'd2;
  localparam logic [1:0] F_DONE   = 2'd3;

  always_ff @(posedge clk) begin
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
          end
        end
        F_DCACHE: begin
          if (dcache_flush_done) begin
            dcache_flush <= 1'b0;
            icache_flush <= 1'b1;
            fence_state <= F_ICACHE;
          end
        end
        F_ICACHE: begin
          fence_done <= 1'b1;
          fence_state <= F_DONE;
        end
        F_DONE: begin
          if (!core_fence_req) begin
            fence_done <= 1'b0;
            fence_state <= F_IDLE;
          end
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
  assign dmem_rsp_valid = dmem_in_sdram ? dc_cpu_rsp : d_unc_rsp;
  assign dmem_rsp_addr = dmem_in_sdram ? dc_cpu_rsp_addr : d_unc_rsp_addr;
  assign dmem_rsp_data = dmem_in_sdram ? dc_cpu_rsp_data : d_unc_rsp_data;

  assign leds = led_reg;

endmodule
