# End-to-end roco smoke test: bss, data, loads, stores, and branches.

.section .rodata
message:
  .asciz "roco"

.section .data
value:
  .word 0x12345678

.section .bss
buffer:
  .zero 16

.section .text
.globl main

main:
  la t0, buffer
  lw t1, 0(t0)
  bnez t1, fail

  la t0, value
  lw t1, 0(t0)
  li t2, 0x12345678
  bne t1, t2, fail

  li t3, 0x10004000
  sw t1, 0(t3)
  lw t4, 0(t3)
  bne t4, t2, fail

  la t5, message
  lbu t6, 0(t5)
  li a0, 'r'
  bne t6, a0, fail
  ret

fail:
  li t0, 0x80001000
  li t1, 3
  sw t1, 0(t0)
1:
  j 1b
