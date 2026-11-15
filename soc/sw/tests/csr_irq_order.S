# An interrupt accepted with a CSR write must use the state after that
# instruction retires, including a newly selected trap vector.
.section .text.init
.globl _start
_start:
  li s11, 0x80001000
  la t0, bad_handler
  csrw mtvec, t0
  csrw mip, zero
  li t0, 8
  csrw mie, t0
  li s1, 0
  la s2, handler
  la s4, resume

  # Keep the sequence within one cache line so fetch misses cannot move
  # interrupt acceptance into a gap before the vector write.
  .balign 16
  csrsi mstatus, 8
  csrw mip, t0
  csrw mtvec, s2
resume:
  li t1, 1
  bne s1, t1, fail
  csrr t1, mip
  andi t1, t1, 8
  bnez t1, fail
  li a0, 1
  sw a0, 0(s11)
1: j 1b

.align 2
handler:
  csrr t1, mcause
  li t2, 0x80000003
  bne t1, t2, fail
  csrr t1, mepc
  bne t1, s4, fail
  csrr t1, mtvec
  bne t1, s2, fail
  csrr t1, mstatus
  andi t1, t1, 128
  beqz t1, fail
  addi s1, s1, 1
  csrw mip, zero
  mret

.align 2
bad_handler:
fail:
  li a0, 29
  sw a0, 0(s11)
2: j 2b
