// Sv32 memory management unit.
//
// Two direct-mapped TLBs (16 entries each) translate instruction and data
// virtual addresses. A miss starts a shared hardware page-table walker
// that reads two PTEs through the physical page-walker port, checks the
// Sv32 permission rules, and fills the TLB. Page faults are reported to
// the pipeline with the faulting virtual address; software-managed A/D
// bits are required to be set in the PTE.
//
// Translation is active only when satp.MODE is Sv32 and the effective
// privilege is S or U. M-mode fetches bypass translation; M-mode data
// accesses translate only when mstatus.MPRV selects an S/U mode. SUM and
// MXR are applied at lookup time so a TLB entry can be shared by both
// privilege modes. sfence.vma invalidates all entries (the address/ASID
// operands are accepted and treated as a full flush).
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
  /* sfence.vma: invalidate all translations. */
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
  localparam logic [31:0] SDRAM_BASE = 32'h1000_0000;
  localparam logic [31:0] SDRAM_LIMIT = 32'h1200_0000;

  typedef enum logic [2:0] {
    W_IDLE,
    W_PTE1_REQ,
    W_PTE1_WAIT,
    W_PTE0_REQ,
    W_PTE0_WAIT
  } walk_state_t;

  typedef enum logic [1:0] {
    R_NONE,
    R_INSTALL,
    R_NEXT,
    R_FAULT
  } result_t;

  // Instruction TLB. Valid and permission bits are kept as packed
  // vectors so a flush is a single assignment.
  logic [TLB_ENTRIES-1:0] i_valid;
  logic [TLB_ENTRIES-1:0] i_global_ram;
  logic [TLB_ENTRIES-1:0] i_is4m_ram;
  logic [TLB_ENTRIES-1:0] i_r_ram;
  logic [TLB_ENTRIES-1:0] i_w_ram;
  logic [TLB_ENTRIES-1:0] i_x_ram;
  logic [TLB_ENTRIES-1:0] i_u_ram;
  logic [TLB_ENTRIES-1:0] i_a_ram;
  logic [TLB_ENTRIES-1:0] i_d_ram;
  logic [8:0] i_asid_ram[0:TLB_ENTRIES-1];
  logic [19:0] i_vpn_ram[0:TLB_ENTRIES-1];
  logic [19:0] i_ppn_ram[0:TLB_ENTRIES-1];

  // Data TLB.
  logic [TLB_ENTRIES-1:0] d_valid;
  logic [TLB_ENTRIES-1:0] d_global_ram;
  logic [TLB_ENTRIES-1:0] d_is4m_ram;
  logic [TLB_ENTRIES-1:0] d_r_ram;
  logic [TLB_ENTRIES-1:0] d_w_ram;
  logic [TLB_ENTRIES-1:0] d_x_ram;
  logic [TLB_ENTRIES-1:0] d_u_ram;
  logic [TLB_ENTRIES-1:0] d_a_ram;
  logic [TLB_ENTRIES-1:0] d_d_ram;
  logic [8:0] d_asid_ram[0:TLB_ENTRIES-1];
  logic [19:0] d_vpn_ram[0:TLB_ENTRIES-1];
  logic [19:0] d_ppn_ram[0:TLB_ENTRIES-1];

  walk_state_t wstate;
  logic w_is_if;
  logic w_is_store;
  logic w_discard;
  logic [31:0] w_vaddr;
  logic [1:0] w_priv;
  logic [8:0] w_asid;
  logic [31:0] w_pte_addr;

  logic i_miss_pending;
  logic d_miss_pending;
  logic i_fault_pending;
  logic d_fault_pending;
  logic [31:0] i_fault_vaddr;
  logic [19:0] d_fault_vpn;
  logic [3:0] d_fault_cause_q;

  logic [8:0] satp_asid;
  logic i_translate;
  logic d_translate;
  logic [19:0] i_vpn;
  logic [19:0] d_vpn;
  logic [IDX_BITS-1:0] i_idx;
  logic [IDX_BITS-1:0] d_idx;
  logic [IDX_BITS-1:0] w_idx;
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
  logic pte_range_ok;
  logic root_range_ok;
  logic walk_result_valid;
  logic walk_result_perm_ok;
  logic walk_result_leaf;
  result_t walk_result;
  logic [31:0] i_req_vaddr;
  logic i_rsp_armed;
  integer n;

  assign satp_asid = satp[30:22];
  assign i_translate = satp[31] && (priv_fetch != PRIV_M);
  assign d_translate = satp[31] && (priv_data != PRIV_M);
  assign i_vpn = i_vaddr[31:12];
  assign d_vpn = d_vaddr[31:12];
  assign i_idx = i_vaddr[IDX_BITS+11:12];
  assign d_idx = d_vaddr[IDX_BITS+11:12];
  assign w_idx = w_vaddr[IDX_BITS+11:12];

  function automatic logic [31:0] translate(logic [19:0] ppn, logic is_4m, logic [31:0] va);
    logic [19:0] page_base;
    page_base = is_4m ? {ppn[19:10], va[21:12]} : ppn;
    translate = {page_base, va[11:0]};
  endfunction

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

  assign i_tag_hit = i_valid[i_idx] &&
                     (i_global_ram[i_idx] || (i_asid_ram[i_idx] == satp_asid)) &&
                     (i_vpn_ram[i_idx] == i_vpn);
  assign d_tag_hit = d_valid[d_idx] &&
                     (d_global_ram[d_idx] || (d_asid_ram[d_idx] == satp_asid)) &&
                     (d_vpn_ram[d_idx] == d_vpn);
  assign i_perm_ok = tlb_perm_ok(
      i_a_ram[i_idx],
      i_r_ram[i_idx],
      i_w_ram[i_idx],
      i_x_ram[i_idx],
      i_u_ram[i_idx],
      i_d_ram[i_idx],
      1'b1,
      1'b0,
      priv_fetch,
      mstatus_sum,
      mstatus_mxr
  );
  assign d_perm_ok = tlb_perm_ok(
      d_a_ram[d_idx],
      d_r_ram[d_idx],
      d_w_ram[d_idx],
      d_x_ram[d_idx],
      d_u_ram[d_idx],
      d_d_ram[d_idx],
      1'b0,
      d_we,
      priv_data,
      mstatus_sum,
      mstatus_mxr
  );
  assign i_perm_fault = i_translate && i_req && i_tag_hit && !i_perm_ok;
  assign d_perm_fault = d_translate && d_req && d_tag_hit && !d_perm_ok;

  assign i_phys = i_translate ? translate(i_ppn_ram[i_idx], i_is4m_ram[i_idx], i_vaddr) : i_vaddr;
  assign d_phys = d_translate ? translate(d_ppn_ram[d_idx], d_is4m_ram[d_idx], d_vaddr) : d_vaddr;

  assign i_hit = !i_translate || (i_tag_hit && i_perm_ok);
  // A translation miss must hold the fetch PC on the request cycle; the
  // registered pending flag then stalls issue while the walker runs.
  assign i_miss = i_translate && i_req && !i_tag_hit;
  assign d_hit = !d_translate || (d_tag_hit && d_perm_ok);
  assign ic_req = i_req && i_hit;
  assign ic_addr = i_phys;
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
  assign root_range_ok = in_sdram(root_pte_addr);
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
      w_asid <= '0;
      w_pte_addr <= '0;
      i_miss_pending <= 1'b0;
      d_miss_pending <= 1'b0;
      i_fault_pending <= 1'b0;
      d_fault_pending <= 1'b0;
      i_fault_vaddr <= '0;
      d_fault_vpn <= '0;
      d_fault_cause_q <= 4'd13;
      i_req_vaddr <= '0;
      i_rsp_armed <= 1'b0;
      i_valid <= '0;
      d_valid <= '0;
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
        i_valid <= '0;
        d_valid <= '0;
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
              w_asid <= satp_asid;
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
              w_asid <= satp_asid;
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
              if (w_discard || flush) begin
                i_miss_pending <= 1'b0;
                d_miss_pending <= 1'b0;
              end else if (walk_result == R_INSTALL) begin
                if (w_is_if) begin
                  i_valid[w_idx] <= 1'b1;
                  i_global_ram[w_idx] <= p_rdata[5];
                  i_asid_ram[w_idx] <= w_asid;
                  i_vpn_ram[w_idx] <= w_vaddr[31:12];
                  i_ppn_ram[w_idx] <= p_rdata[29:10];
                  i_is4m_ram[w_idx] <= 1'b1;
                  i_r_ram[w_idx] <= p_rdata[1];
                  i_w_ram[w_idx] <= p_rdata[2];
                  i_x_ram[w_idx] <= p_rdata[3];
                  i_u_ram[w_idx] <= p_rdata[4];
                  i_a_ram[w_idx] <= p_rdata[6];
                  i_d_ram[w_idx] <= p_rdata[7];
                  i_miss_pending <= 1'b0;
                end else begin
                  d_valid[w_idx] <= 1'b1;
                  d_global_ram[w_idx] <= p_rdata[5];
                  d_asid_ram[w_idx] <= w_asid;
                  d_vpn_ram[w_idx] <= w_vaddr[31:12];
                  d_ppn_ram[w_idx] <= p_rdata[29:10];
                  d_is4m_ram[w_idx] <= 1'b1;
                  d_r_ram[w_idx] <= p_rdata[1];
                  d_w_ram[w_idx] <= p_rdata[2];
                  d_x_ram[w_idx] <= p_rdata[3];
                  d_u_ram[w_idx] <= p_rdata[4];
                  d_a_ram[w_idx] <= p_rdata[6];
                  d_d_ram[w_idx] <= p_rdata[7];
                  d_miss_pending <= 1'b0;
                end
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
              if (w_discard || flush) begin
                i_miss_pending <= 1'b0;
                d_miss_pending <= 1'b0;
              end else if (walk_result == R_INSTALL) begin
                if (w_is_if) begin
                  i_valid[w_idx] <= 1'b1;
                  i_global_ram[w_idx] <= p_rdata[5];
                  i_asid_ram[w_idx] <= w_asid;
                  i_vpn_ram[w_idx] <= w_vaddr[31:12];
                  i_ppn_ram[w_idx] <= p_rdata[29:10];
                  i_is4m_ram[w_idx] <= 1'b0;
                  i_r_ram[w_idx] <= p_rdata[1];
                  i_w_ram[w_idx] <= p_rdata[2];
                  i_x_ram[w_idx] <= p_rdata[3];
                  i_u_ram[w_idx] <= p_rdata[4];
                  i_a_ram[w_idx] <= p_rdata[6];
                  i_d_ram[w_idx] <= p_rdata[7];
                  i_miss_pending <= 1'b0;
                end else begin
                  d_valid[w_idx] <= 1'b1;
                  d_global_ram[w_idx] <= p_rdata[5];
                  d_asid_ram[w_idx] <= w_asid;
                  d_vpn_ram[w_idx] <= w_vaddr[31:12];
                  d_ppn_ram[w_idx] <= p_rdata[29:10];
                  d_is4m_ram[w_idx] <= 1'b0;
                  d_r_ram[w_idx] <= p_rdata[1];
                  d_w_ram[w_idx] <= p_rdata[2];
                  d_x_ram[w_idx] <= p_rdata[3];
                  d_u_ram[w_idx] <= p_rdata[4];
                  d_a_ram[w_idx] <= p_rdata[6];
                  d_d_ram[w_idx] <= p_rdata[7];
                  d_miss_pending <= 1'b0;
                end
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
          default: begin
            wstate <= W_IDLE;
          end
        endcase
      end
    end
  end

endmodule
