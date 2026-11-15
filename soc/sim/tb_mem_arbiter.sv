`timescale 1ns / 1ps
module tb_mem_arbiter;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1;
  logic i_req = 0, d_req = 0, b_req = 0, p_req = 0;
  logic i_ready, d_ready, b_ready, p_ready, d_wready, b_wready;
  logic b_wvalid = 0;
  logic i_rvalid, d_rvalid, p_rvalid, i_rlast, d_rlast, p_rlast;
  logic [31:0] i_rdata, d_rdata, p_rdata;
  logic c_req, c_ready, c_we, c_wready, c_wvalid, c_rvalid, c_rlast;
  logic [22:0] c_word_addr;
  logic [3:0] c_len, c_wbe;
  logic [31:0] c_wdata, c_rdata;
  logic busy = 0, writing = 0, blocked = 1, traffic = 0;
  logic [22:0] address;
  integer age, remaining, cycle = 0, b_words;
  integer accepted[1:4];
  integer i_done = 0, d_done = 0, b_done = 0, p_done = 0;

  mem_arbiter dut (
      .clk(clk),
      .rst(rst),
      .i_req(i_req),
      .i_we(1'b0),
      .i_word_addr(23'd1),
      .i_len(4'd0),
      .i_ready(i_ready),
      .i_wvalid(1'b0),
      .i_wdata(32'd0),
      .i_wbe(4'd0),
      .i_rvalid(i_rvalid),
      .i_rdata(i_rdata),
      .i_rlast(i_rlast),
      .d_req(d_req),
      .d_we(1'b0),
      .d_word_addr(23'd2),
      .d_len(4'd0),
      .d_ready(d_ready),
      .d_wready(d_wready),
      .d_wvalid(1'b0),
      .d_wdata(32'd0),
      .d_wbe(4'd0),
      .d_rvalid(d_rvalid),
      .d_rdata(d_rdata),
      .d_rlast(d_rlast),
      .b_req(b_req),
      .b_we(1'b1),
      .b_word_addr(23'd3),
      .b_len(4'd1),
      .b_ready(b_ready),
      .b_wready(b_wready),
      .b_wvalid(b_wvalid),
      .b_wdata(32'h55667788),
      .b_wbe(4'hf),
      .p_req(p_req),
      .p_word_addr(23'd4),
      .p_ready(p_ready),
      .p_rvalid(p_rvalid),
      .p_rdata(p_rdata),
      .p_rlast(p_rlast),
      .c_req(c_req),
      .c_ready(c_ready),
      .c_we(c_we),
      .c_word_addr(c_word_addr),
      .c_len(c_len),
      .c_wready(c_wready),
      .c_wvalid(c_wvalid),
      .c_wdata(c_wdata),
      .c_wbe(c_wbe),
      .c_rvalid(c_rvalid),
      .c_rdata(c_rdata),
      .c_rlast(c_rlast)
  );

  assign c_ready = !busy && !blocked;
  assign c_wready = busy && writing && !cycle[0];
  assign c_rvalid = busy && !writing && age == 1;
  assign c_rlast = c_rvalid;
  assign c_rdata = 32'ha5000000 | {9'd0, address};

  always @(posedge clk) begin
    if (rst) begin
      busy <= 0;
      writing <= 0;
      age <= 0;
      remaining <= 0;
      cycle <= 0;
      for (int k = 1; k <= 4; k++) accepted[k] <= 0;
    end else begin
      cycle <= cycle + 1;
      if (c_req && c_ready) begin
        if (c_word_addr < 1 || c_word_addr > 4 || c_we != (c_word_addr == 3) ||
            c_len != ((c_word_addr == 3) ? 1 : 0))
          $fatal(1, "incorrect command routing");
        if (({3'd0, i_ready} + {3'd0, d_ready} + {3'd0, b_ready} + {3'd0, p_ready}) != 1)
          $fatal(1, "command handshake was not exclusive");
        accepted[c_word_addr] <= accepted[c_word_addr] + 1;
        address <= c_word_addr;
        writing <= c_we;
        remaining <= c_len + 1;
        age <= 3;
        busy <= 1;
      end else if (busy && writing && c_wvalid && c_wready) begin
        if (c_wdata != 32'h55667788 || c_wbe != 4'hf) $fatal(1, "write burst mixed clients");
        if (remaining == 1) busy <= 0;
        else remaining <= remaining - 1;
      end else if (busy && !writing) begin
        if (age == 1) busy <= 0;
        else age <= age - 1;
      end
      if (c_rvalid) begin
        if ((address == 1 && (!i_rvalid || d_rvalid || p_rvalid || i_rdata != c_rdata)) ||
            (address == 2 && (!d_rvalid || i_rvalid || p_rvalid || d_rdata != c_rdata)) ||
            (address == 4 && (!p_rvalid || i_rvalid || d_rvalid || p_rdata != c_rdata)))
          $fatal(1, "read response changed owner");
      end
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      i_req <= 0;
      d_req <= 0;
      b_req <= 0;
      p_req <= 0;
      b_wvalid <= 0;
      i_done <= 0;
      d_done <= 0;
      p_done <= 0;
      b_done <= 0;
      b_words <= 0;
    end else if (traffic) begin
      if (i_req && i_ready) i_req <= 0;
      if (d_req && d_ready) d_req <= 0;
      if (p_req && p_ready) p_req <= 0;
      if (i_rvalid && i_rlast) begin
        i_req <= 1;
        i_done <= i_done + 1;
      end
      if (d_rvalid && d_rlast) begin
        d_req <= 1;
        d_done <= d_done + 1;
      end
      if (p_rvalid && p_rlast) begin
        p_req <= 1;
        p_done <= p_done + 1;
      end
      if (b_req && b_ready) begin
        b_req <= 0;
        b_wvalid <= 1;
        b_words <= 2;
      end
      if (b_wvalid && b_wready) begin
        if (b_words == 1) begin
          b_wvalid <= 0;
          b_req <= 1;
          b_done <= b_done + 1;
        end else b_words <= b_words - 1;
      end
    end
  end

  task automatic tick;
    @(posedge clk);
    #1;
    @(negedge clk);
  endtask
  initial begin
    repeat (5000) @(posedge clk);
    $fatal(1, "arbiter timeout or starvation");
  end
  initial begin
    repeat (2) tick();
    rst = 0;
    p_req = 1;
    repeat (3) tick();
    if (!c_req || c_word_addr != 4) $fatal(1, "blocked grant was not selected");
    p_req = 0;
    i_req = 1;
    repeat (2) tick();
    blocked = 0;
    #1;
    while (!i_ready) tick();
    tick();
    i_req = 0;
    while (!i_rvalid) tick();
    tick();
    if (accepted[4] != 0 || accepted[1] != 1) $fatal(1, "withdrawn request was accepted");
    rst = 1;
    repeat (2) tick();
    rst = 0;
    traffic = 1;
    i_req = 1;
    d_req = 1;
    p_req = 1;
    b_req = 1;
    while (i_done < 8 || d_done < 8 || p_done < 8 || b_done < 8) tick();
    if (i_done > 9 || d_done > 9 || p_done > 9 || b_done > 9)
      $fatal(1, "round-robin service was unfair");
    $display("tb_mem_arbiter: PASS (cancellation, stalled bursts, four-client fairness)");
    $finish;
  end
endmodule
