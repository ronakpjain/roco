// Startup code for the vector test on the core testbench.
//
// The testbench memory covers 64 KiB at 0x1000_0000, so the stack sits
// inside that window rather than at the SoC image top.

.section .text.init
.globl _start

_start:
  li sp, 0x10008000
  call main
  li t0, 0x80001000
  li t1, 1
  sw t1, 0(t0)
1:
  j 1b
