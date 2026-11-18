// Included only by the divider formal job. The reference performs two
// restoring radix-2 steps per active digit, rather than choosing among
// three parallel radix-4 subtractions.
logic [4:0] ref_phase;
logic [31:0] ref_a, ref_b, ref_shift, ref_den, ref_rem, ref_quot, ref_result;
logic [2:0] ref_op;
logic ref_signed, ref_rem_op;
logic [32:0] ref_first_in, ref_first_out, ref_second_in, ref_second_out;
logic ref_first_take, ref_second_take;
assign ref_signed = (ref_op == `RV32_MD_DIV || ref_op == `RV32_MD_REM);
assign ref_rem_op = (ref_op == `RV32_MD_REM || ref_op == `RV32_MD_REMU);
assign ref_first_in = {ref_rem, ref_shift[31]};
assign ref_first_take = ref_first_in >= {1'b0, ref_den};
assign ref_first_out = ref_first_take ? ref_first_in - {1'b0, ref_den} : ref_first_in;
assign ref_second_in = {ref_first_out[31:0], ref_shift[30]};
assign ref_second_take = ref_second_in >= {1'b0, ref_den};
assign ref_second_out = ref_second_take ? ref_second_in - {1'b0, ref_den} : ref_second_in;

function automatic [31:0] ref_negate(input logic [31:0] x, input logic negate);
  ref_negate = negate ? 0 - x : x;
endfunction

always @(posedge clk) begin
  if (rst) begin
    ref_phase <= 0;
    ref_a <= 0;
    ref_b <= 0;
    ref_op <= 0;
    ref_shift <= 0;
    ref_den <= 0;
    ref_rem <= 0;
    ref_quot <= 0;
    ref_result <= 0;
  end else if (!halt) begin
    case (ref_phase)
      0, 20: begin
        ref_phase <= start ? 5'd1 : 5'd0;
        if (start) begin
          ref_a <= a;
          ref_b <= b;
          ref_op <= op;
        end
      end
      1: begin
        ref_phase <= 2;
        ref_shift <= ref_negate(ref_a, ref_signed && ref_a[31]);
        ref_den <= ref_negate(ref_b, ref_signed && ref_b[31]);
        ref_rem <= 0;
        ref_quot <= 0;
      end
      2: ref_phase <= 3;
      19: begin
        ref_phase <= 20;
        if (ref_b == 0) ref_result <= ref_rem_op ? ref_a : 32'hffff_ffff;
        else if (ref_rem_op) ref_result <= ref_negate(ref_rem, ref_signed && ref_a[31]);
        else ref_result <= ref_negate(ref_quot, ref_signed && (ref_a[31] != ref_b[31]));
      end
      default: begin
        ref_phase <= ref_phase + 1'b1;
        ref_shift <= {ref_shift[29:0], 2'b00};
        ref_rem <= ref_second_out[31:0];
        ref_quot <= {ref_quot[29:0], ref_first_take, ref_second_take};
      end
    endcase
  end
end

// Strengthening invariants are asserted, not assumed. They let induction
// relate arbitrary in-flight DUT states to the reference at every digit.
always @(posedge clk) begin
  if (!rst) begin
    assert (ref_phase <= 20);
    assert (fsm_busy == (ref_phase >= 1 && ref_phase <= 19));
    assert (loading == (ref_phase == 1));
    assert (preparing == (ref_phase == 2));
    assert (finishing == (ref_phase == 19));
    assert (busy == (ref_phase != 0));
    assert (done == (ref_phase == 20));
    assert (div_result == ref_result);
    if (ref_phase == 1) assert ({start_a, start_b, start_op} == {ref_a, ref_b, ref_op});
    if (ref_phase >= 2 && ref_phase <= 19) begin
      assert (div_by_zero == (ref_den == 0));
      assert (div_by_zero == (ref_b == 0));
      assert (div_is_rem == ref_rem_op);
      assert (div_orig_a == ref_a);
      assert (div_sign == (ref_signed && (ref_a[31] != ref_b[31])));
      assert (div_a_neg == (ref_signed && ref_a[31]));
      assert (div_divisor == ref_den);
      if (ref_den != 0) begin
        assert (ref_rem < ref_den);
        assert (div_dividend == ref_shift);
        assert (div_rem == {1'b0, ref_rem});
        assert (div_quot == ref_quot);
      end
    end
    if (ref_phase >= 2 && ref_phase <= 18) begin
      if (ref_phase == 2)
        assert (div_chunks == 16);
        else assert (div_chunks == 5'd19 - ref_phase);
    end
    if (ref_phase >= 3 && ref_phase <= 18)
      assert (div_triple == 34'(ref_den) + (34'(ref_den) << 1));

    cover (done && ref_op == `RV32_MD_DIV && ref_a == 32'h8000_0000 && ref_b == 32'hffff_ffff);
    cover (done && ref_op == `RV32_MD_DIVU && ref_b != 0);
    cover (done && ref_op == `RV32_MD_REM && ref_a[31] && ref_b != 0);
    cover (done && ref_op == `RV32_MD_REMU && ref_b == 0);
    cover (busy && !done && halt);
  end
end
