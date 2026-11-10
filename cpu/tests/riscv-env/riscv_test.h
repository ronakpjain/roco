// Minimal riscv-tests environment for the roco RV32I core.
//
// Derived from riscv-software-src/riscv-tests env/p/riscv_test.h
// (BSD-3-Clause). The upstream reset vector programs PMP, satp and
// mnstatus, which this machine-mode-only core does not implement, so
// those steps are removed. Everything else (link-time init, trap
// vector, pass/fail protocol, tohost signalling) is unchanged.
//
// Tests signal completion by storing gp (TESTNUM) to tohost:
// 1 means PASS, anything else is the failing test number.

#ifndef _ROCO_RISCV_TEST_H
#define _ROCO_RISCV_TEST_H

#define RVTEST_RV64U \
  .macro init; \
  .endm

#define RVTEST_RV32U \
  .macro init; \
  .endm

#define INIT_XREG \
  li x1, 0; \
  li x2, 0; \
  li x3, 0; \
  li x4, 0; \
  li x5, 0; \
  li x6, 0; \
  li x7, 0; \
  li x8, 0; \
  li x9, 0; \
  li x10, 0; \
  li x11, 0; \
  li x12, 0; \
  li x13, 0; \
  li x14, 0; \
  li x15, 0; \
  li x16, 0; \
  li x17, 0; \
  li x18, 0; \
  li x19, 0; \
  li x20, 0; \
  li x21, 0; \
  li x22, 0; \
  li x23, 0; \
  li x24, 0; \
  li x25, 0; \
  li x26, 0; \
  li x27, 0; \
  li x28, 0; \
  li x29, 0; \
  li x30, 0; \
  li x31, 0;

#if __riscv_xlen == 64
#define CHECK_XLEN li a0, 1; slli a0, a0, 31; bgez a0, 1f; RVTEST_PASS; 1:
#else
#define CHECK_XLEN li a0, 1; slli a0, a0, 31; bltz a0, 1f; RVTEST_PASS; 1:
#endif

#define RVTEST_CODE_BEGIN \
  .section .text.init; \
  .align 6; \
  .weak stvec_handler; \
  .weak mtvec_handler; \
  .globl _start; \
_start: \
  j reset_vector; \
  .align 2; \
trap_vector: \
  csrr t5, mcause; \
  li t6, 8; \
  beq t5, t6, write_tohost; \
  li t6, 9; \
  beq t5, t6, write_tohost; \
  li t6, 11; \
  beq t5, t6, write_tohost; \
  la t5, mtvec_handler; \
  beqz t5, 1f; \
  jr t5; \
1: \
  csrr t5, mcause; \
  bgez t5, handle_exception; \
  j other_exception; \
handle_exception: \
other_exception: \
1: \
  ori TESTNUM, TESTNUM, 1337; \
write_tohost: \
  sw TESTNUM, tohost, t5; \
  sw zero, tohost + 4, t5; \
  j write_tohost; \
reset_vector: \
  INIT_XREG; \
  li TESTNUM, 0; \
  la t0, trap_vector; \
  csrw mtvec, t0; \
  CHECK_XLEN; \
  la t0, stvec_handler; \
  beqz t0, 1f; \
  csrw stvec, t0; \
1: \
  csrwi mstatus, 0; \
  init; \
  la t0, 1f; \
  csrw mepc, t0; \
  csrr a0, mhartid; \
  mret; \
1:

#define RVTEST_CODE_END unimp

#define RVTEST_PASS \
  fence; \
  li TESTNUM, 1; \
  li a7, 93; \
  li a0, 0; \
  ecall

#define TESTNUM gp

#define RVTEST_FAIL \
  fence; \
1: \
  beqz TESTNUM, 1b; \
  sll TESTNUM, TESTNUM, 1; \
  or TESTNUM, TESTNUM, 1; \
  li a7, 93; \
  addi a0, TESTNUM, 0; \
  ecall

#define RVTEST_DATA_BEGIN \
  .pushsection .tohost, "aw", @progbits; \
  .align 6; \
  .global tohost; \
tohost: \
  .dword 0; \
  .size tohost, 8; \
  .align 6; \
  .global fromhost; \
fromhost: \
  .dword 0; \
  .size fromhost, 8; \
  .popsection; \
  .align 4; \
  .global begin_signature; \
begin_signature:

#define RVTEST_DATA_END \
  .align 4; \
  .global end_signature; \
end_signature:

#endif
