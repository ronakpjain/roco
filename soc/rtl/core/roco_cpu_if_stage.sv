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
`ifdef ROCO_RVFI_PC_CHECKS
  output logic [31:0] rvfi_fetch_head_pc,
`endif
`ifdef ROCO_RVFI_INSN_CHECKS
  output logic [3:0] rvfi_queue_live,
  output logic [127:0] rvfi_queue_insn,
`endif
  input logic clk,
  input logic rst,
  input logic halt,
  input logic [31:0] boot_addr,
  input logic stall,
  input logic flush,
  input logic [31:0] redirect_pc,
  input logic pred_taken,
  input logic [31:0] pred_target,
  input logic pred_direct,
  input logic [20:0] pred_imm,
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
  output logic if_pred_direct,
  output logic [20:0] if_pred_imm,
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
  (* mem2reg *) logic q_pred_direct[0:DEPTH-1];
  (* mem2reg *) logic [20:0] q_pred_imm[0:DEPTH-1];
  logic pending_pred_direct;
  logic [20:0] pending_pred_imm;
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
  assign if_pred_direct = q_pred_direct[q_head];
  assign if_pred_imm = q_pred_imm[q_head];

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
      pending_pred_direct <= 1'b0;
      pending_pred_imm <= '0;
    end else if (issue) begin
      pending_pred_taken <= pred_taken;
      pending_pred_target <= pred_target;
      pending_pred_direct <= pred_direct;
      pending_pred_imm <= pred_imm;
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
      q_pred_direct[q_tail] <= !fault_push && pending_pred_direct;
      q_pred_imm[q_tail] <= pending_pred_imm;
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

`ifdef ROCO_RVFI_INSN_CHECKS
  for (genvar slot = 0; slot < DEPTH; slot++) begin : g_queue_insn
    logic [1:0] distance;
    assign distance = 2'(slot) - q_head;
    assign rvfi_queue_live[slot] = 3'(distance) < q_count;
    assign rvfi_queue_insn[32*slot+:32] = q_instr[slot];
  end
`endif

`ifdef ROCO_RVFI_PC_CHECKS
  // In the one-cycle hit environment, the response in flight is the next
  // queue entry; without one, the next entry starts at the request PC.
  logic [31:0] rvfi_queue_end_pc;
  assign rvfi_queue_end_pc = prediction_pending ? last_req : request_pc;
  assign rvfi_fetch_head_pc = boot_load ? boot_addr : q_empty ? rvfi_queue_end_pc : if_pc;
  always @(posedge clk) begin
    if (!rst) begin
      assert (!retry_pending && !imem_fault && !imem_busy && !imem_miss);
      assert (imem_rsp_valid == prediction_pending);
      assert (pc_if[1:0] == 0 && last_req[1:0] == 0);
      if (prediction_pending) begin
        assert (imem_rsp_addr == last_req && pc_if == last_req + 32'd4);
        assert (q_count < 3'(DEPTH));
        if (pending_pred_taken) assert (pending_pred_target[1:0] == 0);
        if (pending_pred_taken && pending_pred_direct)
          assert (pending_pred_target == last_req + {{11{pending_pred_imm[20]}}, pending_pred_imm});
      end
      if (boot_load) assert (q_empty && !prediction_pending);
    end
  end
  for (genvar slot = 0; slot < DEPTH; slot++) begin : g_pc_chain
    localparam int Next = (slot + 1) % DEPTH;
    logic [1:0] distance;
    logic [31:0] successor;
    assign distance = 2'(slot) - q_head;
    assign successor = q_pred_taken[slot] ? q_pred_target[slot] : q_pc[slot] + 32'd4;
    always @(posedge clk) begin
      if (!rst && 3'(distance) < q_count) begin
        assert (!q_fault[slot] && q_pc[slot][1:0] == 0);
        if (q_pred_taken[slot]) assert (q_pred_target[slot][1:0] == 0);
        if (q_pred_taken[slot] && q_pred_direct[slot])
          assert (q_pred_target[slot] == q_pc[slot] + {{11{q_pred_imm[slot][20]}}, q_pred_imm[slot]});
        if (3'(distance) + 3'd1 == q_count)
          assert (successor == rvfi_queue_end_pc);
          else assert (successor == q_pc[Next]);
      end
    end
  end
`endif

`ifdef ROCO_RVFI_NO_DIV_CHECKS
  // A slot is live iff its distance from the circular head is below count.
  // The payload may be arbitrary in the other slots, including after flush.
  // Every encoding class the harness never fetches is excluded from live
  // slots: M, vector, AMO/LR/SC, FENCE.I/SFENCE, privilege returns, and CSR
  // accesses that could enable data translation. Only ECALL/EBREAK remain
  // from the SYSTEM funct3-zero space, matching both fetch restriction sets.
  function automatic logic excluded_enc(input logic [31:0] w);
    excluded_enc =
        (w[6:0] == 7'h33 && w[31:25] == 7'd1) ||
        (w[6:0] == 7'h57) ||
        (w[6:0] == 7'h07) ||
        (w[6:0] == 7'h27) ||
        (w[6:0] == 7'h2f) ||
        (w[6:0] == 7'h0f && w[14:12] != 3'b000) ||
        (w[6:0] == 7'h73 && w[14:12] == 3'b000 &&
         !(w == 32'h0000_0073 || w == 32'h0010_0073)) ||
        (w[6:0] == 7'h73 && w[14:12] != 3'b000 &&
         (w[31:20] == 12'h180 || w[31:20] == 12'h300 || w[31:20] == 12'h302 ||
          w[31:20] == 12'h303 || w[31:20] == 12'h304 || w[31:20] == 12'h344));
  endfunction
  for (genvar slot = 0; slot < DEPTH; slot++) begin : g_no_div
    logic [1:0] distance;
    assign distance = 2'(slot) - q_head;
    always @(posedge clk) begin
      if (!rst && 3'(distance) < q_count) assert (!excluded_enc(q_instr[slot]));
    end
  end
  always @(posedge clk) begin
    if (!rst) begin
      assert (q_count <= 3'(DEPTH) && q_tail == q_head + q_count[1:0]);
      if (if_valid) assert (!excluded_enc(if_instr));
    end
  end
`endif
endmodule
