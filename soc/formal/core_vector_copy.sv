`include "axi4_defs.svh"
`default_nettype none

// A whole-core vector integration property. Run a two-element copy at
// every supported SEW with arbitrary source data and data-port stalls.
module core_vector_copy (
  input logic clk
);
  logic rst = 1'b1;
  always @(posedge clk) rst <= 1'b0;

  localparam logic [31:0] Boot = 32'h1000_0000, Source = 32'h100, Dest = 32'h200;
  (* anyconst *) logic [1:0] sew;
  (* anyconst *) logic [31:0] source_low, source_high;
  (* anyseq *) logic dmem_ready;
  logic [2:0] width_enc;
  assign width_enc = sew == 0 ? 3'b000 : sew == 1 ? 3'b101 : 3'b110;

  logic imem_req, imem_rsp_valid;
  logic [31:0] imem_addr, imem_rsp_addr, imem_rsp_data;
  always @(posedge clk) begin
    imem_rsp_valid <= !rst && imem_req;
    imem_rsp_addr <= imem_addr;
    case (imem_addr)
      Boot: imem_rsp_data <= 32'h1000_0093;  // addi x1, x0, 0x100
      Boot + 4: imem_rsp_data <= 32'h2000_0113;  // addi x2, x0, 0x200
      Boot + 8:
      imem_rsp_data <= {
        2'b11, 2'b00, 2'b11, 1'b0, sew, 3'b000, 5'd2, 3'b111, 5'd3, 7'h57
      };  // vsetivli x3, 2, e*, m1, ta, ma
      Boot + 12: imem_rsp_data <= {6'b0, 1'b1, 5'd0, 5'd1, width_enc, 5'd1, 7'h07};
      Boot + 16: imem_rsp_data <= {6'b0, 1'b1, 5'd0, 5'd2, width_enc, 5'd1, 7'h27};
      default: imem_rsp_data <= 32'h0000_006f;  // jal x0, 0
    endcase
  end

  axi4_r_t ptw_r;
  assign ptw_r = '0;
  logic dmem_req, dmem_valid, dmem_we;
  logic [31:0] dmem_addr, dmem_wdata, load_word;
  logic [3:0] dmem_be;
  assign load_word = dmem_addr[2] ? source_high : source_low;
  logic rvfi_valid, rvfi_trap;
  logic [31:0] rvfi_pc, rvfi_rd_data;
  logic [4:0] rvfi_rd;
  roco_cpu dut (
      .clk(clk),
      .rst(rst),
      .boot_addr(Boot),
      .halt(1'b0),
      .irq_timer(1'b0),
      .irq_external(1'b0),
      .irq_software(1'b0),
      .imem_req(imem_req),
      .imem_addr(imem_addr),
      .imem_rsp_valid(imem_rsp_valid),
      .imem_rsp_addr(imem_rsp_addr),
      .imem_rsp_data(imem_rsp_data),
      .imem_miss(1'b0),
      .imem_busy(1'b0),
      .dmem_lu_valid(),
      .dmem_lu_addr(),
      .dmem_lu_offset(),
      .dmem_lu_funct3(),
      .dmem_ready(dmem_ready),
      .dmem_busy(1'b0),
      .dmem_req(dmem_req),
      .dmem_valid(dmem_valid),
      .dmem_we(dmem_we),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_be(dmem_be),
      .dmem_rsp_data(load_word),
      .dmem_forward_data(32'd0),
      .dmem_amo_retry(1'b0),
      .ptw_bus_rst(rst),
      .ptw_ar(),
      .ptw_ready(1'b0),
      .ptw_r(ptw_r),
      .ptw_r_ready(),
      .trace_valid(),
      .trace_pc(),
      .trace_instr(),
      .trace_rd(),
      .trace_wdata(),
      .fence_req(),
      .fence_done(1'b1),
      .res_remote_valid(1'b0),
      .res_remote_addr(30'd0),
      .remote_tlb_flush(1'b0),
      .rvfi_valid(rvfi_valid),
      .rvfi_trap(rvfi_trap),
      .rvfi_pc_rdata(rvfi_pc),
      .rvfi_rd_addr(rvfi_rd),
      .rvfi_rd_wdata(rvfi_rd_data),
      .rvfi_order(),
      .rvfi_insn(),
      .rvfi_halt(),
      .rvfi_intr(),
      .rvfi_mode(),
      .rvfi_ixl(),
      .rvfi_rs1_addr(),
      .rvfi_rs2_addr(),
      .rvfi_rs1_rdata(),
      .rvfi_rs2_rdata(),
      .rvfi_pc_wdata(),
      .rvfi_mem_addr(),
      .rvfi_mem_rmask(),
      .rvfi_mem_wmask(),
      .rvfi_mem_rdata(),
      .rvfi_mem_wdata()
  );

  logic [2:0] elements, retirements;
  logic [31:0] expected_offset, expected_addr, expected_word;
  logic [3:0] expected_mask;
  assign expected_offset = 32'(elements[0]) << sew;
  assign expected_addr = (elements[1] ? Dest : Source) + expected_offset;
  assign expected_word = expected_offset[2] ? source_high : source_low;
  assign expected_mask = (sew == 0 ? 4'b0001 : sew == 1 ? 4'b0011 : 4'b1111)
                         << expected_offset[1:0];
  always @(posedge clk) begin
    assume (sew <= 2);
    if (rst) begin
      elements <= 0;
      retirements <= 0;
    end else begin
      if (dmem_req) begin
        assert (dmem_valid && dmem_ready);
        assert (elements < 4);
        assert (dmem_addr == expected_addr && dmem_we == elements[1]);
        assert (rvfi_valid == elements[0]);  // Only the last element retires.
        if (dmem_we) begin
          assert (dmem_be == expected_mask);
          for (integer b = 0; b < 4; b = b + 1)
          if (expected_mask[b]) assert (dmem_wdata[8*b+:8] == expected_word[8*b+:8]);
        end
        elements <= elements + 1;
      end
      if (rvfi_valid) begin
        assert (!rvfi_trap);
        assert (rvfi_pc == Boot + 4 * 32'(retirements));
        case (retirements)
          0: assert (rvfi_rd == 1 && rvfi_rd_data == Source);
          1: assert (rvfi_rd == 2 && rvfi_rd_data == Dest);
          2: assert (rvfi_rd == 3 && rvfi_rd_data == 2);
          3: assert (dmem_req && elements == 1 && rvfi_rd == 0);
          4: assert (dmem_req && elements == 3 && rvfi_rd == 0);
          default: assert (elements == 4 && rvfi_rd == 0);
        endcase
        if (retirements < 5) retirements <= retirements + 1;
      end
      cover (retirements == 5 && sew == 0);
      cover (retirements == 5 && sew == 1);
      cover (retirements == 5 && sew == 2);
      cover (dmem_valid && !dmem_ready);
    end
  end
endmodule
