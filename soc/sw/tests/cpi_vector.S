# Each vector arithmetic/reduction instruction retires in one cycle,
# including consecutive dependent reductions at every supported SEW.
.section .text.init
.globl _start, cpi_reduce8, cpi_reduce16, cpi_reduce32, cpi_vec_alu
_start:
  li s11, 0x80001000
  la t0, fail
  csrw mtvec, t0
  vsetivli zero, 16, e8, m1, ta, ma
  vmv.v.i v2, 1
  vmv.v.i v1, 0
  li t6, 64
  li s0, 0
cpi_reduce8:
  vredsum.vs v1, v2, v1
  vmv.x.s t0, v1
  add s0, s0, t0
  addi t6, t6, -1
  bnez t6, cpi_reduce8
  bnez t0, fail
  li t1, -512
  bne s0, t1, fail
  vsetivli zero, 8, e16, m1, ta, ma
  vmv.v.i v2, 1
  vmv.v.i v1, 0
  li t6, 64
  li s0, 0
cpi_reduce16:
  vredsum.vs v1, v2, v1
  vmv.x.s t0, v1
  add s0, s0, t0
  addi t6, t6, -1
  bnez t6, cpi_reduce16
  li t1, 512
  bne t0, t1, fail
  li t1, 16640
  bne s0, t1, fail
  vsetivli zero, 4, e32, m1, ta, ma
  vmv.v.i v2, 1
  vmv.v.i v1, 0
  li t6, 64
  li s0, 0
cpi_reduce32:
  vredsum.vs v1, v2, v1
  vmv.x.s t0, v1
  add s0, s0, t0
  addi t6, t6, -1
  bnez t6, cpi_reduce32
  li t1, 256
  bne t0, t1, fail
  li t1, 8320
  bne s0, t1, fail
  li t6, 64
  li s0, 0
  li s6, 3
cpi_vec_alu:
  vadd.vv v3, v2, v2
  vadd.vx v3, v3, s6
  vadd.vi v3, v3, -1
  vmv.x.s t0, v3
  add s0, s0, t0
  addi t6, t6, -1
  bnez t6, cpi_vec_alu
  li t1, 256
  bne s0, t1, fail
  li a0, 1
  sw a0, 0(s11)
1: j 1b
fail:
  li a0, 11
  sw a0, 0(s11)
2: j 2b
