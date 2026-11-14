# Directed A-extension test.
#
# Checks the AMO read-modify-write result, the load-use style hazard on
# the returned value, all nine AMO operations, LR/SC success and failure
# conditions, and the misaligned access trap.

.section .text.init
.globl _start

_start:
  li x31, 0x80001000
  la s1, scratch
  li t0, 100
  sw t0, 0(s1)

  # 1: amoadd returns the old value and stores the sum
  li a0, 5
  amoadd.w a1, a0, (s1)
  li t1, 100
  bne a1, t1, fail_1
  lw t1, 0(s1)
  li t2, 105
  bne t1, t2, fail_1

  # 2: a dependent instruction right after the AMO
  li a0, 1
  amoadd.w a1, a0, (s1)
  add a2, a1, a0
  li t1, 106
  bne a2, t1, fail_2

  # 3: word value after a swap
  li a0, 0xff
  amoswap.w a1, a0, (s1)
  lw t1, 0(s1)
  li t2, 0xff
  bne t1, t2, fail_3

  # 4: and, or, xor
  li a0, 0x0f0f
  amoxor.w a1, a0, (s1)
  li a0, 0x00ff
  amoor.w a1, a0, (s1)
  li a0, 0x0f0f
  amoand.w a1, a0, (s1)
  lw t1, 0(s1)
  li t2, 0x0f0f
  bne t1, t2, fail_4

  # 5: signed and unsigned min/max
  li t0, -5
  sw t0, 0(s1)
  li a0, 3
  amomin.w a1, a0, (s1)
  lw t1, 0(s1)
  li t2, -5
  bne t1, t2, fail_5
  amomax.w a1, a0, (s1)
  lw t1, 0(s1)
  li t2, 3
  bne t1, t2, fail_5
  li t0, -5
  sw t0, 0(s1)
  amomaxu.w a1, a0, (s1)
  lw t1, 0(s1)
  li t2, -5
  bne t1, t2, fail_5
  amominu.w a1, a0, (s1)
  lw t1, 0(s1)
  li t2, 3
  bne t1, t2, fail_5

  # 6: lr/sc succeeds
  lr.w a1, (s1)
  li a0, 42
  sc.w a2, a0, (s1)
  bnez a2, fail_6
  lw t1, 0(s1)
  li t2, 42
  bne t1, t2, fail_6

  # 7: sc without lr fails and leaves memory alone
  li a0, 7
  sc.w a2, a0, (s1)
  li t2, 1
  bne a2, t2, fail_7
  lw t1, 0(s1)
  li t2, 42
  bne t1, t2, fail_7

  # 8: a store to the reserved word cancels the reservation
  lr.w a1, (s1)
  li a0, 9
  sw a0, 0(s1)
  li a0, 11
  sc.w a2, a0, (s1)
  li t2, 1
  bne a2, t2, fail_8

  # 9: a store to another word keeps the reservation
  lr.w a1, (s1)
  li a0, 0x1234
  sw a0, 4(s1)
  li a0, 0x5678
  sc.w a2, a0, (s1)
  bnez a2, fail_9
  lw t1, 0(s1)
  li t2, 0x5678
  bne t1, t2, fail_9

  # 10: a misaligned AMO traps with cause 6 and the right mepc
  la t0, trap_handler
  csrw mtvec, t0
  li s0, 0
  la t2, misaligned_word
  addi t2, t2, 1
  li a0, 1
mis_amo:
  amoadd.w a1, a0, 0(t2)
  li t1, 1
  bne s0, t1, fail_10

  li a0, 1
  sw a0, 0(x31)
1:
  j 1b

.align 2
trap_handler:
  csrr t0, mcause
  li t1, 6
  bne t0, t1, h_bad
  csrr t0, mepc
  la t1, mis_amo
  bne t0, t1, h_bad
  li s0, 1
  addi t0, t0, 4
  csrw mepc, t0
  mret
h_bad:
  li s0, 2
  mret

fail_1:
  li a0, 21
  j fail
fail_2:
  li a0, 22
  j fail
fail_3:
  li a0, 23
  j fail
fail_4:
  li a0, 24
  j fail
fail_5:
  li a0, 25
  j fail
fail_6:
  li a0, 26
  j fail
fail_7:
  li a0, 27
  j fail
fail_8:
  li a0, 28
  j fail
fail_9:
  li a0, 29
  j fail
fail_10:
  li a0, 30
fail:
  sw a0, 0(x31)
1:
  j 1b

.section .data
.align 4
scratch:
  .word 0
  .word 0
misaligned_word:
  .word 0
  .word 0
