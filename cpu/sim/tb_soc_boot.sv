// SoC boot-over-UART testbench.
//
// The SDRAM starts empty. After the controller finishes initialisation,
// the packet file (produced by scripts/boot.py --emit-hex) is shifted
// into the UART pin at the configured baud rate. The bootloader must
// reply 'K', release the CPU, and the loaded program must halt through
// the tohost register.

`timescale 1ns / 1ps

module tb_soc_boot;

  localparam int CLK_HZ = 48_000_000;
  localparam int BAUD = 1_000_000;
  localparam int DIV = CLK_HZ / BAUD;

  logic clk;
  logic rst;
  logic [1:0] buttons;
  logic [3:0] leds;
  logic uart_rx;
  logic uart_tx;

  logic [12:0] sdram_a;
  logic [1:0] sdram_ba;
  logic [1:0] sdram_dqm;
  logic sdram_cs_n;
  logic sdram_ras_n;
  logic sdram_cas_n;
  logic sdram_we_n;
  logic sdram_cke;
  logic sdram_clk;
  logic [15:0] sdram_dq_out;
  logic sdram_dq_oe;
  logic [15:0] sdram_dq_in;
  logic [15:0] model_dq_out;
  logic model_dq_oe;
  logic [15:0] dq_bus;
  logic [31:0] sdram_errors;

  logic halted;
  logic [31:0] exit_code;

  logic [7:0] packet[0:65535];
  logic [7:0] rx_byte;
  integer packet_len;
  integer fd;
  integer scan_ret;
  integer bit_idx;
  integer i;
  integer guard;
  int unsigned cycles;
  int unsigned max_cycles;
  string packet_file;

  logic trace_on;
  initial trace_on = $test$plusargs("trace");

  always_ff @(posedge clk) begin
    if (trace_on && u_soc.u_cpu.trace_valid) begin
      $display("  retire pc=%08x instr=%08x rd=%0d data=%08x", u_soc.u_cpu.trace_pc,
               u_soc.u_cpu.trace_instr, u_soc.u_cpu.trace_rd, u_soc.u_cpu.trace_wdata);
    end
  end

  int unsigned dbg_cycles;
  initial dbg_cycles = 0;
  always_ff @(posedge clk) begin
    dbg_cycles <= dbg_cycles + 1;
    if (trace_on && (dbg_cycles % 2000 == 0)) begin
      $display("  dbg rst=%b boot=%b rel=%b pc=%08x ireq=%b icst=%0d lock=%b own=%0d cst=%0d",
               u_soc.core_rst, u_soc.boot_done, u_soc.boot_release, u_soc.u_cpu.u_if.pc_if,
               u_soc.u_cpu.imem_req, u_soc.u_icache.state, u_soc.u_arbiter.locked,
               u_soc.u_arbiter.owner, u_soc.u_sdram.state);
    end
  end

  assign dq_bus = sdram_dq_oe ? sdram_dq_out : (model_dq_oe ? model_dq_out : 16'hzzzz);
  assign sdram_dq_in = dq_bus;

  roco_soc #(
      .CLK_HZ(CLK_HZ),
      .BAUD(BAUD),
      .BOOT_OVERRIDE(1'b0)
  ) u_soc (
      .clk(clk),
      .rst(rst),
      .buttons(buttons),
      .leds(leds),
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
      .halted(halted),
      .exit_code(exit_code)
  );

  sdram_model #(
      .CL(3)
  ) u_sdram (
      .clk(clk),
      .cke(sdram_cke),
      .cs_n(sdram_cs_n),
      .ras_n(sdram_ras_n),
      .cas_n(sdram_cas_n),
      .we_n(sdram_we_n),
      .a(sdram_a),
      .ba(sdram_ba),
      .dqm(sdram_dqm),
      .dq_in(dq_bus),
      .dq_out(model_dq_out),
      .dq_oe(model_dq_oe),
      .errors(sdram_errors)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  task automatic send_byte(input logic [7:0] value);
    integer b;
    begin
      uart_rx = 1'b0;
      repeat (DIV) @(posedge clk);
      for (b = 0; b < 8; b = b + 1) begin
        uart_rx = value[b];
        repeat (DIV) @(posedge clk);
      end
      uart_rx = 1'b1;
      repeat (DIV) @(posedge clk);
    end
  endtask

  initial begin
    if (!$value$plusargs("packet=%s", packet_file)) begin
      $display("tb_soc_boot: no +packet file");
      $finish;
    end
    fd = $fopen(packet_file, "r");
    if (fd == 0) begin
      $display("tb_soc_boot: cannot open %s", packet_file);
      $finish;
    end
    packet_len = 0;
    scan_ret = $fscanf(fd, "%h\n", rx_byte);
    while (scan_ret == 1) begin
      packet[packet_len] = rx_byte;
      packet_len = packet_len + 1;
      scan_ret = $fscanf(fd, "%h\n", rx_byte);
    end
    $fclose(fd);
    if (packet_len == 0) begin
      $display("tb_soc_boot: empty packet file");
      $finish;
    end
    $display("tb_soc_boot: %0d packet bytes", packet_len);
    if (!$value$plusargs("max_cycles=%d", max_cycles)) begin
      max_cycles = 6_000_000;
    end
    cycles = 0;
    buttons = 2'b11;
    uart_rx = 1'b1;
    rst = 1'b1;
    repeat (10) @(posedge clk);
    rst = 1'b0;

    // Wait for the SDRAM controller and the bootloader.
    guard = 0;
    while (!u_soc.sdram_init_done && guard < 40000) begin
      @(posedge clk);
      guard = guard + 1;
    end
    if (!u_soc.sdram_init_done) begin
      $display("tb_soc_boot: SDRAM init timeout");
      $finish;
    end
    repeat (10) @(posedge clk);

    for (i = 0; i < packet_len; i = i + 1) begin
      send_byte(packet[i]);
    end
    $display("tb_soc_boot: packet sent");

    guard = 0;
    while (!u_soc.boot_done && guard < 200000) begin
      @(posedge clk);
      guard = guard + 1;
    end
    if (!u_soc.boot_done) begin
      $display("tb_soc_boot: bootloader did not accept the image");
      $finish;
    end
    $display("tb_soc_boot: bootloader accepted image at %0t", $time);
  end

  // UART monitor on the transmit pin.
  initial begin
    forever begin
      @(negedge uart_tx);
      repeat (DIV + DIV / 2) @(posedge clk);
      for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
        rx_byte[bit_idx] = uart_tx;
        repeat (DIV) @(posedge clk);
      end
      $write("%c", rx_byte);
      $fflush();
    end
  end

  always_ff @(posedge clk) begin
    if (!rst && !halted) begin
      cycles <= cycles + 1;
      if (cycles > max_cycles) begin
        $display("tb_soc_boot: TIMEOUT after %0d cycles", max_cycles);
        $finish;
      end
    end
  end

  always @(posedge clk) begin
    if (!rst && halted) begin
      repeat (5000) @(posedge clk);
      if (exit_code == 32'd1) begin
        $display("tb_soc_boot: PASS (%0d sdram errors)", sdram_errors);
      end else begin
        $display("tb_soc_boot: FAIL code=%0d (%0d sdram errors)", exit_code, sdram_errors);
      end
      $finish;
    end
  end

endmodule
