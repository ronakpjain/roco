`timescale 1ns / 1ps
`default_nettype none

module tb_dcache;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst = 1'b1;
  logic flush = 1'b0, flush_done;
  logic lu_valid = 1'b0;
  logic [24:2] lu_addr = '0;
  logic [1:0] lu_offset = 0;
  logic [2:0] lu_funct3 = 3'b010;
  logic cm_valid = 1'b0, cm_we = 1'b0, cm_ready;
  logic [24:2] cm_addr = '0;
  logic [31:0] cm_wdata = '0, cm_rdata, cm_forward_data;
  logic [3:0] cm_be = 4'hf;
  logic mem_req, mem_we, mem_ready, mem_wvalid, mem_wready;
  logic [22:0] mem_word_addr;
  logic [3:0] mem_len, mem_wbe;
  logic [31:0] mem_wdata;
  logic mem_rvalid = 1'b0, mem_rlast = 1'b0;
  logic [31:0] mem_rdata = '0;
  logic hit_pulse, miss_pulse;

  dcache #(
      .NUM_LINES(256),
      .LINE_WORDS(4)
  ) dut (
      .*
  );

  // A burst memory with initial backpressure on reads and writebacks.
  logic [31:0] memory[0:2047];
  logic busy = 1'b0, write_transfer = 1'b0;
  logic [22:0] transfer_base = '0;
  int transfer_beat = 0, transfer_last = 0, delay_cycles = 0;
  int writebacks = 0;
  assign mem_ready = !busy;
  assign mem_wready = busy && write_transfer && (delay_cycles == 0);

  always @(posedge clk) begin
    mem_rvalid <= 1'b0;
    mem_rlast <= 1'b0;
    if (rst) begin
      busy <= 1'b0;
    end else if (!busy && mem_req) begin
      if (mem_word_addr > 23'd2044 || mem_len != 4'd3) $fatal(1, "bad burst request");
      busy <= 1'b1;
      write_transfer <= mem_we;
      transfer_base <= mem_word_addr;
      transfer_beat <= 0;
      transfer_last <= int'(mem_len);
      delay_cycles <= 2;
      if (mem_we) writebacks <= writebacks + 1;
    end else if (busy) begin
      if (delay_cycles != 0) begin
        delay_cycles <= delay_cycles - 1;
      end else if (write_transfer) begin
        if (mem_wvalid && mem_wready) begin
          for (int b = 0; b < 4; b++) begin
            if (mem_wbe[b]) memory[transfer_base+transfer_beat][8*b+:8] <= mem_wdata[8*b+:8];
          end
          if (transfer_beat == transfer_last) busy <= 1'b0;
          else transfer_beat <= transfer_beat + 1;
        end
      end else begin
        mem_rvalid <= 1'b1;
        mem_rdata <= memory[transfer_base+transfer_beat];
        mem_rlast <= (transfer_beat == transfer_last);
        if (transfer_beat == transfer_last) busy <= 1'b0;
        else transfer_beat <= transfer_beat + 1;
      end
    end
  end

  always @(negedge clk) begin
    if (!rst && cm_ready && (cm_rdata !== cm_forward_data))
      $fatal(1, "cache forwarding mirror differs from committed data");
  end

  task automatic lookup(input int word_addr);
    @(negedge clk);
    lu_valid = 1'b1;
    lu_addr = 23'(word_addr);
    @(negedge clk);
    lu_valid = 1'b0;
  endtask

  task automatic wait_ready;
    int cycles;
    cycles = 0;
    while (!cm_ready && cycles < 200) begin
      @(negedge clk);
      cycles++;
    end
    if (!cm_ready) $fatal(1, "cache response timeout");
  endtask

  task automatic ack_read(input int word_addr);
    cm_addr = 23'(word_addr);
    cm_valid = 1'b1;
    cm_we = 1'b0;
    @(negedge clk);
    cm_valid = 1'b0;
  endtask

  initial begin
    for (int w = 0; w < 2048; w++) memory[w] = 32'hc0000000 + 32'(w);
    repeat (2) @(negedge clk);
    rst = 1'b0;

    // A last-word miss also exercises read-during-write at the final fill beat.
    lookup(3);
    if (cm_ready) $fatal(1, "cold miss reported a hit");
    wait_ready();
    if (cm_rdata !== 32'hc0000003) $fatal(1, "first miss data");

    // Commit the recovered word and launch another miss on the same edge.
    cm_addr = 23'd3;
    cm_valid = 1'b1;
    lu_valid = 1'b1;
    lu_addr = 23'd1024;
    @(negedge clk);
    cm_valid = 1'b0;
    lu_valid = 1'b0;
    if (cm_ready) $fatal(1, "following miss reused the preceding ready flag");
    wait_ready();
    if (cm_rdata !== 32'hc0000400) $fatal(1, "following miss data");
    ack_read(1024);

    // An AMO may consume hit data without committing until a later cycle.
    lookup(1025);
    if (!cm_ready || cm_rdata !== 32'hc0000401) $fatal(1, "hit latency/data");
    repeat (2) @(negedge clk);
    if (!cm_ready) $fatal(1, "unacknowledged hit was dropped");

    // A partial store and lookup to the same word must forward on the edge.
    cm_valid = 1'b1;
    cm_we = 1'b1;
    cm_addr = 23'd1025;
    cm_wdata = 32'h11223344;
    cm_be = 4'b0101;
    lu_valid = 1'b1;
    lu_addr = 23'd1025;
    @(negedge clk);
    cm_valid = 1'b0;
    cm_we = 1'b0;
    lu_valid = 1'b0;
    if (!cm_ready || cm_rdata !== 32'hc0220444) $fatal(1, "store-to-load forwarding");
    ack_read(1025);
    if (memory[1025] !== 32'hc0000401) $fatal(1, "store bypassed write-back policy");

    // Evict the dirty alias and check that all writeback data reached memory.
    lookup(0);
    wait_ready();
    if (cm_rdata !== 32'hc0000000) $fatal(1, "dirty eviction refill data");
    if (memory[1025] !== 32'hc0220444 || writebacks != 1) $fatal(1, "dirty eviction writeback");
    ack_read(0);

    lookup(1);
    wait_ready();
    cm_valid = 1'b1;
    cm_we = 1'b1;
    cm_addr = 23'd1;
    cm_wdata = 32'h55aa55aa;
    cm_be = 4'hf;
    @(negedge clk);
    cm_valid = 1'b0;
    cm_we = 1'b0;
    flush = 1'b1;
    for (int c = 0; c < 2000 && !flush_done; c++) @(negedge clk);
    if (!flush_done || memory[1] !== 32'h55aa55aa || writebacks != 2) begin
      $fatal(1, "flush did not write the dirty line");
    end
    flush = 1'b0;
    // Every forwarding bank sees the same low address. Warm them all,
    // then reverse the order to catch a stale or truncated bank selector.
    for (int bank = 0; bank < 16; bank++) begin
      lookup(bank * 64 + 2);
      wait_ready();
      if (cm_rdata !== (32'hc0000000 + 32'(bank * 64 + 2))) $fatal(1, "bank refill data");
      ack_read(bank * 64 + 2);
    end
    for (int bank = 15; bank >= 0; bank--) begin
      lookup(bank * 64 + 2);
      if (!cm_ready || cm_forward_data !== (32'hc0000000 + 32'(bank * 64 + 2)))
        $fatal(1, "registered forwarding bank selection");
      ack_read(bank * 64 + 2);
    end
    // Matching offsets in different banks must not forward a store.
    lookup(2);
    if (!cm_ready) $fatal(1, "store bank was not warm");
    cm_valid = 1'b1;
    cm_we = 1'b1;
    cm_addr = 23'd2;
    cm_wdata = 32'hdeadbeef;
    cm_be = 4'b0101;
    lu_valid = 1'b1;
    lu_addr = 23'd962;
    @(negedge clk);
    cm_valid = 1'b0;
    cm_we = 1'b0;
    lu_valid = 1'b0;
    if (!cm_ready || cm_forward_data !== 32'hc00003c2) $fatal(1, "store forwarded across banks");
    ack_read(962);
    lookup(2);
    if (!cm_ready || cm_forward_data !== 32'hc0ad00ef) $fatal(1, "partial store bank data");
    ack_read(2);
    $display("tb_dcache: PASS");
    $finish;
  end
endmodule
