# Exercise cache counter clears while instruction lookup events continue.
# The SoC testbench compares every cycle against the original transition rule.
.section .text.init
.globl _start
_start:
  li x31, 0x80001000
  li t0, 0x80000030
  li t1, 32
1:
  sw zero, 0(t0)
  addi t1, t1, -1
  bnez t1, 1b
  li a0, 1
  sw a0, 0(x31)
2: j 2b
