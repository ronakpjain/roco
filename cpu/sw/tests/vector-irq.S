# A pending software interrupt must wait for vector memory instructions
# to finish, then return without losing or replaying the next instruction.
.section .text.init
.globl _start
_start:
  li x31, 0x80001000
  la t0, handler
  csrw mtvec, t0
  la s1, source
  la s2, destination
  li s4, 0
  li s6, 0
  vsetivli zero, 4, e32, m1, ta, ma
  li t0, 8
  csrw mie, t0
  csrsi mstatus, 8
  csrw mip, t0
vector_load:
  vle32.v v1, (s1)
  vse32.v v1, (s2)
  addi s4, s4, 1
resume:
  li t0, 1
  bne s4, t0, fail_count
  bne s6, t0, fail_count
  lw t0, 0(s2)
  li t1, 17
  bne t0, t1, fail_data
  lw t0, 4(s2)
  li t1, 34
  bne t0, t1, fail_data
  lw t0, 8(s2)
  li t1, 51
  bne t0, t1, fail_data
  lw t0, 12(s2)
  li t1, 68
  bne t0, t1, fail_data
  li a0, 1
  sw a0, 0(x31)
1: j 1b
.align 2
handler:
  csrr t0, mepc
  # A fetch bubble can provide an earlier legal interrupt boundary.
  la t1, vector_load
  bltu t0, t1, fail
  la t1, resume
  bltu t1, t0, fail
  addi s6, s6, 1
  csrw mip, zero
  mret
fail_data:
  li a0, 13
  j report_failure
fail_count:
  li a0, 12
  j report_failure
fail:
  li a0, 11
report_failure:
  sw a0, 0(x31)
2: j 2b
.section .data
.balign 16
source: .word 17, 34, 51, 68
destination: .word 0, 0, 0, 0
