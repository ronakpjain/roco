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

// M-extension operations, encoded as the funct3 field of OP.
`define RV32_MD_MUL 3'd0
`define RV32_MD_MULH 3'd1
`define RV32_MD_MULHSU 3'd2
`define RV32_MD_MULHU 3'd3
`define RV32_MD_DIV 3'd4
`define RV32_MD_DIVU 3'd5
`define RV32_MD_REM 3'd6
`define RV32_MD_REMU 3'd7

// Vector element operations, encoded as the funct6 field of OP-V.
`define RV32_VOP_ADD 6'b000000
`define RV32_VOP_SUB 6'b000010
`define RV32_VOP_AND 6'b001001
`define RV32_VOP_OR 6'b001010
`define RV32_VOP_XOR 6'b001011
`define RV32_VOP_MOVE 6'b010111
`define RV32_VOP_SCALAR 6'b010000
`define RV32_VOP_REDSUM 6'b000000

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
