`include "axi4_defs.svh"
`default_nettype none

module axi_sdram_contract #(
    parameter int ClockHz = 96_000_000,
    parameter int PowerupCycles = ClockHz / 5000
) (
  input logic clk
);
  (* anyseq *) logic rst, r_ready, b_ready;
`ifdef ROCO_SDRAM_LINK_FORMAL
  logic req_ready, wready, rvalid;
  logic [31:0] rdata;
`ifdef ROCO_SDRAM_MEMORY_FORMAL
  logic [15:0] sd_dq_in, sd_dq_out;
  logic [12:0] sd_a;
  logic [1:0] sd_dqm;
  logic sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
  logic [14:0] f_pin_row;
`else
  (* anyseq *) logic [15:0] sd_dq_in;
`endif
  logic f_ctrl_busy, f_ctrl_read_owned, f_ctrl_we;
  logic [22:0] f_ctrl_addr;
  logic [3:0] f_ctrl_len;
  logic [4:0] f_ctrl_read_count, f_ctrl_write_count, f_ctrl_pins_written;
`else
  (* anyseq *) logic req_ready, wready, rvalid;
  (* anyseq *) logic [31:0] rdata;
`endif
  (* anyseq *) axi4_ar_t ar;
  (* anyseq *) axi4_aw_t aw;
  (* anyseq *) axi4_w_t w;
  axi4_r_t r;
  axi4_b_t b;
  logic ar_ready, aw_ready, w_ready, req_valid, req_we, wvalid;
  logic [22:0] req_word_addr;
  logic [3:0] req_len, wbe;
  logic [31:0] wdata;

  `include "axi_sdram_state.svh"
axi4_sdram_adapter dut (.*);
`ifdef ROCO_SDRAM_LINK_FORMAL
  sdram_ctrl #(
      .CLK_HZ(ClockHz),
      .T_POWERUP(PowerupCycles)
  ) ctrl (
      .clk(clk),
      .rst(rst),
      .req_valid(req_valid),
      .req_ready(req_ready),
      .req_we(req_we),
      .req_word_addr(req_word_addr),
      .req_len(req_len),
      .wvalid(wvalid),
      .wready(wready),
      .wdata(wdata),
      .wbe(wbe),
      .rvalid(rvalid),
      .rdata(rdata),
      .rlast(),
      .init_done(),
      .sd_ba(),
`ifdef ROCO_SDRAM_MEMORY_FORMAL
      .sd_a(sd_a),
      .sd_cs_n(sd_cs_n),
      .sd_ras_n(sd_ras_n),
      .sd_cas_n(sd_cas_n),
      .sd_we_n(sd_we_n),
      .sd_dqm(sd_dqm),
      .sd_dq_out(sd_dq_out),
      .sd_dq_oe(sd_dq_oe),
      .f_pin_row(f_pin_row),
`else
      .sd_a(),
      .sd_cs_n(),
      .sd_ras_n(),
      .sd_cas_n(),
      .sd_we_n(),
      .sd_dqm(),
      .sd_dq_out(),
      .sd_dq_oe(),
`endif
      .sd_dq_in(sd_dq_in),
      .f_ctrl_busy(f_ctrl_busy),
      .f_ctrl_read_owned(f_ctrl_read_owned),
      .f_ctrl_we(f_ctrl_we),
      .f_ctrl_addr(f_ctrl_addr),
      .f_ctrl_len(f_ctrl_len),
      .f_ctrl_read_count(f_ctrl_read_count),
      .f_ctrl_write_count(f_ctrl_write_count),
      .f_ctrl_pins_written(f_ctrl_pins_written)
  );
`endif

`ifdef ROCO_SDRAM_MEMORY_FORMAL
  `include "sdram_memory_checks.svh"
`endif

  `include "axi_sdram_checks.svh"
endmodule
