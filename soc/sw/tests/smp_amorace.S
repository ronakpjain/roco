# SMP AMO race: both harts hammer the SAME counter line concurrently.
#
# Minimal isolator for concurrent same-line AMO upgrades. Both harts run
# this image; hart1 spins in reset until released. Each hart performs 50
# AMOADD +1 to COUNTER, then hart1 publishes FLAG_H1 and parks; hart0
# waits, checks COUNTER == 100 (every AMO applied exactly once) and halts
# PASS. Any mismatch halts FAIL (tohost=32); a hang trips the tb timeout.
.section .text.init
.globl _start
_start:
  csrr t0, mhartid
  beqz t0, hart0_main
  li t1, 1
  bne t0, t1, fail
  j hart1_main

hart0_main:
  la s0, flag_h0
  li t0, 0x12345678
  sw t0, 0(s0)
  fence.i
  la t0, hart1_main
  li s1, 0x80000110
  sw t0, 0(s1)
  li t0, 1
  li s1, 0x80000114
  sw t0, 0(s1)
  # Hammer the shared counter: 50 AMOADD +1.
  la s0, counter
  li t1, 1
  li t2, 50
amo0:
  amoadd.w t0, t1, (s0)
  addi t2, t2, -1
  bnez t2, amo0
  fence.i
  # Join: wait for hart1's done flag.
  la s0, flag_h1
  li t2, 1000000
poll_h1:
  lw t0, 0(s0)
  bnez t0, check_counter
  addi t2, t2, -1
  bnez t2, poll_h1
  j fail
check_counter:
  la s0, counter
  lw t0, 0(s0)
  li t1, 100
  bne t0, t1, fail
  li a0, 1
  li x31, 0x80001000
  sw a0, 0(x31)
1:
  j 1b

hart1_main:
  la s0, flag_h0
  li t2, 1000000
poll_h0:
  lw t0, 0(s0)
  li t1, 0x12345678
  beq t0, t1, do_amos
  addi t2, t2, -1
  bnez t2, poll_h0
  j fail
do_amos:
  la s0, counter
  li t1, 1
  li t2, 50
amo1:
  amoadd.w t0, t1, (s0)
  addi t2, t2, -1
  bnez t2, amo1
  fence.i
  la s0, flag_h1
  li t0, 1
  sw t0, 0(s0)
  fence.i
1:
  j 1b

fail:
  li a0, 32
  li x31, 0x80001000
  sw a0, 0(x31)
1:
  j 1b
.section .data
.balign 4
flag_h0:
  .word 0
flag_h1:
  .word 0
counter:
  .word 0
