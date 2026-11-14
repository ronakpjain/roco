# Interrupt test.
#
# Phase 1 takes a machine timer interrupt raised by the testbench and
# resumes the interrupted loop through MRET. Phase 2 raises a machine
# software interrupt by setting mip.MSIP and clears it in the handler.
# The handler also checks mcause, mepc and mstatus.MPIE.

.section .text.init
.globl _start

_start:
  li x31, 0x80001000
  la t0, handler
  csrw mtvec, t0
  li s1, 0
  li s2, 0
  li s3, 0

  # Phase 1: machine timer interrupt.
  li t0, 0x80
  csrw mie, t0
  csrr t1, mie
  bne t0, t1, fail_1
  csrsi mstatus, 0x8
  li a0, 0
1:
  addi a0, a0, 1
  li a1, 150
  blt a0, a1, 1b
  csrci mstatus, 0x8
  beqz s1, fail_1
  bnez s3, fail_1

  # Phase 2: software interrupt through mip.MSIP.
  li t0, 0x8
  csrw mip, t0
  csrw mie, t0
  csrsi mstatus, 0x8
  li a0, 0
2:
  addi a0, a0, 1
  li a1, 50
  blt a0, a1, 2b
  csrci mstatus, 0x8
  li t0, 1
  bne s2, t0, fail_2
  bnez s3, fail_2

  # Interrupts must stay pending when disabled.
  li t0, 0x8
  csrw mip, t0
  li t0, 0
  csrw mie, t0
  csrsi mstatus, 0x8
  li a0, 0
3:
  addi a0, a0, 1
  li a1, 30
  blt a0, a1, 3b
  csrci mstatus, 0x8
  li t0, 1
  bne s2, t0, fail_3
  csrr t0, mip
  andi t0, t0, 0x8
  beqz t0, fail_3
  csrw mip, zero

  li a0, 1
  sw a0, 0(x31)
4:
  j 4b

.align 2
handler:
  csrr t0, mcause
  li t1, 0x80000007
  beq t0, t1, h_timer
  li t1, 0x80000003
  beq t0, t1, h_soft
  li s3, 1
  mret
h_timer:
  addi s1, s1, 1
  csrr t0, mstatus
  andi t1, t0, 0x80
  beqz t1, h_bad
  andi t1, t0, 0x8
  bnez t1, h_bad
  csrr t0, mepc
  beqz t0, h_bad
  mret
h_soft:
  addi s2, s2, 1
  csrw mip, zero
  mret
h_bad:
  li s3, 1
  mret

fail_1:
  li a0, 11
  j fail
fail_2:
  li a0, 12
  j fail
fail_3:
  li a0, 13
fail:
  sw a0, 0(x31)
5:
  j 5b
