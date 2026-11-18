`timescale 1ns / 1ps

module tb_roco_apb_peripherals;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1;
  logic psel = 0, penable = 0, pwrite = 0, pready;
  logic [15:0] paddr = '0;
  logic [31:0] pwdata = '0, prdata;
  logic [3:0] pstrb = '0;
  logic uart_tx_ready = 0, boot_tx_valid = 0;
  logic uart_tx_push, uart_rx_pop, uart_rx_clear;
  logic [7:0] uart_tx_byte;
  logic [3:0] leds;
  logic irq_timer;
  logic ic_hit = 0;
  logic mmio_commit = 0, boot_restart, halted;
  logic [31:0] exit_code;
  int tx_pushes = 0;

  roco_apb_peripherals dut (
      .clk(clk),
      .rst(rst),
      .psel(psel),
      .penable(penable),
      .pwrite(pwrite),
      .paddr(paddr),
      .pwdata(pwdata),
      .pstrb(pstrb),
      .pready(pready),
      .prdata(prdata),
      .uart_rx_data(8'h34),
      .uart_rx_valid(1'b1),
      .uart_rx_overflow(1'b1),
      .uart_tx_ready(uart_tx_ready),
      .boot_tx_valid(boot_tx_valid),
      .uart_tx_push(uart_tx_push),
      .uart_rx_pop(uart_rx_pop),
      .uart_rx_clear(uart_rx_clear),
      .uart_tx_byte(uart_tx_byte),
      .buttons(2'b10),
      .leds(leds),
      .irq_timer(irq_timer),
      .ic_hit(ic_hit),
      .ic_miss(1'b0),
      .dc_hit(1'b0),
      .dc_miss(1'b0),
      .boot_status(4'h9),
      .boot_addr(32'h1000_0040),
      .mmio_commit(mmio_commit),
      .boot_restart(boot_restart),
      .halted(halted),
      .exit_code(exit_code)
  );

  always @(posedge clk) if (uart_tx_push) tx_pushes <= tx_pushes + 1;

  task automatic setup(input logic we, input logic [15:0] addr, input logic [31:0] data,
                       input logic [3:0] lanes);
    psel = 1;
    pwrite = we;
    paddr = addr;
    pwdata = data;
    pstrb = lanes;
    @(negedge clk);
    penable = 1;
  endtask

  task automatic complete_access;
    do @(posedge clk); while (!pready);
    @(negedge clk);
    psel = 0;
    penable = 0;
  endtask

  task automatic check_read(input logic [15:0] addr, input logic [31:0] expected);
    setup(0, addr, '0, '0);
    @(posedge clk);
    if (!pready || prdata !== expected) $fatal(1, "bad APB read at %h: %h", addr, prdata);
    if (uart_rx_pop !== (addr == 16'h0000) || uart_rx_clear !== (addr == 16'h0004))
      $fatal(1, "incorrect UART read side effect");
    @(negedge clk);
    psel = 0;
    penable = 0;
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst = 0;
    setup(1, 16'h0000, 32'hAB, 4'h1);
    repeat (3) begin
      @(negedge clk);
      if (pready || uart_tx_push) $fatal(1, "UART advanced while FIFO full");
    end
    uart_tx_ready = 1;
    boot_tx_valid = 1;
    @(negedge clk);
    if (pready || uart_tx_push) $fatal(1, "UART advanced while bootloader owned TX");
    boot_tx_valid = 0;
    complete_access();
    if (tx_pushes != 1 || uart_tx_byte !== 8'hAB) $fatal(1, "UART write lost or duplicated");
    check_read(16'h0000, 32'h34);
    check_read(16'h0004, 32'hB);

    setup(1, 16'h0010, 32'hF, 4'h2);
    complete_access();
    if (leds !== 0) $fatal(1, "wrong LED byte lane changed GPIO");
    setup(1, 16'h0010, 32'hA, 4'h1);
    if (leds !== 0) $fatal(1, "LED changed during setup");
    complete_access();
    check_read(16'h0010, 32'hA);
    check_read(16'h0014, 32'h2);
    setup(1, 16'h0024, 32'hABCD_1234, 4'b0101);
    complete_access();
    check_read(16'h0024, 32'h00CD_0034);
    if (irq_timer) $fatal(1, "timer IRQ remained asserted with future compare");

    ic_hit = 1;
    repeat (3) @(negedge clk);
    setup(1, 16'h0030, '0, 4'hF);
    complete_access();
    ic_hit = 0;
    check_read(16'h0030, 32'd5);
    setup(1, 16'h0030, '0, 4'hF);
    complete_access();
    check_read(16'h0030, 32'd0);
    check_read(16'h0100, 32'h9);
    check_read(16'h0104, 32'h1000_0040);
    check_read(16'h7770, 32'd0);

    setup(1, 16'h1000, 32'h1, 4'hF);
    complete_access();
    if (halted || exit_code !== 1) $fatal(1, "halt occurred before AXI commit or lost exit code");
    mmio_commit = 1;
    @(negedge clk);
    mmio_commit = 0;
    if (!halted) $fatal(1, "halt not applied at commit");
    setup(1, 16'h0108, '0, 4'hF);
    complete_access();
    if (boot_restart || !halted) $fatal(1, "restart occurred before AXI commit");
    mmio_commit = 1;
    @(posedge clk);
    if (!boot_restart) $fatal(1, "missing restart pulse");
    @(negedge clk);
    mmio_commit = 0;
    if (halted || exit_code !== 0) $fatal(1, "restart did not clear halt and exit code");
    $display("tb_roco_apb_peripherals: PASS");
    $finish;
  end

  initial begin
    repeat (500) @(posedge clk);
    $fatal(1, "APB peripheral timeout");
  end
endmodule
