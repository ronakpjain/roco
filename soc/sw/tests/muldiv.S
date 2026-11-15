# Directed M-extension test for the decoupled divider.
#
# Covers the hazard paths that the ISA tests do not reach: a dependent
# instruction right after a divide, back-to-back divides, a write after
# read on the pending destination, and the signed and zero-divisor corner
# cases. Each check jumps to a numbered exit; the final tohost store with
# a0 = 1 means PASS.

.section .text.init
.globl _start

_start:
  li x31, 0x80001000

  # 1: dependent consumer stalls until the quotient is written
  li t0, 1000
  li t1, 7
  div t2, t0, t1
  add t3, t2, t2
  li t4, 284
  bne t3, t4, fail_1

  # 2: back-to-back divides queue behind the busy unit
  li t0, 100
  li t1, 3
  div t2, t0, t1
  div t3, t1, t0
  rem t4, t0, t1
  add t5, t2, t3
  add t5, t5, t4
  li a5, 34
  bne t5, a5, fail_2

  # 3: a younger write to the pending destination must not be clobbered
  li t0, 1000
  li t1, 9
  div t2, t0, t1
  li t2, 55
  li t3, 55
  bne t2, t3, fail_3

  # 4: signed division truncates toward zero
  li t0, -7
  li t1, 2
  div t2, t0, t1
  rem t3, t0, t1
  li t4, -3
  li t5, -1
  bne t2, t4, fail_4
  bne t3, t5, fail_4

  # 5: divide by zero returns -1, remainder returns the dividend
  li t0, 5
  li t1, 0
  div t2, t0, t1
  rem t3, t0, t1
  li t4, -1
  bne t2, t4, fail_5
  bne t3, t0, fail_5

  # 6: signed overflow keeps the architectural result
  li t0, 0x80000000
  li t1, -1
  div t2, t0, t1
  rem t3, t0, t1
  bne t2, t0, fail_6
  bne t3, zero, fail_6

  # 7: high-word multiplies
  li t0, -1
  li t1, -1
  mulh t2, t0, t1
  bne t2, zero, fail_7
  li t0, 0x80000000
  mulhsu t2, t0, t0
  li t3, 0xc0000000
  bne t2, t3, fail_7
  mulhu t2, t0, t0
  li t3, 0x40000000
  bne t2, t3, fail_7

  # PASS
  li a0, 1
  sw a0, 0(x31)
1:
  j 1b

fail_1:
  li a0, 11
  j fail
fail_2:
  li a0, 12
  j fail
fail_3:
  li a0, 13
  j fail
fail_4:
  li a0, 14
  j fail
fail_5:
  li a0, 15
  j fail
fail_6:
  li a0, 16
  j fail
fail_7:
  li a0, 17
fail:
  sw a0, 0(x31)
1:
  j 1b
