# Delayed redirects must cancel every younger EX side effect.
.section .text.init
.globl _start
_start:
  li x31, 0x80001000
  la t0, fail
  csrw mtvec, t0
  csrw mscratch, zero
  li s0, 7
  la s1, data
  vsetivli zero, 4, e32, m1, ta, ma
  vmv.v.i v1, 3
  jal zero, 1f
  addi s0, s0, 1
1:
  li t0, 7
  bne s0, t0, fail
  jal zero, 2f
  sw zero, 0(s1)
2:
  lw t0, 0(s1)
  li t1, 19
  bne t0, t1, fail
  jal zero, 3f
  csrw mscratch, s0
3:
  csrr t0, mscratch
  bnez t0, fail
  jal zero, 4f
  vadd.vi v1, v1, 1
4:
  vmv.x.s t0, v1
  li t1, 3
  bne t0, t1, fail
  jal zero, 5f
  vsetivli zero, 1, e8, m1, ta, ma
5:
  csrr t0, vl
  li t1, 4
  bne t0, t1, fail
  jal zero, 6f
  div s0, zero, zero
6:
  .rept 40
  nop
  .endr
  li t0, 7
  bne s0, t0, fail
  la t0, 7f
  jalr zero, 0(t0)
  ecall
7:
  beq s0, t0, fail
  beq s0, s0, 8f
  csrw mscratch, s0
8:
  csrr t0, mscratch
  bnez t0, fail
  li a0, 1
  sw a0, 0(x31)
9: j 9b
fail:
  li a0, 11
  sw a0, 0(x31)
10: j 10b
.section .data
.balign 16
data: .word 19
