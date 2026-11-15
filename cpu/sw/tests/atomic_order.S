# Acquire/release forms across cache-conflicting lines and memory stalls.
.section .text.init
.globl _start
_start:
  li s11, 0x80001000
  la t0, fail
  csrw mtvec, t0
  la s0, payload
  la s1, flag
  la s2, other
  li s3, 1
  li s4, 65
loop:
  sw s3, 0(s0)
  amoswap.w.rl t0, s3, (s1)
  addi t1, s3, -1
  bne t0, t1, fail
  amoadd.w.aq t0, zero, (s1)
  bne t0, s3, fail
  lw t0, 0(s0)
  bne t0, s3, fail

  # A younger access to a conflicting line must wait for the acquire,
  # while a reservation survives a store to a different physical word.
  lr.w.aq t0, (s0)
  sw s3, 0(s2)
  sc.w.rl t1, s3, (s0)
  bnez t1, fail
  bne t0, s3, fail
  lr.w.rl t0, (s0)
  sc.w.aq t1, s3, (s0)
  bnez t1, fail
  lr.w.aqrl t0, (s0)
  sc.w.aqrl t1, s3, (s0)
  bnez t1, fail
  li t2, -1
  amoxor.w.aqrl t0, t2, (s2)
  bne t0, s3, fail
  lw t0, 0(s2)
  not t1, s3
  bne t0, t1, fail
  lw t0, 0(s0)
  bne t0, s3, fail
  lw t0, 0(s1)
  bne t0, s3, fail
  addi s3, s3, 1
  bne s3, s4, loop
  li a0, 1
  sw a0, 0(s11)
1: j 1b
fail:
  li a0, 101
  sw a0, 0(s11)
1: j 1b

.section .data
# One cache-index alias per page forces eviction/writeback/refill in SoC.
.balign 4096
payload: .word 0
.zero 4092
flag: .word 0
.zero 4092
other: .word 0
