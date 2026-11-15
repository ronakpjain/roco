// Behavioral 16-bit SDR SDRAM model with command/timing checks.
//
// Storage is aliased into the first 1 MiB of the 32 MiB address space so
// that simulation does not need a 32 MiB array. Every legal command is
// checked (row already open, read before activate, refresh with an open
// row, mode register contents) and any violation increments `errors`.

`default_nettype none

module sdram_model #(
    parameter int CL = 3,
    parameter int WORD_AW = 18,
    parameter int REFRESH_MAX = 760
) (
  input logic clk,
  input logic cke,
  input logic cs_n,
  input logic ras_n,
  input logic cas_n,
  input logic we_n,
  input logic [12:0] a,
  input logic [1:0] ba,
  input logic [1:0] dqm,
  input logic [15:0] dq_in,
  output logic [15:0] dq_out,
  output logic dq_oe,
  output logic [31:0] errors
);

  localparam int WORDS = 1 << WORD_AW;

  logic [15:0] mem[0:2*WORDS-1];
  logic row_open[0:3];
  logic [12:0] row_reg[0:3];
  logic [31:0] cycle;
  logic [31:0] refresh_age;
  logic [31:0] mode_reg;
  logic refresh_seen;
  logic [15:0] rd_pipe[0:CL+1];
  logic [CL+1:0] rd_valid;
  logic wr_hi_valid;
  logic [18:0] wr_hi_idx;
  logic [1:0] wr_hi_dqm;
  logic [23:0] hw_addr;
  logic [18:0] idx;
  integer i;
  integer k;

  logic cmd;
  logic is_act;
  logic is_read;
  logic is_write;
  logic is_precharge;
  logic is_refresh;
  logic is_mrs;

  assign cmd = cke && !cs_n;
  assign is_act = cmd && !ras_n && cas_n && we_n;
  assign is_read = cmd && ras_n && !cas_n && we_n;
  assign is_write = cmd && ras_n && !cas_n && !we_n;
  assign is_precharge = cmd && !ras_n && cas_n && !we_n;
  assign is_refresh = cmd && !ras_n && !cas_n && we_n;
  assign is_mrs = cmd && !ras_n && !cas_n && !we_n;

  always_comb begin
    hw_addr = ({22'd0, ba} << 22) | ({11'd0, row_reg[ba]} << 9) | {15'd0, a[8:0]};
    idx = hw_addr[18:0];
  end

  assign dq_out = rd_pipe[0];
  assign dq_oe = rd_valid[0];

  // Testbench backdoor: load one 32-bit word without a bus transaction.
  task automatic preload(input logic [22:0] word_addr, input logic [31:0] data);
    logic [WORD_AW:0] base;
    begin
      base = (word_addr << 1) & ((1 << (WORD_AW + 1)) - 1);
      mem[base] = data[15:0];
      mem[base+1] = data[31:16];
    end
  endtask

  initial begin
    // Memory contents are not initialised: tests write before reading.
    for (k = 0; k < 4; k = k + 1) begin
      row_open[k] = 1'b0;
      row_reg[k] = 13'd0;
    end
    for (k = 0; k <= CL + 1; k = k + 1) begin
      rd_pipe[k] = 16'd0;
      rd_valid[k] = 1'b0;
    end
    cycle = 32'd0;
    refresh_age = 32'd0;
    mode_reg = 32'd0;
    refresh_seen = 1'b0;
    wr_hi_valid = 1'b0;
    wr_hi_idx = '0;
    wr_hi_dqm = 2'b00;
    errors = 32'd0;
  end

  always @(posedge clk) begin
    cycle <= cycle + 32'd1;
    refresh_age <= refresh_age + 32'd1;

    // Shift the read data pipeline towards the pins.
    for (k = 0; k <= CL; k = k + 1) begin
      rd_pipe[k] <= rd_pipe[k+1];
      rd_valid[k] <= rd_valid[k+1];
    end
    rd_valid[CL+1] <= 1'b0;

    // Second half of a BL=2 write.
    if (wr_hi_valid) begin
      if (!wr_hi_dqm[0]) begin
        mem[wr_hi_idx][7:0] <= dq_in[7:0];
      end
      if (!wr_hi_dqm[1]) begin
        mem[wr_hi_idx][15:8] <= dq_in[15:8];
      end
      wr_hi_valid <= 1'b0;
    end

    if (!cke) begin
      $display("SDRAM ERROR: command with CKE low at %0t", $time);
      errors <= errors + 32'd1;
    end

    if (is_mrs) begin
      mode_reg <= {19'd0, a};
      if (a[2:0] != 3'b001) begin
        $display("SDRAM ERROR: mode register burst length is not 2 at %0t", $time);
        errors <= errors + 32'd1;
      end
      if (a[6:4] != 3'(CL)) begin
        $display("SDRAM ERROR: mode register CL=%0d expected %0d at %0t", a[6:4], CL, $time);
        errors <= errors + 32'd1;
      end
    end else if (is_act) begin
      if (cycle < 32'd9000) begin
        $display("SDRAM ERROR: activate during power-up at %0t", $time);
        errors <= errors + 32'd1;
      end
      if (row_open[ba]) begin
        $display("SDRAM ERROR: activate with row %0d open in bank %0d at %0t", row_reg[ba], ba,
                 $time);
        errors <= errors + 32'd1;
      end
      row_open[ba] <= 1'b1;
      row_reg[ba] <= a;
    end else if (is_read) begin
      if (!row_open[ba]) begin
        $display("SDRAM ERROR: read before activate in bank %0d at %0t", ba, $time);
        errors <= errors + 32'd1;
      end
      rd_pipe[CL] <= mem[idx];
      rd_pipe[CL+1] <= mem[idx+19'd1];
      rd_valid[CL] <= 1'b1;
      rd_valid[CL+1] <= 1'b1;
    end else if (is_write) begin
      if (!row_open[ba]) begin
        $display("SDRAM ERROR: write before activate in bank %0d at %0t", ba, $time);
        errors <= errors + 32'd1;
      end
      if (!dqm[0]) begin
        mem[idx][7:0] <= dq_in[7:0];
      end
      if (!dqm[1]) begin
        mem[idx][15:8] <= dq_in[15:8];
      end
      wr_hi_valid <= 1'b1;
      wr_hi_idx <= idx + 19'd1;
      wr_hi_dqm <= dqm;
    end else if (is_precharge) begin
      if (a[10]) begin
        row_open[0] <= 1'b0;
        row_open[1] <= 1'b0;
        row_open[2] <= 1'b0;
        row_open[3] <= 1'b0;
      end else begin
        row_open[ba] <= 1'b0;
      end
    end else if (is_refresh) begin
      if (row_open[0] || row_open[1] || row_open[2] || row_open[3]) begin
        $display("SDRAM ERROR: refresh with an open row at %0t", $time);
        errors <= errors + 32'd1;
      end
      if (refresh_seen && (refresh_age > 32'(REFRESH_MAX))) begin
        $display("SDRAM ERROR: refresh interval %0d cycles exceeds %0d at %0t", refresh_age,
                 REFRESH_MAX, $time);
        errors <= errors + 32'd1;
      end
      refresh_seen <= 1'b1;
      refresh_age <= 32'd0;
    end
  end

endmodule
