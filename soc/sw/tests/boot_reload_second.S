# The entry code and payload replace the cached first image. A word outside
# this packet must retain the first image's committed dirty store.
.section .text.init
.globl _start
_start:
  li s11, 0x80001000
  la t0, fail
  csrw mtvec, t0
  la t0, payload
  lw t1, 0(t0)
  li t2, 2
  bne t1, t2, fail
  li t0, 0x10001000
  lw t1, 0(t0)
  li t2, 0x12345678
  bne t1, t2, fail
  li a0, 1
  sw a0, 0(s11)
1: j 1b
fail:
  li a0, 3
  sw a0, 0(s11)
1: j 1b
.section .data
.balign 256
payload: .word 2
