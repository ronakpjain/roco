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
`include "rv32_defs.svh"

module rv32_mmu #(
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
  output logic p_req,
  output logic [22:0] p_word_addr,
  input logic p_ready,
  input logic p_rvalid,
  input logic [31:0] p_rdata,
  input logic p_rlast
);

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
  logic [19:0] i_vpn;
  logic [19:0] d_vpn;
  logic [IDX_BITS-1:0] i_idx;
  logic [IDX_BITS-1:0] d_idx;
  logic [IDX_BITS-1:0] w_idx;
  logic [TAG_BITS-1:0] i_tag;
  logic [TAG_BITS-1:0] d_tag;
  logic [TLB_W-1:0] i_ent;
  logic [TLB_W-1:0] d_ent;
  logic i_tag_hit;
  logic d_tag_hit;
  logic i_perm_ok;
  logic d_perm_ok;
  logic i_perm_fault;
  logic d_perm_fault;
  logic [31:0] i_phys;
  logic [31:0] d_phys;
  logic [31:0] root_pte_addr;
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

  assign i_translate = satp[31] && (priv_fetch != PRIV_M);
  assign d_translate = satp[31] && (priv_data != PRIV_M);
  assign i_vpn = i_vaddr[31:12];
  assign d_vpn = d_vaddr[31:12];
  assign i_idx = i_vaddr[IDX_BITS+11:12];
  assign d_idx = d_vaddr[IDX_BITS+11:12];
  assign w_idx = w_vaddr[IDX_BITS+11:12];
  assign i_tag = i_vaddr[31:12+IDX_BITS];
  assign d_tag = d_vaddr[31:12+IDX_BITS];

  always_comb begin
    i_ent = itlb[i_idx];
    d_ent = dtlb[d_idx];
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
  assign d_tag_hit = d_valid[d_idx] && (d_ent[TAG_BITS-1:0] == d_tag);
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
  assign d_perm_ok = tlb_perm_ok(
      d_ent[P_A],
      d_ent[P_R],
      d_ent[P_W],
      d_ent[P_X],
      d_ent[P_U],
      d_ent[P_D],
      1'b0,
      d_we,
      priv_data,
      mstatus_sum,
      mstatus_mxr
  );
  assign i_perm_fault = i_translate && i_req && i_tag_hit && !i_perm_ok;
  assign d_perm_fault = d_translate && d_req && d_tag_hit && !d_perm_ok;

  assign i_phys = {i_ent[TAG_BITS+19:TAG_BITS], i_vaddr[11:0]};
  assign d_phys = {d_ent[TAG_BITS+19:TAG_BITS], d_vaddr[11:0]};

  assign i_hit = !i_translate || (i_tag_hit && i_perm_ok);
  assign i_miss = i_translate && i_req && !i_tag_hit;
  assign d_hit = !d_translate || (d_tag_hit && d_perm_ok);
  assign ic_req = i_req && i_hit;
  assign ic_addr = i_translate ? i_phys : i_vaddr;
  assign i_busy = i_fault_pending || i_miss_pending || ((wstate != W_IDLE) && w_is_if);
  assign i_fault = i_fault_pending;
  assign i_fault_addr = i_fault_vaddr;
  assign i_rsp_valid = ic_rsp_valid && i_rsp_armed;
  assign i_rsp_addr = i_req_vaddr;
  assign i_rsp_data = ic_rsp_data;
  assign d_paddr = d_translate ? d_phys : d_vaddr;
  assign d_fault = d_perm_fault || (d_fault_pending && d_req && (d_vpn == d_fault_vpn));
  assign d_fault_cause = d_fault_pending ? d_fault_cause_q : (d_we ? 4'd15 : 4'd13);

  assign p_req = (wstate == W_PTE1_REQ) || (wstate == W_PTE0_REQ);
  assign p_word_addr = w_pte_addr[24:2];

  assign root_pte_addr = {satp[19:0], 12'b0} + {w_vaddr[31:22], 2'b00};
  assign pte_ppn = p_rdata[29:10];
  assign level0_pte_addr = {pte_ppn, 12'b0} + {w_vaddr[21:12], 2'b00};
  assign leaf_ppn_4k = p_rdata[29:10];
  assign leaf_ppn_4m = {p_rdata[29:20], w_vaddr[21:12]};
  assign pte_range_ok = in_sdram(level0_pte_addr);

  always_comb begin
    walk_result = R_NONE;
    walk_result_leaf = p_rdata[1] || p_rdata[3];
    walk_result_perm_ok =
        pte_perm_ok(p_rdata, w_is_if, w_is_store, w_priv, mstatus_sum, mstatus_mxr);
    walk_result_valid = p_rdata[0] && !(p_rdata[2] && !p_rdata[1]);
    if (p_rvalid && (wstate == W_PTE1_WAIT)) begin
      if (!walk_result_valid) begin
        walk_result = R_FAULT;
      end else if (walk_result_leaf) begin
        if (!walk_result_perm_ok || (p_rdata[19:10] != 10'd0)) begin
          walk_result = R_FAULT;
        end else begin
          walk_result = R_INSTALL;
        end
      end else if (pte_range_ok) begin
        walk_result = R_NEXT;
      end else begin
        walk_result = R_FAULT;
      end
    end else if (p_rvalid && (wstate == W_PTE0_WAIT)) begin
      if (!walk_result_valid || !walk_result_leaf || !walk_result_perm_ok) begin
        walk_result = R_FAULT;
      end else begin
        walk_result = R_INSTALL;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      wstate <= W_IDLE;
      w_is_if <= 1'b0;
      w_is_store <= 1'b0;
      w_discard <= 1'b0;
      w_vaddr <= '0;
      w_priv <= PRIV_M;
      w_pte_addr <= '0;
      w_install_word <= '0;
      i_miss_pending <= 1'b0;
      d_miss_pending <= 1'b0;
      i_fault_pending <= 1'b0;
      d_fault_pending <= 1'b0;
      i_fault_vaddr <= '0;
      d_fault_vpn <= '0;
      d_fault_cause_q <= 4'd13;
      i_req_vaddr <= '0;
      i_rsp_armed <= 1'b0;
    end else begin
      // Fault indicators are one-cycle pulses; a new fault sets them again.
      i_fault_pending <= 1'b0;
      if (!d_req || (d_vpn != d_fault_vpn)) begin
        d_fault_pending <= 1'b0;
      end

      if (ic_req) begin
        i_req_vaddr <= i_vaddr;
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
        if (i_req && i_translate && !i_tag_hit && !i_miss_pending && !i_fault_pending &&
            !(w_is_if && (wstate != W_IDLE))) begin
          i_miss_pending <= 1'b1;
        end
        if (d_req && d_translate && !d_tag_hit && !d_miss_pending && !d_fault_pending &&
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
        if (i_perm_fault && !i_fault_pending) begin
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
            if (d_miss_pending) begin
              w_is_if <= 1'b0;
              w_is_store <= d_we;
              w_vaddr <= d_vaddr;
              w_priv <= priv_data;
              w_pte_addr <= {satp[19:0], 12'b0} + {d_vaddr[31:22], 2'b00};
              if (in_sdram({satp[19:0], 12'b0} + {d_vaddr[31:22], 2'b00})) begin
                wstate <= W_PTE1_REQ;
              end else begin
                d_miss_pending <= 1'b0;
                d_fault_pending <= 1'b1;
                d_fault_vpn <= d_vaddr[31:12];
                d_fault_cause_q <= d_we ? 4'd15 : 4'd13;
              end
            end else if (i_miss_pending) begin
              w_is_if <= 1'b1;
              w_is_store <= 1'b0;
              w_vaddr <= i_vaddr;
              w_priv <= priv_fetch;
              w_pte_addr <= {satp[19:0], 12'b0} + {i_vaddr[31:22], 2'b00};
              if (in_sdram({satp[19:0], 12'b0} + {i_vaddr[31:22], 2'b00})) begin
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
            if (p_rvalid) begin
              wstate <= W_IDLE;
              if (w_discard) begin
                i_miss_pending <= 1'b0;
                d_miss_pending <= 1'b0;
              end else if (walk_result == R_INSTALL) begin
                w_install_word <= {
                  p_rdata[1],
                  p_rdata[2],
                  p_rdata[3],
                  p_rdata[4],
                  p_rdata[7],
                  p_rdata[6],
                  leaf_ppn_4m,
                  w_vaddr[31:12+IDX_BITS]
                };
                wstate <= W_INSTALL;
              end else if (walk_result == R_NEXT) begin
                w_pte_addr <= level0_pte_addr;
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
            if (p_rvalid) begin
              wstate <= W_IDLE;
              if (w_discard) begin
                i_miss_pending <= 1'b0;
                d_miss_pending <= 1'b0;
              end else if (walk_result == R_INSTALL) begin
                w_install_word <= {
                  p_rdata[1],
                  p_rdata[2],
                  p_rdata[3],
                  p_rdata[4],
                  p_rdata[7],
                  p_rdata[6],
                  leaf_ppn_4k,
                  w_vaddr[31:12+IDX_BITS]
                };
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
  always_ff @(posedge clk) begin
    if (rst || flush) begin
      i_valid <= '0;
      d_valid <= '0;
    end else if ((wstate == W_INSTALL) && !w_discard) begin
      if (w_is_if) begin
        itlb[w_idx] <= w_install_word;
        i_valid[w_idx] <= 1'b1;
      end else begin
        dtlb[w_idx] <= w_install_word;
        d_valid[w_idx] <= 1'b1;
      end
    end
  end

endmodule
