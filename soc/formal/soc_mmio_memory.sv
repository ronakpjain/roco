// Bounded integration check at the actual SoC's external pins.
`default_nettype none

module soc_mmio_memory (
  input logic clk
);
  localparam int Deadline = 420;
  localparam logic [8:0] DataColumn = 9'd64;  // byte offset 128 in SDRAM
  localparam logic [3:0] ProgramLength = 4'd10;

  (* anyconst *) logic [1:0] buttons;
  (* anyconst *) logic [31:0] initial_word;
  logic rst;
  logic [8:0] cycle;
  logic [3:0] retired;
  logic [3:0] leds;
  logic halted;
  logic [31:0] exit_code;
  logic trace_valid;
  logic [31:0] trace_pc, trace_instr, trace_wdata;
  logic [4:0] trace_rd;
  logic cs_n, ras_n, cas_n, we_n, dq_oe;
  logic [12:0] address;
  logic [1:0] bank, dqm;
  logic [15:0] dq_out, dq_in;

  roco_soc #(
      .CLK_HZ(520_000),
      .BOOT_OVERRIDE(1'b1),
      .ICACHE_LINES(2),
      .DCACHE_LINES(2)
  ) dut (
      .clk(clk),
      .rst(rst),
      .buttons(buttons),
      .leds(leds),
      .uart_rx(1'b1),
      .uart_tx(),
      .sdram_a(address),
      .sdram_ba(bank),
      .sdram_dqm(dqm),
      .sdram_cs_n(cs_n),
      .sdram_ras_n(ras_n),
      .sdram_cas_n(cas_n),
      .sdram_we_n(we_n),
      .sdram_cke(),
      .sdram_clk(),
      .sdram_dq_out(dq_out),
      .sdram_dq_oe(dq_oe),
      .sdram_dq_in(dq_in),
      .halted(halted),
      .exit_code(exit_code),
      .trace_valid(trace_valid),
      .trace_pc(trace_pc),
      .trace_instr(trace_instr),
      .trace_rd(trace_rd),
      .trace_wdata(trace_wdata)
  );

  function automatic logic [31:0] program_word(input logic [7:0] index);
    case (index)
      8'd0: program_word = 32'h200000b7;  // lui x1, 0x20000
      8'd1: program_word = 32'h0140a103;  // lw x2, 20(x1)    (GPIO buttons)
      8'd2: program_word = 32'h100001b7;  // lui x3, 0x10000
      8'd3: program_word = 32'h082180a3;  // sb x2, 129(x3)
      8'd4: program_word = 32'h0000100f;  // fence.i          (write back D-cache)
      8'd5: program_word = 32'h0c01a003;  // lw x0, 192(x3)   (evict the data line)
      8'd6: program_word = 32'h0801a203;  // lw x4, 128(x3)   (refill from SDRAM)
      8'd7: program_word = 32'h0020a823;  // sw x2, 16(x1)    (GPIO LEDs)
      8'd8: program_word = 32'h200012b7;  // lui x5, 0x20001
      8'd9: program_word = 32'h0042a023;  // sw x4, 0(x5)     (exit and halt)
      default: program_word = 32'h00000013;
    endcase
  endfunction

  // Small pin-level BL2/CL3 model: immutable instructions, one writable
  // word and zero padding. Observe real WRITE data and DQM on both beats.
  logic [31:0] stored_word, read_word, expected_word;
  logic row_zero, read_cmd, write_cmd, write_high;
  logic refetched_after_fence, refilled_after_fence;
  (* mem2reg *) logic [15:0] dq_pipe[5];
  assign read_cmd = !cs_n && ras_n && !cas_n && we_n;
  assign write_cmd = !cs_n && ras_n && !cas_n && !we_n;
  assign read_word = address[8:0] == DataColumn ? stored_word :
                     address[8:1] < 8'(ProgramLength) ? program_word(
      address[8:1]
  ) : 32'd0;
  assign dq_in = dq_pipe[0];
  assign expected_word = {initial_word[31:16], 6'd0, buttons, initial_word[7:0]};

  initial cycle = '0;
  assign rst = cycle == 0;
  always_ff @(posedge clk) begin
    if (cycle < 9'(Deadline)) cycle <= cycle + 1'b1;
    if (rst) begin
      retired <= '0;
      row_zero <= 1'b0;
      stored_word <= initial_word;
      write_high <= 1'b0;
      refetched_after_fence <= 1'b0;
      refilled_after_fence <= 1'b0;
      for (int i = 0; i < 5; i++) dq_pipe[i] <= '0;
    end else begin
      if (!cs_n && !ras_n && cas_n) begin
        // The program and data fit in bank zero, row zero.
        row_zero <= we_n && bank == 0 && address == 0;
      end
      for (int i = 0; i < 4; i++) dq_pipe[i] <= dq_pipe[i+1];
      dq_pipe[4] <= '0;
      if (read_cmd || write_cmd) begin
        assert (row_zero && bank == 0 && !address[0]);
      end
      if (read_cmd) begin
        if (retired == 4'd5 && address[8:0] == 9'd8) refetched_after_fence <= 1'b1;
        if (retired == 4'd6 && address[8:0] == DataColumn) refilled_after_fence <= 1'b1;
        dq_pipe[3] <= read_word[15:0];
        dq_pipe[4] <= read_word[31:16];
      end
      write_high <= write_cmd && address[8:0] == DataColumn;
      if (write_cmd) begin
        assert (dq_oe && address[8:4] == DataColumn[8:4] && !write_high);
        if (address[8:0] == DataColumn) begin
          if (!dqm[0]) stored_word[7:0] <= dq_out[7:0];
          if (!dqm[1]) stored_word[15:8] <= dq_out[15:8];
        end
      end
      if (write_high) begin
        assert (dq_oe);
        if (!dqm[0]) stored_word[23:16] <= dq_out[7:0];
        if (!dqm[1]) stored_word[31:24] <= dq_out[15:8];
      end

      if (trace_valid) begin
        assert (!halted && retired < ProgramLength);
        assert (trace_pc == 32'h10000000 + (32'(retired) << 2));
        assert (trace_instr == program_word(8'(retired)));
        if (retired == 4'd1) assert (trace_rd == 5'd2 && trace_wdata == {30'd0, buttons});
        if (retired == 4'd4) assert (stored_word == expected_word);
        if (retired == 4'd5) assert (refetched_after_fence);
        if (retired == 4'd6) begin
          assert (refilled_after_fence);
          assert (trace_rd == 5'd4 && trace_wdata == expected_word);
        end
        retired <= retired + 1'b1;
      end
      assert (halted == (retired == ProgramLength));
      if (halted) begin
        assert (leds == {2'd0, buttons});
        assert (exit_code == expected_word);
        assert (stored_word == expected_word);
      end
      if (cycle == 9'(Deadline)) assert (halted);
      cover (write_high);
      cover (retired == 4'd4);
      cover (refetched_after_fence);
      cover (refilled_after_fence);
      cover (halted && buttons == 2'd3 && initial_word[15:8] != 8'd3);
    end
  end
endmodule
