// Machine/supervisor CSR file for the RV32 core.
//
// Implements machine mode plus the supervisor and user privilege levels
// needed by Sv32 virtual memory: trap delegation, supervisor trap CSRs,
// sstatus/satp and the MPRV/SUM/MXR/TVM/TSR status bits. Accesses that
// are not permitted in the current privilege mode are reported through
// read_ok/write_ok so EX can raise an illegal-instruction trap.
//
// Write ordering within one cycle is architectural: the software write
// lands first, then trap entry overrides it, then MRET/SRET updates the
// privilege state.

`default_nettype none
`include "rv32_defs.svh"

module rv32_csr (
  input logic clk,
  input logic rst,
  // Architectural read port (used in EX).
  input logic [11:0] raddr,
  output logic [31:0] rdata,
  output logic exists,
  output logic read_ok,
  output logic write_ok,
  // Software write port (committed in EX so the next instruction sees it).
  input logic wr_en,
  input logic [11:0] wr_addr,
  input logic [31:0] wr_data,
  /* Platform interrupt inputs. */
  input logic irq_timer,
  input logic irq_external,
  /* Highest-priority enabled interrupt, offered to EX. */
  output logic irq_req,
  output logic [4:0] irq_code,
  /* vsetvl writes the vector configuration CSRs. */
  input logic vset_en,
  input logic [4:0] vset_vl,
  input logic [31:0] vset_vtype,
  input logic vstart_we,
  input logic [4:0] vstart_data,
  /* Vector configuration state for the vector unit. */
  output logic [4:0] vl,
  output logic vtype_vta,
  output logic [2:0] vtype_sew,
  output logic [31:0] vstart_out,
  /* Trap entry and return (used in EX, highest priority). */
  input logic trap_en,
  input logic [31:0] trap_pc,
  input logic [31:0] trap_cause,
  input logic [31:0] trap_tval,
  input logic mret_en,
  input logic sret_en,
  // One instruction retiring in WB, for minstret.
  input logic retire,
  // Privilege and translation state.
  output logic [1:0] priv,
  output logic [31:0] mtvec,
  output logic [31:0] stvec,
  output logic [31:0] trap_vector,
  output logic [31:0] mepc,
  output logic [31:0] sepc,
  output logic [31:0] satp,
  output logic satp_write,
  output logic mstatus_mprv,
  output logic mstatus_sum,
  output logic mstatus_mxr,
  output logic mstatus_tvm,
  output logic mstatus_tsr,
  output logic [1:0] mstatus_mpp
);

  localparam logic [1:0] PRIV_U = `RV32_PRIV_U;
  localparam logic [1:0] PRIV_S = `RV32_PRIV_S;
  localparam logic [1:0] PRIV_M = `RV32_PRIV_M;
  localparam logic [31:0] MISA_VALUE = 32'h4034_1101;
  localparam logic [31:0] MEDELEG_MASK = 32'h0000_b35d;
  // Implemented interrupt bits: SSIP, MSIP, STIP, MTIP, SEIP, MEIP.
  localparam logic [31:0] MIE_MASK = 32'h0000_0aaa;
  // Only supervisor-level interrupts can be delegated.
  localparam logic [31:0] MIDELEG_MASK = 32'h0000_0222;
  // Pending bits software may set: SSIP, MSIP, STIP.
  localparam logic [31:0] MIP_SW_MASK = 32'h0000_002a;

  logic [1:0] priv_q;
  logic [31:0] mtvec_q;
  logic [31:0] stvec_q;
  logic [31:0] medeleg_q;
  logic [31:0] mepc_q;
  logic [31:0] sepc_q;
  logic [31:0] mcause_q;
  logic [31:0] scause_q;
  logic [31:0] mtval_q;
  logic [31:0] stval_q;
  logic [31:0] mscratch_q;
  logic [31:0] sscratch_q;
  logic [31:0] mie_q;
  logic [31:0] mip_q;
  logic [31:0] mideleg_q;
  logic [31:0] mcounteren_q;
  logic [31:0] scounteren_q;
  logic [31:0] satp_q;
  logic [31:0] vl_q;
  logic [31:0] vtype_q;
  logic [31:0] vstart_q;
  logic mstatus_mie;
  logic mstatus_mpie;
  logic mstatus_sie;
  logic mstatus_spie;
  logic mstatus_spp;
  logic mstatus_mprv_q;
  logic mstatus_sum_q;
  logic mstatus_mxr_q;
  logic mstatus_tvm_q;
  logic mstatus_tsr_q;
  logic [1:0] mstatus_mpp_q;

  logic [31:0] mip_value;
  logic [31:0] trap_base;
  logic [31:0] trap_offset;
  logic [31:0] irq_cand;
  logic [31:0] irq_eligible;
  logic irq_m_allowed;
  logic irq_s_allowed;

  logic [31:0] mcycle_lo;
  logic [31:0] mcycle_hi;
  logic [31:0] minstret_lo;
  logic [31:0] minstret_hi;
  logic [31:0] minstret_read_lo, minstret_read_hi;
  // Include the older instruction committing in MEM on this edge.
  assign minstret_read_lo = retire ? (minstret_lo + 32'd1) : minstret_lo;
  assign minstret_read_hi = (retire && (minstret_lo == 32'hffffffff)) ?
                            (minstret_hi + 32'd1) : minstret_hi;

  logic priv_read_ok;
  logic addr_writable;
  logic counter_cycle_ok;
  logic counter_instret_ok;
  logic [1:0] unused_trap_pc_offset;
  assign unused_trap_pc_offset = trap_pc[1:0];

  logic trap_to_s;

  assign priv = priv_q;
  assign mtvec = mtvec_q;
  assign stvec = stvec_q;
  assign mepc = mepc_q;
  assign sepc = sepc_q;
  assign satp = satp_q;
  assign vl = vl_q[4:0];
  assign vtype_vta = vtype_q[6];
  assign vtype_sew = vtype_q[5:3];
  assign vstart_out = vstart_q;
  // A satp write starts a new address space; flush the TLB rather than
  // tagging entries with the ASID.
  assign satp_write = wr_en && (wr_addr == 12'h180);
  assign mstatus_mprv = mstatus_mprv_q;
  assign mstatus_sum = mstatus_sum_q;
  assign mstatus_mxr = mstatus_mxr_q;
  assign mstatus_tvm = mstatus_tvm_q;
  assign mstatus_tsr = mstatus_tsr_q;
  assign mstatus_mpp = mstatus_mpp_q;

  assign priv_read_ok = (raddr[9:8] <= priv_q);
  assign addr_writable = (raddr[11:10] != 2'b11);
  // User-level cycle/instret are readable only when enabled by the
  // privilege level above (mcounteren, then scounteren).
  assign counter_cycle_ok = (priv_q == PRIV_M) ||
                            ((priv_q == PRIV_S) && mcounteren_q[0]) ||
                            ((priv_q == PRIV_U) && mcounteren_q[0] && scounteren_q[0]);
  assign counter_instret_ok = (priv_q == PRIV_M) ||
                              ((priv_q == PRIV_S) && mcounteren_q[2]) ||
                              ((priv_q == PRIV_U) && mcounteren_q[2] && scounteren_q[2]);
  // Interrupt traps follow mideleg, exception traps medeleg.
  assign trap_to_s = trap_cause[31] ? mideleg_q[trap_cause[4:0]] :
                     (priv_q != PRIV_M) && medeleg_q[trap_cause[4:0]];

  assign mip_value = mip_q | (irq_timer ? 32'h0000_0080 : 32'd0) |
                     (irq_external ? 32'h0000_0800 : 32'd0);
  assign irq_cand = mip_value & mie_q & MIE_MASK;
  // Machine interrupts need mstatus.MIE unless a less privileged mode is
  // running; supervisor interrupts additionally need the privilege mode
  // to allow them and the bit to be delegated.
  assign irq_m_allowed = mstatus_mie || (priv_q != PRIV_M);
  assign irq_s_allowed = (priv_q != PRIV_M) && (mstatus_sie || (priv_q != PRIV_S));
  assign irq_eligible = (irq_cand & ~mideleg_q & {32{irq_m_allowed}}) |
                        (irq_cand & mideleg_q & {32{irq_s_allowed}});

  // Architectural interrupt priority: MEI, MSI, MTI, SEI, SSI, STI.
  always_comb begin
    irq_req = |irq_eligible;
    irq_code = 5'd0;
    if (irq_eligible[11]) begin
      irq_code = 5'd11;
    end else if (irq_eligible[3]) begin
      irq_code = 5'd3;
    end else if (irq_eligible[7]) begin
      irq_code = 5'd7;
    end else if (irq_eligible[9]) begin
      irq_code = 5'd9;
    end else if (irq_eligible[1]) begin
      irq_code = 5'd1;
    end else if (irq_eligible[5]) begin
      irq_code = 5'd5;
    end
  end
  // Compute both candidates before EX decides whether to take an interrupt.
  assign trap_base = trap_to_s ? stvec_q : mtvec_q;
  assign trap_offset = (trap_cause[31] && (trap_base[1:0] == 2'b01)) ?
                       {25'd0, trap_cause[4:0], 2'b00} : 32'd0;
  assign trap_vector = {trap_base[31:2], 2'b00} + trap_offset;

  always_comb begin
    exists = 1'b1;
    read_ok = priv_read_ok;
    write_ok = priv_read_ok && addr_writable;
    rdata = '0;
    case (raddr)
      12'h100: begin  // sstatus
        rdata = '0;
        rdata[1] = mstatus_sie;
        rdata[5] = mstatus_spie;
        rdata[8] = mstatus_spp;
        rdata[18] = mstatus_sum_q;
        rdata[19] = mstatus_mxr_q;
      end
      12'h104: begin  // sie: the delegated view of mie
        rdata = mie_q & mideleg_q;
      end
      12'h008: begin  // vstart
        rdata = vstart_q;
      end
      12'h105: begin  // stvec
        rdata = stvec_q;
      end
      12'h106: begin  // scounteren
        rdata = scounteren_q;
      end
      12'h140: begin  // sscratch
        rdata = sscratch_q;
      end
      12'h141: begin  // sepc
        rdata = sepc_q;
      end
      12'h142: begin  // scause
        rdata = scause_q;
      end
      12'h143: begin  // stval
        rdata = stval_q;
      end
      12'h144: begin  // sip: the delegated view of mip
        rdata = mip_value & mideleg_q;
      end
      12'hC20: begin  // vl
        rdata = vl_q;
      end
      12'hC21: begin  // vtype
        rdata = vtype_q;
      end
      12'hC22: begin  // vlenb: VLEN / 8
        rdata = 32'd16;
        write_ok = 1'b0;
      end
      12'h180: begin  // satp
        rdata = satp_q;
        if ((priv_q == PRIV_S) && mstatus_tvm_q) begin
          read_ok = 1'b0;
          write_ok = 1'b0;
        end
      end
      12'h300: begin  // mstatus
        rdata = '0;
        rdata[3] = mstatus_mie;
        rdata[7] = mstatus_mpie;
        rdata[12:11] = mstatus_mpp_q;
        rdata[1] = mstatus_sie;
        rdata[5] = mstatus_spie;
        rdata[8] = mstatus_spp;
        rdata[17] = mstatus_mprv_q;
        rdata[18] = mstatus_sum_q;
        rdata[19] = mstatus_mxr_q;
        rdata[20] = mstatus_tvm_q;
        rdata[22] = mstatus_tsr_q;
      end
      12'h301: begin  // misa
        rdata = MISA_VALUE;
        write_ok = 1'b0;
      end
      12'h302: begin  // medeleg
        rdata = medeleg_q;
      end
      12'h303: begin  // mideleg
        rdata = mideleg_q;
      end
      12'h304: begin  // mie
        rdata = mie_q;
      end
      12'h305: begin  // mtvec
        rdata = mtvec_q;
      end
      12'h306: begin  // mcounteren
        rdata = mcounteren_q;
      end
      12'h310: begin  // mstatush: no big-endian support
        rdata = '0;
        write_ok = 1'b0;
      end
      12'h340: begin  // mscratch
        rdata = mscratch_q;
      end
      12'h341: begin  // mepc
        rdata = mepc_q;
      end
      12'h342: begin  // mcause
        rdata = mcause_q;
      end
      12'h343: begin  // mtval
        rdata = mtval_q;
      end
      12'h344: begin  // mip: timer and external bits are hardware-driven
        rdata = mip_value;
      end
      12'hB00: begin
        rdata = mcycle_lo;
      end
      12'hB02: begin
        rdata = minstret_read_lo;
      end
      12'hB80: begin
        rdata = mcycle_hi;
      end
      12'hB82: begin
        rdata = minstret_read_hi;
      end
      12'hC00: begin
        rdata = mcycle_lo;
        read_ok = counter_cycle_ok;
        write_ok = 1'b0;
      end
      12'hC02: begin
        rdata = minstret_read_lo;
        read_ok = counter_instret_ok;
        write_ok = 1'b0;
      end
      12'hF11, 12'hF12, 12'hF13, 12'hF14: begin
        rdata = '0;
        write_ok = 1'b0;
      end
      default: begin
        exists = 1'b0;
        read_ok = 1'b0;
        write_ok = 1'b0;
        rdata = '0;
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      priv_q <= PRIV_M;
      mtvec_q <= '0;
      stvec_q <= '0;
      medeleg_q <= '0;
      mepc_q <= '0;
      sepc_q <= '0;
      mcause_q <= '0;
      scause_q <= '0;
      mtval_q <= '0;
      stval_q <= '0;
      mscratch_q <= '0;
      sscratch_q <= '0;
      mie_q <= '0;
      mip_q <= '0;
      mideleg_q <= '0;
      mcounteren_q <= '0;
      scounteren_q <= '0;
      satp_q <= '0;
      vl_q <= '0;
      vtype_q <= '0;
      vstart_q <= '0;
      mstatus_mie <= 1'b0;
      mstatus_mpie <= 1'b0;
      mstatus_sie <= 1'b0;
      mstatus_spie <= 1'b0;
      mstatus_spp <= 1'b0;
      mstatus_mprv_q <= 1'b0;
      mstatus_sum_q <= 1'b0;
      mstatus_mxr_q <= 1'b0;
      mstatus_tvm_q <= 1'b0;
      mstatus_tsr_q <= 1'b0;
      mstatus_mpp_q <= PRIV_U;
      mcycle_lo <= '0;
      mcycle_hi <= '0;
      minstret_lo <= '0;
      minstret_hi <= '0;
    end else begin
      // Free-running counters.
      mcycle_lo <= mcycle_lo + 32'd1;
      if (mcycle_lo == 32'hFFFF_FFFF) begin
        mcycle_hi <= mcycle_hi + 32'd1;
      end
      if (retire) begin
        minstret_lo <= minstret_lo + 32'd1;
        if (minstret_lo == 32'hFFFF_FFFF) begin
          minstret_hi <= minstret_hi + 32'd1;
        end
      end

      // Software writes.
      if (wr_en) begin
        case (wr_addr)
          12'h100: begin  // sstatus
            mstatus_sie <= wr_data[1];
            mstatus_spie <= wr_data[5];
            mstatus_spp <= wr_data[8];
            mstatus_sum_q <= wr_data[18];
            mstatus_mxr_q <= wr_data[19];
          end
          12'h104: begin  // sie writes the delegated mie bits
            mie_q <= (mie_q & ~mideleg_q) | (wr_data & mideleg_q & MIE_MASK);
          end
          12'h105: begin
            stvec_q <= {wr_data[31:2], (wr_data[1:0] == 2'b01) ? 2'b01 : 2'b00};
          end
          12'h106: begin
            scounteren_q <= {29'd0, wr_data[2:0]};
          end
          12'h140: begin
            sscratch_q <= wr_data;
          end
          12'h144: begin  // sip writes the delegated pending bits
            mip_q <= (mip_q & ~mideleg_q) | (wr_data & mideleg_q & MIP_SW_MASK);
          end
          12'h141: begin
            sepc_q <= {wr_data[31:2], 2'b00};
          end
          12'h142: begin
            scause_q <= wr_data;
          end
          12'h143: begin
            stval_q <= wr_data;
          end
          12'h008: begin
            vstart_q <= {27'd0, wr_data[4:0]};
          end
          12'h180: begin
            satp_q <= wr_data[31] ? wr_data : 32'd0;
          end
          12'hC20: begin
            vl_q <= {27'd0, wr_data[4:0]};
          end
          12'hC21: begin
            vtype_q <= wr_data;
          end
          12'h300: begin
            mstatus_mie <= wr_data[3];
            mstatus_mpie <= wr_data[7];
            case (wr_data[12:11])
              PRIV_U, PRIV_S, PRIV_M: begin
                mstatus_mpp_q <= wr_data[12:11];
              end
              default: begin
                mstatus_mpp_q <= PRIV_U;
              end
            endcase
            mstatus_sie <= wr_data[1];
            mstatus_spie <= wr_data[5];
            mstatus_spp <= wr_data[8];
            mstatus_mprv_q <= wr_data[17];
            mstatus_sum_q <= wr_data[18];
            mstatus_mxr_q <= wr_data[19];
            mstatus_tvm_q <= wr_data[20];
            mstatus_tsr_q <= wr_data[22];
          end
          12'h302: begin
            medeleg_q <= wr_data & MEDELEG_MASK;
          end
          12'h303: begin
            mideleg_q <= wr_data & MIDELEG_MASK;
          end
          12'h304: begin
            mie_q <= wr_data & MIE_MASK;
          end
          12'h305: begin
            mtvec_q <= {wr_data[31:2], (wr_data[1:0] == 2'b01) ? 2'b01 : 2'b00};
          end
          12'h306: begin
            mcounteren_q <= {29'd0, wr_data[2:0]};
          end
          12'h340: begin
            mscratch_q <= wr_data;
          end
          12'h341: begin
            mepc_q <= {wr_data[31:2], 2'b00};
          end
          12'h342: begin
            mcause_q <= wr_data;
          end
          12'h343: begin
            mtval_q <= wr_data;
          end
          12'h344: begin
            mip_q <= wr_data & MIP_SW_MASK;
          end
          12'hB00: begin
            mcycle_lo <= wr_data;
          end
          12'hB02: begin
            minstret_lo <= wr_data;
          end
          12'hB80: begin
            mcycle_hi <= wr_data;
          end
          12'hB82: begin
            minstret_hi <= wr_data;
          end
          default: begin
          end
        endcase
      end

      // vsetvl commits the new configuration alongside any software
      // write; it is always the instruction in EX.
      if (vstart_we) vstart_q <= {27'd0, vstart_data};
      if (vset_en) begin
        vstart_q <= '0;
        vl_q <= {27'd0, vset_vl};
        vtype_q <= vset_vtype;
      end

      // Trap entry overrides any software write in flight.
      if (trap_en) begin
        if (trap_to_s) begin
          sepc_q <= {trap_pc[31:2], 2'b00};
          scause_q <= trap_cause;
          stval_q <= trap_tval;
          mstatus_spie <= mstatus_sie;
          mstatus_sie <= 1'b0;
          mstatus_spp <= (priv_q == PRIV_S);
          priv_q <= PRIV_S;
        end else begin
          mepc_q <= {trap_pc[31:2], 2'b00};
          mcause_q <= trap_cause;
          mtval_q <= trap_tval;
          mstatus_mpie <= mstatus_mie;
          mstatus_mie <= 1'b0;
          mstatus_mpp_q <= priv_q;
          priv_q <= PRIV_M;
        end
      end else if (sret_en) begin
        priv_q <= mstatus_spp ? PRIV_S : PRIV_U;
        mstatus_sie <= mstatus_spie;
        mstatus_spie <= 1'b1;
        mstatus_spp <= 1'b0;
      end else if (mret_en) begin
        priv_q <= mstatus_mpp_q;
        mstatus_mie <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
        mstatus_mpp_q <= PRIV_U;
      end
    end
  end

endmodule
