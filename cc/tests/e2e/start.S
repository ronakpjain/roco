# Minimal freestanding startup for the roco core testbench.
#
# The core testbench provides 64 KiB at 0x10000000, so the stack sits at
# 0x10008000. SoC programs should raise this to 0x100f0000.

.section .text.init
.globl _start

_start:
  li sp, 0x10008000

  la t0, __bss_start
  la t1, __bss_end
1:
  bgeu t0, t1, 2f
  sb zero, 0(t0)
  addi t0, t0, 1
  j 1b

2:
  call main

  li t0, 0x80001000
  li t1, 1
  sw t1, 0(t0)
3:
  j 3b
