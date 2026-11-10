// Startup code for freestanding roco programs.

.section .text.init
.globl _start

_start:
  li sp, 0x100f0000
  call main
  # Let the UART FIFO drain before halting (about 4 ms at 48 MHz).
  li t0, 30000
1:
  addi t0, t0, -1
  bnez t0, 1b
  li t0, 0x80001000
  li t1, 1
  sw t1, 0(t0)
1:
  j 1b
