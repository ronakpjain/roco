# Dependent scalar operations must sustain one retirement per cycle with
# warm caches. Each loop checks a different MEM-to-EX forwarding path.
.section .text.init
.globl _start, cpi_load, cpi_load_control, cpi_mul, cpi_lrsc, cpi_amo, cpi_atomic_order
_start:
  li s11, 0x80001000
  la t0, fail
  csrw mtvec, t0
  la s0, data
  la s1, scratch
  li s2, 0
  li s3, 0
  li s4, 0
  li s5, -1
  li s6, 7
  li s7, 1
  li a0, 11
  li t6, 64
cpi_load:
  lw t0, 0(s0)
  add t1, t0, t0
  sub t2, t1, t0
  sw t2, 0(s1)
  lw t3, 0(s1)
  add s2, s2, t3
  lbu t0, 4(s0)
  addi t0, t0, 1
  lb t1, 4(s0)
  addi t1, t1, -1
  lhu t2, 6(s0)
  addi t2, t2, 1
  lh t3, 6(s0)
  addi t3, t3, -1
  lw t4, 8(s0)
  lw t5, 0(t4)
  add s3, s3, t5
  lw t5, 0(s0)
  sw t5, 0(s1)
  lw t5, 0(s0)
  slli t4, t5, 2
  srli t4, t4, 1
  srai t4, s5, 1
  sltu t4, s5, s6
  slt t4, s5, s6
  xor t4, s5, s6
  or t4, t4, s6
  and t4, t4, s6
  addi t6, t6, -1
  bnez t6, cpi_load
  bne t4, s6, fail
  li t4, 448
  bne s2, t4, fail
  bne s3, t4, fail
  li t4, 129
  bne t0, t4, fail
  li t4, -129
  bne t1, t4, fail
  li t4, 0x8002
  bne t2, t4, fail
  li t4, -32768
  bne t3, t4, fail
  li t6, 64
cpi_load_control:
  lw t0, 12(s0)
  jalr zero, 0(t0)
  sw a0, 0(s11)
indirect_target:
  lw t1, 0(s0)
  beq t1, zero, fail
  csrw mscratch, t1
  csrr t2, mscratch
  lw t3, 0(s0)
  csrw mscratch, t3
  csrr t4, mscratch
  addi t6, t6, -1
  bnez t6, cpi_load_control
  bne t2, s6, fail
  bne t4, s6, fail
  li t6, 64
cpi_mul:
  mul t0, s6, s6
  mul t1, t0, s6
  mulh t2, t1, s6
  addi t3, t2, 1
  mulhu t4, s5, s5
  mulhsu t5, s5, s6
  add t0, t4, t5
  sw t0, 0(s1)
  lw t1, 0(s1)
  add s2, s2, t1
  mul t0, s0, s7
  lw t1, 0(t0)
  addi t6, t6, -1
  bnez t6, cpi_mul
  li t0, 256
  bne s2, t0, fail
  bnez t2, fail
  bne t3, s7, fail
  li t0, -2
  bne t4, t0, fail
  bne t5, s5, fail
  bne t1, s6, fail
  sw s6, 0(s1)
  li t6, 64
cpi_lrsc:
  lr.w t0, (s1)
  addi t0, t0, 1
  sc.w t1, t0, (s1)
  add s4, s4, t1
  addi t6, t6, -1
  bnez t6, cpi_lrsc
  bnez s4, fail
  lw t0, 0(s1)
  li t1, 71
  bne t0, t1, fail
  sw s6, 0(s1)
  li t6, 64
  li s8, 0
  li s9, 0x80000000
  li s10, 0x7fffffff
cpi_amo:
  amoadd.w t0, s7, (s1)
  amoxor.w t1, s5, (s1)
  amoxor.w t2, s5, (s1)
  add t3, t1, t2
  amomax.w t4, s5, (s1)
  amomin.w t5, s9, (s1)
  amomaxu.w t0, s10, (s1)
  amominu.w t1, s10, (s1)
  amoswap.w t2, s6, (s1)
  amoand.w zero, s5, (s1)
  amoor.w zero, zero, (s1)
  lw t4, 0(s1)
  add s8, s8, t4
  addi t6, t6, -1
  bnez t6, cpi_amo
  bne t3, s5, fail
  li a1, 8
  bne t5, a1, fail
  bne t0, s9, fail
  bne t1, s9, fail
  bne t2, s10, fail
  bne t4, s6, fail
  li a1, 448
  bne s8, a1, fail
  sw s6, 0(s1)
  li t6, 64
cpi_atomic_order:
  sw s6, 4(s1)
  amoadd.w.rl t0, s7, (s1)
  lw t1, 4(s1)
  amoxor.w.aq t2, s5, (s1)
  amoxor.w.aqrl t3, s5, (s1)
  lr.w.aq t4, (s1)
  sc.w.rl t5, s6, (s1)
  lr.w.aqrl a1, (s1)
  sc.w.aqrl a2, s6, (s1)
  lw a3, 4(s1)
  addi t6, t6, -1
  bnez t6, cpi_atomic_order
  li a4, 7
  bne t0, a4, fail
  bne t1, a4, fail
  li a4, 8
  bne t2, a4, fail
  bne t4, a4, fail
  li a4, -9
  bne t3, a4, fail
  bnez t5, fail
  bnez a2, fail
  bne a1, s6, fail
  bne a3, s6, fail
  li a0, 1
  sw a0, 0(s11)
1: j 1b
fail:
  li a0, 11
  sw a0, 0(s11)
2: j 2b
.section .data
.balign 16
data:
  .word 7, 0x80010080, data, indirect_target+1
scratch:
  .word 0
