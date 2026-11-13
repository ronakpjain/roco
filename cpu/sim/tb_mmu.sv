// Unit test for the Sv32 MMU.
//
// The page-table walker port is backed by a small physical memory model
// that returns one PTE per cycle. Page tables are placed at 0x1000_1000
// (root) and 0x1000_2000 (level 0), and virtual address zero is mapped to
// physical SDRAM at 0x1000_0000.

`timescale 1ns / 1ps

module tb_mmu;

  localparam int MEM_WORDS = 16384;
  localparam logic [19:0] ROOT_PPN = 20'h1_0001;
  localparam logic [19:0] LEAF_PPN = 20'h1_0002;
  localparam logic [19:0] DATA_PPN = 20'h1_0000;

  logic clk;
  logic rst;
  logic flush;
  logic iflush;
  logic [31:0] satp;
  logic [1:0] priv_fetch;
  logic [1:0] priv_data;
  logic mstatus_sum;
  logic mstatus_mxr;

  logic i_req;
  logic [31:0] i_vaddr;
  logic i_hit;
  logic i_miss;
  logic i_busy;
  logic i_fault;
  logic [31:0] i_fault_addr;
  logic ic_req;
  logic [31:0] ic_addr;
  logic ic_rsp_valid;
  logic [31:0] ic_rsp_data;
  logic i_rsp_valid;
  logic [31:0] i_rsp_addr;
  logic [31:0] i_rsp_data;

  logic d_req;
  logic [31:0] d_vaddr;
  logic d_we;
  logic d_hit;
  logic d_fault;
  logic [3:0] d_fault_cause;
  logic [31:0] d_paddr;

  logic p_req;
  logic [22:0] p_word_addr;
  logic p_ready;
  logic p_rvalid;
  logic [31:0] p_rdata;
  logic p_rlast;

  logic [31:0] pte_mem[0:MEM_WORDS-1];
  int unsigned cycles;
  int unsigned walk_reads;
  int unsigned i;
  int unsigned n;

  rv32_mmu u_mmu (
      .clk(clk),
      .rst(rst),
      .flush(flush),
      .iflush(iflush),
      .satp(satp),
      .priv_fetch(priv_fetch),
      .priv_data(priv_data),
      .mstatus_sum(mstatus_sum),
      .mstatus_mxr(mstatus_mxr),
      .i_req(i_req),
      .i_vaddr(i_vaddr),
      .i_hit(i_hit),
      .i_miss(i_miss),
      .i_busy(i_busy),
      .i_fault(i_fault),
      .i_fault_addr(i_fault_addr),
      .ic_req(ic_req),
      .ic_addr(ic_addr),
      .ic_rsp_valid(ic_rsp_valid),
      .ic_rsp_data(ic_rsp_data),
      .i_rsp_valid(i_rsp_valid),
      .i_rsp_addr(i_rsp_addr),
      .i_rsp_data(i_rsp_data),
      .d_req(d_req),
      .d_vaddr(d_vaddr),
      .d_we(d_we),
      .d_hit(d_hit),
      .d_fault(d_fault),
      .d_fault_cause(d_fault_cause),
      .d_paddr(d_paddr),
      .p_req(p_req),
      .p_word_addr(p_word_addr),
      .p_ready(p_ready),
      .p_rvalid(p_rvalid),
      .p_rdata(p_rdata),
      .p_rlast(p_rlast)
  );

  always begin
    clk = 1'b0;
    #5;
    clk = 1'b1;
    #5;
  end

  // Page-table memory: one-cycle read latency.
  assign p_ready = 1'b1;
  assign p_rlast = 1'b1;
  always_ff @(posedge clk) begin
    p_rvalid <= p_req && p_ready;
    if (p_req && p_ready) begin
      p_rdata <= pte_mem[p_word_addr[13:0]];
      walk_reads <= walk_reads + 1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      cycles <= cycles + 1;
    end
  end

  task automatic check(input logic condition, input string message);
    if (!condition) begin
      $display("tb_mmu: FAIL: %s", message);
      $finish;
    end
  endtask

  task automatic reset_inputs;
    i_req = 1'b0;
    i_vaddr = '0;
    ic_rsp_valid = 1'b0;
    ic_rsp_data = '0;
    d_req = 1'b0;
    d_vaddr = '0;
    d_we = 1'b0;
    flush = 1'b0;
    iflush = 1'b0;
    mstatus_sum = 1'b0;
    mstatus_mxr = 1'b0;
    priv_fetch = 2'b11;
    priv_data = 2'b11;
    satp = '0;
  endtask

  task automatic wait_d_hit(input int unsigned limit);
    int unsigned k;
    #1;
    k = 0;
    while (!d_hit && (k < limit)) begin
      @(posedge clk);
      k = k + 1;
    end
    check(d_hit, "data translation did not become ready");
  endtask

  task automatic wait_i_hit(input int unsigned limit);
    int unsigned k;
    #1;
    k = 0;
    while (!i_hit && (k < limit)) begin
      @(posedge clk);
      k = k + 1;
    end
    check(i_hit, "fetch translation did not become ready");
  endtask

  initial begin
    cycles = 0;
    walk_reads = 0;
    reset_inputs();
    satp = '0;
    rst = 1'b1;
    flush = 1'b1;
    repeat (3) @(posedge clk);
    flush = 1'b0;
    rst = 1'b0;
    repeat (2) @(posedge clk);

    // Build page tables in the physical memory model.
    for (i = 0; i < MEM_WORDS; i = i + 1) begin
      pte_mem[i] = 32'd0;
    end
    // Root[0] -> level-0 table.
    pte_mem[23'h400] = (LEAF_PPN << 10) | 32'h1;
    // Leaf[0] -> 0x1000_0000, read/write/execute, user, A/D set.
    pte_mem[23'h800] = (DATA_PPN << 10) | 32'hdf;
    // Leaf[1] -> 0x1000_3000, read/write, user.
    pte_mem[23'h801] = (20'h1_0003 << 10) | 32'hdf;
    // Leaf[2] -> read-only execute page (store must fault).
    pte_mem[23'h802] = (DATA_PPN << 10) | 32'hd3;
    // Leaf[3] -> supervisor-only page (U-mode must fault).
    pte_mem[23'h803] = (DATA_PPN << 10) | 32'hcf;
    // Root[1] -> 4 MiB superpage for virtual 0x0040_0000.
    pte_mem[23'h401] = (20'h40 << 20) | 32'hdf;

    // Bypass when satp is off.
    d_req = 1'b1;
    d_vaddr = 32'h1234_5678;
    d_we = 1'b0;
    @(posedge clk);
    check(d_hit, "bypass mode should always hit");
    check(d_paddr == 32'h1234_5678, "bypass mode should pass the address through");
    check(!d_fault, "bypass mode should not fault");
    d_req = 1'b0;

    // Enable Sv32 and translate a data access through both levels.
    satp = 32'h8000_0000 | {12'd0, ROOT_PPN};
    priv_data = 2'b00;
    d_req = 1'b1;
    d_vaddr = 32'h0000_0010;
    d_we = 1'b1;
    wait_d_hit(20);
    check(d_paddr == 32'h1000_0010, "4 KiB data translation");
    check(!d_fault, "writable user page should not fault");
    check(walk_reads == 2, "walk should read two PTEs");
    d_req = 1'b0;
    @(posedge clk);

    // The TLB should now answer without another walk.
    d_req = 1'b1;
    d_vaddr = 32'h0000_0020;
    @(posedge clk);
    check(d_hit, "TLB hit after fill");
    check(d_paddr == 32'h1000_0020, "TLB hit address");
    check(walk_reads == 2, "TLB hit should not walk");
    d_req = 1'b0;
    @(posedge clk);

    // Fetch translation and virtual response tagging.
    i_req = 1'b1;
    i_vaddr = 32'h0000_0100;
    priv_fetch = 2'b00;
    wait_i_hit(20);
    check(ic_req, "fetch should issue to the I-cache");
    check(ic_addr == 32'h1000_0100, "fetch physical address");
    @(posedge clk);
    ic_rsp_valid = 1'b1;
    ic_rsp_data = 32'hdead_beef;
    #1;
    check(i_rsp_valid, "fetch response should be returned");
    check(i_rsp_addr == 32'h0000_0100, "fetch response should carry the virtual address");
    check(i_rsp_data == 32'hdead_beef, "fetch response data");
    ic_rsp_valid = 1'b0;
    i_req = 1'b0;
    @(posedge clk);

    // Read-only page: a store must fault with cause 15.
    d_req = 1'b1;
    d_vaddr = 32'h0000_2000;
    d_we = 1'b1;
    for (n = 0; (n < 20) && !d_fault; n = n + 1) begin
      @(posedge clk);
    end
    check(d_fault, "store to read-only page should fault");
    check(d_fault_cause == 4'd15, "store page fault cause");
    d_req = 1'b0;
    @(posedge clk);

    // U-mode access to a supervisor-only page must fault with cause 13.
    d_req = 1'b1;
    d_vaddr = 32'h0000_3000;
    d_we = 1'b0;
    for (n = 0; (n < 20) && !d_fault; n = n + 1) begin
      @(posedge clk);
    end
    check(d_fault, "user load from supervisor page should fault");
    check(d_fault_cause == 4'd13, "load page fault cause");
    d_req = 1'b0;
    @(posedge clk);

    // 4 MiB superpage: root-level leaf with PPN[0] == 0.
    d_req = 1'b1;
    d_vaddr = 32'h0040_2345;
    d_we = 1'b0;
    wait_d_hit(20);
    check(d_paddr == 32'h1000_2345, "4 MiB superpage translation");
    check(!d_fault, "superpage read should not fault");
    d_req = 1'b0;
    @(posedge clk);

    // Unmapped root entry: instruction page fault.
    i_req = 1'b1;
    i_vaddr = 32'h0080_0000;
    priv_fetch = 2'b00;
    for (n = 0; (n < 20) && !i_fault; n = n + 1) begin
      @(posedge clk);
    end
    check(i_fault, "unmapped fetch should fault");
    check(i_fault_addr == 32'h0080_0000, "instruction fault address");
    i_req = 1'b0;
    @(posedge clk);

    // sfence.vma drops the TLB; the next access must walk again.
    walk_reads = 0;
    flush = 1'b1;
    @(posedge clk);
    flush = 1'b0;
    d_req = 1'b1;
    d_vaddr = 32'h0000_0010;
    d_we = 1'b1;
    wait_d_hit(20);
    check(walk_reads == 2, "sfence should force a new walk");
    d_req = 1'b0;

    $display("tb_mmu: PASS (%0d walks)", walk_reads);
    $finish;
  end

endmodule
