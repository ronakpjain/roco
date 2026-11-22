`ifndef ROCO_RVFI_SVH
`define ROCO_RVFI_SVH

`ifdef ROCO_RVFI
typedef struct packed {
  logic [31:0] instr, pc, next_pc, vaddr;
  logic [31:0] rs1_data, rs2_data;
  logic [4:0] rs1, rs2;
  logic [1:0] mode;
} roco_rvfi_meta_t;
`ifdef ROCO_IRQ_PIPELINE_CHECKS
`define ROCO_RVFI_IRQ_METADATA
`endif
`ifdef ROCO_SOC_PC_FORMAL
`define ROCO_RVFI_IRQ_METADATA
`endif
`endif

`endif
