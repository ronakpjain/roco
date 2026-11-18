`timescale 1ns / 1ps
`include "axi4_defs.svh"

module tb_axi4_apb_bridge;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1;
  axi4_ar_t ar = '0;
  axi4_aw_t aw = '0;
  axi4_w_t w = '0;
  axi4_r_t r;
  axi4_b_t b;
  logic ar_ready, aw_ready, w_ready;
  logic r_ready = 0, b_ready = 0;
  logic psel, penable, pwrite;
  logic [31:0] paddr, pwdata;
  logic [3:0] pstrb;
  logic [2:0] pprot;
  logic pready = 0, pslverr = 0;
  logic [31:0] prdata = 0;
  int transfers = 0;
  axi4_r_t held_r;
  axi4_b_t held_b;

  axi4_apb_bridge dut (.*);
  always @(posedge clk) if (psel && penable && pready) transfers <= transfers + 1;

  task automatic apb_reply(input bit we, input logic [31:0] addr, input logic [3:0] strb,
                           input logic [2:0] prot, input logic [31:0] wr_data,
                           input logic [31:0] rd_data, input bit err);
    while (!psel) @(negedge clk);
    if (penable) $fatal(1, "APB access without setup");
    for (int i = 0; i < 5; i++) begin
      if (!psel || penable != (i != 0) || pwrite != we || paddr != addr ||
          pstrb != strb || pprot != prot || (we && pwdata != wr_data))
        $fatal(1, "APB control or payload incorrect during setup/access");
      @(negedge clk);
    end
    if (r.valid || b.valid) $fatal(1, "premature response before PREADY");
    prdata = rd_data;
    pslverr = err;
    pready = 1;
    @(negedge clk);
    pready = 0;
    pslverr = 0;
    prdata = '0;
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst = 0;

    // W can arrive first, but the bridge must wait for its AW.
    w = '{valid: 1'b1, data: 32'h00AB_0000, strb: 4'b0100, last: 1'b1};
    repeat (3) begin
      @(negedge clk);
      if (w_ready || psel) $fatal(1, "W advanced before AW");
    end
    aw = '{
        valid: 1'b1,
        addr: 32'h8000_0012,
        size: 3'd0,
        id: 4'hA,
        burst: `AXI4_BURST_INCR,
        len: '0,
        prot: 3'b101
    };
    do @(posedge clk); while (!aw_ready);
    @(negedge clk);
    aw = '0;
    do @(posedge clk); while (!w_ready);
    @(negedge clk);
    w = '0;
    apb_reply(1, 32'h8000_0010, 4'b0100, 3'b101, 32'h00AB_0000, '0, 0);
    held_b = b;
    if (!held_b.valid || held_b.id != 4'hA || held_b.resp != `AXI4_RESP_OKAY)
      $fatal(1, "incorrect B response");
    repeat (4) begin
      @(negedge clk);
      if (b !== held_b || psel) $fatal(1, "B stall replayed or changed write");
    end
    b_ready = 1;
    @(negedge clk);
    b_ready = 0;

    ar = '{
        valid: 1'b1,
        addr: 32'h8000_0010,
        size: 3'd2,
        id: 4'h5,
        burst: `AXI4_BURST_INCR,
        len: '0,
        prot: 3'b011
    };
    do @(posedge clk); while (!ar_ready);
    @(negedge clk);
    ar = '0;
    apb_reply(0, 32'h8000_0010, '0, 3'b011, '0, 32'h1234_5678, 1);
    held_r = r;
    if (!held_r.valid || held_r.id != 4'h5 || held_r.resp != `AXI4_RESP_SLVERR ||
        !held_r.last || held_r.data != 32'h1234_5678)
      $fatal(1, "incorrect R response");
    repeat (4) begin
      @(negedge clk);
      if (r !== held_r || psel) $fatal(1, "R stall replayed or changed read");
    end
    r_ready = 1;
    @(negedge clk);
    r_ready = 0;

    ar = '{
        valid: 1'b1,
        addr: 32'h8000_0010,
        size: 3'd2,
        id: 4'hB,
        burst: `AXI4_BURST_INCR,
        len: 8'd2,
        prot: '0
    };
    do @(posedge clk); while (!ar_ready);
    @(negedge clk);
    ar = '0;
    r_ready = 1;
    for (int i = 0; i < 3; i++) begin
      @(posedge clk);
      if (!r.valid || r.id != 4'hB || r.resp != `AXI4_RESP_SLVERR ||
          r.last != (i == 2) || r.data != 0 || psel)
        $fatal(1, "invalid read burst response");
    end
    @(negedge clk);
    r_ready = 0;

    aw = '{
        valid: 1'b1,
        addr: 32'h8000_0010,
        size: 3'd2,
        id: 4'hC,
        burst: `AXI4_BURST_INCR,
        len: 8'd1,
        prot: '0
    };
    do @(posedge clk); while (!aw_ready);
    @(negedge clk);
    aw = '0;
    for (int i = 0; i < 2; i++) begin
      w = '{valid: 1'b1, data: 32'hDEAD_BEEF, strb: 4'hF, last: i == 1};
      do @(posedge clk); while (!w_ready);
      if (b.valid || psel) $fatal(1, "write burst not drained before response");
      @(negedge clk);
    end
    w = '0;
    if (!b.valid || b.id != 4'hC || b.resp != `AXI4_RESP_SLVERR || psel || transfers != 2)
      $fatal(1, "invalid write burst response or unexpected peripheral transfer");
    b_ready = 1;
    @(negedge clk);
    $display("tb_axi4_apb_bridge: PASS");
    $finish;
  end

  initial begin
    repeat (500) @(posedge clk);
    $fatal(1, "APB bridge timeout");
  end
endmodule
