# FENCE.I must discard younger EX operations before refetching them.
.section .text.init
.globl _start
_start:
  li x31, 0x80001000
  vsetivli zero, 4, e32, m1, ta, ma
  la s1, data
  vle32.v v1, (s1)
  vmv.s.x v2, zero
  fence.i
  vredsum.vs v2, v1, v2
  vmv.x.s t0, v2
  li t1, 10
  bne t0, t1, fail
  fence.i
  vadd.vi v1, v1, 1
  vmv.x.s t0, v1
  li t1, 2
  bne t0, t1, fail
  li t2, 0
  fence.i
  addi t2, t2, 1
  li t1, 1
  bne t2, t1, fail
  li t0, 5
  csrw mscratch, t0
  li t1, 7
  fence.i
  csrrw t0, mscratch, t1
  li t1, 5
  bne t0, t1, fail
  li a0, 1
  sw a0, 0(x31)
1: j 1b
fail:
  li a0, 11
  sw a0, 0(x31)
2: j 2b
.section .data
.balign 16
data: .word 1, 2, 3, 4
