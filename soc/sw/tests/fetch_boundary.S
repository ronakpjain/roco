# Execute the final SDRAM word, then take an illegal-instruction trap on
# the first uncached word. The final cached response must not be dropped
# when the next speculative request selects the uncached response path.
.section .text.init
.globl _start
_start:
  li s11, 0x80001000
  la t0, handler
  csrw mtvec, t0
  li s1, 0
  li t0, 0x11fffffc
  li t1, 0x00100493  # addi s1, zero, 1
  sw t1, 0(t0)
  fence.i
  jalr ra, 0(t0)
resume:
  li t0, 1
  bne s1, t0, fail
  li a0, 1
  sw a0, 0(s11)
1: j 1b
handler:
  csrr t0, mcause
  li t1, 2
  bne t0, t1, fail
  csrr t0, mepc
  li t1, 0x12000000
  bne t0, t1, fail
  csrr t0, mtval
  bnez t0, fail
  li t0, 1
  bne s1, t0, fail
  csrw mepc, ra
  mret
fail:
  li a0, 37
  sw a0, 0(s11)
1: j 1b
