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
`ifdef ROCO_SOC_RETIRE_COVER
// Concrete external memory choices for the three pipeline witnesses: the
// reset instruction is either NOP (normal retirement) or zero (illegal trap).
// No internal CPU, cache or bus signal is constrained.
always_comb begin
  assume (cell_addr == 23'd0);
`ifdef ROCO_SOC_ISA_MEMORY_FORMAL
  // Also witness all nine base-ISA effect families. Operands are x0, so
  // these one-instruction programs need no internal register initialization.
  assume (initial_cell == 32'd0 || initial_cell == 32'h00700093 ||
          initial_cell == 32'h000000b3 || initial_cell == 32'h100000b7 ||
          initial_cell == 32'h00000097 || initial_cell == 32'h004000ef ||
          initial_cell == 32'h000000e7 || initial_cell == 32'h00000263 ||
          initial_cell == 32'h00002083 || initial_cell == 32'h00002023);
`else
  assume (initial_cell == 32'h00000013 || initial_cell == 32'd0);
`endif
  assume (other_halfword == 16'd0);
end
`endif
`include "axi_sdram_checks.svh"
assign f_watch = cell_addr[3:0] - base[5:2];

// Relate the independently observed AW/W count to the slave scoreboard.
// This discharges WLAST using the actual master and crossbar state.
always_ff @(posedge clk) begin
  if (!rst)
    assert (9'(f_ram_write_left) == (active && writing && !final_w ? length - transferred : 9'd0));
end

`ifdef ROCO_SOC_DCACHE_MEMORY_FORMAL
// The two independent native-port scoreboards name the same in-flight
// beat. This connects cache writeback history to the fabric memory copy.
always_ff @(posedge clk) begin
  if (!rst && !cache_rst) begin
    assert (f_d_write_left == f_dc_write_left);
    assert (f_dc_read_left == f_dc_cache_read_left);
    if (!core0_rst) begin
      assert ((f_dc_checker_pending && !f_dc_checker_abandoned) == f_dc_pending);
      if (f_dc_pending) assert (f_dc_checker_cpu_word == f_dc_word);
    end
    if (f_d_write_left != 0)
      assert (f_dc_memory_active && f_dc_memory_write && f_dc_beat_word == dc_write_word);
    if (f_dc_read_left != 0)
      assert (f_dc_memory_active && !f_dc_memory_write && f_dc_beat_word == dc_read_word);
  end
end
`endif

logic [22:0] dc_write_word, boot_write_word;
logic [31:0] native_cell;
logic dc_write_fire, boot_write_fire;
assign dc_write_fire = dc0_mem_wvalid && dc0_mem_wready;
assign boot_write_fire = boot_mem_wvalid && boot_mem_wready;
always_ff @(posedge clk) begin
  if (rst) begin
    {dc_write_word, boot_write_word} <= '0;
    native_cell <= initial_cell;
  end else begin
    if (dc0_mem_req && dc0_mem_ready && dc0_mem_we) dc_write_word <= dc0_mem_word_addr;
    if (boot_mem_req && boot_mem_ready) boot_write_word <= boot_mem_word_addr;
    if (f_ram_write_left != 0) begin
      assert (active && writing && supported && !final_w);
      assert (base[24:2] + 23'(transferred) ==
              (f_ram_write_is_boot ? boot_write_word : dc_write_word));
    end
    assert (w_fire == (dc_write_fire || boot_write_fire));
    assert (!(dc_write_fire && boot_write_fire));
    if (dc_write_fire) begin
      if (dc_write_word == cell_addr)
        native_cell <= {
          overlay(native_cell[31:16], dc0_mem_wdata[31:16], dc0_mem_wbe[3:2]),
          overlay(native_cell[15:0], dc0_mem_wdata[15:0], dc0_mem_wbe[1:0])
        };
      dc_write_word <= dc_write_word + 23'd1;
    end
    if (boot_write_fire) begin
      if (boot_write_word == cell_addr)
        native_cell <= {
          overlay(native_cell[31:16], boot_mem_wdata[31:16], boot_mem_wbe[3:2]),
          overlay(native_cell[15:0], boot_mem_wdata[15:0], boot_mem_wbe[1:0])
        };
      boot_write_word <= boot_write_word + 23'd1;
    end
    assert (native_cell == axi_cell);
  end
end

// Track cache-side burst addresses independently of both the slave
// scoreboard and the memory-device word. Check the data at the native
// refill ports, after routing and response conversion in the AXI masters.
logic [22:0] dc_read_word, ic_read_word;
always_ff @(posedge clk) begin
  if (rst) begin
    {dc_read_word, ic_read_word} <= '0;
  end else begin
    cover (pin_read);
    cover (pin_write);
    cover (f_ram_read_i);
    cover (f_ram_read_d);
    cover (ic_read_word == cell_addr && ic0_mem_rvalid);
    cover (dc_read_word == cell_addr && dc0_mem_rvalid);
    if (dc0_mem_req && dc0_mem_ready && !dc0_mem_we) dc_read_word <= dc0_mem_word_addr;
    if (ic0_mem_req && ic0_mem_ready) ic_read_word <= ic0_mem_word_addr;
    if (f_ram_read_d) begin
      assert (active && !writing && supported && length == 8);
      assert (base[24:2] + 23'(transferred) == dc_read_word);
    end
    if (f_ram_read_i) begin
      assert (active && !writing && supported && length == 4);
      assert (base[24:2] + 23'(transferred) == ic_read_word);
    end
    if (dc0_mem_rvalid) begin
      if (dc_read_word == cell_addr) assert (dc0_mem_rdata == axi_cell);
      dc_read_word <= dc_read_word + 23'd1;
    end
    if (ic0_mem_rvalid) begin
      if (ic_read_word == cell_addr) assert (ic0_mem_rdata == axi_cell);
      ic_read_word <= ic_read_word + 23'd1;
    end
  end
end
