# Alternate two warm DTLB entries and load/store permission contexts.
# Offsets select different cache indices so both physical lines stay hot.
.section .text.init
.globl _start, cpi_vm
_start:
  li s11, 0x80001000
  la t0, fail
  csrw mtvec, t0
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
  la t0, page1
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, 0xc7
  sw t0, 4(t1)
  li t0, 7
  la t1, page0
  sw t0, 0(t1)
  li t0, 11
  la t1, page1
  sw t0, 64(t1)
  sfence.vma
  la t0, root
  srli t0, t0, 12
  li t1, 0x80000000
  or t0, t0, t1
  csrw satp, t0
  li t0, 0x20800
  csrs mstatus, t0
  li s0, 0x40000000
  li s1, 0x40001040
  li s2, 0
  li s3, 0
  li t6, 64
cpi_vm:
  lw t0, 0(s0)
  add s2, s2, t0
  sw t0, 0(s0)
  lw t1, 0(s1)
  add s3, s3, t1
  sw t1, 0(s1)
  addi t6, t6, -1
  bnez t6, cpi_vm
  li t0, 0x20000
  csrc mstatus, t0
  li t0, 448
  bne s2, t0, fail
  li t0, 704
  bne s3, t0, fail
  li a0, 1
  sw a0, 0(s11)
1: j 1b
fail:
  li t0, 0x20000
  csrc mstatus, t0
  li a0, 11
  sw a0, 0(s11)
2: j 2b
.section .data
.balign 4096
root: .zero 4096
leaf: .zero 4096
page0: .zero 4096
page1: .zero 4096
