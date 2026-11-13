// Instruction fetch stage with a streaming cache port and a fetch queue.
//
// The PC advances every cycle unless the cache is filling, the pipeline
// stalls, or a redirect occurs. Cache responses arrive one cycle after
// the request and are written into a four-entry queue; the queue output
// is the IF/ID interface. The queue absorbs fetch latency and lets the
// decoder consume one instruction per cycle, which is what allows a
// cache-hit stream to run at one instruction per cycle.
//
// Each queue entry carries the branch prediction that was made when it
// was fetched, so EX can verify it against the resolved branch. A queued
// entry can also carry an instruction-page-fault marker: the fault is
// raised only when the entry reaches EX, so wrong-path fetches that are
// flushed before reaching EX never trap.

`default_nettype none

module rv32_if_stage (
  input logic clk,
  input logic rst,
  input logic halt,
  input logic [31:0] boot_addr,
  input logic stall,
  input logic flush,
  input logic [31:0] redirect_pc,
  input logic pred_taken,
  input logic [31:0] pred_target,
  /* Streaming instruction memory port. */
  output logic imem_req,
  output logic [31:0] imem_addr,
  input logic imem_rsp_valid,
  input logic [31:0] imem_rsp_addr,
  input logic [31:0] imem_rsp_data,
  input logic imem_miss,
  input logic imem_busy,
  input logic imem_fault,
  input logic [31:0] imem_fault_addr,
  /* IF/ID queue head. */
  output logic if_valid,
  output logic [31:0] if_pc,
  output logic [31:0] if_instr,
  output logic if_fault,
  output logic if_pred_taken,
  output logic [31:0] if_pred_target,
  output logic [31:0] fetch_pc,
  input logic if_consume
);

  localparam int DEPTH = 4;

  logic [31:0] pc_if;
  logic [31:0] last_req;
  logic [31:0] q_pc[0:DEPTH-1];
  logic [31:0] q_instr[0:DEPTH-1];
  logic q_fault[0:DEPTH-1];
  logic q_pred_taken[0:DEPTH-1];
  logic [31:0] q_pred_target[0:DEPTH-1];
  logic [1:0] q_head;
  logic [1:0] q_tail;
  logic [2:0] q_count;
  logic pending_pred_taken;
  logic [31:0] pending_pred_target;

  logic q_empty;
  logic issue;
  logic push;
  logic fault_push;
  logic queue_push;
  logic miss_now;
  logic [31:0] pc_next;

  assign q_empty = (q_count == 3'd0);
  assign issue = !rst && !halt && !stall && !flush && !imem_busy && (q_count < 3'(DEPTH - 1));
  assign miss_now = issue && imem_miss;
  assign pc_next = pred_taken ? pred_target : (pc_if + 32'd4);
  assign fault_push = imem_fault && !flush && !halt && !rst &&
                      (imem_fault_addr == pc_if) && (q_count < 3'(DEPTH));
  assign push = !fault_push && imem_rsp_valid && !flush && !halt && !rst &&
                (q_count < 3'(DEPTH)) && (imem_rsp_addr == last_req);
  assign queue_push = push || fault_push;

  assign imem_req = issue;
  assign imem_addr = pc_if;
  assign fetch_pc = pc_if;

  assign if_valid = !q_empty;
  assign if_pc = q_pc[q_head];
  assign if_instr = q_instr[q_head];
  assign if_fault = q_fault[q_head];
  assign if_pred_taken = q_pred_taken[q_head];
  assign if_pred_target = q_pred_target[q_head];

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_if <= boot_addr;
      last_req <= boot_addr;
      q_head <= '0;
      q_tail <= '0;
      q_count <= '0;
      pending_pred_taken <= 1'b0;
      pending_pred_target <= '0;
    end else if (halt) begin
      // Frozen after a tohost store.
    end else if (flush) begin
      pc_if <= redirect_pc;
      last_req <= redirect_pc;
      q_head <= '0;
      q_tail <= '0;
      q_count <= '0;
    end else begin
      // Queue push and pop.
      if (push) begin
        q_pc[q_tail] <= imem_rsp_addr;
        q_instr[q_tail] <= imem_rsp_data;
        q_fault[q_tail] <= 1'b0;
        q_pred_taken[q_tail] <= pending_pred_taken;
        q_pred_target[q_tail] <= pending_pred_target;
        q_tail <= q_tail + 1'b1;
      end else if (fault_push) begin
        q_pc[q_tail] <= imem_fault_addr;
        q_instr[q_tail] <= 32'h0000_0013;
        q_fault[q_tail] <= 1'b1;
        q_pred_taken[q_tail] <= 1'b0;
        q_pred_target[q_tail] <= '0;
        q_tail <= q_tail + 1'b1;
      end
      if (if_consume) begin
        q_head <= q_head + 1'b1;
      end
      if (queue_push && !if_consume) begin
        q_count <= q_count + 3'd1;
      end else if (!queue_push && if_consume) begin
        q_count <= q_count - 3'd1;
      end

      // Fetch issue and PC advance.
      if (fault_push) begin
        pc_if <= pc_if + 32'd4;
        last_req <= pc_if + 32'd4;
      end else if (issue) begin
        last_req <= pc_if;
        pending_pred_taken <= pred_taken;
        pending_pred_target <= pred_target;
        if (!miss_now) begin
          pc_if <= pc_next;
        end
      end
    end
  end

endmodule
