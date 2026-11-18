`default_nettype none

module vector_regs_contract (
  input logic clk
);
  // Allow another reset at any point, including with a pending write.
  logic first_cycle = 1'b1;
  always @(posedge clk) first_cycle <= 1'b0;
  (* anyseq *) logic reset_request;
  logic rst;
  assign rst = first_cycle || reset_request;

  (* anyseq *) logic [4:0] free_vs1, free_vs2, free_vd, ex_wd, mem_wd;
  logic [4:0] vs1, vs2, vd;
  (* anyseq *) logic ex_we, mem_we;
  (* anyseq *) logic [127:0] ex_wdata;
  (* anyseq *) logic [31:0] mem_wdata;
  (* anyseq *) logic [3:0] mem_elem;
  (* anyseq *) logic [2:0] mem_sew;
  logic [127:0] vs1_data, vs2_data, vd_data;
  roco_cpu_vec dut (.*);

  // The solver chooses an arbitrary register and byte. Comparing all
  // three ports when they address it checks every byte of every register.
  (* anyconst *) logic [4:0] watched_reg;
  (* anyconst *) logic [3:0] watched_byte;
  (* anyconst *) logic [1:0] observer;
  // One arbitrary port continuously exposes the tracked state to induction;
  // keeping the other ports free still exercises independent addressing.
  assign vs1 = observer == 0 ? watched_reg : free_vs1;
  assign vs2 = observer == 1 ? watched_reg : free_vs2;
  assign vd = observer == 2 ? watched_reg : free_vd;
  logic [7:0] reference_byte;
  logic [4:0] bytes_per_element, element_start, byte_delta;
  assign bytes_per_element = 5'd1 << mem_sew;
  assign element_start = 5'(mem_elem) * bytes_per_element;
  assign byte_delta = 5'(watched_byte) - element_start;

  always @(posedge clk) begin
    assume (observer <= 2);
    if (rst) reference_byte <= 0;
    else begin
      if (mem_we && !ex_we) begin
        assume (mem_sew <= 2);
        // Legal element index for a 128-bit register at the requested SEW.
        assume ((8'(mem_elem) << mem_sew) < 16);
      end
      if (ex_we) begin
        if (ex_wd == watched_reg) reference_byte <= ex_wdata[8*watched_byte+:8];
      end else if (mem_we && mem_wd == watched_reg && byte_delta < bytes_per_element) begin
        case (byte_delta)
          0: reference_byte <= mem_wdata[7:0];
          1: reference_byte <= mem_wdata[15:8];
          2: reference_byte <= mem_wdata[23:16];
          default: reference_byte <= mem_wdata[31:24];
        endcase
      end
      if (vs1 == watched_reg) assert (vs1_data[8*watched_byte+:8] == reference_byte);
      if (vs2 == watched_reg) assert (vs2_data[8*watched_byte+:8] == reference_byte);
      if (vd == watched_reg) assert (vd_data[8*watched_byte+:8] == reference_byte);

      cover (ex_we && mem_we && ex_wd == watched_reg && mem_wd == watched_reg);
      cover (mem_we && !ex_we && mem_wd == watched_reg && mem_sew == 0);
      cover (mem_we && !ex_we && mem_wd == watched_reg && mem_sew == 1);
      cover (mem_we && !ex_we && mem_wd == watched_reg && mem_sew == 2);
      cover (vs1 == watched_reg && reference_byte != 0 && $past(mem_we && !ex_we));
    end
  end
endmodule
