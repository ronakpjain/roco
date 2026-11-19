// Observe the real slave and controller; only the external SDRAM pins
// are constrained to the sparse BL2/CL3 memory device model.
axi4_ar_t ar;
assign ar = ram_ar;
axi4_aw_t aw;
assign aw = ram_aw;
axi4_w_t w;
assign w = ram_w;
axi4_r_t r;
assign r = ram_r;
axi4_b_t b;
assign b = ram_b;
logic ar_ready;
assign ar_ready = ram_arready;
logic aw_ready;
assign aw_ready = ram_awready;
logic w_ready;
assign w_ready = ram_wready;
logic r_ready;
assign r_ready = ram_rready;
logic b_ready;
assign b_ready = ram_bready;
logic req_valid;
assign req_valid = c_req;
logic req_ready;
assign req_ready = c_ready;
logic req_we;
assign req_we = c_we;
logic wvalid;
assign wvalid = c_wvalid;
logic wready;
assign wready = c_wready;
logic rvalid;
assign rvalid = c_rvalid;
logic [22:0] req_word_addr;
assign req_word_addr = c_word_addr;
logic [3:0] req_len;
assign req_len = c_len;
logic [3:0] wbe;
assign wbe = c_wbe;
logic [31:0] wdata;
assign wdata = c_wdata;
logic [31:0] rdata;
assign rdata = c_rdata;
logic [12:0] sd_a;
assign sd_a = sdram_a;
logic [1:0] sd_dqm;
assign sd_dqm = sdram_dqm;
logic [15:0] sd_dq_out;
assign sd_dq_out = sdram_dq_out;
logic sd_cs_n;
assign sd_cs_n = sdram_cs_n;
logic sd_ras_n;
assign sd_ras_n = sdram_ras_n;
logic sd_cas_n;
assign sd_cas_n = sdram_cas_n;
logic sd_we_n;
assign sd_we_n = sdram_we_n;
logic sd_dq_oe;
assign sd_dq_oe = sdram_dq_oe;
logic [15:0] sd_dq_in;
always_comb assume (sdram_dq_in == sd_dq_in);
`include "sdram_memory_checks.svh"
`include "axi_sdram_checks.svh"

// Relate the independently observed AW/W count to the slave scoreboard.
// This discharges WLAST using the actual master and crossbar state.
always_ff @(posedge clk) begin
  if (!rst)
    assert (9'(f_ram_write_left) == (active && writing && !final_w ? length - transferred : 9'd0));
end
