# SMP bring-up: hart release, mhartid, MSI coherence and cross-hart atomics.
#
# Both harts run this image; hart1 spins in reset until hart0 publishes an
# entry point and writes the release mailbox. No stack is used, only
# registers and three shared SDRAM words.
#
# Hart0: checks mhartid==0, publishes FLAG_H0, fence.i (push to SDRAM),
# releases hart1, polls FLAG_H1, validates the AMO counter, halts PASS.
# Hart1: checks mhartid==1, polls FLAG_H0, AMO-increments COUNTER ten
# times, publishes FLAG_H1, spins. Any mismatch halts FAIL (tohost=32).
.section .text.init
.globl _start
_start:
  csrr t0, mhartid
  beqz t0, hart0_main
  li t1, 1
  bne t0, t1, fail
  j hart1_main

hart0_main:
  # Publish the message word, then push it all the way to SDRAM so the
  # parked hart cannot observe a stale cache copy when it fills.
  la s0, flag_h0
  li t0, 0x12345678
  sw t0, 0(s0)
  fence.i
  # Release hart1 at hart1_main.
  la t0, hart1_main
  li s1, 0x80000110
  sw t0, 0(s1)
  li t0, 1
  li s1, 0x80000114
  sw t0, 0(s1)
  # Poll FLAG_H1 with a bounded spin; hart1 publishes it after its AMOs.
  la s0, flag_h1
  li t2, 100000
poll_h1:
  lw t0, 0(s0)
  li t1, 0x87654321
  beq t0, t1, check_counter
  addi t2, t2, -1
  bnez t2, poll_h1
  j fail
check_counter:
  la s0, counter
  lw t0, 0(s0)
  li t1, 10
  bne t0, t1, fail
  li a0, 1
  li x31, 0x80001000
  sw a0, 0(x31)
1:
  j 1b

hart1_main:
  # Poll FLAG_H0 with a bounded spin.
  la s0, flag_h0
  li t2, 100000
poll_h0:
  lw t0, 0(s0)
  li t1, 0x12345678
  beq t0, t1, do_amos
  addi t2, t2, -1
  bnez t2, poll_h0
  j fail
do_amos:
  # Ten exclusive AMO increments: each takes the line Modified and
  # invalidates any hart0 copy, exercising the MSI upgrade path.
  la s0, counter
  li t1, 1
  li t2, 10
amo_loop:
  amoadd.w t0, t1, (s0)
  addi t2, t2, -1
  bnez t2, amo_loop
  # Publish completion, push it out, then park (hart0 halts the SoC).
  la s0, flag_h1
  li t0, 0x87654321
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
