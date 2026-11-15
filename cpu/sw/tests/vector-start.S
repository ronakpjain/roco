# Restart, completion, and fault-index checks for vstart.
.section .text.init
.globl _start

.macro check_restart sew, vlmax, store, load, step
  vsetivli zero, \vlmax, \sew, m1, tu, mu
  vmv.v.i v18, 9
  vmv.v.i v21, 1
  vmv.v.i v22, 2
  li t0, 2
  csrw vstart, t0
  vadd.vv v18, v21, v22
  csrr t0, vstart
  bnez t0, fail
  \store v18, (s2)
  mv a4, s2
  li t3, 0
.Lrestart_\@:
  \load t4, 0(a4)
  li t5, 3
  li t0, 2
  bgeu t3, t0, .Lcheck_\@
  li t5, 9
.Lcheck_\@:
  bne t4, t5, fail
  addi a4, a4, \step
  addi t3, t3, 1
  li t0, \vlmax
  bltu t3, t0, .Lrestart_\@

  vmv.v.i v18, 9
  li t0, (\vlmax - 1)
  vsetvli zero, t0, \sew, m1, ta, mu
  li t0, 1
  csrw vstart, t0
  vadd.vv v18, v21, v22
  csrr t0, vstart
  bnez t0, fail
  vsetivli zero, \vlmax, \sew, m1, tu, mu
  \store v18, (s2)
  \load t4, 0(s2)
  li t5, 9
  bne t4, t5, fail
  addi a4, s2, \step
  li t3, (\vlmax - 2)
  li t5, 3
.Lactive_\@:
  \load t4, 0(a4)
  bne t4, t5, fail
  addi a4, a4, \step
  addi t3, t3, -1
  bnez t3, .Lactive_\@
  \load t4, 0(a4)
  li t5, 9
  beq t4, t5, .Ltail_ok_\@
  li t5, -1
  li t0, (32 - 8 * \step)
  srl t5, t5, t0
  bne t4, t5, fail
.Ltail_ok_\@:
.endm


.macro check_memory_restart sew, vlmax, loadvec, storevec, load, step
  vsetivli zero, \vlmax, \sew, m1, tu, mu
  vmv.v.i v19, 9
  li t0, 2
  csrw vstart, t0
  \loadvec v19, (s0)
  csrr t0, vstart
  bnez t0, fail
  \storevec v19, (s2)
  mv a4, s2
  mv a3, s0
  li t3, 0
.Lmemory_load_\@:
  \load t4, 0(a4)
  \load t5, 0(a3)
  li t0, 2
  bgeu t3, t0, .Lmemory_check_\@
  li t5, 9
.Lmemory_check_\@:
  bne t4, t5, fail
  addi a4, a4, \step
  addi a3, a3, \step
  addi t3, t3, 1
  li t0, \vlmax
  bltu t3, t0, .Lmemory_load_\@
  vmv.v.i v20, 9
  \storevec v20, (s2)
  vmv.v.i v20, 5
  li t0, 2
  csrw vstart, t0
  \storevec v20, (s2)
  csrr t0, vstart
  bnez t0, fail
  mv a4, s2
  li t3, 0
.Lmemory_store_\@:
  \load t4, 0(a4)
  li t5, 5
  li t0, 2
  bgeu t3, t0, .Lmemory_store_check_\@
  li t5, 9
.Lmemory_store_check_\@:
  bne t4, t5, fail
  addi a4, a4, \step
  addi t3, t3, 1
  li t0, \vlmax
  bltu t3, t0, .Lmemory_store_\@
.endm

_start:
  li s11, 0x80001000
  la t0, trap
  csrw mtvec, t0
  li s3, 0
  li s4, 0
  la s0, input
  la s2, output
  check_restart e8, 16, vse8.v, lbu, 1
  check_restart e16, 8, vse16.v, lhu, 2
  check_restart e32, 4, vse32.v, lw, 4
  check_memory_restart e8, 16, vle8.v, vse8.v, lbu, 1
  check_memory_restart e16, 8, vle16.v, vse16.v, lhu, 2

  # No body means no destination changes, including agnostic tails.
  vsetivli zero, 16, e8, m1, tu, mu
  vmv.v.i v23, 9
  vsetivli zero, 2, e8, m1, ta, mu
  li t0, 2
  csrw vstart, t0
  vmv.v.i v23, 3
  csrr t0, vstart
  bnez t0, fail
  li t0, 0
  vsetvli zero, t0, e8, m1, ta, mu
  vmv.v.i v23, 4
  vredsum.vs v23, v21, v22
  li t0, 5
  csrw vstart, t0
  vmv.x.s t1, v23
  li t0, 9
  bne t0, t1, fail
  csrr t0, vstart
  bnez t0, fail
  vsetivli zero, 16, e8, m1, tu, mu
  vse8.v v23, (s2)
  li t1, 0x09090909
  lw t0, 0(s2)
  bne t0, t1, fail
  lw t0, 12(s2)
  bne t0, t1, fail

  # vset resets vstart; scalar-element writes retain their special layout.
  li t0, 3
  csrw vstart, t0
  vsetivli zero, 4, e32, m1, tu, mu
  csrr t0, vstart
  bnez t0, fail
  vmv.v.i v23, 9
  li t0, 1
  csrw vstart, t0
  li t0, 7
  vmv.s.x v23, t0
  vse32.v v23, (s2)
  lw t0, 0(s2)
  li t1, 7
  bne t0, t1, fail
  lw t0, 4(s2)
  li t1, 9
  bne t0, t1, fail

  # Unit-stride memory resumes at base + vstart * element size.
  vmv.v.i v19, 9
  li t0, 2
  csrw vstart, t0
  vle32.v v19, (s0)
  csrr t0, vstart
  bnez t0, fail
  vse32.v v19, (s2)
  lw t0, 0(s2)
  li t1, 9
  bne t0, t1, fail
  lw t0, 4(s2)
  bne t0, t1, fail
  lw t0, 8(s2)
  li t1, 30
  bne t0, t1, fail
  lw t0, 12(s2)
  li t1, 40
  bne t0, t1, fail
  li t0, 11
  sw t0, 0(s2)
  li t0, 22
  sw t0, 4(s2)
  vmv.v.i v20, 5
  li t0, 2
  csrw vstart, t0
  vse32.v v20, (s2)
  csrr t0, vstart
  bnez t0, fail
  lw t0, 0(s2)
  li t1, 11
  bne t0, t1, fail
  lw t0, 4(s2)
  li t1, 22
  bne t0, t1, fail
  lw t0, 8(s2)
  li t1, 5
  bne t0, t1, fail

  # A completed/no-body memory operation must not check a bad address.
  li t0, 4
  csrw vstart, t0
  li t1, 1
  vle32.v v20, (t1)
  csrr t0, vstart
  bnez t0, fail
  li t0, 4
  csrw vstart, t0
  vse32.v v20, (t1)
  csrr t0, vstart
  bnez t0, fail

  # Reductions cannot resume from a nonzero vstart.
  li s3, 1
  li t0, 1
  csrw vstart, t0
reduction_fault:
  vredsum.vs v20, v19, v20
  li t0, 1
  bne s4, t0, fail
  csrr t0, vstart
  li t1, 1
  bne t0, t1, fail
  csrw vstart, zero

  # Fault halfway through a vector load, then resume without rereading
  # the completed prefix (the handler deliberately changes those bytes).
  la t0, leaf
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, 1
  la t1, root
  sw t0, 1024(t1)
  la t0, page0
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, 0xc7
  la t1, leaf
  sw t0, 0(t1)
  la t1, page0
  li t0, 4088
  add t1, t1, t0
  li t0, 10
  sw t0, 0(t1)
  li t0, 20
  sw t0, 4(t1)
  la t1, page1
  li t0, 30
  sw t0, 0(t1)
  li t0, 40
  sw t0, 4(t1)
  sfence.vma
  la t0, root
  srli t0, t0, 12
  li t1, 0x80000000
  or t0, t0, t1
  csrw satp, t0
  li s3, 2
  li s0, 0x40000ff8
  vmv.v.i v20, 9
retry_vector:
  li t0, 0x20800
  csrw mstatus, t0
fault_load:
  vle32.v v20, (s0)
  csrw mstatus, zero
  csrr t0, vstart
  bnez t0, fail
  li t0, 2
  bne s4, t0, fail
  vse32.v v20, (s2)
  lw t0, 0(s2)
  li t1, 10
  bne t0, t1, fail
  lw t0, 4(s2)
  li t1, 20
  bne t0, t1, fail
  lw t0, 8(s2)
  li t1, 30
  bne t0, t1, fail
  lw t0, 12(s2)
  li t1, 40
  bne t0, t1, fail
  li a0, 1
  sw a0, 0(s11)
1: j 1b

trap:
  li t0, 1
  beq s3, t0, illegal_reduction
  li t0, 2
  bne s3, t0, fail
  csrr t0, mcause
  li t1, 13
  bne t0, t1, fail
  csrr t0, vstart
  li t1, 2
  bne t0, t1, fail
  csrr t0, mepc
  la t1, fault_load
  bne t0, t1, fail
  la t0, page1
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, 0xc7
  la t1, leaf
  sw t0, 4(t1)
  la t1, page0
  li t0, 4088
  add t1, t1, t0
  li t0, 99
  sw t0, 0(t1)
  li t0, 88
  sw t0, 4(t1)
  sfence.vma
  li t0, 0x1800
  csrw mstatus, t0
  la t0, retry_vector
  csrw mepc, t0
  j trap_return
illegal_reduction:
  csrr t0, mcause
  li t1, 2
  bne t0, t1, fail
  csrr t0, vstart
  li t1, 1
  bne t0, t1, fail
  csrr t0, mepc
  la t1, reduction_fault
  bne t0, t1, fail
  addi t0, t0, 4
  csrw mepc, t0
trap_return:
  li s3, 0
  addi s4, s4, 1
  mret
fail:
  csrw mstatus, zero
  li a0, 100
  sw a0, 0(s11)
1: j 1b

.section .data
.balign 16
input: .word 10, 20, 30, 40
output: .zero 16
.balign 4096
root: .zero 4096
leaf: .zero 4096
page0: .zero 4096
page1: .zero 4096
