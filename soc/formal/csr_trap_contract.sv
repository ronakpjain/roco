`default_nettype none

// Architectural checks for the CSR file, driven by accepted writes and
// legal returns. EX instruction decoding and trap timing are separate.
module csr_trap_contract (
  input logic clk
);
  localparam logic [1:0] UserMode = 0, Supervisor = 1, Machine = 3;
  localparam logic [31:0] IrqBits = 32'h0000_0aaa, DelegableIrqs = 32'h0000_0222;
  localparam logic [31:0] SoftwarePending = 32'h0000_002a, DelegableExceptions = 32'h0000_b35d;

  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;
  (* anyseq *) logic timer_irq, external_irq, write_req, trap_req, irq_trap, return_req, sret;
  (* anyseq *) logic [11:0] raddr, wr_addr;
  (* anyseq *) logic [31:0] wr_data, epc, tval;
  (* anyseq *) logic [4:0] exception;
  logic [31:0] rdata, trap_vector, cause;
  logic [1:0] priv;
  logic irq_req, take_trap, wr_en, mret_en, sret_en, mstatus_mprv, mstatus_tsr;
  logic [4:0] irq_code;

  // The input is the handoff from EX, not an instruction stream. Do not
  // inject an interrupt the CSR file did not offer, or a return from an
  // insufficient privilege. Trap entry may not coincide with a CSR write.
  assign take_trap = trap_req && (!irq_trap || irq_req);
  assign cause = irq_trap ? {1'b1, 26'd0, irq_code} : {27'd0, exception};
  assign mret_en = !take_trap && return_req && !sret && priv == Machine;
  assign sret_en = !take_trap && return_req && sret &&
                   (priv == Machine || (priv == Supervisor && !mstatus_tsr));
  assign wr_en = write_req && !take_trap && !mret_en && !sret_en &&
                 wr_addr[9:8] <= priv && wr_addr[11:10] != 2'b11;

  roco_cpu_csr dut (
      .clk(clk),
      .rst(rst),
      .raddr(raddr),
      .rdata(rdata),
      .exists(),
      .read_ok(),
      .write_ok(),
      .wr_en(wr_en),
      .wr_addr(wr_addr),
      .wr_data(wr_data),
      .irq_timer(timer_irq),
      .irq_external(external_irq),
      .irq_software(1'b0),
      .irq_req(irq_req),
      .irq_code(irq_code),
      .vset_en(1'b0),
      .vset_vl(5'd0),
      .vset_vtype(32'd0),
      .vstart_we(1'b0),
      .vstart_data(5'd0),
      .vl(),
      .vtype_vta(),
      .vtype_sew(),
      .vstart_out(),
      .trap_en(take_trap),
      .trap_pc(epc),
      .trap_cause(cause),
      .trap_tval(tval),
      .mret_en(mret_en),
      .sret_en(sret_en),
      .retire(1'b0),
      .priv(priv),
      .mtvec(),
      .stvec(),
      .trap_vector(trap_vector),
      .mepc(),
      .sepc(),
      .satp(),
      .satp_write(),
      .mstatus_mprv(mstatus_mprv),
      .mstatus_sum(),
      .mstatus_mxr(),
      .mstatus_tvm(),
      .mstatus_tsr(mstatus_tsr),
      .mstatus_mpp()
  );

  typedef struct packed {
    logic [31:0] vec, epc, cause, tval;
    logic enabled, previous_enabled;
    logic [1:0] previous_priv;
  } trap_state_t;
  trap_state_t machine, supervisor;
  logic [1:0] mode;
  logic mprv, tsr;
  logic [31:0] enabled_irqs, sw_pending, delegated_irqs, delegated_exceptions, pending;
  logic [4:0] selected;
  logic [1:0] selected_mode;
  logic supervisor_trap;
  logic [31:0] vec;

  function automatic logic [31:0] warl_vec(input logic [31:0] word);
    warl_vec = (word & 32'hffff_fffc) | 32'(word[1:0] == 1);
  endfunction

  function automatic logic [4:0] code_for_rank(input int rank);
    case (rank)
      0: code_for_rank = 11;
      1: code_for_rank = 3;
      2: code_for_rank = 7;
      3: code_for_rank = 9;
      4: code_for_rank = 1;
      default: code_for_rank = 5;
    endcase
  endfunction

  assign pending = sw_pending | (32'(external_irq) << 11) | (32'(timer_irq) << 7);
  // Choose the highest target privilege first, then the architectural
  // cause priority among interrupts routed to that privilege.
  always_comb begin
    selected = 0;
    selected_mode = UserMode;
    for (integer rank = 5; rank >= 0; rank = rank - 1) begin
      logic [4:0] code;
      logic [1:0] target;
      logic global_enable;
      code = code_for_rank(rank);
      target = delegated_irqs[code] ? Supervisor : Machine;
      global_enable = delegated_irqs[code] ? supervisor.enabled : machine.enabled;
      if (pending[code] && enabled_irqs[code] && target >= selected_mode &&
          (mode < target || (mode == target && global_enable))) begin
        selected = code;
        selected_mode = target;
      end
    end
  end
  assign supervisor_trap = irq_trap ? selected_mode == Supervisor :
                           mode != Machine && delegated_exceptions[exception];
  assign vec = supervisor_trap ? supervisor.vec : machine.vec;

  always @(posedge clk) begin
    if (rst) begin
      mode <= Machine;
      mprv <= 0;
      tsr <= 0;
      machine <= '0;
      supervisor <= '0;
      enabled_irqs <= '0;
      sw_pending <= '0;
      delegated_irqs <= '0;
      delegated_exceptions <= '0;
    end else begin
      assert (priv == mode && mstatus_mprv == mprv && mstatus_tsr == tsr);
      assert (irq_req == (selected != 0) && irq_code == selected);
      if (take_trap)
        assert (trap_vector == (vec & 32'hffff_fffc) +
                (vec[0] && irq_trap ? 32'(selected) * 4 : 32'd0));
      case (raddr)
        12'h100:
        assert ({rdata[8], rdata[5], rdata[1]} ==
                        {supervisor.previous_priv == Supervisor,
                         supervisor.previous_enabled, supervisor.enabled});
        12'h104: assert (rdata == (enabled_irqs & delegated_irqs));
        12'h105: assert (rdata == supervisor.vec);
        12'h141: assert (rdata == supervisor.epc);
        12'h142: assert (rdata == supervisor.cause);
        12'h143: assert (rdata == supervisor.tval);
        12'h144: assert (rdata == (pending & delegated_irqs));
        12'h300:
        assert ({rdata[22], rdata[17], rdata[12:11], rdata[7], rdata[3]} ==
                        {tsr, mprv, machine.previous_priv, machine.previous_enabled, machine.enabled});
        12'h302: assert (rdata == delegated_exceptions);
        12'h303: assert (rdata == delegated_irqs);
        12'h304: assert (rdata == enabled_irqs);
        12'h305: assert (rdata == machine.vec);
        12'h341: assert (rdata == machine.epc);
        12'h342: assert (rdata == machine.cause);
        12'h343: assert (rdata == machine.tval);
        12'h344: assert (rdata == pending);
        default: begin
        end
      endcase

      if (take_trap) begin
        if (supervisor_trap) begin
          mode <= Supervisor;
          supervisor.epc <= epc & 32'hffff_fffc;
          supervisor.cause <= irq_trap ? 32'h8000_0000 | 32'(selected) : 32'(exception);
          supervisor.tval <= tval;
          supervisor.previous_priv <= mode;
          supervisor.previous_enabled <= supervisor.enabled;
          supervisor.enabled <= 0;
        end else begin
          mode <= Machine;
          machine.epc <= epc & 32'hffff_fffc;
          machine.cause <= irq_trap ? 32'h8000_0000 | 32'(selected) : 32'(exception);
          machine.tval <= tval;
          machine.previous_priv <= mode;
          machine.previous_enabled <= machine.enabled;
          machine.enabled <= 0;
        end
      end else if (mret_en) begin
        mode <= machine.previous_priv;
        if (machine.previous_priv != Machine) mprv <= 0;
        machine.enabled <= machine.previous_enabled;
        machine.previous_enabled <= 1;
        machine.previous_priv <= UserMode;
      end else if (sret_en) begin
        mode <= supervisor.previous_priv;
        mprv <= 0;
        supervisor.enabled <= supervisor.previous_enabled;
        supervisor.previous_enabled <= 1;
        supervisor.previous_priv <= UserMode;
      end else if (wr_en) begin
        case (wr_addr)
          12'h100, 12'h300: begin
            supervisor.enabled <= wr_data[1];
            supervisor.previous_enabled <= wr_data[5];
            supervisor.previous_priv <= wr_data[8] ? Supervisor : UserMode;
            if (wr_addr == 12'h300) begin
              mprv <= wr_data[17];
              tsr <= wr_data[22];
              machine.enabled <= wr_data[3];
              machine.previous_enabled <= wr_data[7];
              machine.previous_priv <= wr_data[12:11] == 2 ? UserMode : wr_data[12:11];
            end
          end
          12'h104: enabled_irqs <= (enabled_irqs & ~delegated_irqs) | (wr_data & delegated_irqs);
          12'h105: supervisor.vec <= warl_vec(wr_data);
          12'h141: supervisor.epc <= wr_data & 32'hffff_fffc;
          12'h142: supervisor.cause <= wr_data;
          12'h143: supervisor.tval <= wr_data;
          12'h144:
          sw_pending <= (sw_pending & ~delegated_irqs) |
                                 (wr_data & delegated_irqs & SoftwarePending);
          12'h302: delegated_exceptions <= wr_data & DelegableExceptions;
          12'h303: delegated_irqs <= wr_data & DelegableIrqs;
          12'h304: enabled_irqs <= wr_data & IrqBits;
          12'h305: machine.vec <= warl_vec(wr_data);
          12'h341: machine.epc <= wr_data & 32'hffff_fffc;
          12'h342: machine.cause <= wr_data;
          12'h343: machine.tval <= wr_data;
          12'h344: sw_pending <= wr_data & SoftwarePending;
          default: begin
          end
        endcase
      end

      cover (take_trap && !irq_trap && supervisor_trap && mode == UserMode);
      cover (take_trap && irq_trap && supervisor_trap && vec[0] && vec[31:2] != 0);
      cover (take_trap && irq_trap && !supervisor_trap && external_irq && timer_irq &&
             enabled_irqs[11] && enabled_irqs[7]);
      cover (take_trap && irq_trap && mode == UserMode && selected == 5 && delegated_irqs[1] &&
             enabled_irqs[1] && pending[1]);
      cover (mret_en && mprv && machine.previous_priv == Supervisor);
      cover (sret_en && supervisor.previous_priv == UserMode);
    end
  end
endmodule
