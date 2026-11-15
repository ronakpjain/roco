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

module roco_cpu_if_stage (
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
  input logic imem_retry_previous,
  input logic [31:0] imem_miss_addr,
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
  // Four-entry queues are shallow muxes, not RAMs with registered read
  // addresses. Keep the ID payload registers near EX so backend hold
  // does not drive a distant RAM read-address feedback path.
  (* mem2reg *) logic [31:0] q_pc[0:DEPTH-1];
  (* mem2reg *) logic [31:0] q_instr[0:DEPTH-1];
  (* mem2reg *) logic q_fault[0:DEPTH-1];
  (* mem2reg *) logic q_pred_taken[0:DEPTH-1];
  (* mem2reg *) logic [31:0] q_pred_target[0:DEPTH-1];
  logic [1:0] q_head;
  logic [1:0] q_tail;
  logic [2:0] q_count;
  logic prediction_pending;
  logic apply_prediction;
  logic pending_pred_taken;
  logic [31:0] pending_pred_target;

  logic q_empty;
  logic issue;
  logic push;
  logic fault_push;
  logic queue_push;
  logic retry_pending;
  logic [31:0] retry_pc, retry_miss_pc;
  logic retry_previous_q;
  logic [31:0] request_pc;
  logic [31:0] pc_next;
  // Asynchronous reset can only clear to a constant, so the image base
  // address is loaded on the first cycle after reset instead of during
  // it. Fetch stays idle across that cycle so no request uses the zero
  // PC that the reset leaves behind.
  logic boot_load;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      boot_load <= 1'b1;
    end else begin
      boot_load <= 1'b0;
    end
  end

  assign q_empty = (q_count == 3'd0);
  // A request may be issued on a redirect cycle. Flush discards its
  // response and overrides PC/queue updates below, so branch resolution
  // need not feed the instruction-cache request and miss-counter paths.
  // Busy/miss feedback controls one retry-valid flop, not the wide PC
  // register enable. Requests may repeat while busy; the cache/MMU ignores
  // unaccepted requests and the response address still validates each push.
  assign request_pc = retry_pending ? (retry_previous_q ? retry_miss_pc : retry_pc) : pc_if;
  assign apply_prediction = prediction_pending && pending_pred_taken;
  assign issue = !boot_load && !halt && !stall && !apply_prediction && (q_count < 3'(DEPTH - 1));
  assign pc_next = request_pc + 32'd4;
  assign fault_push = imem_fault && !halt && (imem_fault_addr == request_pc) && (q_count < 3'(DEPTH));
  assign push = !fault_push && imem_rsp_valid && !halt &&
                (q_count < 3'(DEPTH)) && (imem_rsp_addr == last_req);
  assign queue_push = push || fault_push;

  assign imem_req = issue;
  assign imem_addr = request_pc;
  assign fetch_pc = request_pc;

  // Retry payload is captured independently of late acceptance control.
  always_ff @(posedge clk) begin
    retry_pc <= request_pc;
    retry_miss_pc <= imem_miss_addr;
    retry_previous_q <= imem_retry_previous;
  end
  always_ff @(posedge clk or posedge rst) begin
    if (rst) retry_pending <= 1'b0;
    else if (boot_load) retry_pending <= 1'b0;
    else if (!halt) begin
      if (flush || fault_push) retry_pending <= 1'b0;
      // A response-stage miss also wins during a taken-prediction bubble.
      else if (imem_retry_previous) retry_pending <= 1'b1;
      else if (issue) retry_pending <= imem_busy || imem_miss;
    end
  end

  assign if_valid = !q_empty;
  assign if_pc = q_pc[q_head];
  assign if_instr = q_instr[q_head];
  assign if_fault = q_fault[q_head];
  assign if_pred_taken = q_pred_taken[q_head];
  assign if_pred_target = q_pred_target[q_head];

  // Resolve a BTB prediction from the previous request's saved metadata.
  // Taken predictions insert one fetch bubble, separating the BTB read
  // and tag comparison from the PC feedback mux. No fall-through request
  // is issued in that bubble, so the queue still contains the predicted
  // instruction stream and EX can validate predictions unchanged.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) prediction_pending <= 1'b0;
    else if (boot_load || flush || fault_push) prediction_pending <= 1'b0;
    else if (!halt) prediction_pending <= issue;
  end

  // A redirect invalidates queue pointers, not payload bits. Allowing
  // these writes on a flush edge keeps redirect resolution off the many
  // queue and prediction payload enables.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      pending_pred_taken <= 1'b0;
      pending_pred_target <= '0;
    end else if (issue) begin
      pending_pred_taken <= pred_taken;
      pending_pred_target <= pred_target;
    end
  end

  // The tail slot is unobservable while the queue is not full. Refresh
  // its payload speculatively; only pointer/count updates publish a push.
  // This keeps late MMU/cache response validation off the wide payload
  // register enables. A full queue must retain every occupied slot.
  always_ff @(posedge clk) begin
    if (q_count < 3'(DEPTH)) begin
      q_pc[q_tail] <= fault_push ? imem_fault_addr : imem_rsp_addr;
      q_instr[q_tail] <= fault_push ? 32'h0000_0013 : imem_rsp_data;
      q_fault[q_tail] <= fault_push;
      q_pred_taken[q_tail] <= !fault_push && pending_pred_taken;
      // Fault entries never execute a branch; their target is ignored.
      q_pred_target[q_tail] <= pending_pred_target;
    end
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      pc_if <= '0;
      last_req <= '0;
      q_head <= '0;
      q_tail <= '0;
      q_count <= '0;
    end else if (boot_load) begin
      pc_if <= boot_addr;
      last_req <= boot_addr;
      q_head <= '0;
      q_tail <= '0;
      q_count <= '0;
    end else if (halt) begin
      // Frozen after a tohost store.
    end else if (flush) begin
      pc_if <= redirect_pc;
      last_req <= redirect_pc;
      q_head <= '0;
      q_tail <= '0;
      q_count <= '0;
    end else begin
      // Queue pointers and validity retain flush priority. Payload writes
      // are independent below: flushed slots are never made visible.
      if (queue_push) begin
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
        pc_if <= request_pc + 32'd4;
        last_req <= request_pc + 32'd4;
      end else if (apply_prediction) begin
        pc_if <= pending_pred_target;
      end else if (issue) begin
        last_req <= request_pc;
        pc_if <= pc_next;
      end
    end
  end

endmodule
