`timescale 1ns / 1ps
`include "axi4_defs.svh"

module tb_axi4_sdram_adapter;
  logic clk = 0;
  always #5.208 clk = ~clk;
  logic rst = 1;
  axi4_ar_t ar = '0;
  axi4_aw_t aw = '0;
  axi4_w_t w = '0;
  axi4_r_t r;
  axi4_b_t b;
  logic ar_ready, aw_ready, w_ready;
  logic r_ready = 0, b_ready = 0;
  logic req_valid, req_ready, req_we, wvalid, wready, rvalid, rlast, init_done;
  logic [22:0] req_word_addr;
  logic [3:0] req_len, wbe;
  logic [31:0] wdata, rdata;
  logic [12:0] sd_a;
  logic [1:0] sd_ba, sd_dqm;
  logic sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
  logic [15:0] sd_dq_out, sd_dq_in, model_dq_out;
  logic model_dq_oe;
  logic [31:0] errors;
  int issued = 0;

  axi4_sdram_adapter dut (.*);
  sdram_ctrl ctrl (.*);
  sdram_model model (
      .clk(clk),
      .cke(1'b1),
      .cs_n(sd_cs_n),
      .ras_n(sd_ras_n),
      .cas_n(sd_cas_n),
      .we_n(sd_we_n),
      .a(sd_a),
      .ba(sd_ba),
      .dqm(sd_dqm),
      .dq_in(sd_dq_in),
      .dq_out(model_dq_out),
      .dq_oe(model_dq_oe),
      .errors(errors)
  );
  assign sd_dq_in = sd_dq_oe ? sd_dq_out : (model_dq_oe ? model_dq_out : 16'hzzzz);
  always @(posedge clk) if (req_valid && req_ready) issued <= issued + 1;

  task automatic write_words(input logic [31:0] addr, input int count, input logic [31:0] data,
                             input logic [3:0] strb, input logic [1:0] resp);
    axi4_b_t held;
    aw = '{
        valid: 1'b1,
        id: 4'h9,
        addr: addr,
        len: 8'(count - 1),
        size: 3'd2,
        burst: `AXI4_BURST_INCR,
        prot: '0
    };
    w = '{valid: 1'b1, data: data, strb: strb, last: count == 1};
    do @(posedge clk); while (!aw_ready);
    if (w_ready) $fatal(1, "W accepted before AW");
    @(negedge clk);
    aw = '0;
    for (int i = 0; i < count; i++) begin
      w.data = data + 32'(i);
      w.last = i == count - 1;
      do @(posedge clk); while (!w_ready);
      @(negedge clk);
    end
    w = '0;
    while (!b.valid) @(negedge clk);
    held = b;
    repeat (6) begin
      @(negedge clk);
      if (b !== held || !held.valid || held.id != 4'h9 || held.resp != resp)
        $fatal(1, "bad write response or B changed while stalled");
    end
    b_ready = 1;
    @(negedge clk);
    b_ready = 0;
  endtask

  task automatic read_words(input logic [31:0] addr, input int count, input logic [31:0] data,
                            input logic [1:0] resp);
    axi4_r_t held;
    ar = '{
        valid: 1'b1,
        id: 4'h5,
        addr: addr,
        len: 8'(count - 1),
        size: 3'd2,
        burst: `AXI4_BURST_INCR,
        prot: '0
    };
    do @(posedge clk); while (!ar_ready);
    @(negedge clk);
    ar = '0;
    while (!r.valid) @(negedge clk);
    held = r;
    // Long enough for every SDRAM beat to arrive without an AXI handshake.
    repeat (48) begin
      @(negedge clk);
      if (r !== held) $fatal(1, "R changed while stalled");
    end
    r_ready = 1;
    for (int i = 0; i < count; i++) begin
      do @(posedge clk); while (!r.valid);
      if (r.id !== 4'h5 || r.resp !== resp || r.last !== (i == count-1) ||
          r.data !== (resp == `AXI4_RESP_OKAY ? data + 32'(i) : 32'd0))
        $fatal(1, "bad read payload at beat %0d: %h", i, r);
    end
    @(negedge clk);
    r_ready = 0;
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst = 0;
    wait (init_done);
    @(negedge clk);
    write_words(32'h1000_0040, 16, 32'h1234_5670, 4'hf, `AXI4_RESP_OKAY);
    read_words(32'h1000_0040, 16, 32'h1234_5670, `AXI4_RESP_OKAY);
    write_words(32'h1000_0040, 1, 32'hAABB_CCDD, 4'b0101, `AXI4_RESP_OKAY);
    read_words(32'h1000_0040, 1, 32'h12BB_56DD, `AXI4_RESP_OKAY);
    // Row-crossing writes, overlength reads, and out-of-range addresses
    // must not start any controller transaction.
    write_words(32'h1000_03FC, 2, 32'hDEAD_BEEF, 4'hf, `AXI4_RESP_SLVERR);
    read_words(32'h1000_0040, 17, '0, `AXI4_RESP_SLVERR);
    read_words(32'h1200_0000, 1, '0, `AXI4_RESP_SLVERR);
    if (issued != 4 || errors != 0) $fatal(1, "issued=%0d, SDRAM errors=%h", issued, errors);
    $display("tb_axi4_sdram_adapter: PASS");
    $finish;
  end

  initial begin
    repeat (50000) @(posedge clk);
    $fatal(1, "SDRAM adapter timeout");
  end
endmodule
