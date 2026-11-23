// AXI register slice: 2-deep FIFO on {VALID, payload}.
//
// VALID (MSB of V, per axi4_defs.svh field order with `valid` declared
// first) and READY are both flopped, so combinational paths are cut in
// both directions while sustaining one beat per cycle. Adds one cycle of
// forward latency per slice.
//
// Used on the axi4_xbar slave ports (AR/AW/W) and per-master return paths
// (R/B) so the 9:1 owner muxes and the CDC/APB READY returns terminate in
// flops instead of spanning hart0 <-> fabric <-> hart1 in one cycle.

`default_nettype none

module axi4_register_slice #(
    parameter int WIDTH = 8  // $bits(channel) including VALID as MSB
) (
  input logic clk,
  input logic rst,
  input logic [WIDTH-1:0] s_data,  // {valid, payload} from upstream
  output logic s_ready,  // flopped: low only when full
  output logic [WIDTH-1:0] m_data,  // {valid, payload} to downstream
  input logic m_ready
);

  logic [WIDTH-1:0] e0, e1;
  logic [1:0] count;
  logic push, pop;
  logic valid_out;

  assign valid_out = (count != 2'd0);
  assign s_ready = (count != 2'd2);
  // Gate the payload on empty: e0 keeps its last beat after drain and its
  // embedded VALID bit would otherwise read as a phantom beat downstream.
  assign m_data = valid_out ? e0 : '0;
  assign push = s_data[WIDTH-1] && s_ready;
  assign pop = valid_out && m_ready;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      count <= 2'd0;
      e0 <= '0;
      e1 <= '0;
    end else begin
      case ({
        push, pop
      })
        2'b10: begin
          if (count == 2'd0) e0 <= s_data;
          else e1 <= s_data;
          count <= count + 2'd1;
        end
        2'b01: begin
          if (count == 2'd2) e0 <= e1;
          count <= count - 2'd1;
        end
        2'b11: begin
          if (count == 2'd2) begin
            e0 <= e1;
            e1 <= s_data;
          end else begin
            e0 <= s_data;
          end
        end
        default: begin
        end
      endcase
    end
  end

endmodule
