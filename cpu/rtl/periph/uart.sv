// 8N1 UART with 16-byte transmit and receive FIFOs.
//
// The baud divisor is CLK_HZ/BAUD. Receive is oversampled at the bit
// centre after detecting the start edge, then checked for a stop bit.
// A byte that arrives while the receive FIFO is full is dropped and
// sets `rx_overflow` until the status read clears it.

`default_nettype none

module uart #(
    parameter int CLK_HZ = 48_000_000,
    parameter int BAUD = 115200,
    parameter int FIFO_DEPTH = 16
) (
  input logic clk,
  input logic rst,
  input logic [7:0] tx_data,
  input logic tx_valid,
  output logic tx_ready,
  output logic [7:0] rx_data,
  output logic rx_valid,
  input logic rx_ready,
  output logic rx_overflow,
  input logic clear_overflow,
  input logic uart_rx,
  output logic uart_tx
);

  localparam int DIV = (CLK_HZ / BAUD) < 4 ? 4 : (CLK_HZ / BAUD);
  localparam int ADDR_BITS = $clog2(FIFO_DEPTH);

  typedef enum logic [1:0] {
    RX_IDLE,
    RX_START,
    RX_DATA,
    RX_STOP
  } rx_state_t;

  // ------------------------------------------------------------ TX FIFO
  logic [7:0] tx_mem[0:FIFO_DEPTH-1];
  logic [ADDR_BITS:0] tx_head;
  logic [ADDR_BITS:0] tx_tail;
  logic tx_empty;
  logic tx_full;
  logic tx_busy;
  logic [15:0] tx_cnt;
  logic [3:0] tx_bit;
  logic [9:0] tx_shift;

  assign tx_empty = (tx_head == tx_tail);
  assign tx_full = (tx_head[ADDR_BITS] != tx_tail[ADDR_BITS]) &&
                   (tx_head[ADDR_BITS-1:0] == tx_tail[ADDR_BITS-1:0]);
  assign tx_ready = !tx_full;

  logic tx_direct;
  assign tx_direct = tx_valid && tx_ready && tx_empty && !tx_busy;

  always_ff @(posedge clk) begin
    if (rst) begin
      tx_head <= '0;
      tx_tail <= '0;
      tx_busy <= 1'b0;
      tx_cnt <= '0;
      tx_bit <= '0;
      tx_shift <= 10'h3ff;
      uart_tx <= 1'b1;
    end else begin
      if (tx_valid && tx_ready && !tx_direct) begin
        tx_mem[tx_tail[ADDR_BITS-1:0]] <= tx_data;
        tx_tail <= tx_tail + 1'b1;
      end

      if (!tx_busy) begin
        if (tx_direct) begin
          tx_shift <= {1'b1, tx_data, 1'b0};
          tx_busy <= 1'b1;
          tx_cnt <= 16'(DIV - 1);
          tx_bit <= 4'd0;
          uart_tx <= 1'b0;
        end else if (!tx_empty) begin
          tx_shift <= {1'b1, tx_mem[tx_head[ADDR_BITS-1:0]], 1'b0};
          tx_head <= tx_head + 1'b1;
          tx_busy <= 1'b1;
          tx_cnt <= 16'(DIV - 1);
          tx_bit <= 4'd0;
          uart_tx <= 1'b0;
        end else begin
          uart_tx <= 1'b1;
        end
      end else if (tx_cnt == 16'd0) begin
        tx_cnt <= 16'(DIV - 1);
        if (tx_bit == 4'd9) begin
          tx_busy <= 1'b0;
          uart_tx <= 1'b1;
        end else begin
          uart_tx <= tx_shift[tx_bit+1];
          tx_bit <= tx_bit + 1'b1;
        end
      end else begin
        tx_cnt <= tx_cnt - 16'd1;
      end
    end
  end

  // ------------------------------------------------------------ RX path
  logic [7:0] rx_mem[0:FIFO_DEPTH-1];
  logic [ADDR_BITS:0] rx_head;
  logic [ADDR_BITS:0] rx_tail;
  logic rx_empty;
  logic rx_full;
  logic [1:0] rx_sync;
  rx_state_t rx_state;
  logic [15:0] rx_cnt;
  logic [2:0] rx_bit;
  logic [7:0] rx_shift;
  logic rx_done;

  assign rx_empty = (rx_head == rx_tail);
  assign rx_full = (rx_head[ADDR_BITS] != rx_tail[ADDR_BITS]) &&
                   (rx_head[ADDR_BITS-1:0] == rx_tail[ADDR_BITS-1:0]);
  assign rx_valid = !rx_empty;
  assign rx_data = rx_mem[rx_head[ADDR_BITS-1:0]];

  always_ff @(posedge clk) begin
    if (rst) begin
      rx_sync <= 2'b11;
      rx_state <= RX_IDLE;
      rx_cnt <= '0;
      rx_bit <= '0;
      rx_shift <= '0;
      rx_done <= 1'b0;
      rx_head <= '0;
      rx_tail <= '0;
      rx_overflow <= 1'b0;
    end else begin
      rx_sync <= {rx_sync[0], uart_rx};
      rx_done <= 1'b0;

      if (rx_ready && !rx_empty) begin
        rx_head <= rx_head + 1'b1;
      end

      if (clear_overflow) begin
        rx_overflow <= 1'b0;
      end

      case (rx_state)
        RX_IDLE: begin
          if (!rx_sync[1]) begin
            rx_state <= RX_START;
            rx_cnt <= 16'(DIV / 2);
          end
        end
        RX_START: begin
          if (rx_cnt == 16'd0) begin
            if (!rx_sync[1]) begin
              rx_state <= RX_DATA;
              rx_cnt <= 16'(DIV - 1);
              rx_bit <= 3'd0;
            end else begin
              rx_state <= RX_IDLE;
            end
          end else begin
            rx_cnt <= rx_cnt - 16'd1;
          end
        end
        RX_DATA: begin
          if (rx_cnt == 16'd0) begin
            rx_shift[rx_bit] <= rx_sync[1];
            rx_cnt <= 16'(DIV - 1);
            if (rx_bit == 3'd7) begin
              rx_state <= RX_STOP;
            end else begin
              rx_bit <= rx_bit + 1'b1;
            end
          end else begin
            rx_cnt <= rx_cnt - 16'd1;
          end
        end
        RX_STOP: begin
          if (rx_cnt == 16'd0) begin
            rx_state <= RX_IDLE;
            rx_done <= 1'b1;
          end else begin
            rx_cnt <= rx_cnt - 16'd1;
          end
        end
        default: begin
          rx_state <= RX_IDLE;
        end
      endcase

      if (rx_done) begin
        if (!rx_full) begin
          rx_mem[rx_tail[ADDR_BITS-1:0]] <= rx_shift;
          rx_tail <= rx_tail + 1'b1;
        end else begin
          rx_overflow <= 1'b1;
        end
      end
    end
  end

endmodule
