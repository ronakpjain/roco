// Bounded integration check at the actual SoC's external pins.
`default_nettype none

module soc_mmio_memory #(
    parameter int SdramPowerup = 520_000 / 5000,
    parameter bit MmioOnly = 1'b0,
    parameter bit TrapProgram = 1'b0,
    parameter bit ForwardProgram = 1'b0,
    parameter bit MProgram = 1'b0,
    parameter bit PcProgram = 1'b0,
    parameter bit AProgram = 1'b0,
    parameter bit VProgram = 1'b0
) (
  input logic clk
);
  localparam int Deadline = 420;
  localparam logic [8:0] DataColumn = 9'd64;  // byte offset 128 in SDRAM
  localparam logic [3:0] ProgramLength = MmioOnly ?
      (PcProgram ? 4'd8 : ForwardProgram ? 4'd6 : AProgram ? 4'd4 : VProgram ? 4'd5 : 4'd5) : 4'd10;

  (* anyconst *) logic [1:0] buttons;
  (* anyconst *) logic [1:0] cover_trap_kind;
  (* anyconst *) logic cover_vector_mem;
  (* anyconst *) logic [2:0] cover_m_variant;
  (* anyconst *) logic [1:0] cover_irq_case, cover_atomic_case, cover_vector_case;
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
  // Hart0 trace is trace0_*; alias locally so the checks below are unchanged.
  assign trace_valid = trace0_valid;
  assign trace_pc = trace0_pc;
  assign trace_instr = trace0_instr;
  assign trace_rd = trace0_rd;
  assign trace_wdata = trace0_wdata;
  logic trace0_valid;
  logic [31:0] trace0_pc, trace0_instr, trace0_wdata;
  logic [4:0] trace0_rd;
  logic cs_n, ras_n, cas_n, we_n, dq_oe;
  logic [12:0] address;
  logic [1:0] bank, dqm;
  logic [15:0] dq_out, dq_in;

  roco_soc #(
      .CLK_HZ(520_000),
      .SDRAM_POWERUP(SdramPowerup),
      .BOOT_OVERRIDE(1'b1),
      .ICACHE_LINES(2),
      .DCACHE_LINES(2)
  ) dut (
      .clk(clk),
      .rst(rst),
      .clk_mem(clk),
      .rst_mem(rst),
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
      .trace0_valid(trace0_valid),
      .trace0_pc(trace0_pc),
      .trace0_instr(trace0_instr),
      .trace0_rd(trace0_rd),
      .trace0_wdata(trace0_wdata)
  );

  function automatic logic [31:0] program_word(input logic [7:0] index);
    if (TrapProgram && cover_trap_kind == 2'd3) begin
      case (index)
        8'd0: program_word = 32'h800000b7;  // lui x1, 0x80000: Sv32, root outside SDRAM
        8'd1: program_word = 32'h18009073;  // csrw satp, x1
        8'd2: program_word = 32'h000200b7;  // lui x1, 0x20: MPRV=1, MPP=U
        8'd3: program_word = 32'h30009073;  // csrw mstatus, x1
        8'd4: program_word = 32'h00002103;  // lw x2, 0(x0): load page fault
        default: program_word = 32'h00000013;
      endcase
    end else if (TrapProgram) begin
      case (index)
        8'd0: program_word = 32'h00100093;  // addi x1, x0, 1
        8'd1: begin
          case (cover_trap_kind)
            2'd0: program_word = 32'h00000073;  // ecall
            2'd1: program_word = 32'h00100073;  // ebreak
            default: program_word = 32'h00208067;  // jalr x0, 2(x1), target 2
          endcase
        end
        default: program_word = 32'h00000013;
      endcase
    end else if (ForwardProgram && cover_vector_mem) begin
      case (index)
        8'd0: program_word = 32'h200001b7;  // lui x3, 0x20000
        8'd1: program_word = 32'hcd017057;  // vsetivli x0, 2, e32, m1, ta, ma
        8'd2: program_word = 32'h01018193;  // addi x3, x3, 16
        8'd3: program_word = 32'h0201e087;  // vle32.v v1, (x3) (LEDs and buttons)
        default: program_word = 32'h00000013;
      endcase
    end else if (ForwardProgram) begin
      case (index)
        8'd0: program_word = 32'h200000b7;  // lui x1, 0x20000
        8'd1: program_word = 32'h0140a103;  // lw x2, 20(x1)
        8'd2: program_word = 32'h0020a823;  // sw x2, 16(x1)
        8'd3: program_word = 32'hcd017057;  // vsetivli x0, 2, e32, m1, ta, ma
        8'd4: program_word = 32'h00700193;  // addi x3, x0, 7
        8'd5: program_word = 32'h4201e0d7;  // vmv.s.x v1, x3
        default: program_word = 32'h00000013;
      endcase
    end else if (MProgram) begin
      case (index)
        8'd0: program_word = 32'hff800093;  // addi x1, x0, -8
        8'd1: program_word = 32'h00300113;  // addi x2, x0, 3
        8'd2: program_word = 32'h022081b3 | {17'd0, cover_m_variant, 12'd0};
        8'd3: program_word = 32'h00118213;  // addi x4, x3, 1
        default: program_word = 32'h00000013;
      endcase
    end else if (AProgram) begin
      case (index)
        8'd0: program_word = 32'h200000b7;  // lui x1, 0x20000
        8'd1: program_word = 32'h01008093;  // addi x1, x1, 16 (LEDs)
        8'd2: begin
          case (cover_atomic_case)
            2'd1: program_word = 32'h0010a1af;  // amoadd.w x3, x1, (x1)
            2'd2: program_word = 32'h1020a1af;  // illegal LR.W (rs2 != 0)
            2'd3: program_word = 32'h1810a22f;  // sc.w x4, x1, (x1), no reservation
            default: program_word = 32'h1000a1af;  // lr.w x3, (x1)
          endcase
        end
        8'd3: program_word = 32'h1810a22f;  // sc.w x4, x1, (x1)
        default: program_word = 32'h00000013;
      endcase
    end else if (VProgram) begin
      case (index)
        8'd0: program_word = 32'h200000b7;  // lui x1, 0x20000
        8'd1: program_word = 32'h01008093;  // addi x1, x1, 16 (LEDs)
        8'd2: begin
          case (cover_vector_case)
            2'd1: program_word = 32'hcc017057;  // vsetivli x0, 2, e8 (EEW32 illegal)
            2'd2: program_word = 32'hcd007057;  // vsetivli x0, 0, e32 (empty)
            2'd3: program_word = 32'hcc017057;  // vsetivli x0, 2, e8
            default: program_word = 32'hcd017057;  // vsetivli x0, 2, e32
          endcase
        end
        8'd3: begin
          case (cover_vector_case)
            2'd3: program_word = 32'h02008087;  // vle8.v v1, (x1)
            default: program_word = 32'h0200e087;  // vle32.v v1, (x1)
          endcase
        end
        8'd4: begin
          case (cover_vector_case)
            2'd3: program_word = 32'h020080a7;  // vse8.v v1, (x1)
            default: program_word = 32'h0200e0a7;  // vse32.v v1, (x1)
          endcase
        end
        default: program_word = 32'h00000013;
      endcase
    end else if (PcProgram) begin
      // MTIP is already pending at reset. Enable it before a buffered
      // ADDI or FENCE.I, or at the end of the cache line with no buffered
      // successor. The handler begins at the already cached MEPC read.
      case (index)
        8'd0: program_word = 32'h100000b7;  // lui x1, 0x10000
        8'd1: program_word = 32'h01408093;  // addi x1, x1, 20
        8'd2: program_word = 32'h30509073;  // csrw mtvec, x1
        8'd3: program_word = 32'h08000113;  // addi x2, x0, 128
        8'd4: program_word = 32'h30411073;  // csrw mie, x2
        8'd5: program_word = 32'h34102273;  // csrr x4, mepc (also handler entry)
        8'd6: program_word = cover_irq_case == 1 ? 32'h00118193 : 32'h30046073;
        8'd7: begin
          case (cover_irq_case)
            2'd1: program_word = 32'h30046073;  // csrsi mstatus, 8
            2'd2: program_word = 32'h0000100f;  // fence.i
            default: program_word = 32'h00118193;  // addi x3, x3, 1
          endcase
        end
        default: program_word = 32'h00000013;
      endcase
    end else if (MmioOnly) begin
      case (index)
        8'd0: program_word = 32'h200000b7;  // lui x1, 0x20000
        8'd1: program_word = 32'h0140a103;  // lw x2, 20(x1)   (GPIO buttons)
        8'd2: program_word = 32'h0020a823;  // sw x2, 16(x1)   (GPIO LEDs)
        8'd3: program_word = 32'h200010b7;  // lui x1, 0x20001
        8'd4: program_word = 32'h0020a023;  // sw x2, 0(x1)    (exit and halt)
        default: program_word = 32'h00000013;
      endcase
    end else
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

      if (!MmioOnly && trace_valid) begin
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
      if (!MmioOnly) begin
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
  end
endmodule
