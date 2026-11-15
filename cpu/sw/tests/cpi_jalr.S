# Warm indirect jumps must retire every cycle. Changing the target must
# recover precisely, with no wrong-path register or store side effects.
.section .text.init
.globl _start, cpi_target_a, cpi_target_b
_start:
  li x31, 0x80001000
  la t0, fail
  csrw mtvec, t0
  li s0, 80
  li s1, 0
  li s2, 0
  li a0, 11
  la t0, cpi_target_a
site:
  jalr zero, 0(t0)
  sw a0, 0(x31)
  j fail
cpi_target_a:
  addi s1, s1, 1
  addi s0, s0, -1
  bnez s0, site
  la t0, cpi_target_b
  li s0, 80
  j site
cpi_target_b:
  addi s2, s2, 1
  addi s0, s0, -1
  bnez s0, site
  li t1, 80
  bne s1, t1, fail
  bne s2, t1, fail
  li a0, 1
  sw a0, 0(x31)
1: j 1b
fail:
  li a0, 11
  sw a0, 0(x31)
2: j 2b
