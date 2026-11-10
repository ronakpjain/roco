// UART image loader.
//
// The host sends:
//   "ROCO"            4-byte magic
//   base              4-byte little-endian SDRAM byte address
//   length            4-byte little-endian payload length
//   crc32             4-byte little-endian CRC-32 (IEEE) of the payload
//   payload           length bytes
//
// Payload bytes are packed into 32-bit words and written to SDRAM.
// On success the loader replies 'K' and raises boot_done; on a framing,
// range or CRC error it replies 'E' and returns to the magic search
// without releasing the CPU.

`default_nettype none

module uart_boot (
  input logic clk,
  input logic rst,
  input logic restart,
  /* UART receive. */
  input logic [7:0] rx_data,
  input logic rx_valid,
  output logic rx_ready,
  /* UART transmit. */
  output logic [7:0] tx_data,
  output logic tx_valid,
  input logic tx_ready,
  /* Memory write port. */
  output logic mem_req,
  input logic mem_ready,
  output logic mem_wvalid,
  input logic mem_wready,
  output logic [22:0] mem_word_addr,
  output logic [31:0] mem_wdata,
  output logic [3:0] mem_wbe,
  /* Status. */
  output logic boot_done,
  output logic [31:0] boot_addr,
  output logic boot_busy,
  output logic boot_error
);

  localparam logic [31:0] SDRAM_BASE = 32'h1000_0000;
  localparam logic [31:0] SDRAM_LIMIT = 32'h1200_0000;
  localparam logic [31:0] MAX_LENGTH = 32'h0080_0000;
  localparam logic [31:0] CRC_POLY = 32'hEDB8_8320;

  typedef enum logic [3:0] {
    S_MAGIC,
    S_BASE,
    S_LEN,
    S_CRC,
    S_DATA,
    S_WR_REQ,
    S_WR_BEAT,
    S_END,
    S_FINISH,
    S_ERROR
  } state_t;

  state_t state;
  logic [1:0] magic_idx;
  logic [1:0] hdr_idx;
  logic [31:0] base_q;
  logic [31:0] len_q;
  logic [31:0] crc_q;
  logic [31:0] crc_reg;
  logic [31:0] byte_cnt;
  logic [31:0] word_buf;
  logic [3:0] word_be;
  logic [1:0] word_idx;
  logic [22:0] word_addr;
  logic last_payload;
  logic tx_done;
  logic [31:0] crc_x;
  logic [32:0] range_sum;
  integer k;

  assign boot_busy = (state != S_MAGIC);
  // After a successful boot the CPU owns the UART; the loader must not
  // consume the application's receive bytes while waiting for a restart.
  assign rx_ready = rx_valid && !boot_done &&
                    ((state == S_MAGIC) || (state == S_BASE) || (state == S_LEN) ||
                     (state == S_CRC) || (state == S_DATA));
  assign tx_valid = ((state == S_FINISH) || (state == S_ERROR)) && !tx_done;
  assign tx_data = (state == S_FINISH) ? 8'h4B : 8'h45;  // 'K' / 'E'
  assign mem_req = (state == S_WR_REQ);
  assign mem_word_addr = word_addr;
  assign mem_wdata = word_buf;
  assign mem_wbe = word_be;
  assign mem_wvalid = (state == S_WR_BEAT);
  assign range_sum = {1'b0, base_q} + {1'b0, len_q};

  // Reflected CRC-32, one byte per cycle, eight shifts.
  always_comb begin
    crc_x = crc_reg ^ {24'd0, rx_data};
    for (k = 0; k < 8; k = k + 1) begin
      if (crc_x[0]) begin
        crc_x = (crc_x >> 1) ^ CRC_POLY;
      end else begin
        crc_x = crc_x >> 1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst || restart) begin
      state <= S_MAGIC;
      magic_idx <= '0;
      hdr_idx <= '0;
      base_q <= '0;
      len_q <= '0;
      crc_q <= '0;
      crc_reg <= 32'hFFFF_FFFF;
      byte_cnt <= '0;
      word_buf <= '0;
      word_be <= '0;
      word_idx <= '0;
      word_addr <= '0;
      last_payload <= 1'b0;
      tx_done <= 1'b0;
      boot_done <= 1'b0;
      boot_addr <= '0;
      boot_error <= 1'b0;
    end else begin
      case (state)
        S_MAGIC: begin
          if (rx_valid && rx_ready) begin
            if (((magic_idx == 2'd0) && (rx_data == 8'h52)) ||
                ((magic_idx == 2'd1) && (rx_data == 8'h4F)) ||
                ((magic_idx == 2'd2) && (rx_data == 8'h43)) ||
                ((magic_idx == 2'd3) && (rx_data == 8'h4F))) begin
              if (magic_idx == 2'd3) begin
                hdr_idx <= '0;
                state <= S_BASE;
              end else begin
                magic_idx <= magic_idx + 1'b1;
              end
            end else begin
              magic_idx <= '0;
            end
          end
        end
        S_BASE: begin
          if (rx_valid && rx_ready) begin
            base_q <= (base_q >> 8) | ({24'd0, rx_data} << 24);
            if (hdr_idx == 2'd3) begin
              hdr_idx <= '0;
              state <= S_LEN;
            end else begin
              hdr_idx <= hdr_idx + 1'b1;
            end
          end
        end
        S_LEN: begin
          if (rx_valid && rx_ready) begin
            len_q <= (len_q >> 8) | ({24'd0, rx_data} << 24);
            if (hdr_idx == 2'd3) begin
              hdr_idx <= '0;
              state <= S_CRC;
            end else begin
              hdr_idx <= hdr_idx + 1'b1;
            end
          end
        end
        S_CRC: begin
          if (rx_valid && rx_ready) begin
            crc_q <= (crc_q >> 8) | ({24'd0, rx_data} << 24);
            if (hdr_idx == 2'd3) begin
              if ((base_q[1:0] != 2'b00) || (base_q < SDRAM_BASE) ||
                  (base_q >= SDRAM_LIMIT) || (len_q == 32'd0) ||
                  (len_q > MAX_LENGTH) || (range_sum > {1'b0, SDRAM_LIMIT})) begin
                state <= S_ERROR;
                tx_done <= 1'b0;
              end else begin
                crc_reg <= 32'hFFFF_FFFF;
                byte_cnt <= '0;
                word_buf <= '0;
                word_be <= '0;
                word_idx <= '0;
                word_addr <= base_q[24:2];
                last_payload <= 1'b0;
                state <= S_DATA;
              end
            end else begin
              hdr_idx <= hdr_idx + 1'b1;
            end
          end
        end
        S_DATA: begin
          if (rx_valid && rx_ready) begin
            crc_reg <= crc_x;
            word_buf <= word_buf | ({24'd0, rx_data} << {word_idx, 3'b000});
            word_be <= word_be | (4'b0001 << word_idx);
            byte_cnt <= byte_cnt + 32'd1;
            if (byte_cnt + 32'd1 == len_q) begin
              last_payload <= 1'b1;
              state <= S_WR_REQ;
            end else if (word_idx == 2'd3) begin
              word_idx <= '0;
              state <= S_WR_REQ;
            end else begin
              word_idx <= word_idx + 1'b1;
            end
          end
        end
        S_WR_REQ: begin
          if (mem_ready) begin
            state <= S_WR_BEAT;
          end
        end
        S_WR_BEAT: begin
          if (mem_wready) begin
            word_buf <= '0;
            word_be <= '0;
            word_idx <= '0;
            word_addr <= word_addr + 1'b1;
            if (last_payload) begin
              state <= S_END;
            end else begin
              state <= S_DATA;
            end
          end
        end
        S_END: begin
          if (~crc_reg == crc_q) begin
            tx_done <= 1'b0;
            state <= S_FINISH;
          end else begin
            boot_error <= 1'b1;
            tx_done <= 1'b0;
            state <= S_ERROR;
          end
        end
        S_FINISH: begin
          if (tx_done) begin
            boot_done <= 1'b1;
            boot_addr <= base_q;
            state <= S_MAGIC;
            magic_idx <= '0;
          end else if (tx_valid && tx_ready) begin
            tx_done <= 1'b1;
          end
        end
        S_ERROR: begin
          if (tx_done) begin
            boot_error <= 1'b1;
            state <= S_MAGIC;
            magic_idx <= '0;
            hdr_idx <= '0;
          end else if (tx_valid && tx_ready) begin
            tx_done <= 1'b1;
          end
        end
        default: begin
          state <= S_MAGIC;
        end
      endcase
    end
  end

endmodule
