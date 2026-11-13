# Directed Sv32 virtual-memory test.
#
# Builds a page table in SDRAM, enables satp, and checks:
#   - MPRV data translation and a PTE remap after sfence.vma
#   - U-mode instruction/data translation
#   - load, store and instruction page faults
#   - S-mode execution, delegated ECALL, and SRET
#
# The page table maps the program image twice: 0x1000_0000 as a 4 MiB
# U-accessible superpage and 0x4000_0000 as the same physical range with
# U=0 so S-mode can fetch it.

.section .text.init
.globl _start

_start:
  la t0, m_trap
  csrw mtvec, t0

  # ---------------------------------------------------------- page tables
  la t0, root

  # Root entry 0x40: 4 MiB identity superpage, U/R/W/X, A/D set.
  li t2, 0x100
  add t3, t0, t2
  li t1, 0x040000df
  sw t1, 0(t3)

  # Root entry 0x100: the same physical range at 0x4000_0000, S-only.
  li t2, 0x400
  add t3, t0, t2
  li t1, 0x040000cf
  sw t1, 0(t3)

  # Root entry 0x80: pointer to the level-0 table.
  la t1, leaf
  srli t1, t1, 12
  slli t1, t1, 10
  ori t1, t1, 1
  li t2, 0x200
  add t3, t0, t2
  sw t1, 0(t3)

  # Root entry 0xC0: deliberately invalid for VA 0x3000_0000.
  li t2, 0x300
  add t3, t0, t2
  sw zero, 0(t3)

  # Leaf entry 0: VA 0x2000_0000 -> remap_a, U/R/W, A/D set.
  la t1, remap_a
  srli t1, t1, 12
  slli t1, t1, 10
  ori t1, t1, 0xd7
  la t3, leaf
  sw t1, 0(t3)

  la t0, root
  srli t0, t0, 12
  li t1, 0x80000000
  or t0, t0, t1
  csrw satp, t0
  csrr s9, satp
  sfence.vma

  # ------------------------------------- MPRV data translation and remap
  la t0, remap_a
  li t1, 0x0000aaaa
  sw t1, 0(t0)
  la t0, remap_b
  li t1, 0x0000bbbb
  sw t1, 0(t0)

  li t0, 0x00020000  # MPRV=1, MPP=U
  csrw mstatus, t0
  li t0, 0x20000000
  lw t1, 0(t0)
  li t2, 0x0000aaaa
  bne t1, t2, fail

  # Point leaf entry 0 at remap_b and make the change visible to the walker.
  la t1, remap_b
  srli t1, t1, 12
  slli t1, t1, 10
  ori t1, t1, 0xd7
  la t3, leaf
  sw t1, 0(t3)
  sfence.vma

  li t0, 0x20000000
  lw t1, 0(t0)
  li t2, 0x0000bbbb
  bne t1, t2, fail
  csrw mstatus, zero

  # ----------------------------------------------------------- U-mode
  li s7, 0
  la t0, u_entry
  csrw mepc, t0
  mret

m_after_u:
  li t0, 0x00001234
  bne s4, t0, fail

  # ----------------------------------------------------------- S-mode
  li t0, 0x200  # delegate ECALL from S
  csrw medeleg, t0
  li t1, 0x30000000
  la t0, s_trap
  add t0, t0, t1
  csrw stvec, t0
  la t0, s_entry
  add t0, t0, t1
  csrw mepc, t0
  li t0, 0x800  # MPP=S
  csrw mstatus, t0
  mret

m_after_s:
  bne s8, s9, fail

  li t0, 1
  li t1, 0x80001000
  sw t0, 0(t1)
1:
  j 1b

# --------------------------------------------------------- U-mode program
u_entry:
  la s2, u_data
  li s3, 0x00001234
  sw s3, 0(s2)
  lw s4, 0(s2)
  bne s3, s4, u_fail

  li s5, 0x30000000
  lw s6, 0(s5)     # load page fault; handler skips the instruction
  li s5, 0x30000000
  sw s6, 0(s5)     # store page fault; handler skips the instruction

  li s5, 0x30001000
  jr s5            # instruction page fault
u_after_bad_jump:
  ecall            # ECALL from U returns to M

u_fail:
  li s7, 1
  ecall

# --------------------------------------------------------- S-mode program
s_entry:
  csrr s8, satp
  sfence.vma
  ecall            # delegated to the S-mode handler below
s_after:
  li s11, 1
  .word 0          # illegal instruction traps to M

s_trap:
  csrr t0, scause
  li t1, 9
  bne t0, t1, s_fail
  la t0, s_after
  csrw sepc, t0
  sret

s_fail:
  li s11, 0
  .word 0

# -------------------------------------------------------- M-mode trap handler
m_trap:
  csrr t0, mcause
  li t1, 13
  beq t0, t1, trap_mem
  li t1, 15
  beq t0, t1, trap_mem
  li t1, 12
  beq t0, t1, trap_ifetch
  li t1, 8
  beq t0, t1, trap_ecall_u
  li t1, 2
  beq t0, t1, trap_illegal
  j fail

trap_mem:
  csrr t2, mtval
  li t3, 0x30000000
  bne t2, t3, fail
  csrr t4, mepc
  addi t4, t4, 4
  csrw mepc, t4
  mret

trap_ifetch:
  csrr t2, mtval
  li t3, 0x30001000
  bne t2, t3, fail
  la t4, u_after_bad_jump
  csrw mepc, t4
  mret

trap_ecall_u:
  li t3, 1
  beq s7, t3, fail
  la t4, m_after_u
  csrw mepc, t4
  li t4, 0x1800  # MPP=M
  csrs mstatus, t4
  mret

trap_illegal:
  li t3, 1
  beq s11, t3, trap_illegal_ok
  j fail
trap_illegal_ok:
  li s11, 0
  la t4, m_after_s
  csrw mepc, t4
  li t4, 0x1800  # MPP=M
  csrs mstatus, t4
  mret

fail:
  csrw mstatus, zero
  li t0, 0x80001000
  li t1, 0xdead
  sw t1, 0(t0)
1:
  j 1b

.section .bss
.balign 4096
root:
  .space 4096
leaf:
  .space 4096
.balign 4096
remap_a:
  .space 4096
remap_b:
  .space 4096
u_data:
  .space 4
