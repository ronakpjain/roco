// Unit test for the Sv32 MMU.
//
// The page-table walker port is backed by a small physical memory model
// that returns one PTE per cycle. Page tables are placed at 0x1000_1000
// (root) and 0x1000_2000 (level 0), and virtual address zero is mapped to
// physical SDRAM at 0x1000_0000.

`timescale 1ns / 1ps
`include "axi4_defs.svh"

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

  axi4_ar_t ptw_ar;
  axi4_r_t ptw_r;
  logic ptw_r_ready;
  logic p_req;
  assign p_req = ptw_ar.valid;
  logic [22:0] p_word_addr;
  assign p_word_addr = ptw_ar.addr[24:2];
  logic p_ready;
  logic p_rvalid;
  logic [31:0] p_rdata;
  logic p_rlast;

  logic [31:0] pte_mem[0:MEM_WORDS-1];
  int unsigned cycles;
  int unsigned walk_reads;
  int unsigned i;
  int unsigned n;

  roco_cpu_mmu u_mmu (
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
      .ptw_ar(ptw_ar),
      .p_ready(p_ready),
      .ptw_r(ptw_r),
      .ptw_r_ready(ptw_r_ready)
  );

  always begin
    clk = 1'b0;
    #5;
    clk = 1'b1;
    #5;
  end

  // Page-table memory: one-cycle read latency.
  initial p_ready = 1'b1;
  assign p_rlast = 1'b1;
  assign ptw_r = {p_rvalid, 4'd0, p_rdata, `AXI4_RESP_OKAY, p_rlast};
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
      $fatal(1, "tb_mmu: FAIL: %s", message);
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

  task automatic cancel_walk(input logic fetch, input logic redirect, input int target_state,
                             input logic blocked = 1'b0, input logic invalid_pte = 1'b0);
    int unsigned k;
    axi4_ar_t held_ar;
    logic [1:0] saved_priv;
    // Drive cancellation between clock edges, including on request
    // acceptance, each PTE response and the TLB installation edge.
    @(negedge clk);
    i_req = 1'b0;
    d_req = 1'b0;
    flush = 1'b1;
    @(negedge clk);
    flush = 1'b0;
    pte_mem[23'h400] = (LEAF_PPN << 10) | 32'h1;
    pte_mem[23'h800] = (DATA_PPN << 10) | 32'hdf;
    if (invalid_pte) begin
      if (target_state == 2) pte_mem[23'h400] = '0;
      else pte_mem[23'h800] = '0;
    end
    i_vaddr = 32'h0000_0010;
    d_vaddr = 32'h0000_0010;
    d_we = 1'b0;
    i_req = fetch;
    d_req = !fetch;
    k = 0;
    while ((int'(u_mmu.wstate) != target_state) && (k < 40)) begin
      @(negedge clk);
      k = k + 1;
    end
    check(int'(u_mmu.wstate) == target_state, "walk did not reach cancellation point");
    held_ar = ptw_ar;
    p_ready = !blocked;
    flush = !redirect;
    iflush = redirect;
    i_req = 1'b0;
    d_req = 1'b0;
    @(negedge clk);
    check(!i_fault && !d_fault, "cancellation edge reported a stale fault");
    if (blocked && held_ar.valid) begin
      saved_priv = priv_fetch;
      if (fetch && redirect) begin
        // A trap into M-mode bypasses translation, but the discarded
        // instruction walk still owns the fetch hold until it drains.
        iflush = 1'b0;
        priv_fetch = 2'b11;
        i_req = 1'b1;
        #1;
        check(i_hit && i_busy && !ic_req, "bare fetch escaped a canceled walk hold");
      end
      // A warm reset can keep flush high through the address handshake
      // and the response, unlike an instruction redirect pulse.
      repeat (3) begin
        check(ptw_ar === held_ar, "flush changed a stalled AXI address");
        @(negedge clk);
      end
      p_ready = 1'b1;
      repeat (4) @(negedge clk);
      check(u_mmu.wstate == u_mmu.W_IDLE, "held flush did not drain the AXI read");
      if (fetch && redirect) begin
        check(i_hit && !i_busy && ic_req, "bare fetch did not resume after walk drain");
        i_req = 1'b0;
        priv_fetch = saved_priv;
      end
    end
    flush = 1'b0;
    iflush = 1'b0;
    p_ready = 1'b1;
    repeat (4) begin
      @(negedge clk);
      check(!i_fault && !d_fault, "canceled walk reported a fault");
    end
    check(u_mmu.wstate == u_mmu.W_IDLE, "canceled walker failed to drain");
    check(!i_fault && !d_fault, "canceled walk reported a fault");
    check(fetch ? (u_mmu.i_valid == '0) : (u_mmu.d_valid == '0),
          "canceled walk installed a stale translation");

    // A fresh request must walk the updated table and complete.
    pte_mem[23'h400] = (LEAF_PPN << 10) | 32'h1;
    pte_mem[23'h800] = (20'h1_0003 << 10) | 32'hdf;
    i_req = fetch;
    d_req = !fetch;
    k = 0;
    while (!(fetch ? i_hit : d_hit) && (k < 40)) begin
      @(negedge clk);
      k = k + 1;
    end
    check(fetch ? i_hit : d_hit, "translation after cancellation did not complete");
    check((fetch ? ic_addr : d_paddr) == 32'h1000_3010,
          "translation after cancellation used stale page-table data");
    i_req = 1'b0;
    d_req = 1'b0;
    pte_mem[23'h800] = (DATA_PPN << 10) | 32'hdf;
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
    // Leaf[4] -> execute-only user page, readable only with MXR.
    pte_mem[23'h804] = (DATA_PPN << 10) | 32'hd9;
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
    #1;
    check(d_hit, "same-page translation should be immediately ready");
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

    // A warm fetch translation must follow offsets without another walk,
    // but must never authorize a different privilege context.
    @(negedge clk);
    i_req = 1'b1;
    i_vaddr = 32'h0000_0200;
    #1;
    check(i_hit && ic_req && !i_busy, "same-page fetch should stay ready");
    check(ic_addr == 32'h1000_0200, "same-page fetch offset");
    priv_fetch = 2'b01;
    #1;
    check(!i_hit && !ic_req, "U fetch translation must not authorize S fetch");
    for (n = 0; (n < 4) && !i_fault; n++) @(negedge clk);
    check(i_fault && i_fault_addr == i_vaddr, "S fetch on a user page must fault");
    i_req = 1'b0;
    iflush = 1'b1;
    @(negedge clk);
    iflush = 1'b0;
    priv_fetch = 2'b00;
    i_req = 1'b1;
    wait_i_hit(20);
    check(ic_req && ic_addr == 32'h1000_0200, "U fetch should recover after redirect");
    @(negedge clk);
    i_req = 1'b0;
    flush = 1'b1;
    pte_mem[23'h800] = (20'h1_0005 << 10) | 32'hdf;
    @(negedge clk);
    flush = 1'b0;
    i_req = 1'b1;
    #1;
    check(!i_hit && !ic_req, "sfence must invalidate warm fetch translation");
    wait_i_hit(20);
    check(ic_addr == 32'h1000_5200, "fetch after sfence used stale physical page");
    @(negedge clk);
    i_req = 1'b0;
    flush = 1'b1;
    pte_mem[23'h800] = (DATA_PPN << 10) | 32'hdf;
    @(negedge clk);
    flush = 1'b0;

    // Warm a read translation, then change access class on the same
    // page: the registered read permission must not authorize a store.
    @(negedge clk);
    d_req = 1'b1;
    d_vaddr = 32'h0000_2000;
    d_we = 1'b0;
    wait_d_hit(20);
    @(negedge clk);
    d_we = 1'b1;
    #1;
    check(!d_hit, "cached read permission must not authorize a store");
    for (n = 0; (n < 20) && !d_fault; n = n + 1) begin
      @(posedge clk);
    end
    check(d_fault, "store to read-only page should fault");
    check(d_fault_cause == 4'd15, "store page fault cause");
    d_req = 1'b0;
    @(posedge clk);

    // A cached S-mode translation must not authorize U-mode access.
    @(negedge clk);
    priv_data = 2'b01;
    d_req = 1'b1;
    d_vaddr = 32'h0000_3000;
    d_we = 1'b0;
    wait_d_hit(20);
    @(negedge clk);
    priv_data = 2'b00;
    #1;
    check(!d_hit, "cached S permission must not authorize U mode");
    for (n = 0; (n < 20) && !d_fault; n = n + 1) begin
      @(posedge clk);
    end
    check(d_fault, "user load from supervisor page should fault");
    check(d_fault_cause == 4'd13, "load page fault cause");
    d_req = 1'b0;
    @(posedge clk);

    // SUM and MXR are part of the registered permission context.
    @(negedge clk);
    priv_data = 2'b01;
    mstatus_sum = 1'b1;
    d_req = 1'b1;
    d_vaddr = 32'h0000_0030;
    wait_d_hit(20);
    @(negedge clk);
    mstatus_sum = 1'b0;
    #1;
    check(!d_hit && d_fault, "clearing SUM must reject a cached user-page access");
    check(d_fault_cause == 4'd13, "SUM fault cause");
    d_req = 1'b0;
    @(negedge clk);
    priv_data = 2'b00;
    mstatus_mxr = 1'b1;
    d_req = 1'b1;
    d_vaddr = 32'h0000_4000;
    wait_d_hit(20);
    @(negedge clk);
    mstatus_mxr = 1'b0;
    #1;
    check(!d_hit && d_fault, "clearing MXR must reject a cached execute-only read");
    check(d_fault_cause == 4'd13, "MXR fault cause");
    d_req = 1'b0;
    @(negedge clk);

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

    // Warm the exact page/context retried after SFENCE.VMA, so the
    // test detects stale entries in either translation level.
    @(negedge clk);
    d_req = 1'b1;
    d_vaddr = 32'h0000_0010;
    d_we = 1'b1;
    wait_d_hit(20);
    @(negedge clk);
    d_req = 1'b0;
    walk_reads = 0;
    flush = 1'b1;
    @(negedge clk);
    flush = 1'b0;
    d_req = 1'b1;
    #1;
    check(!d_hit, "sfence must invalidate the registered last translation");
    wait_d_hit(20);
    check(walk_reads == 2, "sfence should force a new walk");
    d_req = 1'b0;

    for (int state_index = 1; state_index <= 5; state_index++) begin
      cancel_walk(1'b0, 1'b0, state_index);
      cancel_walk(1'b1, 1'b0, state_index);
      cancel_walk(1'b1, 1'b1, state_index);
      if ((state_index == 1) || (state_index == 3)) begin
        cancel_walk(1'b0, 1'b0, state_index, 1'b1);
        cancel_walk(1'b1, 1'b0, state_index, 1'b1);
        cancel_walk(1'b1, 1'b1, state_index, 1'b1);
      end
      if ((state_index == 2) || (state_index == 4)) begin
        cancel_walk(1'b1, 1'b0, state_index, 1'b0, 1'b1);
        cancel_walk(1'b1, 1'b1, state_index, 1'b0, 1'b1);
      end
    end

    $display("tb_mmu: PASS (%0d walks)", walk_reads);
    $finish;
  end

endmodule
