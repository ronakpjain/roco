# Direct and vectored trap-vector test.
#
# A machine software interrupt uses mtvec[0] = 1 and must enter at
# base + 4 * cause. An ECALL exception must still enter at the base.
# WFI must retire without trapping.

.section .text.init
.globl _start
_start:
  li x31, 0x80001000
  la t0, vector_table
  ori t0, t0, 1
  csrw mtvec, t0
  csrr t1, mtvec
  bne t0, t1, fail_1

  li s1, 0
  li s2, 0
  li s3, 0
  li t0, 0x8
  csrw mie, t0
  csrw mip, t0
  csrsi mstatus, 0x8
  li a0, 0
1:
  addi a0, a0, 1
  li a1, 30
  blt a0, a1, 1b
  csrci mstatus, 0x8
  li t0, 1
  bne s1, t0, fail_2
  csrw mip, zero

  # An exception must use the base even when mtvec is vectored.
  ecall
  li t0, 1
  bne s2, t0, fail_3

  # WFI is a hint and must retire.
  wfi

  li a0, 1
  sw a0, 0(x31)
2:
  j 2b

.align 2
vector_table:
  j exception_handler   # cause 0
  j bad_handler         # cause 1
  j bad_handler         # cause 2
  j software_handler    # cause 3
  j bad_handler         # cause 4
  j bad_handler         # cause 5
  j bad_handler         # cause 6
  j bad_handler         # cause 7
  j bad_handler         # cause 8
  j bad_handler         # cause 9
  j bad_handler         # cause 10
  j bad_handler         # cause 11; exceptions must not use this entry

exception_handler:
  csrr t0, mcause
  li t1, 11
  bne t0, t1, bad_handler
  li s2, 1
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret

software_handler:
  csrr t0, mcause
  li t1, 0x80000003
  bne t0, t1, bad_handler
  li s1, 1
  csrw mip, zero
  mret

bad_handler:
  li s3, 1
  li a0, 13
  j fail

fail_1:
  li a0, 11
  j fail
fail_2:
  li a0, 12
  j fail
fail_3:
  li a0, 14
fail:
  sw a0, 0(x31)
3:
  j 3b
