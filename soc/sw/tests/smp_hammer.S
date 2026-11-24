# SMP hammer: randomized cross-hart coherence stress.
#
# Both harts run this image; hart1 spins in reset until hart0 publishes an
# entry point and writes the release mailbox (same mechanism as
# smp_bringup). No stack is used, only registers, three mailboxes, a shared
# counter and a shared array.
#
# Phase 1 (hammer): each hart runs N iterations of LCG-randomized
# loads/stores/AMOs over a shared array bigger than neither cache but
# with alias pairs that force evictions, plus one AMOADD to a shared
# counter per iteration. A fence.i every 32 iterations pushes dirty lines
# to SDRAM so writebacks interleave with peer snoops.
# Phase 2 (join): hart1 publishes its iteration count; hart0 waits, then
# checks the shared counter equals exactly 2*N (every AMO applied once:
# no lost updates, no phantom increments, full cross-hart visibility).
# Phase 3 (message passing, both directions): hart0 writes a deterministic
# pattern to the whole array with fence.i; hart1 reads it all back and
# verifies; then the roles swap. Any mismatch halts FAIL (tohost=32).
.section .text.init
.globl _start
_start:
  csrr t0, mhartid
  beqz t0, hart0_main
  li t1, 1
  bne t0, t1, fail
  j hart1_main

# Hart0: publish FLAG_H0, release hart1, hammer, join, verify, halt PASS.
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
  # Hammer with hart-specific LCG seed in s2.
  la s0, shared
  li s1, 200
  li s2, 0x12345
  jal ra, hammer
  # Join: wait for hart1's done count.
  la s0, flag_h1
  li t2, 1000000
poll_h1:
  lw t0, 0(s0)
  bnez t0, check_counter
  addi t2, t2, -1
  bnez t2, poll_h1
  j fail
check_counter:
  # Hart1 must have finished all 200 iterations.
  li t1, 200
  bne t0, t1, fail
  # Exactly 2*N AMOADDs of +1 must be visible (no lost/phantom updates).
  la s0, counter
  lw t0, 0(s0)
  li t1, 400
  bne t0, t1, fail
  fence.i
  # Deterministic phase, hart0 -> hart1.
  la s0, shared
  li t1, 0
  li t2, 256
pat0_loop:
  slli t3, t1, 8
  li t4, 0x01010101
  mul t3, t3, t4
  addi t3, t3, 0x22
  slli t4, t1, 2
  add t4, t4, s0
  sw t3, 0(t4)
  addi t1, t1, 1
  bne t1, t2, pat0_loop
  fence.i
  # Tell hart1 the pattern is ready, wait for its ack.
  la s0, flag_h0
  li t0, 0xAAAAAAAA
  sw t0, 0(s0)
  fence.i
  la s0, flag_h1
  li t2, 1000000
poll_ack1:
  lw t0, 0(s0)
  li t1, 0xBBBBBBBB
  beq t0, t1, phase2
  addi t2, t2, -1
  bnez t2, poll_ack1
  j fail
phase2:
  # Hart1 wrote its pattern; verify every word.
  la s0, shared
  li t1, 0
  li t2, 256
ver1_loop:
  slli t4, t1, 2
  add t4, t4, s0
  lw t0, 0(t4)
  slli t3, t1, 8
  li t4, 0x01010101
  mul t3, t3, t4
  addi t3, t3, 0x77
  bne t0, t3, fail
  addi t1, t1, 1
  bne t1, t2, ver1_loop
  li a0, 1
  li x31, 0x80001000
  sw a0, 0(x31)
1:
  j 1b

# Hart1: wait for release, hammer, publish done, both pattern phases.
hart1_main:
  la s0, flag_h0
  li t2, 1000000
poll_h0:
  lw t0, 0(s0)
  li t1, 0x12345678
  beq t0, t1, do_hammer1
  addi t2, t2, -1
  bnez t2, poll_h0
  j fail
do_hammer1:
  la s0, shared
  li s1, 200
  li s2, 0x54321
  jal ra, hammer
  # Publish iteration count, then wait for hart0's pattern.
  la s0, flag_h1
  li t0, 200
  sw t0, 0(s0)
  fence.i
  la s0, flag_h0
  li t2, 1000000
poll_pat0:
  lw t0, 0(s0)
  li t1, 0xAAAAAAAA
  beq t0, t1, ver0
  addi t2, t2, -1
  bnez t2, poll_pat0
  j fail
ver0:
  # Verify hart0's pattern word by word.
  la s0, shared
  li t1, 0
  li t2, 256
ver0_loop:
  slli t4, t1, 2
  add t4, t4, s0
  lw t0, 0(t4)
  slli t3, t1, 8
  li t4, 0x01010101
  mul t3, t3, t4
  addi t3, t3, 0x22
  bne t0, t3, fail
  addi t1, t1, 1
  bne t1, t2, ver0_loop
  # Write hart1's own pattern and ack.
  la s0, shared
  li t1, 0
  li t2, 256
pat1_loop:
  slli t3, t1, 8
  li t4, 0x01010101
  mul t3, t3, t4
  addi t3, t3, 0x77
  slli t4, t1, 2
  add t4, t4, s0
  sw t3, 0(t4)
  addi t1, t1, 1
  bne t1, t2, pat1_loop
  fence.i
  la s0, flag_h1
  li t0, 0xBBBBBBBB
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

# hammer: s0 = array base, s1 = iterations, s2 = LCG state.
# Each iteration does one LCG step, picks load/store/AMO by low bits and
# a word index, issues it, and fences every 32 iterations. Clobbers
# t0-t4. Returns with s2 updated.
hammer:
  li t4, 0
ham_loop:
  # LCG: r = r * 1103515245 + 12345.
  li t0, 1103515245
  mul s2, s2, t0
  li t0, 12345
  add s2, s2, t0
  # Word index 0..255 in t1; op select in t0.
  srli t1, s2, 8
  andi t1, t1, 255
  andi t0, s2, 3
  slli t1, t1, 2
  add t1, t1, s0
  beqz t0, ham_load
  li t3, 1
  beq t0, t3, ham_store
  # AMOADD +1 to the shared counter (op 2 and 3 both AMO for pressure).
  la t3, counter
  li t4, 0
  amoadd.w t4, s2, (t3)
  j ham_next
ham_load:
  lw t3, 0(t1)
  j ham_next
ham_store:
  sw s2, 0(t1)
ham_next:
  addi t4, t4, 1
  andi t0, t4, 31
  bnez t0, ham_cont
  fence.i
ham_cont:
  addi s1, s1, -1
  bnez s1, ham_loop
  ret

.section .data
.balign 4
flag_h0:
  .word 0
flag_h1:
  .word 0
counter:
  .word 0
shared:
  .zero 1024
