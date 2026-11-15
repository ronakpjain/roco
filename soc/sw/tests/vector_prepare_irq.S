# An interrupt must wait for vector operand preparation to finish. The
# vector instruction retires before the saved next PC skips over it.
.section .text.init
.globl _start
_start:
  li s11, 0x80001000
  la t0, handler
  csrw mtvec, t0
  csrw mip, zero
  li t0, 8
  csrw mie, t0
  li s1, 0
  la s3, destination
  la s4, resume
  vsetivli zero, 4, e32, m1, ta, ma
  vmv.v.i v1, 3

  .balign 16
  csrsi mstatus, 8
  csrw mip, t0
  vadd.vi v1, v1, 7
resume:
  vse32.v v1, (s3)
  li t0, 10
  lw t1, 0(s3)
  bne t1, t0, fail
  lw t1, 12(s3)
  bne t1, t0, fail
  li t0, 1
  bne s1, t0, fail
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
  addi s1, s1, 1
  csrw mip, zero
  mret
fail:
  li a0, 30
  sw a0, 0(s11)
2: j 2b
.section .data
.balign 16
destination: .word 0, 0, 0, 0
