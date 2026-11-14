# Uncached AMOs must return the old value and perform exactly one write.
.section .text.init
.globl _start
_start:
  li x31, 0x80001000
  li s1, 0x80000020
  li t0, 100
  sw t0, 0(s1)
  li t1, 5
  amoadd.w t2, t1, (s1)
  addi t2, t2, 1
  li t3, 101
  bne t2, t3, fail
  lw t2, 0(s1)
  addi t2, t2, 1
  li t3, 106
  bne t2, t3, fail
  li s4, 37
  amoxor.w zero, zero, (s1)
  addi t2, s4, 1
  li t3, 38
  bne t2, t3, fail
  lw t2, 0(s1)
  li t3, 105
  bne t2, t3, fail
  li a0, 1
  sw a0, 0(x31)
1: j 1b
fail:
  li a0, 11
  sw a0, 0(x31)
2: j 2b
