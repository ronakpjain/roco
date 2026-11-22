// Sv32 memory management unit.
//
// Two direct-mapped TLBs translate instruction and data virtual addresses.
// A miss starts a shared hardware page-table walker that reads two PTEs
// through the physical page-walker port, checks the Sv32 permission
// rules, and fills the TLB. Page faults are reported to the pipeline with
// the faulting virtual address; software-managed A/D bits are required to
// be set in the PTE.
//
// Translation is active only when satp.MODE is Sv32 and the effective
// privilege is S or U. M-mode fetches bypass translation; M-mode data
// accesses translate only when mstatus.MPRV selects an S/U mode. SUM and
// MXR are applied at lookup time. sfence.vma and any satp write invalidate
// all entries, so ASIDs are accepted but do not have to tag the fast lookup
// path. A 4 MiB superpage is cached as the specific 4 KiB translation that
// caused the walk.
//
// Physical addresses are the 32-bit subset of the 34-bit Sv32 physical
// address space used by the SoC: PPN bits 21:20 are ignored. Page tables
// must live in the SDRAM window because the walker reads through the
// SDRAM arbiter.

`default_nettype none
`include "roco_cpu_defs.svh"
`include "axi4_defs.svh"

module roco_cpu_mmu #(
    parameter int TLB_ENTRIES = 16
) (
  input logic clk,
  input logic rst,
  /* sfence.vma or a satp write: invalidate all translations. */
  input logic flush,
  /* Fetch redirect: discard a pending fetch walk/fault. */
  input logic iflush,
  input logic [31:0] satp,
  input logic [1:0] priv_fetch,
  input logic [1:0] priv_data,
  input logic mstatus_sum,
  input logic mstatus_mxr,
  /* Instruction fetch side. */
  input logic i_req,
  input logic [31:0] i_vaddr,
  output logic i_hit,
  output logic i_miss,
  output logic i_busy,
  output logic i_fault,
  output logic [31:0] i_fault_addr,
  output logic ic_req,
  output logic [31:0] ic_addr,
  input logic ic_rsp_valid,
  input logic [31:0] ic_rsp_data,
  output logic i_rsp_valid,
  output logic [31:0] i_rsp_addr,
  output logic [31:0] i_rsp_data,
  /* Data side. */
  input logic d_req,
  input logic [31:0] d_vaddr,
  input logic d_we,
  output logic d_hit,
  output logic d_fault,
  output logic [3:0] d_fault_cause,
  output logic [31:0] d_paddr,
  /* Physical page-table walker port. */
  output axi4_ar_t ptw_ar,
  input logic p_ready,
  input axi4_r_t ptw_r,
  output logic ptw_r_ready
);

  // Break the SDRAM/arbiter route before interpreting a PTE. Flush
  // handling drains this registered response just like an outstanding
  // bus response, so cancellation still wins over installation/faults.
  logic [31:0] pte_data_q;
  logic pte_valid_q;
  always_ff @(posedge clk) pte_data_q <= ptw_r.resp == `AXI4_RESP_OKAY ? ptw_r.data : 32'd0;
  always_ff @(posedge clk or posedge rst) begin
    if (rst) pte_valid_q <= 1'b0;
    else pte_valid_q <= ptw_r.valid && ptw_r.last;
  end

  localparam logic [1:0] PRIV_U = `RV32_PRIV_U;
  localparam logic [1:0] PRIV_S = `RV32_PRIV_S;
  localparam logic [1:0] PRIV_M = `RV32_PRIV_M;
  localparam int IDX_BITS = $clog2(TLB_ENTRIES);
  localparam int TAG_BITS = 20 - IDX_BITS;
  localparam int P_A = TAG_BITS + 20;
  localparam int P_D = TAG_BITS + 21;
  localparam int P_U = TAG_BITS + 22;
  localparam int P_X = TAG_BITS + 23;
  localparam int P_W = TAG_BITS + 24;
  localparam int P_R = TAG_BITS + 25;
  localparam int TLB_W = TAG_BITS + 26;
  localparam logic [31:0] SDRAM_BASE = 32'h1000_0000;
  localparam logic [31:0] SDRAM_LIMIT = 32'h1200_0000;

  typedef enum logic [2:0] {
    W_IDLE,
    W_PTE1_REQ,
    W_PTE1_WAIT,
    W_PTE0_REQ,
    W_PTE0_WAIT,
    W_INSTALL
  } walk_state_t;

  typedef enum logic [1:0] {
    R_NONE,
    R_INSTALL,
    R_NEXT,
    R_FAULT
  } result_t;

  // A TLB word is {r, w, x, u, d, a, ppn[19:0], vpn_tag}. Keeping it in
  // one LUTRAM word shortens the tag-compare and physical-address path.
  logic [TLB_ENTRIES-1:0] i_valid;
  logic [TLB_ENTRIES-1:0] d_valid;
  logic [TLB_W-1:0] itlb[0:TLB_ENTRIES-1];
  logic [TLB_W-1:0] dtlb[0:TLB_ENTRIES-1];

  walk_state_t wstate;
  logic w_is_if;
  logic w_is_store;
  logic w_discard;
  logic [31:0] w_vaddr;
  logic [1:0] w_priv;
  logic [31:0] w_pte_addr;
  logic [TLB_W-1:0] w_install_word;

  logic i_miss_pending;
  logic d_miss_pending;
  logic i_fault_pending;
  logic d_fault_pending;
  logic [31:0] i_fault_vaddr;
  logic [19:0] d_fault_vpn;
  logic [3:0] d_fault_cause_q;

  logic i_translate;
  logic d_translate;
  logic [19:0] d_vpn;
  logic [IDX_BITS-1:0] i_idx;
  logic [IDX_BITS-1:0] d_idx;
  logic [IDX_BITS-1:0] w_idx;
  logic [TAG_BITS-1:0] i_tag;
  logic [TAG_BITS-1:0] d_tag;
  logic [TLB_W-1:0] i_ent;
  logic i_tag_hit;
  logic i_hot_valid, i_hot_match;
  logic [19:0] i_hot_vpn, i_hot_ppn;
  logic [1:0] i_hot_priv;
  logic d_tag_hit;
  logic i_perm_ok;
  logic d_perm_ok;
  logic i_perm_fault;
  logic d_perm_fault;
  logic [19:0] d_ppn;
  logic [TLB_ENTRIES-1:0] d_way_tags, d_way_allowed;
  logic [19:0] d_way_ppn[0:TLB_ENTRIES-1];
  logic d_cached_hit;
  assign d_cached_hit = d_perm_ok;
  logic [31:0] level0_pte_addr;
  logic [19:0] pte_ppn;
  logic [19:0] leaf_ppn_4k;
  logic [19:0] leaf_ppn_4m;
  logic pte_range_ok;
  logic walk_result_valid;
  logic walk_result_perm_ok;
  logic walk_result_leaf;
  result_t walk_result;
  logic [31:0] i_req_vaddr;
  logic i_rsp_armed;
  logic [10:0] unused_satp_asid_ppn;
  assign unused_satp_asid_ppn = satp[30:20];


  assign i_translate = satp[31] && (priv_fetch != PRIV_M);
  assign d_translate = satp[31] && (priv_data != PRIV_M);
  assign d_vpn = d_vaddr[31:12];
  assign i_idx = i_vaddr[IDX_BITS+11:12];
  assign d_idx = d_vaddr[IDX_BITS+11:12];
  assign w_idx = w_vaddr[IDX_BITS+11:12];
  assign i_tag = i_vaddr[31:12+IDX_BITS];
  assign d_tag = d_vaddr[31:12+IDX_BITS];

  always_comb begin
    i_ent = itlb[i_idx];
  end

  function automatic logic in_sdram(logic [31:0] addr);
    in_sdram = (addr >= SDRAM_BASE) && (addr < SDRAM_LIMIT);
  endfunction

  function automatic logic tlb_perm_ok(logic a_bit, r_bit, w_bit, x_bit, u_bit, d_bit,
                                       logic is_fetch, logic is_store, logic [1:0] priv, logic sum,
                                       logic mxr);
    logic ok;
    ok = a_bit;
    if (is_fetch) begin
      ok = ok && x_bit;
      if (priv == PRIV_U) begin
        ok = ok && u_bit;
      end else if (priv == PRIV_S) begin
        ok = ok && !u_bit;
      end
    end else begin
      if (is_store) begin
        ok = ok && w_bit && d_bit;
      end else begin
        ok = ok && (r_bit || (mxr && x_bit));
      end
      if (priv == PRIV_U) begin
        ok = ok && u_bit;
      end else if ((priv == PRIV_S) && u_bit) begin
        ok = ok && sum;
      end
    end
    tlb_perm_ok = ok;
  endfunction

  function automatic logic pte_perm_ok(logic [31:0] pte, logic is_fetch, logic is_store,
                                       logic [1:0] priv, logic sum, logic mxr);
    logic ok;
    logic [25:0] unused_pte_bits;
    unused_pte_bits = {pte[31:8], pte[5], pte[0]};
    ok = pte[6];
    if (is_fetch) begin
      ok = ok && pte[3];
      if (priv == PRIV_U) begin
        ok = ok && pte[4];
      end else if (priv == PRIV_S) begin
        ok = ok && !pte[4];
      end
    end else begin
      if (is_store) begin
        ok = ok && pte[2] && pte[7];
      end else begin
        ok = ok && (pte[1] || (mxr && pte[3]));
      end
      if (priv == PRIV_U) begin
        ok = ok && pte[4];
      end else if ((priv == PRIV_S) && pte[4]) begin
        ok = ok && sum;
      end
    end
    pte_perm_ok = ok;
  endfunction

  assign i_tag_hit = i_valid[i_idx] && (i_ent[TAG_BITS-1:0] == i_tag);
  // Compare constant entries in parallel, before selecting the PPN.
  // Warm page and permission-context changes do not need a register cycle.
  for (genvar way = 0; way < TLB_ENTRIES; way = way + 1) begin : g_d_lookup
    assign d_way_tags[way] = d_valid[way] && (d_idx == IDX_BITS'(way)) &&
                             (dtlb[way][TAG_BITS-1:0] == d_tag);
    assign d_way_allowed[way] = d_way_tags[way] && tlb_perm_ok(
        dtlb[way][P_A],
        dtlb[way][P_R],
        dtlb[way][P_W],
        dtlb[way][P_X],
        dtlb[way][P_U],
        dtlb[way][P_D],
        1'b0,
        d_we,
        priv_data,
        mstatus_sum,
        mstatus_mxr
    );
    // Address selection runs alongside tag and permission validation.
    // The cache accepts the address only when d_hit validates the entry.
    assign d_way_ppn[way] = {20{d_idx == IDX_BITS'(way)}} & dtlb[way][TAG_BITS+19:TAG_BITS];
  end
  assign d_tag_hit = |d_way_tags;
  assign i_perm_ok = tlb_perm_ok(
      i_ent[P_A],
      i_ent[P_R],
      i_ent[P_W],
      i_ent[P_X],
      i_ent[P_U],
      i_ent[P_D],
      1'b1,
      1'b0,
      priv_fetch,
      mstatus_sum,
      mstatus_mxr
  );
  assign d_perm_ok = |d_way_allowed;
  assign i_perm_fault = i_translate && i_req && i_tag_hit && !i_perm_ok;
  assign d_perm_fault = d_translate && d_req && !d_cached_hit && d_tag_hit && !d_perm_ok;

  always_comb begin
    d_ppn = '0;
    for (int way = 0; way < TLB_ENTRIES; way = way + 1) d_ppn |= d_way_ppn[way];
  end

  // Keep a validated page translation in registers on the cache path.
  // A page/context change refills it from the main TLB in one cycle;
  // instruction streams within a page bypass the TLB RAM and permissions.
  assign i_hot_match = i_hot_valid && (i_hot_vpn == i_vaddr[31:12]) && (i_hot_priv == priv_fetch);
  always_ff @(posedge clk) begin
    if (!i_hot_match) begin
      i_hot_vpn <= i_vaddr[31:12];
      i_hot_ppn <= i_ent[TAG_BITS+19:TAG_BITS];
      i_hot_priv <= priv_fetch;
    end
  end
  always_ff @(posedge clk or posedge rst) begin
    if (rst) i_hot_valid <= 1'b0;
    else if (flush) i_hot_valid <= 1'b0;
    else if ((wstate == W_INSTALL) && !w_discard && w_is_if &&
             (w_idx == (i_hot_match ? i_hot_vpn[IDX_BITS-1:0] : i_idx)))
      i_hot_valid <= 1'b0;
    else if (!i_hot_match) i_hot_valid <= i_req && i_translate && i_tag_hit && i_perm_ok;
  end
  assign i_hit = !i_translate || i_hot_match;
  assign i_miss = i_translate && i_req && !i_tag_hit;
  assign d_hit = !d_translate || d_cached_hit;
  assign ic_req = i_req && i_hit && !i_busy;
  assign ic_addr = i_translate ? {i_hot_ppn, i_vaddr[11:0]} : i_vaddr;
  assign i_busy = i_fault_pending || i_miss_pending || ((wstate != W_IDLE) && w_is_if) ||
                  (i_translate && i_req && !i_hot_match);
`ifdef ROCO_RVFI_NO_DIV_INDUCTION
  // The bare reset-to-reset fetch environment must also exclude walks
  // that carry an arbitrary in-flight translation into the induction step.
  always @(posedge clk) begin
    if (!rst) begin
      assert (!i_translate && !d_translate);
      assert (wstate == W_IDLE && !i_miss_pending && !d_miss_pending);
      assert (!i_fault_pending && !d_fault_pending);
    end
  end
`endif
  assign i_fault = i_fault_pending;
  assign i_fault_addr = i_fault_vaddr;
  assign i_rsp_valid = ic_rsp_valid && i_rsp_armed;
  assign i_rsp_addr = i_req_vaddr;
  assign i_rsp_data = ic_rsp_data;
  // Cache hits return on the following cycle. Their virtual tag can
  // refresh independently of late acceptance and redirect qualification.
  always_ff @(posedge clk) i_req_vaddr <= i_vaddr;
  assign d_paddr = d_translate ? {d_ppn, d_vaddr[11:0]} : d_vaddr;
  assign d_fault = d_translate && !d_cached_hit &&
                   (d_perm_fault || (d_fault_pending && d_req && (d_vpn == d_fault_vpn)));
  assign d_fault_cause = d_fault_pending && !d_perm_fault ? d_fault_cause_q :
                         (d_we ? 4'd15 : 4'd13);

  axi4_ar_t ptw_ar_payload;
  assign ptw_ar = ptw_ar_payload;
  assign ptw_ar_payload.valid = (wstate == W_PTE1_REQ) || (wstate == W_PTE0_REQ);
  assign ptw_ar_payload.addr = w_pte_addr;
  assign ptw_ar_payload.id = '0;
  assign ptw_ar_payload.len = '0;
  assign ptw_ar_payload.size = 3'd2;
  assign ptw_ar_payload.burst = `AXI4_BURST_INCR;
  assign ptw_ar_payload.prot = 3'b001;
  assign ptw_r_ready = 1'b1;
`ifdef ROCO_SOC_RAM_FORMAL
  always_ff @(posedge clk) begin
    if (!rst && wstate != W_IDLE) assert (in_sdram(w_pte_addr) && w_pte_addr[1:0] == 0);
  end
`endif

  assign pte_ppn = pte_data_q[29:10];
  assign level0_pte_addr = {pte_ppn, w_vaddr[21:12], 2'b00};
  assign leaf_ppn_4k = pte_data_q[29:10];
  assign leaf_ppn_4m = {pte_data_q[29:20], w_vaddr[21:12]};
  assign pte_range_ok = in_sdram(level0_pte_addr);

  always_comb begin
    walk_result = R_NONE;
    walk_result_leaf = pte_data_q[1] || pte_data_q[3];
    walk_result_perm_ok =
        pte_perm_ok(pte_data_q, w_is_if, w_is_store, w_priv, mstatus_sum, mstatus_mxr);
    walk_result_valid = pte_data_q[0] && !(pte_data_q[2] && !pte_data_q[1]);
    if (pte_valid_q && (wstate == W_PTE1_WAIT)) begin
      if (!walk_result_valid) begin
        walk_result = R_FAULT;
      end else if (walk_result_leaf) begin
        if (!walk_result_perm_ok || (pte_data_q[19:10] != 10'd0)) begin
          walk_result = R_FAULT;
        end else begin
          walk_result = R_INSTALL;
        end
      end else if (pte_range_ok && !(pte_data_q[7] || pte_data_q[6] || pte_data_q[4])) begin
        // U, A and D are reserved in an Sv32 non-leaf PTE.
        walk_result = R_NEXT;
      end else begin
        walk_result = R_FAULT;
      end
    end else if (pte_valid_q && (wstate == W_PTE0_WAIT)) begin
      if (!walk_result_valid || !walk_result_leaf || !walk_result_perm_ok) begin
        walk_result = R_FAULT;
      end else begin
        walk_result = R_INSTALL;
      end
    end
  end

  logic start_data_walk;
  assign start_data_walk = d_miss_pending && d_translate && d_req;

  // Walker state determines whether this payload is live. Capture idle
  // candidates even when a flush cancels the request, keeping redirect
  // arbitration off the physical request-address register enable.
  always_ff @(posedge clk) begin
    if (wstate == W_IDLE) begin
      w_pte_addr <= start_data_walk ? {satp[19:0], d_vaddr[31:22], 2'b00} :
                                    {satp[19:0], i_vaddr[31:22], 2'b00};
    end else if ((wstate == W_PTE1_WAIT) && pte_valid_q && (walk_result == R_NEXT)) begin
      w_pte_addr <= level0_pte_addr;
    end
  end

  // Walker state/validity determines whether these payloads are live.
  // Flush may discard a candidate, but need not gate its wide registers.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      w_vaddr <= '0;
      w_priv <= PRIV_M;
      w_is_if <= 1'b0;
      w_is_store <= 1'b0;
      w_install_word <= '0;
    end else begin
      if (wstate == W_IDLE) begin
        w_vaddr <= start_data_walk ? d_vaddr : i_vaddr;
        w_priv <= start_data_walk ? priv_data : priv_fetch;
        w_is_if <= !start_data_walk;
        w_is_store <= start_data_walk && d_we;
      end
      if (pte_valid_q && ((wstate == W_PTE1_WAIT) || (wstate == W_PTE0_WAIT))) begin
        w_install_word <= {
          pte_data_q[1],
          pte_data_q[2],
          pte_data_q[3],
          pte_data_q[4],
          pte_data_q[7],
          pte_data_q[6],
          (wstate == W_PTE1_WAIT) ? leaf_ppn_4m : leaf_ppn_4k,
          w_vaddr[31:12+IDX_BITS]
        };
      end
    end
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      wstate <= W_IDLE;
      w_discard <= 1'b0;
      i_miss_pending <= 1'b0;
      d_miss_pending <= 1'b0;
      i_fault_pending <= 1'b0;
      d_fault_pending <= 1'b0;
      i_fault_vaddr <= '0;
      d_fault_vpn <= '0;
      d_fault_cause_q <= 4'd13;
      i_rsp_armed <= 1'b0;
    end else begin
      // Fault indicators are one-cycle pulses; a new fault sets them again.
      i_fault_pending <= 1'b0;
      if (!d_req || (d_vpn != d_fault_vpn)) begin
        d_fault_pending <= 1'b0;
      end

      if (ic_req) begin
        i_rsp_armed <= 1'b1;
      end
      if (flush || iflush) begin
        i_rsp_armed <= 1'b0;
      end

      if (flush) begin
        i_miss_pending <= 1'b0;
        d_miss_pending <= 1'b0;
        i_fault_pending <= 1'b0;
        d_fault_pending <= 1'b0;
        if (wstate != W_IDLE) begin
          w_discard <= 1'b1;
        end
        // AXI VALID must remain asserted even if a flush arrives before
        // acceptance. Hold the request and drain its eventual response.
        case (wstate)
          W_PTE1_REQ: begin
            if (p_ready) wstate <= W_PTE1_WAIT;
          end
          W_PTE0_REQ: begin
            if (p_ready) wstate <= W_PTE0_WAIT;
          end
          W_PTE1_WAIT, W_PTE0_WAIT: begin
            if (pte_valid_q) begin
              wstate <= W_IDLE;
            end
          end
          default: wstate <= W_IDLE;
        endcase
      end else begin
        if (iflush) begin
          i_miss_pending <= 1'b0;
          i_fault_pending <= 1'b0;
          if ((wstate != W_IDLE) && w_is_if) begin
            w_discard <= 1'b1;
          end
        end

        // Capture translation misses. IF holds its PC until the walker
        // answers, so the address is stable for the whole walk.
        if (i_req && !iflush && i_translate && !i_tag_hit && !i_miss_pending && !i_fault_pending &&
            !(w_is_if && (wstate != W_IDLE))) begin
          i_miss_pending <= 1'b1;
        end
        if (d_req && d_translate && !d_cached_hit && !d_tag_hit && !d_miss_pending && !d_fault_pending &&
            !(!w_is_if && (wstate != W_IDLE))) begin
          d_miss_pending <= 1'b1;
        end
        if (!i_translate) begin
          i_miss_pending <= 1'b0;
        end
        if (!d_translate || !d_req) begin
          d_miss_pending <= 1'b0;
        end

        // Permission faults on a TLB hit are reported without a walk.
        if (i_perm_fault && !iflush && !i_fault_pending) begin
          i_fault_pending <= 1'b1;
          i_fault_vaddr <= i_vaddr;
          i_miss_pending <= 1'b0;
        end
        if (d_perm_fault && !d_fault_pending) begin
          d_fault_pending <= 1'b1;
          d_fault_vpn <= d_vpn;
          d_fault_cause_q <= d_we ? 4'd15 : 4'd13;
          d_miss_pending <= 1'b0;
        end

        case (wstate)
          W_IDLE: begin
            w_discard <= 1'b0;
            if (start_data_walk) begin
              if (in_sdram({satp[19:0], d_vaddr[31:22], 2'b00})) begin
                wstate <= W_PTE1_REQ;
              end else begin
                d_miss_pending <= 1'b0;
                d_fault_pending <= 1'b1;
                d_fault_vpn <= d_vaddr[31:12];
                d_fault_cause_q <= d_we ? 4'd15 : 4'd13;
              end
            end else if (i_miss_pending && !iflush && i_translate && i_req) begin
              if (in_sdram({satp[19:0], i_vaddr[31:22], 2'b00})) begin
                wstate <= W_PTE1_REQ;
              end else begin
                i_miss_pending <= 1'b0;
                i_fault_pending <= 1'b1;
                i_fault_vaddr <= i_vaddr;
              end
            end
          end
          W_PTE1_REQ: begin
            if (p_ready) begin
              wstate <= W_PTE1_WAIT;
            end
          end
          W_PTE1_WAIT: begin
            if (pte_valid_q) begin
              wstate <= W_IDLE;
              if (w_discard || (iflush && w_is_if)) begin
                if (w_is_if) begin
                  i_miss_pending <= 1'b0;
                end else begin
                  d_miss_pending <= 1'b0;
                end
              end else if (walk_result == R_INSTALL) begin
                wstate <= W_INSTALL;
              end else if (walk_result == R_NEXT) begin
                wstate <= W_PTE0_REQ;
              end else begin
                if (w_is_if) begin
                  i_miss_pending <= 1'b0;
                  i_fault_pending <= 1'b1;
                  i_fault_vaddr <= w_vaddr;
                end else begin
                  d_miss_pending <= 1'b0;
                  d_fault_pending <= 1'b1;
                  d_fault_vpn <= w_vaddr[31:12];
                  d_fault_cause_q <= w_is_store ? 4'd15 : 4'd13;
                end
              end
            end
          end
          W_PTE0_REQ: begin
            if (p_ready) begin
              wstate <= W_PTE0_WAIT;
            end
          end
          W_PTE0_WAIT: begin
            if (pte_valid_q) begin
              wstate <= W_IDLE;
              if (w_discard || (iflush && w_is_if)) begin
                if (w_is_if) begin
                  i_miss_pending <= 1'b0;
                end else begin
                  d_miss_pending <= 1'b0;
                end
              end else if (walk_result == R_INSTALL) begin
                wstate <= W_INSTALL;
              end else begin
                if (w_is_if) begin
                  i_miss_pending <= 1'b0;
                  i_fault_pending <= 1'b1;
                  i_fault_vaddr <= w_vaddr;
                end else begin
                  d_miss_pending <= 1'b0;
                  d_fault_pending <= 1'b1;
                  d_fault_vpn <= w_vaddr[31:12];
                  d_fault_cause_q <= w_is_store ? 4'd15 : 4'd13;
                end
              end
            end
          end
          W_INSTALL: begin
            if (w_is_if) begin
              i_miss_pending <= 1'b0;
            end else begin
              d_miss_pending <= 1'b0;
            end
            wstate <= W_IDLE;
          end
          default: begin
            wstate <= W_IDLE;
          end
        endcase
      end
    end
  end

  // Register the fill data first, then write the LUTRAM on the following
  // cycle. This keeps the large walker control cone off the TLB write
  // enables, which otherwise becomes a critical path at 48 MHz.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      i_valid <= '0;
      d_valid <= '0;
    end else if (flush) begin
      i_valid <= '0;
      d_valid <= '0;
    end else if ((wstate == W_INSTALL) && !w_discard) begin
      if (w_is_if) begin
        // Redirect cancellation affects validity, not refill RAM data.
        // The discarded payload is never visible to a translation hit.
        i_valid[w_idx] <= !iflush;
      end else begin
        d_valid[w_idx] <= 1'b1;
      end
    end
  end

  // TLB payload RAM carries no reset; an entry is only observable through
  // its validity bit above, so it stays out of the asynchronous reset cone.
  always_ff @(posedge clk) begin
    if ((wstate == W_INSTALL) && !w_discard) begin
      if (w_is_if) begin
        itlb[w_idx] <= w_install_word;
      end else begin
        dtlb[w_idx] <= w_install_word;
      end
    end
  end

`ifdef ROCO_SV32_FORMAL
  `include "sv32_checks.svh"
`endif
`ifdef ROCO_SOC_PC_FORMAL
  logic [TLB_W-1:0] f_hot_entry;
  assign f_hot_entry = itlb[i_hot_vpn[IDX_BITS-1:0]];
  always_ff @(posedge clk) begin
    if (!rst && i_hot_valid) begin
      assert (i_valid[i_hot_vpn[IDX_BITS-1:0]]);
      assert (f_hot_entry[TAG_BITS-1:0] == i_hot_vpn[19:IDX_BITS]);
      assert (f_hot_entry[P_A] && f_hot_entry[P_X]);
      assert (f_hot_entry[P_U] == (i_hot_priv == PRIV_U));
    end
  end
`endif
endmodule
