# Directed Zve32x vector test.
#
# Exercises vsetvli/vsetivli, unit-stride vector load and store, the
# element-wise add forms, vmv between vector and scalar registers, the
# reduction sum, and the tail policy.

.section .text.init
.globl _start

_start:
  li x31, 0x80001000
  la s1, vbuf_a
  la s2, vbuf_b
  la s3, vbuf_o

  # 1: vsetvli reports vl = min(AVL, VLMAX) and writes the vl CSR
  li t0, 4
  vsetvli t1, t0, e32, m1, ta, ma
  li t2, 4
  bne t1, t2, fail_1
  csrr t3, vl
  bne t3, t2, fail_1
  csrr t3, vlenb
  li t2, 16
  bne t3, t2, fail_1

  # 2: load, add, store
  vle32.v v1, (s1)
  vle32.v v2, (s2)
  vadd.vv v3, v1, v2
  vse32.v v3, (s3)
  lw t4, 0(s3)
  li t5, 11
  bne t4, t5, fail_2
  lw t4, 8(s3)
  li t5, 33
  bne t4, t5, fail_2
  lw t4, 12(s3)
  li t5, 44
  bne t4, t5, fail_2

  # 3: vector to scalar and scalar to vector element moves
  vmv.x.s a5, v3
  li t5, 11
  bne a5, t5, fail_3
  li a5, 77
  vmv.s.x v4, a5
  vmv.x.s t5, v4
  li t4, 77
  bne t5, t4, fail_3

  # 4: reduction over the active elements
  li a5, 0
  vmv.s.x v5, a5
  vredsum.vs v5, v1, v5
  vmv.x.s t5, v5
  li t4, 100
  bne t5, t4, fail_4

  # 5: add with a scalar register and with an immediate
  li a5, 5
  vadd.vx v6, v1, a5
  vmv.x.s t5, v6
  li t4, 15
  bne t5, t4, fail_5
  vadd.vi v6, v1, -1
  vmv.x.s t5, v6
  li t4, 9
  bne t5, t4, fail_5

  # 6: logical operations
  vand.vv v7, v1, v2
  vmv.x.s t5, v7
  li t4, 0
  bne t5, t4, fail_6
  vxor.vv v7, v1, v1
  vmv.x.s t5, v7
  bne t5, zero, fail_6

  # 7: tail agnostic lanes become all ones
  li t0, 2
  vsetvli t1, t0, e32, m1, ta, ma
  vadd.vv v3, v1, v2
  li t0, 4
  vsetvli t1, t0, e32, m1, ta, ma
  vse32.v v3, (s3)
  lw t4, 0(s3)
  li t5, 11
  bne t4, t5, fail_7
  lw t4, 8(s3)
  li t5, -1
  bne t4, t5, fail_7

  # 8: tail undisturbed keeps the destination lanes
  li t0, 4
  vsetvli t1, t0, e32, m1, ta, ma
  li a5, -1
  vmv.v.i v8, -1
  li t0, 2
  vsetvli t1, t0, e32, m1, tu, ma
  vadd.vv v8, v1, v2
  li t0, 4
  vsetvli t1, t0, e32, m1, ta, ma
  vse32.v v8, (s3)
  lw t4, 0(s3)
  li t5, 11
  bne t4, t5, fail_8
  lw t4, 12(s3)
  li t5, -1
  bne t4, t5, fail_8

  # 9: byte and halfword element widths
  li t0, 8
  vsetvli t1, t0, e16, m1, ta, ma
  li t2, 8
  bne t1, t2, fail_9
  la s4, vbuf_h
  vle16.v v9, (s4)
  vadd.vx v9, v9, t0
  vse16.v v9, (s4)
  lh t4, 0(s4)
  li t5, 9
  bne t4, t5, fail_9
  lh t4, 14(s4)
  li t5, 16
  bne t4, t5, fail_9

  # Consecutive reductions must read the preceding reduction result.
  li a5, 3
  vmv.s.x v13, a5
  vredsum.vs v14, v9, v13
  vredsum.vs v14, v9, v14
  vmv.x.s t4, v14
  slli t4, t4, 16
  srli t4, t4, 16
  li t5, 203
  bne t4, t5, fail_9

  # 10: byte elements crossing cache lines, including first/last lanes.
  vsetivli zero, 16, e8, m1, ta, ma
  la s4, vbuf_bytes
  addi s4, s4, 1
  la s5, vbuf_byte_out
  addi s5, s5, 1
  vle8.v v10, (s4)
  vadd.vi v10, v10, 1
  vse8.v v10, (s5)
  lbu t4, 0(s5)
  li t5, 1
  bne t4, t5, fail_10
  lbu t4, 15(s5)
  li t5, 16
  bne t4, t5, fail_10
  li a5, 5
  vmv.s.x v11, a5
  vredsum.vs v12, v10, v11
  vmv.x.s t4, v12
  andi t4, t4, 255
  li t5, 141
  bne t4, t5, fail_10

  # Zero-length memory instructions must not change registers or memory.
  vsetivli zero, 0, e8, m1, ta, ma
  vle8.v v10, (s4)
  vse8.v v11, (s5)
  lbu t4, 0(s5)
  li t5, 1
  bne t4, t5, fail_10
  vsetivli zero, 16, e8, m1, ta, ma
  vse8.v v10, (s5)
  lbu t4, 0(s5)
  bne t4, t5, fail_10

  li a0, 1
  sw a0, 0(x31)
1:
  j 1b

fail_1:
  li a0, 41
  j fail
fail_2:
  li a0, 42
  j fail
fail_3:
  li a0, 43
  j fail
fail_4:
  li a0, 44
  j fail
fail_5:
  li a0, 45
  j fail
fail_6:
  li a0, 46
  j fail
fail_7:
  li a0, 47
  j fail
fail_8:
  li a0, 48
  j fail
fail_9:
  li a0, 49
  j fail
fail_10:
  li a0, 50
fail:
  sw a0, 0(x31)
1:
  j 1b

.section .data
.align 4
vbuf_a:
  .word 10
  .word 20
  .word 30
  .word 40
vbuf_b:
  .word 1
  .word 2
  .word 3
  .word 4
vbuf_o:
  .word 0
  .word 0
  .word 0
  .word 0
vbuf_h:
  .half 1
  .half 2
  .half 3
  .half 4
  .half 5
  .half 6
  .half 7
  .half 8

.balign 16
vbuf_bytes:
  .byte 99, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
.balign 16
vbuf_byte_out:
  .space 32
