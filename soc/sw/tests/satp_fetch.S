# SATP invalidation must replay younger fetches rather than dropping one.
.section .text.init
.globl _start
_start:
  li s11, 0x80001000
  la t0, fail
  csrw mtvec, t0
  csrw mscratch, zero
  li s0, 0
  li t0, 0x80010000
  csrw satp, t0
  addi s0, s0, 1
  addi s0, s0, 2
  csrw mscratch, s0
  addi s0, s0, 4
  addi s0, s0, 8
  csrr t0, mscratch
  li t1, 3
  bne t0, t1, fail
  li t1, 15
  bne s0, t1, fail
  csrw satp, zero
  addi s0, s0, 16
  addi s0, s0, 32
  addi s0, s0, 64
  addi s0, s0, 128
  li t1, 255
  bne s0, t1, fail
  li a0, 1
  sw a0, 0(s11)
1: j 1b
fail:
  li a0, 11
  sw a0, 0(s11)
2: j 2b
