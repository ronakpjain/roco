# MMIO formatting uses the lookup's offset and width, including signed
# partial reads and unimplemented byte-offset addresses returning zero.
.section .text.init
.globl _start
_start:
  li x31, 0x80001000
  li s0, 0x80000048
  li t0, 0x76548080
  sw t0, 0(s0)
  lb t1, 0(s0)
  li t2, -128
  bne t1, t2, fail
  lbu t1, 0(s0)
  li t2, 128
  bne t1, t2, fail
  lh t1, 0(s0)
  li t2, -32640
  bne t1, t2, fail
  lhu t1, 0(s0)
  li t2, 0x8080
  bne t1, t2, fail
  lw t1, 0(s0)
  bne t1, t0, fail
  lbu t1, 1(s0)
  bnez t1, fail
  lhu t1, 2(s0)
  bnez t1, fail
  # Alternate a byte-aligned MMIO word and cached stack words.
  la s1, scratch
  li t0, 0x80ff7f01
  sw t0, 0(s1)
  lb t1, 3(s1)
  li t2, -128
  bne t1, t2, fail
  lh t1, 0(s0)
  li t2, -32640
  bne t1, t2, fail
  lhu t1, 2(s1)
  li t2, 0x80ff
  bne t1, t2, fail
  lbu t1, 0(s0)
  li t2, 128
  bne t1, t2, fail
  li a0, 1
  sw a0, 0(x31)
1: j 1b
fail:
  li a0, 32
  sw a0, 0(x31)
2: j 2b
.section .data
.balign 4
scratch: .word 0
