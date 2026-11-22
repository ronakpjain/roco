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
// not-taken), and installs the target on taken branches, JALs and JALRs.
// Indirect jumps predict their most recently resolved target;
// EX verifies that target before allowing younger instructions to commit.

`default_nettype none

module roco_cpu_branch_predictor #(
    parameter int ENTRIES = 32
) (
  input logic clk,
  input logic rst,
  input logic flush,
  /* Fetch-side prediction. */
  input logic [31:0] if_pc,
  output logic if_pred_taken,
  output logic [31:0] if_pred_target,
  output logic if_pred_direct,
  output logic [20:0] if_pred_imm,
  /* Execute-side update. The byte offset inside a word is never used. */
  input logic [31:2] ex_pc,
  input logic ex_update,
  input logic ex_is_branch,
  input logic ex_is_jal,
  input logic ex_is_jalr,
  input logic ex_taken,
  input logic [20:0] ex_imm,
  input logic [31:0] ex_target
);

  localparam int IDX_BITS = $clog2(ENTRIES);
  localparam int TAG_LO   = IDX_BITS + 2;
  localparam int TAG_BITS = 32 - TAG_LO;

  logic [1:0] counters[0:ENTRIES-1];
  logic [TAG_BITS-1:0] tags[0:ENTRIES-1];
  logic [31:0] targets[0:ENTRIES-1];
  logic valid[0:ENTRIES-1];
  logic direct[0:ENTRIES-1];
  logic [20:0] immediates[0:ENTRIES-1];

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
  // The target is consumed only when if_pred_taken is asserted. Fetch
  // computes its own sequential PC, so a miss need not select a fallback
  // address through the tag comparator and wide target mux.
  assign if_pred_target = targets[if_idx];
  // A matching PC tag and direct-branch immediate identify the target
  // without putting another address sum in the decode stage.
  assign if_pred_direct = direct[if_idx] && (if_pc[1:0] == 2'b00);
  assign if_pred_imm = immediates[if_idx];

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

  // Yosys only accepts an asynchronous reset branch guarded by the reset
  // signal alone, so the flush clear repeats the same entry sweep instead of
  // sharing one `rst || flush` branch.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      for (i = 0; i < ENTRIES; i = i + 1) begin
        valid[i] <= 1'b0;
        counters[i] <= 2'b01;
      end
    end else if (flush) begin
      for (i = 0; i < ENTRIES; i = i + 1) begin
        valid[i] <= 1'b0;
        counters[i] <= 2'b01;
      end
    end else if (ex_update) begin
      if (ex_is_branch) begin
        counters[ex_idx] <= counter_next;
        if (ex_taken) begin
          valid[ex_idx] <= 1'b1;
        end
      end else if (ex_is_jal || ex_is_jalr) begin
        counters[ex_idx] <= 2'b11;
        valid[ex_idx] <= 1'b1;
      end
    end
  end

  // Tag and target arrays carry no reset value, so they stay out of the
  // asynchronous reset cone and keep mapping to distributed RAM.
  always_ff @(posedge clk) begin
    if (ex_update && (((ex_is_branch && ex_taken)) || ex_is_jal || ex_is_jalr)) begin
      tags[ex_idx] <= ex_tag;
      targets[ex_idx] <= ex_target;
      direct[ex_idx] <= !ex_is_jalr;
      immediates[ex_idx] <= ex_imm;
    end
  end

`ifdef ROCO_RVFI_PC_CHECKS
  `define ROCO_BTB_FORMAL
`endif
`ifdef ROCO_IRQ_PIPELINE_CHECKS
  `define ROCO_BTB_FORMAL
`endif
`ifdef ROCO_SOC_PC_FORMAL
  `define ROCO_BTB_FORMAL
`endif
`ifdef ROCO_BTB_FORMAL
  // A matching tag and immediate stand in for a wide direct-target compare
  // in ID/EX. Prove that the BTB maintains the relation this relies on.
  for (genvar slot = 0; slot < ENTRIES; slot++) begin : g_direct_target
    logic [31:0] entry_pc;
    assign entry_pc = {tags[slot], IDX_BITS'(slot), 2'b00};
    always @(posedge clk) begin
      if (!rst && valid[slot]) begin
        assert (targets[slot][1:0] == 0);
        if (direct[slot])
          assert (targets[slot] == entry_pc + {{11{immediates[slot][20]}}, immediates[slot]});
      end
    end
  end
`endif
  `undef ROCO_BTB_FORMAL
endmodule
