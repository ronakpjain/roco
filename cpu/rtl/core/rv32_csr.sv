// Machine-mode CSR file for the RV32I core.
//
// Implements the small CSR subset needed by the core and by bare-metal
// software: trap CSRs, mstatus, mscratch, mhartid/misa and the cycle /
// instruction counters. Accesses to any other CSR are reported as
// non-existent so the core can raise an illegal-instruction trap.
//
// Write ordering within one cycle is architectural: the writeback write
// lands first, then trap entry overrides it, then MRET updates mstatus.

`default_nettype none
`include "rv32_defs.svh"

module rv32_csr (
  input logic clk,
  input logic rst,
  // Architectural read port (used in EX).
  input logic [11:0] raddr,
  output logic [31:0] rdata,
  output logic exists,
  output logic writable,
  // Software write port (committed in EX so the next instruction sees it).
  input logic wr_en,
  input logic [11:0] wr_addr,
  input logic [31:0] wr_data,
  // Trap entry and return (used in EX, highest priority).
  input logic trap_en,
  input logic [31:0] trap_pc,
  input logic [31:0] trap_cause,
  input logic [31:0] trap_tval,
  input logic mret_en,
  // One instruction retiring in WB, for minstret.
  input logic retire,
  output logic [31:0] mtvec,
  output logic [31:0] mepc
);

  logic [31:0] mtvec_q;
  logic [31:0] mepc_q;
  logic [31:0] mcause_q;
  logic [31:0] mtval_q;
  logic [31:0] mscratch_q;
  logic [31:0] mie_q;
  logic mstatus_mie;
  logic mstatus_mpie;
  logic [1:0] mstatus_mpp;

  logic [31:0] mcycle_lo;
  logic [31:0] mcycle_hi;
  logic [31:0] minstret_lo;
  logic [31:0] minstret_hi;

  assign mtvec = mtvec_q;
  assign mepc = mepc_q;

  always_comb begin
    exists = 1'b1;
    writable = (raddr[11:10] != 2'b11);
    rdata = '0;
    case (raddr)
      12'h300: begin
        rdata = {19'd0, mstatus_mpp, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};
      end
      12'h301: begin
        rdata = 32'h4000_0100;  // MXL=32, extension I
        writable = 1'b0;
      end
      12'h304: begin
        rdata = mie_q;
      end
      12'h305: begin
        rdata = mtvec_q;
      end
      12'h310: begin
        rdata = '0;
      end
      12'h340: begin
        rdata = mscratch_q;
      end
      12'h341: begin
        rdata = mepc_q;
      end
      12'h342: begin
        rdata = mcause_q;
      end
      12'h343: begin
        rdata = mtval_q;
      end
      12'h344: begin
        rdata = '0;  // mip: no interrupt sources are wired to the core
      end
      12'hB00: begin
        rdata = mcycle_lo;
      end
      12'hB02: begin
        rdata = minstret_lo;
      end
      12'hB80: begin
        rdata = mcycle_hi;
      end
      12'hB82: begin
        rdata = minstret_hi;
      end
      12'hC00: begin
        rdata = mcycle_lo;
        writable = 1'b0;
      end
      12'hC02: begin
        rdata = minstret_lo;
        writable = 1'b0;
      end
      12'hF11, 12'hF12, 12'hF13, 12'hF14: begin
        rdata = '0;
        writable = 1'b0;
      end
      default: begin
        exists = 1'b0;
        writable = 1'b0;
        rdata = '0;
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      mtvec_q <= '0;
      mepc_q <= '0;
      mcause_q <= '0;
      mtval_q <= '0;
      mscratch_q <= '0;
      mie_q <= '0;
      mstatus_mie <= 1'b0;
      mstatus_mpie <= 1'b0;
      mstatus_mpp <= 2'b00;
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
          12'h300: begin
            mstatus_mie <= wr_data[3];
            mstatus_mpie <= wr_data[7];
            mstatus_mpp <= wr_data[12:11];
          end
          12'h304: begin
            mie_q <= wr_data;
          end
          12'h305: begin
            mtvec_q <= {wr_data[31:2], 2'b00};
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

      // Trap entry overrides any software write in flight.
      if (trap_en) begin
        mepc_q <= trap_pc;
        mcause_q <= trap_cause;
        mtval_q <= trap_tval;
        mstatus_mpie <= mstatus_mie;
        mstatus_mie <= 1'b0;
        mstatus_mpp <= 2'b11;
      end

      if (mret_en) begin
        mstatus_mie <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
        mstatus_mpp <= 2'b00;
      end
    end
  end

endmodule
