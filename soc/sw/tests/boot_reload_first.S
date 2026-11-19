# Dirty two data lines and restart without FENCE.I. The replacement image
# overwrites payload, but must preserve the dirty word outside its image.
.section .text.init
.globl _start
_start:
  la t0, payload
  li t1, 1
  sw t1, 0(t0)
  li t0, 0x10001000
  li t1, 0x12345678
  sw t1, 0(t0)
  li t0, 0x80000108
  li t1, 1
  sw t1, 0(t0)
1: j 1b
.section .data
.balign 256
payload: .word 0
