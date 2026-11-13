// Memory arbiter.
//
// Shares the single SDRAM controller between the instruction cache, the
// data cache, the UART boot loader and the MMU page-table walker. One
// transaction is granted at a time and the grant is held until the last
// read or write beat, so a cache fill or writeback is never interleaved
// with another client. Round-robin priority prevents any client from
// starving the others.

`default_nettype none

module mem_arbiter (
  input logic clk,
  input logic rst,
  /* Instruction cache: read-only. */
  input logic i_req,
  input logic i_we,
  input logic [22:0] i_word_addr,
  input logic [3:0] i_len,
  output logic i_ready,
  input logic i_wvalid,
  input logic [31:0] i_wdata,
  input logic [3:0] i_wbe,
  output logic i_rvalid,
  output logic [31:0] i_rdata,
  output logic i_rlast,
  /* Data cache. */
  input logic d_req,
  input logic d_we,
  input logic [22:0] d_word_addr,
  input logic [3:0] d_len,
  output logic d_ready,
  output logic d_wready,
  input logic d_wvalid,
  input logic [31:0] d_wdata,
  input logic [3:0] d_wbe,
  output logic d_rvalid,
  output logic [31:0] d_rdata,
  output logic d_rlast,
  /* Boot loader: write-only. */
  input logic b_req,
  input logic b_we,
  input logic [22:0] b_word_addr,
  input logic [3:0] b_len,
  output logic b_ready,
  output logic b_wready,
  input logic b_wvalid,
  input logic [31:0] b_wdata,
  input logic [3:0] b_wbe,
  /* Page-table walker: read-only, one word per transaction. */
  input logic p_req,
  input logic [22:0] p_word_addr,
  output logic p_ready,
  output logic p_rvalid,
  output logic [31:0] p_rdata,
  output logic p_rlast,
  /* SDRAM controller. */
  output logic c_req,
  input logic c_ready,
  output logic c_we,
  output logic [22:0] c_word_addr,
  output logic [3:0] c_len,
  input logic c_wready,
  output logic c_wvalid,
  output logic [31:0] c_wdata,
  output logic [3:0] c_wbe,
  input logic c_rvalid,
  input logic [31:0] c_rdata,
  input logic c_rlast
);

  localparam logic [2:0] OWN_NONE = 3'd0;
  localparam logic [2:0] OWN_I = 3'd1;
  localparam logic [2:0] OWN_D = 3'd2;
  localparam logic [2:0] OWN_B = 3'd3;
  localparam logic [2:0] OWN_P = 3'd4;

  logic [2:0] owner;
  logic [2:0] pick;
  logic [2:0] sel;
  logic [2:0] rr;
  logic locked;
  logic [3:0] wr_rem;

  assign sel = locked ? owner : pick;

  always_comb begin
    pick = OWN_NONE;
    case (rr)
      3'd0: begin
        if (i_req) begin
          pick = OWN_I;
        end else if (d_req) begin
          pick = OWN_D;
        end else if (p_req) begin
          pick = OWN_P;
        end else if (b_req) begin
          pick = OWN_B;
        end
      end
      3'd1: begin
        if (d_req) begin
          pick = OWN_D;
        end else if (p_req) begin
          pick = OWN_P;
        end else if (b_req) begin
          pick = OWN_B;
        end else if (i_req) begin
          pick = OWN_I;
        end
      end
      3'd2: begin
        if (p_req) begin
          pick = OWN_P;
        end else if (b_req) begin
          pick = OWN_B;
        end else if (i_req) begin
          pick = OWN_I;
        end else if (d_req) begin
          pick = OWN_D;
        end
      end
      3'd3: begin
        if (b_req) begin
          pick = OWN_B;
        end else if (i_req) begin
          pick = OWN_I;
        end else if (d_req) begin
          pick = OWN_D;
        end else if (p_req) begin
          pick = OWN_P;
        end
      end
      default: begin
        if (i_req) begin
          pick = OWN_I;
        end else if (d_req) begin
          pick = OWN_D;
        end else if (p_req) begin
          pick = OWN_P;
        end else if (b_req) begin
          pick = OWN_B;
        end
      end
    endcase
  end

  always_comb begin
    c_req = 1'b0;
    c_we = 1'b0;
    c_word_addr = 23'd0;
    c_len = 4'd0;
    c_wvalid = 1'b0;
    c_wdata = 32'd0;
    c_wbe = 4'd0;
    i_ready = 1'b0;
    i_rvalid = 1'b0;
    i_rdata = 32'd0;
    i_rlast = 1'b0;
    d_ready = 1'b0;
    d_wready = 1'b0;
    d_rvalid = 1'b0;
    d_rdata = 32'd0;
    d_rlast = 1'b0;
    b_ready = 1'b0;
    b_wready = 1'b0;
    p_ready = 1'b0;
    p_rvalid = 1'b0;
    p_rdata = 32'd0;
    p_rlast = 1'b0;
    case (sel)
      OWN_I: begin
        c_req = i_req;
        c_we = i_we;
        c_word_addr = i_word_addr;
        c_len = i_len;
        c_wvalid = i_wvalid;
        c_wdata = i_wdata;
        c_wbe = i_wbe;
        i_ready = c_ready;
        i_rvalid = c_rvalid;
        i_rdata = c_rdata;
        i_rlast = c_rlast;
      end
      OWN_D: begin
        c_req = d_req;
        c_we = d_we;
        c_word_addr = d_word_addr;
        c_len = d_len;
        c_wvalid = d_wvalid;
        c_wdata = d_wdata;
        c_wbe = d_wbe;
        d_ready = c_ready;
        d_wready = c_wready;
        d_rvalid = c_rvalid;
        d_rdata = c_rdata;
        d_rlast = c_rlast;
      end
      OWN_B: begin
        c_req = b_req;
        c_we = b_we;
        c_word_addr = b_word_addr;
        c_len = b_len;
        c_wvalid = b_wvalid;
        c_wdata = b_wdata;
        c_wbe = b_wbe;
        b_ready = c_ready;
        b_wready = c_wready;
      end
      OWN_P: begin
        c_req = p_req;
        c_we = 1'b0;
        c_word_addr = p_word_addr;
        c_len = 4'd0;
        c_wvalid = 1'b0;
        c_wdata = 32'd0;
        c_wbe = 4'd0;
        p_ready = c_ready;
        p_rvalid = c_rvalid;
        p_rdata = c_rdata;
        p_rlast = c_rlast;
      end
      default: begin
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      locked <= 1'b0;
      owner <= OWN_NONE;
      rr <= 3'd0;
      wr_rem <= 4'd0;
    end else if (!locked) begin
      if (c_req && c_ready) begin
        locked <= 1'b1;
        owner <= sel;
        wr_rem <= c_len;
        case (sel)
          OWN_I: begin
            rr <= 3'd1;
          end
          OWN_D: begin
            rr <= 3'd2;
          end
          OWN_B: begin
            rr <= 3'd3;
          end
          OWN_P: begin
            rr <= 3'd4;
          end
          default: begin
            rr <= 3'd0;
          end
        endcase
      end
    end else begin
      if (c_rvalid && c_rlast) begin
        locked <= 1'b0;
      end
      if (c_wvalid && c_wready) begin
        if (wr_rem == 4'd0) begin
          locked <= 1'b0;
        end else begin
          wr_rem <= wr_rem - 4'd1;
        end
      end
    end
  end

endmodule
