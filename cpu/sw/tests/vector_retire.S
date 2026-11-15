# Element transfers are micro-operations: a vector memory instruction must
# increment minstret exactly once, including VL zero.
.section .text.init
.globl _start
_start:
  li s11, 0x80001000
  la s3, source
  la s4, destination
  vsetivli zero, 4, e32, m1, ta, ma
  # Put both counter reads after a hit stream of NOPs, so their pipeline
  # position is identical even when vector transfers miss in the caches.
  .balign 32
  nop
  nop
  nop
  csrr s0, minstret
  vle32.v v1, (s3)
  vse32.v v1, (s4)
  vsetivli zero, 0, e32, m1, ta, ma
  vle32.v v1, (s3)
  vse32.v v1, (s4)
  nop
  nop
  nop
  csrr s1, minstret
  sub s2, s1, s0
  li t0, 9
  bne s2, t0, fail
  lw t0, 12(s4)
  li t1, 4
  bne t0, t1, fail
  li a0, 1
  sw a0, 0(s11)
1: j 1b
fail:
  li a0, 11
  sw a0, 0(s11)
2: j 2b
.section .data
.balign 16
source: .word 1, 2, 3, 4
destination: .word 0, 0, 0, 0
