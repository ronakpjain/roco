// Bimodal 2-bit branch predictor with a branch target buffer.
//
// 32 entries indexed by pc[6:2]. Each entry has a 2-bit saturating
// counter (00 strongly not-taken .. 11 strongly taken) and a BTB tag
// and target. The IF stage predicts taken only when the counter says
// taken and a matching BTB target exists. The prediction is carried
// through the fetch queue and ID/EX so EX compares it with the real
// outcome without re-reading a table that may have changed.
//
// Resolution updates the counter (increment on taken, decrement on
// not-taken), installs the target on taken branches and JALs, and clears
// the entry for a JALR (dynamic target).

`default_nettype none

module rv32_branch_predictor #(
    parameter int ENTRIES = 32
) (
  input logic clk,
  input logic rst,
  input logic flush,
  /* Fetch-side prediction. */
  input logic [31:0] if_pc,
  output logic if_pred_taken,
  output logic [31:0] if_pred_target,
  /* Execute-side update. */
  input logic [31:0] ex_pc,
  input logic ex_update,
  input logic ex_is_branch,
  input logic ex_is_jal,
  input logic ex_is_jalr,
  input logic ex_taken,
  input logic [31:0] ex_target
);

  localparam int IDX_BITS = $clog2(ENTRIES);
  localparam int TAG_LO   = IDX_BITS + 2;
  localparam int TAG_BITS = 32 - TAG_LO;

  logic [1:0] counters[0:ENTRIES-1];
  logic [TAG_BITS-1:0] tags[0:ENTRIES-1];
  logic [31:0] targets[0:ENTRIES-1];
  logic valid[0:ENTRIES-1];

  logic [IDX_BITS-1:0] if_idx;
  logic [IDX_BITS-1:0] ex_idx;
  logic [TAG_BITS-1:0] if_tag;
  logic [TAG_BITS-1:0] ex_tag;
  logic if_btb_hit;
  logic [1:0] counter_next;
  integer i;

  assign if_idx = if_pc[IDX_BITS+1:2];
  assign if_tag = if_pc[31:TAG_LO];
  assign ex_idx = ex_pc[IDX_BITS+1:2];
  assign ex_tag = ex_pc[31:TAG_LO];

  assign if_btb_hit = valid[if_idx] && (tags[if_idx] == if_tag);

  assign if_pred_taken = counters[if_idx][1] && if_btb_hit;
  assign if_pred_target = if_btb_hit ? targets[if_idx] : (if_pc + 32'd4);

  always_comb begin
    counter_next = counters[ex_idx];
    if (ex_taken) begin
      if (counter_next != 2'b11) begin
        counter_next = counter_next + 2'd1;
      end
    end else begin
      if (counter_next != 2'b00) begin
        counter_next = counter_next - 2'd1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      for (i = 0; i < ENTRIES; i = i + 1) begin
        valid[i] <= 1'b0;
        counters[i] <= 2'b01;
      end
    end else if (ex_update) begin
      if (ex_is_branch) begin
        counters[ex_idx] <= counter_next;
        if (ex_taken) begin
          valid[ex_idx] <= 1'b1;
          tags[ex_idx] <= ex_tag;
          targets[ex_idx] <= ex_target;
        end
      end else if (ex_is_jal) begin
        counters[ex_idx] <= 2'b11;
        valid[ex_idx] <= 1'b1;
        tags[ex_idx] <= ex_tag;
        targets[ex_idx] <= ex_target;
      end else if (ex_is_jalr) begin
        counters[ex_idx] <= 2'b00;
        valid[ex_idx] <= 1'b0;
      end
    end
  end

endmodule
