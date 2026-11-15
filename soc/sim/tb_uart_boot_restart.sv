`timescale 1ns / 1ps
module tb_uart_boot_restart;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1;
  logic restart = 0;
  logic [7:0] rx_data = 0;
  logic rx_valid = 0;
  logic rx_ready, tx_valid, mem_req, mem_wvalid;
  logic [7:0] tx_data;
  logic mem_ready = 1;
  logic mem_wready = 1;
  logic [22:0] mem_word_addr;
  logic [31:0] mem_wdata;
  logic [3:0] mem_wbe;
  logic boot_done, boot_busy, boot_error;
  logic [31:0] boot_addr;
  logic [31:0] last_word;
  logic [22:0] last_addr;
  integer writes = 0;
  integer errors = 0;

  uart_boot dut (
      .*,
      .tx_ready(1'b1)
  );

  always @(posedge clk) begin
    if (!rst && mem_wvalid && mem_wready) begin
      last_word <= mem_wdata;
      last_addr <= mem_word_addr;
      if (mem_wbe != 4'hf) $fatal(1, "unexpected write byte mask");
      writes <= writes + 1;
    end
    if (!rst && tx_valid && tx_data != 8'h4b) errors <= errors + 1;
  end

  task automatic tick;
    @(posedge clk);
    #1;
    @(negedge clk);
  endtask

  task automatic send_byte(input logic [7:0] data);
    rx_data = data;
    rx_valid = 1;
    #1;
    while (!rx_ready) tick();
    tick();
    rx_valid = 0;
  endtask

  function automatic [7:0] packet_byte(input integer index, input logic [31:0] base,
                                       input logic [31:0] word_data, input logic [31:0] crc);
    if (index < 4) packet_byte = 8'((32'h4f434f52 >> (8 * index)));
    else if (index < 8) packet_byte = 8'(base >> (8 * (index - 4)));
    else if (index < 12) packet_byte = 8'(32'd4 >> (8 * (index - 8)));
    else if (index < 16) packet_byte = 8'(crc >> (8 * (index - 12)));
    else packet_byte = 8'(word_data >> (8 * (index - 16)));
  endfunction

  task automatic restart_loader;
    restart = 1;
    tick();
    restart = 0;
    if (boot_done || boot_error || boot_busy || mem_req || mem_wvalid)
      $fatal(1, "restart did not immediately invalidate the loader");
  endtask

  task automatic load_good_packet;
    integer before_writes;
    before_writes = writes;
    for (int i = 0; i < 20; i++)
      send_byte(packet_byte(i, 32'h10000100, 32'ha5c3e719, 32'he693d2c6));
    for (int i = 0; i < 20 && !boot_done; i++) tick();
    if (!boot_done || boot_error || boot_addr != 32'h10000100 ||
        last_word != 32'ha5c3e719 || last_addr != 23'h40 || writes != before_writes + 1)
      $fatal(1, "reloaded packet retained stale header, data, address or CRC");
    if (errors != 0) $fatal(1, "unexpected loader error reply");
  endtask

  initial begin
    repeat (20000) @(posedge clk);
    $fatal(1, "timeout");
  end

  initial begin
    tick();
    rst = 0;
    // Interrupt at every magic/header/data boundary, including after a
    // successful packet. The replacement packet has different address,
    // payload and a Python/zlib-generated IEEE CRC-32 fixture.
    for (int prefix = 0; prefix <= 20; prefix++) begin
      for (int i = 0; i < prefix; i++)
      send_byte(packet_byte(i, 32'h10000200, 32'h11223344, 32'hde1d2d6d));
      restart_loader();
      load_good_packet();
      restart_loader();
    end
    // Restart with a memory request stalled, then with its data beat stalled.
    for (int phase = 0; phase < 2; phase++) begin
      mem_ready = (phase != 0);
      mem_wready = 0;
      for (int i = 0; i < 20; i++)
      send_byte(packet_byte(i, 32'h10000200, 32'h11223344, 32'hde1d2d6d));
      repeat (3) tick();
      if ((phase == 0 && !mem_req) || (phase == 1 && !mem_wvalid))
        $fatal(1, "memory stall case was not exercised");
      restart_loader();
      mem_ready = 1;
      mem_wready = 1;
      load_good_packet();
      restart_loader();
    end
    $display("tb_uart_boot_restart: PASS");
    $finish;
  end
endmodule
