# A cold fetch at the last word of a virtual page must replay before the
# speculative next-page TLB miss. The JAL link and AUIPC check virtual PCs.
.section .text.init
.globl _start
_start:
  li s11, 0x80001000
  la t0, m_trap
  csrw mtvec, t0
  la t0, leaf
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, 1
  la t1, root
  sw t0, 0(t1)
  la t0, code_page0
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, 0xdf
  la t1, leaf
  sw t0, 0(t1)
  la t0, code_page1
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, 0xdf
  sw t0, 4(t1)
  fence.i
  la t0, root
  srli t0, t0, 12
  li t1, 0x80000000
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li s0, 0xbad
  li s1, 0
  li s2, 0
  li t0, 0xffc
  csrw mepc, t0
  csrw mstatus, zero
  mret

.align 2
m_trap:
  csrr t0, mcause
  li t1, 8
  bne t0, t1, fail
  li t0, 0x1000
  bne s0, t0, fail
  li t0, 0x1004
  bne s1, t0, fail
  li t0, 0x55
  bne s2, t0, fail
  csrr t0, mepc
  li t1, 0x1008
  bne t0, t1, fail
  li a0, 1
  sw a0, 0(s11)
1: j 1b
fail:
  li a0, 31
  sw a0, 0(s11)
2: j 2b

.section .text
.balign 4096
code_page0:
  .space 4092
  jal s0, 4
  .space 4096
.balign 4096
code_page1:
  li s2, 0x55
  auipc s1, 0
  ecall
  j fail

.section .data
.balign 4096
root: .space 4096
leaf: .space 4096
