# Directed smoke test for the pipelined core.
#
# Every check jumps to a numbered failure exit; the final tohost store
# with a0 = 1 means PASS.

.section .text.init
.globl _start

_start:
  li x31, 0x80001000

  # 1: ADDI / ADD
  li t0, 5
  addi t1, t0, 7
  li t2, 12
  bne t1, t2, fail_1

  # 2: SUB
  li t0, 10
  li t1, 17
  sub t2, t0, t1
  li t3, -7
  bne t2, t3, fail_2

  # 3: AND / OR / XOR
  li t0, 0x0F0F0F0F
  li t1, 0x00FF00FF
  and t2, t0, t1
  li t3, 0x000F000F
  bne t2, t3, fail_3
  or t2, t0, t1
  li t3, 0x0FFF0FFF
  bne t2, t3, fail_3
  xor t2, t0, t1
  li t3, 0x0FF00FF0
  bne t2, t3, fail_3

  # 4: shifts
  li t0, 1
  slli t1, t0, 31
  li t2, 0x80000000
  bne t1, t2, fail_4
  srli t3, t1, 31
  bne t3, t0, fail_4
  srai t4, t1, 31
  li t5, -1
  bne t4, t5, fail_4

  # 5: SLT / SLTU
  li t0, -1
  li t1, 1
  slt t2, t0, t1
  li t3, 1
  bne t2, t3, fail_5
  sltu t4, t0, t1
  bne t4, zero, fail_5
  slti t2, t1, 2
  bne t2, t3, fail_5

  # 6: LUI / AUIPC
  lui t0, 0x12345
  li t1, 0x12345000
  bne t0, t1, fail_6
  auipc t2, 0
  auipc t3, 0
  addi t4, t2, 4
  bne t3, t4, fail_6

  # 7: conditional branches
  li t0, 1
  beq t0, zero, fail_7
  bne t0, zero, 1f
  j fail_7
1:

  # 8: signed and unsigned compares
  li t0, -5
  li t1, 3
  blt t0, t1, 1f
  j fail_8
1:
  bge t1, t0, 1f
  j fail_8
1:
  li t0, -1
  li t1, 1
  bltu t1, t0, 1f
  j fail_8
1:
  bgeu t0, t1, 1f
  j fail_8
1:

  # 9: JAL link value
  jal ra, 1f
  j fail_9
1:
  auipc t0, 0
  addi t1, ra, 4
  bne t0, t1, fail_9

  # 10: JALR link and target
  la t0, jalr_target
  jalr ra, 0(t0)
  j fail_10
jalr_target:
  auipc t0, 0
  addi t1, ra, 4
  bne t0, t1, fail_10

  # 11: byte accesses
  la s2, scratch
  li t0, 0xAB
  sb t0, 5(s2)
  lbu t1, 5(s2)
  bne t0, t1, fail_11
  lb t1, 5(s2)
  li t2, -85
  bne t1, t2, fail_11

  # 12: halfword accesses
  li t0, 0xBEEF
  sh t0, 6(s2)
  lhu t1, 6(s2)
  bne t0, t1, fail_12
  lh t1, 6(s2)
  li t2, -16657
  bne t1, t2, fail_12

  # 13: word accesses
  li t0, 0x11223344
  sw t0, 0(s2)
  lw t1, 0(s2)
  bne t0, t1, fail_13

  # 14: store then load the same word
  li t0, 0x55AA55AA
  sw t0, 8(s2)
  lw t1, 8(s2)
  bne t0, t1, fail_14

  # 15: load-use hazard
  lw t1, 8(s2)
  addi t2, t1, 1
  li t3, 0x55AA55AB
  bne t2, t3, fail_15

  # 16: branch on a freshly loaded value
  lw t1, 8(s2)
  beq t1, zero, fail_16
  bne t1, zero, 1f
  j fail_16
1:

  # 17: CSRs
  li t0, 0x1234
  csrw mscratch, t0
  csrr t1, mscratch
  bne t0, t1, fail_17
  csrr t2, mhartid
  bne t2, zero, fail_17
  csrr t3, misa
  li t4, 0x40000100
  bne t3, t4, fail_17

  # 18: ECALL trap and MRET
  la t0, trap_handler
  csrw mtvec, t0
  li s0, 0
  ecall
  li t0, 1
  bne s0, t0, fail_18

  # 19: illegal instruction trap
  li s1, 0
  .word 0
  li t0, 1
  bne s1, t0, fail_19

  # 20: EBREAK trap
  li s3, 0
  ebreak
  li t0, 1
  bne s3, t0, fail_20

  # PASS
  li a0, 1
  sw a0, 0(x31)
1:
  j 1b

trap_handler:
  csrr t2, mcause
  li t3, 11
  beq t2, t3, trap_ecall
  li t3, 3
  beq t2, t3, trap_ebreak
  li t3, 2
  beq t2, t3, trap_illegal
  li a0, 999
  j fail
trap_ecall:
  li s0, 1
  j trap_return
trap_ebreak:
  li s3, 1
  j trap_return
trap_illegal:
  li s1, 1
trap_return:
  csrr t4, mepc
  addi t4, t4, 4
  csrw mepc, t4
  mret

.macro fail num
  li a0, \num
  j fail
.endm

fail_1:
  fail 1
fail_2:
  fail 2
fail_3:
  fail 3
fail_4:
  fail 4
fail_5:
  fail 5
fail_6:
  fail 6
fail_7:
  fail 7
fail_8:
  fail 8
fail_9:
  fail 9
fail_10:
  fail 10
fail_11:
  fail 11
fail_12:
  fail 12
fail_13:
  fail 13
fail_14:
  fail 14
fail_15:
  fail 15
fail_16:
  fail 16
fail_17:
  fail 17
fail_18:
  fail 18
fail_19:
  fail 19
fail_20:
  fail 20

fail:
  sw a0, 0(x31)
1:
  j 1b

.section .data
.align 4
scratch:
  .word 0
  .word 0
  .word 0
  .word 0
