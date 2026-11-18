`default_nettype none

// Check the four DSP partial products against signed/unsigned half-word
// decomposition for every multiply variant. Together with the carry-save
// recombination proof this fixes the full product for arbitrary operands.
module mul_prod_contract (
  input logic clk
);
  (* anyseq *) logic [31:0] a, b;
  (* anyseq *) logic [2:0] variant;
  logic [31:0] p0, p3;
  logic [33:0] p1, p2;
  roco_cpu_mul_prod dut (
      .a(a),
      .b(b),
      .variant(variant),
      .p0(p0),
      .p1(p1),
      .p2(p2),
      .p3(p3)
  );

  logic signed_a, signed_b;
  logic [33:0] exp_p1, exp_p2;
  logic [31:0] exp_p0, exp_p3;
  assign signed_a = (variant == `RV32_MD_MULH) || (variant == `RV32_MD_MULHSU);
  assign signed_b = (variant == `RV32_MD_MULH);
  assign exp_p0 = a[15:0] * b[15:0];
  assign exp_p1 = 34'($signed({1'b0, a[15:0]})) * 34'($signed({signed_b && b[31], b[31:16]}));
  assign exp_p2 = 34'($signed({signed_a && a[31], a[31:16]})) * 34'($signed({1'b0, b[15:0]}));
  assign exp_p3 = 32'($signed(
      {signed_a && a[31], a[31:16]}
  ) * $signed(
      {signed_b && b[31], b[31:16]}
  ));
  always @(posedge clk) begin
    assert (p0 == exp_p0);
    assert (p1 == exp_p1);
    assert (p2 == exp_p2);
    assert (p3 == exp_p3);
    cover (variant == `RV32_MD_MULH && a[31] && !b[31] && |p3[31:16]);
    cover (variant == `RV32_MD_MULHSU && !a[31] && b[31] && |p3[31:16]);
    cover (variant == `RV32_MD_MULHU && a[31] && b[31] && |p3[31:16]);
    cover (variant == `RV32_MD_MUL && (|p3[31:16] || (|p1 && |p2) == 0));
  end
endmodule
