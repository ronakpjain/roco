// APB4 register bank and local decode for the existing SoC peripheral map.
// Unmapped offsets retain the legacy read-zero/write-ignore behavior.
`default_nettype none

module roco_apb_peripherals (
  input logic clk,
  rst,
  input logic psel,
  penable,
  pwrite,
  input logic [15:0] paddr,
  input logic [31:0] pwdata,
  input logic [3:0] pstrb,
  output logic pready,
  output logic [31:0] prdata,
  input logic [7:0] uart_rx_data,
  input logic uart_rx_valid,
  uart_rx_overflow,
  uart_tx_ready,
  boot_tx_valid,
  output logic uart_tx_push,
  uart_rx_pop,
  uart_rx_clear,
  output logic [7:0] uart_tx_byte,
  input logic [1:0] buttons,
  output logic [3:0] leds,
  output logic irq_timer,
  input logic ic_hit,
  ic_miss,
  dc_hit,
  dc_miss,
  input logic [3:0] boot_status,
  input logic [31:0] boot_addr,
  // These two system effects must wait for the CPU to retire the access;
  // resetting or halting it during APB access would strand the AXI B beat.
  input logic mmio_commit,
  output logic boot_restart,
  halted,
  output logic [31:0] exit_code
);
  typedef enum logic [2:0] {
    Unmapped,
    Uart,
    Gpio,
    Timer,
    Counters,
    Syscon
  } device_t;
  device_t device;
  logic [63:0] mtime, mtimecmp;
  logic [31:0] ic_hits, ic_misses, dc_hits, dc_misses, dbg0, dbg1;
  logic [31:0] uart_data, gpio_data, timer_data, counter_data, syscon_data;
  logic ic_hit_q, ic_miss_q, dc_hit_q, dc_miss_q, clear_q;
  logic [31:0] ic_hits_q, ic_misses_q, dc_hits_q, dc_misses_q;
  logic read_fire, write_fire, uart_data_addr;

  always_comb begin
    case (paddr)
      16'h0000, 16'h0004: device = Uart;
      16'h0010, 16'h0014: device = Gpio;
      16'h0018, 16'h001c, 16'h0020, 16'h0024, 16'h0028: device = Timer;
      16'h0030, 16'h0034, 16'h0038, 16'h003c: device = Counters;
      16'h0048, 16'h004c, 16'h0100, 16'h0104, 16'h0108, 16'h1000: device = Syscon;
      default: device = Unmapped;
    endcase
  end
  always_comb begin
    case (device)
      Uart: prdata = uart_data;
      Gpio: prdata = gpio_data;
      Timer: prdata = timer_data;
      Counters: prdata = counter_data;
      Syscon: prdata = syscon_data;
      default: prdata = '0;
    endcase
  end
  assign read_fire = psel && penable && pready && !pwrite;
  assign write_fire = psel && penable && pready && pwrite && (|pstrb);

  function automatic logic [31:0] merge_bytes(
      input logic [31:0] old_word, input logic [31:0] new_word, input logic [3:0] strobes);
    for (int lane = 0; lane < 4; lane++) begin
      merge_bytes[lane*8+:8] = strobes[lane] ? new_word[lane*8+:8] : old_word[lane*8+:8];
    end
  endfunction

  // UART. A data write may wait for FIFO room; RX side effects happen
  // only when the access completes, not during setup or a stalled access.
  assign uart_data_addr = paddr == 16'h0000;
  assign pready = !(psel && pwrite && uart_data_addr && pstrb[0]) ||
                  (uart_tx_ready && !boot_tx_valid);
  assign uart_tx_push = write_fire && uart_data_addr && pstrb[0];
  assign uart_tx_byte = pwdata[7:0];
  assign uart_rx_pop = read_fire && uart_data_addr && uart_rx_valid;
  assign uart_rx_clear = read_fire && paddr == 16'h0004;
  assign uart_data = uart_data_addr ? {24'd0, uart_rx_data} :
                     {28'd0, uart_rx_overflow, 1'b0, uart_rx_valid, uart_tx_ready};

  // GPIO and timer.
  assign gpio_data = paddr == 16'h0010 ? {28'd0, leds} : {30'd0, buttons};
  assign irq_timer = mtime >= mtimecmp;
  always_comb begin
    case (paddr)
      16'h0018: timer_data = mtime[31:0];
      16'h001c: timer_data = mtime[63:32];
      16'h0020: timer_data = mtimecmp[31:0];
      16'h0024: timer_data = mtimecmp[63:32];
      default: timer_data = {31'd0, irq_timer};
    endcase
  end
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      leds <= '0;
      mtime <= '0;
      mtimecmp <= '0;
    end else begin
      mtime <= mtime + 64'd1;
      if (write_fire) begin
        case (paddr)
          16'h0010: if (pstrb[0]) leds <= pwdata[3:0];
          16'h0020: mtimecmp[31:0] <= merge_bytes(mtimecmp[31:0], pwdata, pstrb);
          16'h0024: mtimecmp[63:32] <= merge_bytes(mtimecmp[63:32], pwdata, pstrb);
          default: begin
          end
        endcase
      end
    end
  end

  // Cache events still take priority over a clear on the same cycle.
  assign ic_hits = ic_hit_q ? ic_hits_q + 32'd1 : clear_q ? 32'd0 : ic_hits_q;
  assign ic_misses = ic_miss_q ? ic_misses_q + 32'd1 : clear_q ? 32'd0 : ic_misses_q;
  assign dc_hits = dc_hit_q ? dc_hits_q + 32'd1 : clear_q ? 32'd0 : dc_hits_q;
  assign dc_misses = dc_miss_q ? dc_misses_q + 32'd1 : clear_q ? 32'd0 : dc_misses_q;
  always_comb begin
    case (paddr)
      16'h0030: counter_data = ic_hits;
      16'h0034: counter_data = ic_misses;
      16'h0038: counter_data = dc_hits;
      default: counter_data = dc_misses;
    endcase
  end
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      {ic_hits_q, ic_misses_q, dc_hits_q, dc_misses_q} <= '0;
      {ic_hit_q, ic_miss_q, dc_hit_q, dc_miss_q, clear_q} <= '0;
    end else begin
      {ic_hits_q, ic_misses_q, dc_hits_q, dc_misses_q} <= {ic_hits, ic_misses, dc_hits, dc_misses};
      {ic_hit_q, ic_miss_q, dc_hit_q, dc_miss_q} <= {ic_hit, ic_miss, dc_hit, dc_miss};
      clear_q <= write_fire && paddr == 16'h0030;
    end
  end

  // System control and diagnostics. The bridge holds PADDR and PWRITE
  // throughout its AXI response, including after APB PSEL deasserts.
  assign boot_restart = mmio_commit && pwrite && (|pstrb) && paddr == 16'h0108;
  always_comb begin
    case (paddr)
      16'h0048: syscon_data = dbg0;
      16'h004c: syscon_data = dbg1;
      16'h0100: syscon_data = {28'd0, boot_status};
      16'h0104: syscon_data = boot_addr;
      16'h1000: syscon_data = exit_code;
      default: syscon_data = '0;
    endcase
  end
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      halted <= 1'b0;
      {dbg0, dbg1, exit_code} <= '0;
    end else begin
      if (write_fire) begin
        case (paddr)
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
      end else if (mmio_commit && pwrite && (|pstrb) && paddr == 16'h1000) begin
        halted <= 1'b1;
      end
    end
  end
endmodule

`default_nettype wire
