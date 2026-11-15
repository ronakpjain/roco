# Counter reads observe every older retirement, including across the low
# word rollover. RMW writes replace the counter on their own retirement.
.section .text.init
.globl _start
_start:
  li x31, 0x80001000
  li t0, 7
  csrw minstreth, t0
  li t0, -1
  csrw minstret, t0
  csrr t1, minstret
  csrr t2, minstret
  csrr t3, minstreth
  bne t1, t0, fail
  bnez t2, fail
  li t4, 8
  bne t3, t4, fail

  li t4, 123
  csrr t1, minstret
  csrrw t2, minstret, t4
  csrr t3, minstret
  addi t1, t1, 1
  bne t1, t2, fail
  bne t3, t4, fail

  li t4, 0x100
  csrrs t1, minstret, t4
  csrr t2, minstret
  or t1, t1, t4
  bne t1, t2, fail
  csrrc t1, minstret, t4
  csrr t2, minstret
  not t4, t4
  and t1, t1, t4
  bne t1, t2, fail

  li a0, 1
  sw a0, 0(x31)
1: j 1b
fail:
  li a0, 31
  sw a0, 0(x31)
2: j 2b
