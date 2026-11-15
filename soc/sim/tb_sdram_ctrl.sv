// SDRAM controller testbench.
//
// Exercises mode-register initialisation, single-word and four-word
// bursts, row changes between banks, refresh, and data retention across
// a refresh interval. The SDRAM model checks every command and reports
// protocol violations.

`timescale 1ns / 1ps

module tb_sdram_ctrl;

  localparam int CL = 3;

  logic clk;
  logic rst;

  logic req_valid;
  logic req_ready;
  logic req_we;
  logic [22:0] req_word_addr;
  logic [3:0] req_len;
  logic wvalid;
  logic wready;
  logic [31:0] wdata;
  logic [3:0] wbe;
  logic rvalid;
  logic [31:0] rdata;
  logic rlast;
  logic init_done;

  logic [12:0] sd_a;
  logic [1:0] sd_ba;
  logic sd_cs_n;
  logic sd_ras_n;
  logic sd_cas_n;
  logic sd_we_n;
  logic [1:0] sd_dqm;
  logic [15:0] sd_dq_out;
  logic sd_dq_oe;
  logic [15:0] sd_dq_in;

  logic [15:0] model_dq_out;
  logic model_dq_oe;
  logic [15:0] dq_bus;
  logic [31:0] errors;

  logic [31:0] expected[0:15];
  logic [31:0] received[0:15];
  integer failures;

  sdram_ctrl #(
      .CL(CL)
  ) u_ctrl (
      .clk(clk),
      .rst(rst),
      .req_valid(req_valid),
      .req_ready(req_ready),
      .req_we(req_we),
      .req_word_addr(req_word_addr),
      .req_len(req_len),
      .wvalid(wvalid),
      .wready(wready),
      .wdata(wdata),
      .wbe(wbe),
      .rvalid(rvalid),
      .rdata(rdata),
      .rlast(rlast),
      .init_done(init_done),
      .sd_a(sd_a),
      .sd_ba(sd_ba),
      .sd_cs_n(sd_cs_n),
      .sd_ras_n(sd_ras_n),
      .sd_cas_n(sd_cas_n),
      .sd_we_n(sd_we_n),
      .sd_dqm(sd_dqm),
      .sd_dq_out(sd_dq_out),
      .sd_dq_oe(sd_dq_oe),
      .sd_dq_in(sd_dq_in)
  );

  sdram_model #(
      .CL(CL)
  ) u_model (
      .clk(clk),
      .cke(1'b1),
      .cs_n(sd_cs_n),
      .ras_n(sd_ras_n),
      .cas_n(sd_cas_n),
      .we_n(sd_we_n),
      .a(sd_a),
      .ba(sd_ba),
      .dqm(sd_dqm),
      .dq_in(dq_bus),
      .dq_out(model_dq_out),
      .dq_oe(model_dq_oe),
      .errors(errors)
  );

  assign dq_bus = sd_dq_oe ? sd_dq_out : (model_dq_oe ? model_dq_out : 16'hzzzz);
  assign sd_dq_in = dq_bus;

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  task automatic tick();
    begin
      @(posedge clk);
      #1;
    end
  endtask

  task automatic apply_reset();
    begin
      rst = 1'b1;
      req_valid = 1'b0;
      req_we = 1'b0;
      req_word_addr = '0;
      req_len = '0;
      wvalid = 1'b0;
      wdata = '0;
      wbe = '0;
      repeat (5) @(posedge clk);
      rst = 1'b0;
    end
  endtask

  task automatic wait_init();
    integer guard;
    begin
      guard = 0;
      while (!init_done && (guard < 40000)) begin
        tick();
        guard = guard + 1;
      end
      if (!init_done) begin
        $display("tb_sdram_ctrl: TIMEOUT waiting for init_done");
        $finish;
      end
    end
  endtask

  task automatic send_write(input logic [22:0] addr, input logic [3:0] len, input integer count);
    integer i;
    begin
      tick();
      while (!req_ready) begin
        tick();
      end
      req_valid = 1'b1;
      req_we = 1'b1;
      req_word_addr = addr;
      req_len = len;
      tick();
      req_valid = 1'b0;
      for (i = 0; i < count; i = i + 1) begin
        while (!wready) begin
          tick();
        end
        wvalid = 1'b1;
        wdata = expected[i];
        wbe = 4'hf;
        tick();
        wvalid = 1'b0;
      end
    end
  endtask

  task automatic send_read(input logic [22:0] addr, input logic [3:0] len, input integer count);
    integer i;
    begin
      tick();
      while (!req_ready) begin
        tick();
      end
      req_valid = 1'b1;
      req_we = 1'b0;
      req_word_addr = addr;
      req_len = len;
      tick();
      req_valid = 1'b0;
      for (i = 0; i < count; i = i + 1) begin
        while (!rvalid) begin
          tick();
        end
        received[i] = rdata;
        tick();
      end
    end
  endtask

  task automatic check_burst(input integer count, input [31:0] tag);
    integer i;
    begin
      for (i = 0; i < count; i = i + 1) begin
        if (received[i] !== expected[i]) begin
          $display("tb_sdram_ctrl: %0s word %0d got %08x expected %08x", tag, i, received[i],
                   expected[i]);
          failures = failures + 1;
        end
      end
    end
  endtask

  task automatic fill_pattern(input logic [31:0] seed);
    integer i;
    begin
      for (i = 0; i < 16; i = i + 1) begin
        expected[i] = seed + 32'(i) * 32'h0101_0101;
      end
    end
  endtask

  initial begin
    repeat (200000) @(posedge clk);
    $display("tb_sdram_ctrl: GLOBAL TIMEOUT");
    $finish;
  end

  initial begin
    failures = 0;
    apply_reset();
    tick();
    wait_init();

    // Four-word burst in bank 0, row 0.
    fill_pattern(32'h1122_3344);
    send_write(23'h000010, 4'd3, 4);
    send_read(23'h000010, 4'd3, 4);
    check_burst(4, "burst bank0 row0");

    // Same row, different column: no activate should be needed.
    fill_pattern(32'hcafe_0001);
    send_write(23'h0000f0, 4'd3, 4);
    send_read(23'h0000f0, 4'd3, 4);
    check_burst(4, "burst bank0 row0 high column");

    // Different row, same bank.
    fill_pattern(32'h55aa_00ff);
    send_write(23'h000210, 4'd3, 4);
    send_read(23'h000210, 4'd3, 4);
    check_burst(4, "burst bank0 row2");

    // Different bank.
    fill_pattern(32'h0bad_f00d);
    send_write(23'h200000, 4'd3, 4);
    send_read(23'h200000, 4'd3, 4);
    check_burst(4, "burst bank1 row0");

    // Maximum-length bursts must not wrap the read timing counter.
    fill_pattern(32'h1234_0000);
    send_write(23'h000100, 4'd15, 16);
    send_read(23'h000100, 4'd15, 16);
    check_burst(16, "sixteen-word burst");

    // Single-beat write and read.
    expected[0] = 32'hdead_beef;
    send_write(23'h001020, 4'd0, 1);
    send_read(23'h001020, 4'd0, 1);
    if (received[0] !== expected[0]) begin
      $display("tb_sdram_ctrl: single word got %08x expected %08x", received[0], expected[0]);
      failures = failures + 1;
    end

    // Let several refresh intervals pass, then check retention.
    repeat (2500) @(posedge clk);
    expected[0] = 32'h1122_3344;
    expected[1] = 32'h1223_3445;
    expected[2] = 32'h1324_3546;
    expected[3] = 32'h1425_3647;
    send_read(23'h000010, 4'd3, 4);
    check_burst(4, "retention");

    if (errors != 0) begin
      $display("tb_sdram_ctrl: %0d SDRAM protocol errors", errors);
      failures = failures + 1;
    end
    if (failures == 0) begin
      $display("tb_sdram_ctrl: PASS");
    end else begin
      $display("tb_sdram_ctrl: FAIL (%0d)", failures);
    end
    $finish;
  end

endmodule
