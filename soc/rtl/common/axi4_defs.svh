// Shared AXI4 channel definitions.
//
// Packed structs rather than a package so every simulator and synthesis
// flow used by this project (Icarus, Verilator, Yosys) can include this
// file directly without package support. Each channel struct carries its
// own VALID bit; the matching READY stays a separate scalar port driven
// by the other side of the channel.
//
// Widths are fixed for this SoC: 32-bit data and addresses and 4-bit IDs.
// Burst length keeps the full 8-bit AXI4 width even though every master
// here issues INCR bursts of at most 16 beats; slaves reject longer
// bursts in simulation.

`ifndef AXI4_DEFS_SVH
`define AXI4_DEFS_SVH

// Response encodings (AXI4 A3.1.1).
`define AXI4_RESP_OKAY 2'b00
`define AXI4_RESP_EXOKAY 2'b01
`define AXI4_RESP_SLVERR 2'b10
`define AXI4_RESP_DECERR 2'b11

// Burst encodings (AXI4 A3.3.3). Only INCR is generated on this SoC.
`define AXI4_BURST_FIXED 2'b00
`define AXI4_BURST_INCR 2'b01
`define AXI4_BURST_WRAP 2'b10

// Write address channel.
typedef struct packed {
  logic valid;
  logic [3:0] id;
  logic [31:0] addr;
  logic [7:0] len;  // Beats minus one.
  logic [2:0] size;  // log2 bytes per beat; always 2 on this SoC.
  logic [1:0] burst;
  logic [2:0] prot;
} axi4_aw_t;

// Write data channel.
typedef struct packed {
  logic valid;
  logic [31:0] data;
  logic [3:0] strb;
  logic last;
} axi4_w_t;

// Write response channel.
typedef struct packed {
  logic valid;
  logic [3:0] id;
  logic [1:0] resp;
} axi4_b_t;

// Read address channel.
typedef struct packed {
  logic valid;
  logic [3:0] id;
  logic [31:0] addr;
  logic [7:0] len;
  logic [2:0] size;
  logic [1:0] burst;
  logic [2:0] prot;
} axi4_ar_t;

// Read data channel.
typedef struct packed {
  logic valid;
  logic [3:0] id;
  logic [31:0] data;
  logic [1:0] resp;
  logic last;
} axi4_r_t;

`endif
