# CSR helpers for the hello C program. Keeping these in assembly lets the
# freestanding C compiler stay free of inline-assembly syntax.

.section .text
.globl roco_read_mcycle, roco_read_mcycleh, roco_read_minstret, roco_read_minstreth

roco_read_mcycle:
  csrr a0, mcycle
  ret

roco_read_mcycleh:
  csrr a0, mcycleh
  ret

roco_read_minstret:
  csrr a0, minstret
  ret

roco_read_minstreth:
  csrr a0, minstreth
  ret
