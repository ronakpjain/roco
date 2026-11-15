`timescale 1ns / 1ps
`default_nettype none
module tb_icache;
  logic clk = 0;
  always #5 clk = !clk;
  logic rst = 1, flush = 0, req = 0;
  logic [31:0] addr = 0;
  wire rsp, miss, busy, mem_req, hit_pulse, miss_pulse;
  wire [31:0] rsp_addr, rsp_data;
  wire [22:0] mem_addr;
  wire [3:0] mem_len;
  logic ready = 0, rvalid = 0, rlast = 0;
  logic [31:0] rdata = 0;
  icache #(
      .NUM_LINES(128)
  ) dut (
      .clk(clk),
      .rst(rst),
      .flush(flush),
      .cpu_req(req),
      .cpu_addr(addr),
      .cpu_rsp_valid(rsp),
      .cpu_rsp_addr(rsp_addr),
      .cpu_rsp_data(rsp_data),
      .cpu_miss(miss),
      .cpu_busy(busy),
      .mem_req(mem_req),
      .mem_word_addr(mem_addr),
      .mem_len(mem_len),
      .mem_ready(ready),
      .mem_rvalid(rvalid),
      .mem_rdata(rdata),
      .mem_rlast(rlast),
      .hit_pulse(hit_pulse),
      .miss_pulse(miss_pulse)
  );
  task automatic fill(input logic [31:0] base, input logic cancel);
    @(negedge clk);
    req = 1;
    addr = base;
    #1;
    assert (miss && miss_pulse && !hit_pulse)
    else $fatal(1, "expected miss");
    @(negedge clk);
    req = 0;
    addr = 32'habcdef00;
    #1;
    assert (mem_req && mem_addr == (base[24:2] & ~23'd3) && mem_len == 3)
    else $fatal(1, "saved miss command changed");
    repeat (3) begin
      @(negedge clk);
      addr = addr + 64;
      #1;
      assert (mem_req && mem_addr == (base[24:2] & ~23'd3))
      else $fatal(1, "backpressure corrupted miss address");
    end
    ready = 1;
    @(negedge clk);
    ready = 0;
    for (int i = 0; i < 4; i++) begin
      rvalid = 1;
      rlast = (i == 3);
      rdata = base + 32'(i);
      flush = cancel && (i == 1);
      @(negedge clk);
    end
    rvalid = 0;
    rlast = 0;
    flush = 0;
    #1;
    assert (!busy && !rsp)
    else $fatal(1, "fill did not finish cleanly");
  endtask
  initial begin
    repeat (3) @(negedge clk);
    rst = 0;
    fill(32'h10000100, 0);
    // Consecutive requests must retain their own response address/data.
    for (int i = 0; i < 12; i++) begin
      req = 1;
      addr = 32'h10000100 + 32'((i % 4) * 4);
      #1;
      assert (!miss && hit_pulse)
      else $fatal(1, "filled line missed");
      @(negedge clk);
      assert (rsp && rsp_addr == addr && rsp_data == 32'h10000100 + 32'(i % 4))
      else $fatal(1, "streaming response mismatch");
    end
    req = 0;
    fill(32'h10000200, 1);
    req = 1;
    addr = 32'h10000200;
    #1;
    assert (miss && !hit_pulse)
    else $fatal(1, "flush allowed canceled fill to hit");
    req = 0;
    fill(32'h10000200, 0);
    req = 1;
    addr = 32'h1000020c;
    @(negedge clk);
    assert (rsp && rsp_data == 32'h10000203)
    else $fatal(1, "refill failed");
    // Exercise every physical tag bank with different low indices, then
    // revisit all banks after unrelated fills have changed the live port.
    req = 0;
    for (int bank = 0; bank < 8; bank++)
    fill(32'h10001000 + 32'(bank * 256 + ((bank * 3) % 16) * 16), 0);
    for (int bank = 7; bank >= 0; bank--) begin
      req = 1;
      addr = 32'h10001000 + 32'(bank * 256 + ((bank * 3) % 16) * 16 + 12);
      #1;
      assert (!miss && hit_pulse)
      else $fatal(1, "tag bank lost its line");
      @(negedge clk);
      assert (rsp && rsp_addr == addr && rsp_data == addr - 9)
      else $fatal(1, "tag bank data/address mismatch");
    end
    rst = 1;
    req = 0;
    @(negedge clk);
    rst = 0;
    req = 1;
    #1;
    assert (miss && !rsp)
    else $fatal(1, "reset retained a valid line");
    $display("tb_icache: PASS (streaming, held miss, canceled fill, reset)");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
