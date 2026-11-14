# CSRRS/CSRRC with a non-x0 register still attempt a write when its value
# is zero; x0 and zero immediate forms suppress writes to read-only CSRs.
.section .text.init
.globl _start
_start:
  li x31, 0x80001000
  la t3, handler
  csrw mtvec, t3
  li s1, 0
  li t0, 0
  la s2, bad_set
bad_set:
  csrrs t1, mhartid, t0
  la s2, bad_clear
bad_clear:
  csrrc t1, mhartid, t0
  la s2, bad_imm
bad_imm:
  csrrsi t1, mhartid, 1
  csrrs t1, mhartid, zero
  bnez t1, fail
  csrrc t1, mhartid, zero
  bnez t1, fail
  csrrsi t1, mhartid, 0
  bnez t1, fail
  csrrci t1, mhartid, 0
  bnez t1, fail
  li t2, 7
  csrw mscratch, t2
  csrrw zero, mscratch, zero
  csrr t2, mscratch
  bnez t2, fail
  li t2, 3
  bne s1, t2, fail
  li a0, 1
  sw a0, 0(x31)
1: j 1b
.align 2
handler:
  csrr t3, mcause
  li t4, 2
  bne t3, t4, fail
  csrr t3, mepc
  bne t3, s2, fail
  addi s1, s1, 1
  addi t3, t3, 4
  csrw mepc, t3
  mret
fail:
  li a0, 11
  sw a0, 0(x31)
2: j 2b
