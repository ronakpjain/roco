# Registered trap entry must preserve the fault payload and cancel both
# younger EX slots, including stores, CSR/vector writes and reservations.
.section .text.init
.globl _start
_start:
  li s11, 0x80001000
  la t0, handler
  csrw mtvec, t0
  csrw mscratch, zero
  la s3, data
  li s2, 7
  li s4, 0
  li s8, 0
  vsetivli zero, 4, e32, m1, ta, ma
  vmv.v.i v1, 3
  lr.w zero, (s3)
  li s9, 2
  li s10, -1
  la s7, illegal_pc
  la s6, illegal_resume
illegal_pc:
  .word 0xffffffff
  csrw mscratch, s2
  sw s2, 0(s3)
  addi s2, s2, 1
illegal_resume:
  sc.w t0, s2, (s3)
  li t1, 1
  bne t0, t1, fail
  li s9, 4
  addi s10, s3, 1
  la s7, load_pc
  la s6, load_resume
  lw t0, 4(s3)
load_pc:
  lw s4, 0(t0)
  csrw mscratch, s2
  sw s2, 0(s3)
  addi s2, s2, 1
load_resume:
  li s9, 6
  addi s10, s3, 2
  la s7, store_pc
  la s6, store_resume
store_pc:
  sw s2, 2(s3)
  vadd.vi v1, v1, 1
  csrw mscratch, s2
  addi s2, s2, 1
store_resume:
  li s9, 0
  la s10, jump_resume
  addi s10, s10, 2
  mv t0, s10
  la s7, jump_pc
  la s6, jump_resume
jump_pc:
  jalr zero, 0(t0)
  vsetivli zero, 1, e8, m1, ta, ma
  vadd.vi v1, v1, 1
  csrw mscratch, s2
jump_resume:
  li t0, 4
  bne s8, t0, fail
  csrr t1, vl
  bne t1, t0, fail
  vmv.x.s t0, v1
  li t1, 3
  bne t0, t1, fail
  li t1, 7
  bne s2, t1, fail
  bnez s4, fail
  li a0, 1
  sw a0, 0(s11)
1: j 1b
.align 2
handler:
  csrr t1, mcause
  bne t1, s9, fail
  csrr t1, mepc
  bne t1, s7, fail
  csrr t1, mtval
  bne t1, s10, fail
  csrr t1, mscratch
  bnez t1, fail
  lw t1, 0(s3)
  bnez t1, fail
  addi s8, s8, 1
  csrw mepc, s6
  mret
fail:
  li a0, 11
  sw a0, 0(s11)
2: j 2b
.section .data
.balign 16
data: .word 0, data+1
