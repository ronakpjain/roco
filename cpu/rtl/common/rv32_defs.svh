// Shared RV32I control encodings.
//
// Kept as macros rather than a package so that every simulator and
// synthesis flow used by this project (Icarus, Verilator, Yosys) can
// consume the sources without package support.

`ifndef RV32_DEFS_SVH
`define RV32_DEFS_SVH

// ALU operations.
`define RV32_ALU_ADD 4'd0
`define RV32_ALU_SUB 4'd1
`define RV32_ALU_SLL 4'd2
`define RV32_ALU_SLT 4'd3
`define RV32_ALU_SLTU 4'd4
`define RV32_ALU_XOR 4'd5
`define RV32_ALU_SRL 4'd6
`define RV32_ALU_SRA 4'd7
`define RV32_ALU_OR 4'd8
`define RV32_ALU_AND 4'd9
`define RV32_ALU_PASS_B 4'd10

// Zicsr operations.
`define RV32_CSR_RW 2'd0
`define RV32_CSR_RS 2'd1
`define RV32_CSR_RC 2'd2

// Machine-mode trap causes used by this core.
`define RV32_CAUSE_INSTR_MISALIGNED 32'd0
`define RV32_CAUSE_ILLEGAL 32'd2
`define RV32_CAUSE_BREAKPOINT 32'd3
`define RV32_CAUSE_LOAD_MISALIGNED 32'd4
`define RV32_CAUSE_STORE_MISALIGNED 32'd6
`define RV32_CAUSE_ECALL_U 32'd8
`define RV32_CAUSE_ECALL_S 32'd9
`define RV32_CAUSE_ECALL_M 32'd11
`define RV32_CAUSE_INSTR_PAGE_FAULT 32'd12
`define RV32_CAUSE_LOAD_PAGE_FAULT 32'd13
`define RV32_CAUSE_STORE_PAGE_FAULT 32'd15

// Privilege mode encoding (RISC-V two-bit values).
`define RV32_PRIV_U 2'b00
`define RV32_PRIV_S 2'b01
`define RV32_PRIV_M 2'b11

`endif
