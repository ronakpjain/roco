// SoC testbench with caches, SDRAM model and UART.
//
// The image is preloaded into the SDRAM model through a backdoor task
// (BOOT_OVERRIDE=1), so this testbench exercises the caches, arbiter and
// SDRAM controller without the UART bootloader. UART transmit bytes are
// decoded and printed; writing tohost halts the core and reports the
// exit code.

`timescale 1ns / 1ps

module tb_soc;

  localparam int CLK_HZ = 48_000_000;
  localparam int BAUD = 1_000_000;
  localparam int DIV = CLK_HZ / BAUD;
  localparam int IMAGE_WORDS = 4096;

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

  logic [31:0] image[0:IMAGE_WORDS-1];
  string hexfile;
  integer hex_fd;
  integer hex_matched;
  int unsigned i;
  int unsigned cycles;
  int unsigned max_cycles;
  logic [7:0] rx_byte;
  integer bit_idx;

  logic trace_on;
  int unsigned push_cnt = 0;
  int unsigned start_cnt = 0;
  int unsigned full_push_cnt = 0;
  logic [7:0] expected_tx[0:65535];
  int unsigned received_cnt = 0;
  logic tx_busy_q = 0;
  integer dbg_cnt2 = 0;
  initial trace_on = $test$plusargs("trace");

  always @(posedge clk) begin
    if (trace_on && u_soc.trace_valid) begin
      $display("  retire pc=%08x instr=%08x rd=%0d data=%08x", u_soc.trace_pc, u_soc.trace_instr,
               u_soc.trace_rd, u_soc.trace_wdata);
    end
    if (trace_on && u_soc.u_cpu.u_ex.idex_valid && (u_soc.u_cpu.u_ex.idex_pc == 32'h10000148) &&
        (dbg_cnt2 < 4)) begin
      dbg_cnt2 <= dbg_cnt2 + 1;
      $display("  st ex rs1=%0d rs1v=%h fwd=%h wb=%h wbv=%b wbrd=%0d exm=%b exmrd=%0d exmw=%h",
               u_soc.u_cpu.u_ex.idex_rs1, u_soc.u_cpu.u_ex.idex_rs1_val, u_soc.u_cpu.u_ex.rs1_fwd,
               u_soc.u_cpu.wb_data, u_soc.u_cpu.wb_we, u_soc.u_cpu.wb_rd,
               u_soc.u_cpu.u_ex.exmem_valid, u_soc.u_cpu.u_ex.exmem_rd,
               u_soc.u_cpu.u_ex.exmem_wbval);
    end
    if (trace_on && !u_soc.sdram_cs_n && u_soc.sdram_ras_n && !u_soc.sdram_cas_n && !u_soc.sdram_we_n) begin
      $display("  sdwr a=%h ba=%0d dq=%h", u_soc.sdram_a[8:0], u_soc.sdram_ba, u_soc.sdram_dq_out);
    end
    if (trace_on && !u_soc.sdram_cs_n && !u_soc.sdram_ras_n && u_soc.sdram_cas_n && u_soc.sdram_we_n) begin
      $display("  sdact a=%h ba=%0d cmd=%h", u_soc.sdram_a, u_soc.sdram_ba, u_soc.u_sdram.cmd_addr);
    end
    if (trace_on && u_soc.dmem_req && u_soc.dmem_we && (u_soc.dmem_addr[15:0] == 16'h0244)) begin
      $display("  store244 state=%0d dirty36=%b cmwe=%b", u_soc.u_dcache.state,
               u_soc.u_dcache.dirty_ram[36], u_soc.dmem_we);
    end
    if (trace_on && (u_soc.u_dcache.state == 8) && u_soc.u_dcache.mem_ready) begin
      $display("  flushreq idx=%0d word=%h tag=%h valid=%b dirty=%b", u_soc.u_dcache.flush_idx,
               u_soc.u_dcache.mem_word_addr, u_soc.u_dcache.tag_ram[u_soc.u_dcache.flush_idx],
               u_soc.u_dcache.valid_ram[u_soc.u_dcache.flush_idx],
               u_soc.u_dcache.dirty_ram[u_soc.u_dcache.flush_idx]);
    end
    if (trace_on && (u_soc.u_dcache.state == 10) && u_soc.u_dcache.mem_wready) begin
      $display("  flushwr idx=%0d beat=%0d data=%h", u_soc.u_dcache.flush_idx, u_soc.u_dcache.beat,
               u_soc.u_dcache.mem_wdata);
    end
    if (trace_on && u_soc.dmem_req && (u_soc.dmem_addr[31:4] == 28'h1000034)) begin
      $display(
          "  dc cm we=%b addr=%h wd=%h be=%b rdata=%h luq=%h pv=%b pa=%h pd=%h pb=%b st=%0d byp=%b",
          u_soc.dmem_we, u_soc.dmem_addr, u_soc.dmem_wdata, u_soc.dmem_be, u_soc.dmem_rsp_data,
          u_soc.u_dcache.lu_addr_q, u_soc.u_dcache.prev_store_valid,
          u_soc.u_dcache.prev_store_addr, u_soc.u_dcache.prev_store_data,
          u_soc.u_dcache.prev_store_be, u_soc.u_dcache.state, u_soc.u_dcache.bypass);
    end
    if (trace_on && u_soc.core_fence_req) begin
      $display("  fence req, state=%0d dcache_done=%b", u_soc.fence_state, u_soc.dcache_flush_done);
    end
    if (trace_on && (cycles % 100 == 0)) begin
      $display(
          "  dbg cyc=%0d pc=%08x icst=%0d dcst=%0d lock=%b own=%0d wr_rem=%0d cst=%0d dre=%b dwe=%b dwv=%b dwr=%b",
          cycles, u_soc.u_cpu.u_if.pc_if, u_soc.u_icache.state, u_soc.u_dcache.state,
          u_soc.u_arbiter.locked, u_soc.u_arbiter.owner, u_soc.u_arbiter.wr_rem,
          u_soc.u_sdram.state, u_soc.u_dcache.mem_req, u_soc.u_dcache.mem_we,
          u_soc.u_dcache.mem_wvalid, u_soc.u_dcache.mem_wready);
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      push_cnt <= 0;
      start_cnt <= 0;
      tx_busy_q <= 0;
    end else begin
      if (u_soc.mmio_tx_push) begin
        if (!u_soc.uart_tx_ready) begin
          $fatal(1, "UART write while not ready");
        end
        expected_tx[push_cnt] <= u_soc.mmio_tx_byte;
        push_cnt <= push_cnt + 1;
        if (u_soc.u_uart.tx_full) begin
          full_push_cnt <= full_push_cnt + 1;
        end
      end
      tx_busy_q <= u_soc.u_uart.tx_busy;
      if (u_soc.u_uart.tx_busy && !tx_busy_q) begin
        start_cnt <= start_cnt + 1;
      end
    end
  end

  assign dq_bus = sdram_dq_oe ? sdram_dq_out : (model_dq_oe ? model_dq_out : 16'hzzzz);
  assign sdram_dq_in = dq_bus;

  roco_soc #(
      .CLK_HZ(CLK_HZ),
      .BAUD(BAUD),
      .BOOT_OVERRIDE(1'b1)
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

  initial begin
    if (!$value$plusargs("hex=%s", hexfile)) begin
      $display("tb_soc: no +hex image");
      $finish;
    end
    for (i = 0; i < IMAGE_WORDS; i = i + 1) begin
      image[i] = 32'd0;
    end
    hex_fd = $fopen(hexfile, "r");
    if (hex_fd == 0) begin
      $display("tb_soc: cannot open %s", hexfile);
      $finish;
    end
    i = 0;
    hex_matched = 1;
    while ((hex_matched == 1) && (i < IMAGE_WORDS)) begin
      hex_matched = $fscanf(hex_fd, "%h", image[i]);
      if (hex_matched == 1) begin
        i = i + 1;
      end
    end
    $fclose(hex_fd);
    for (i = 0; i < IMAGE_WORDS; i = i + 1) begin
      u_sdram.preload(i[22:0], image[i]);
    end
    if (!$value$plusargs("max_cycles=%d", max_cycles)) begin
      max_cycles = 5_000_000;
    end
    cycles = 0;
    buttons = 2'b11;
    uart_rx = 1'b1;
    rst = 1'b1;
    repeat (10) @(posedge clk);
    rst = 1'b0;
  end

  // UART receiver on the transmit pin.
  initial begin
    forever begin
      @(negedge uart_tx);
      repeat (DIV + DIV / 2) @(posedge clk);
      for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
        rx_byte[bit_idx] = uart_tx;
        repeat (DIV) @(posedge clk);
      end
      if (uart_tx !== 1'b1) begin
        $fatal(1, "UART stop bit missing");
      end
      if (received_cnt >= push_cnt || rx_byte !== expected_tx[received_cnt]) begin
        $fatal(1, "UART byte %0d: got %02x expected %02x", received_cnt, rx_byte,
               expected_tx[received_cnt]);
      end
      received_cnt = received_cnt + 1;
      $write("%c", rx_byte);
      $fflush();
    end
  end

  always @(posedge clk) begin
    if (!rst && !halted) begin
      cycles <= cycles + 1;
      if (cycles > max_cycles) begin
        $display("tb_soc: TIMEOUT after %0d cycles", max_cycles);
        $finish;
      end
    end
  end

  always @(posedge clk) begin
    if (!rst && halted) begin
      $display("tb_soc: bench cycles=%0d instret=%0d pushes=%0d starts=%0d full=%0d", u_soc.dbg0,
               u_soc.dbg1, push_cnt, start_cnt, full_push_cnt);
      if (exit_code == 32'd1) begin
        $display("tb_soc: PASS (%0d sdram errors)", sdram_errors);
      end else begin
        $display("tb_soc: FAIL code=%0d (%0d sdram errors)", exit_code, sdram_errors);
      end
      $finish;
    end
  end

endmodule
