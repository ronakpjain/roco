// Multiply/divide unit testbench.
//
// Directed corner cases plus a pseudo-random sweep, each compared with
// an independently written 128-bit reference model.

`timescale 1ns / 1ps

module tb_muldiv;

  logic clk;
  logic rst;
  logic halt;
  logic [2:0] op;
  logic [31:0] a;
  logic [31:0] b;
  logic start;
  logic [31:0] p0;
  logic [31:0] p1;
  logic [31:0] p2;
  logic [31:0] p3;
  logic [31:0] sub_a;
  logic [31:0] sub_b;
  logic [2:0] variant;
  logic [31:0] mul_result;
  logic busy;
  logic done;
  logic [31:0] div_result;

  int errors;
  int checks;
  int cycles;
  int unsigned seed;

  localparam logic [2:0] MUL = 3'd0;
  localparam logic [2:0] MULH = 3'd1;
  localparam logic [2:0] MULHSU = 3'd2;
  localparam logic [2:0] MULHU = 3'd3;
  localparam logic [2:0] DIV = 3'd4;
  localparam logic [2:0] DIVU = 3'd5;
  localparam logic [2:0] REM = 3'd6;
  localparam logic [2:0] REMU = 3'd7;

  assign variant = op;

  rv32_mul_prod u_prod (
      .a(a),
      .b(b),
      .p0(p0),
      .p1(p1),
      .p2(p2),
      .p3(p3),
      .sub_a(sub_a),
      .sub_b(sub_b)
  );

  rv32_mul_finish u_finish (
      .p0(p0),
      .p1(p1),
      .p2(p2),
      .p3(p3),
      .sub_a(sub_a),
      .sub_b(sub_b),
      .variant(variant),
      .result(mul_result)
  );

  rv32_divider u_div (
      .clk(clk),
      .rst(rst),
      .halt(halt),
      .op(op),
      .a(a),
      .b(b),
      .start(start),
      .busy(busy),
      .done(done),
      .div_result(div_result)
  );

  always #5 clk = ~clk;

  // Icarus drops the signedness of / and % inside tasks and functions,
  // so the reference model lives in a module-level combinational block.
  logic [2:0] ref_op;
  logic [31:0] ref_a;
  logic [31:0] ref_b;
  logic [31:0] ref_expected;
  logic [127:0] prod_ss;
  logic [127:0] prod_su;
  logic [127:0] prod_uu;

  always_comb begin
    prod_ss = {{64{ref_a[31]}}, ref_a} * {{64{ref_b[31]}}, ref_b};
    prod_su = {{64{ref_a[31]}}, ref_a} * {64'd0, ref_b};
    prod_uu = {64'd0, ref_a} * {64'd0, ref_b};
    case (ref_op)
      MUL: begin
        ref_expected = prod_uu[31:0];
      end
      MULH: begin
        ref_expected = prod_ss[63:32];
      end
      MULHSU: begin
        ref_expected = prod_su[63:32];
      end
      MULHU: begin
        ref_expected = prod_uu[63:32];
      end
      DIV: begin
        ref_expected = (ref_b == 32'd0) ? 32'hffff_ffff : 32'($signed(ref_a) / $signed(ref_b));
      end
      DIVU: begin
        ref_expected = (ref_b == 32'd0) ? 32'hffff_ffff : ref_a / ref_b;
      end
      REM: begin
        ref_expected = (ref_b == 32'd0) ? ref_a : 32'($signed(ref_a) % $signed(ref_b));
      end
      default: begin
        ref_expected = (ref_b == 32'd0) ? ref_a : ref_a % ref_b;
      end
    endcase
  end

  task automatic check(input logic [2:0] fop, input logic [31:0] fa, input logic [31:0] fb);
    logic [31:0] expected;
    logic [31:0] actual;
    ref_op = fop;
    ref_a = fa;
    ref_b = fb;
    op = fop;
    a = fa;
    b = fb;
    if (fop[2]) begin
      // Hold start across a full cycle: a same-edge deassert would race
      // the unit's clocked start detection.
      @(negedge clk);
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      cycles = 0;
      while (!done) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (cycles > 64) begin
          $display("tb_muldiv: FAIL timeout op=%0d a=%08x b=%08x", fop, fa, fb);
          errors = errors + 1;
          return;
        end
      end
      #1;
      actual = div_result;
      @(posedge clk);
    end else begin
      #1;
      actual = mul_result;
    end
    expected = ref_expected;
    checks = checks + 1;
    if (actual !== expected) begin
      $display("tb_muldiv: FAIL op=%0d a=%08x b=%08x got=%08x exp=%08x", fop, fa, fb, actual,
               expected);
      errors = errors + 1;
    end
    @(posedge clk);
  endtask

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    halt = 1'b0;
    start = 1'b0;
    op = 3'd0;
    a = 32'd0;
    b = 32'd0;
    errors = 0;
    checks = 0;
    seed = 32'h1234_5678;
    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(posedge clk);

    // Multiply corner cases.
    check(MUL, 32'd0, 32'd0);
    check(MUL, 32'hffff_ffff, 32'hffff_ffff);
    check(MULH, 32'hffff_ffff, 32'hffff_ffff);
    check(MULH, 32'h8000_0000, 32'h8000_0000);
    check(MULH, 32'h8000_0000, 32'hffff_ffff);
    check(MULHSU, 32'hffff_fffe, 32'hffff_ffff);
    check(MULHSU, 32'h8000_0000, 32'hffff_ffff);
    check(MULHU, 32'hffff_ffff, 32'hffff_ffff);
    check(MUL, 32'd1, 32'd1);
    check(MUL, 32'd7, 32'hffff_fff9);

    // Divide corner cases: zero divisor, signed overflow, signs.
    check(DIV, 32'd1, 32'd0);
    check(DIVU, 32'd1, 32'd0);
    check(REM, 32'd1, 32'd0);
    check(REMU, 32'd1, 32'd0);
    check(DIV, 32'h8000_0000, 32'hffff_ffff);
    check(REM, 32'h8000_0000, 32'hffff_ffff);
    check(DIV, 32'hffff_fff9, 32'd2);
    check(REM, 32'hffff_fff9, 32'd2);
    check(DIV, 32'h8000_0000, 32'd1);
    check(REM, 32'd100, 32'hffff_fffb);
    check(DIVU, 32'hffff_ffff, 32'hffff_fffe);
    check(REMU, 32'hffff_ffff, 32'hffff_fffe);
    check(DIVU, 32'hffff_ffff, 32'd1);
    check(REMU, 32'hffff_ffff, 32'd1);
    check(DIV, 32'd0, 32'd3);
    check(REM, 32'd0, 32'd3);

    // Random sweep.
    for (int n = 0; n < 400; n = n + 1) begin
      a = $random(seed);
      b = $random(seed);
      for (int f = 0; f < 8; f = f + 1) begin
        check(3'(f), a, b);
      end
    end

    if (errors == 0) begin
      $display("tb_muldiv: PASS (%0d checks)", checks);
    end else begin
      $display("tb_muldiv: FAIL (%0d errors in %0d checks)", errors, checks);
      $fatal(1);
    end
    $finish;
  end

endmodule
