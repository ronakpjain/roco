# Machine-mode boot entry for roco.
#
# The UART loader starts hart 0 at _start.  Hart 1 remains parked in reset
# until hart 0 publishes its entry point through the SMP boot mailbox.
# Both harts then perform the common M-mode setup and drop into S mode in
# supervisor_main().  Page tables and payloads are prepared by hart 0 in
# kernel_init() while paging is still disabled.

.section .text.init
.balign 4
.globl _start
.type _start, @function

_start:
  # Per-hart downward stack.  Hart 0 gets [0x100fd000, 0x100ff000) and
  # hart 1 gets the adjacent 8 KiB at the lower address.
  csrr s0, mhartid
  li t0, 1
  bltu t0, s0, boot_bad_hart
  slli t1, s0, 13
  li s1, 0x100ff000
  sub s1, s1, t1
  mv sp, s1
  la gp, __global_pointer$

  # Interrupts stay disabled during boot.
  la t0, m_trap_vector
  csrw mtvec, t0
  csrw mscratch, zero
  csrw mie, zero
  csrw mideleg, zero

  # Supervisor traps vector through supervisor.S; synchronous exceptions
  # from S/U and U-mode ecall are delegated, S-mode ecall stays in M mode.
  la t0, s_trap_vector
  csrw stvec, t0
  li t0, 0x0000b1ff       # causes 0-8, 12, 13 and 15; not cause 9
  csrw medeleg, t0

  bnez s0, boot_hart1

  # ---------------------------------------------------------------- hart 0
  # Clear .bss.  Handle an unaligned start/end with byte stores, using word
  # stores for the aligned middle.
  la t0, __bss_start
  la t1, __bss_end
  la t2, _end
  li t3, 0x10040000       # Start of user backing RAM; keep in sync with kernel.c.
  bltu t3, t2, boot_image_too_large
  bgeu t0, t1, bss_done
bss_align:
  andi t2, t0, 3
  beqz t2, bss_words
  sb zero, 0(t0)
  addi t0, t0, 1
  bltu t0, t1, bss_align
  j bss_done

bss_words:
  sub t2, t1, t0
  li t3, 4
  bltu t2, t3, bss_tail
bss_word_loop:
  sw zero, 0(t0)
  addi t0, t0, 4
  sub t2, t1, t0
  bgeu t2, t3, bss_word_loop

bss_tail:
  beq t0, t1, bss_done
  sb zero, 0(t0)
  addi t0, t0, 1
  j bss_tail

bss_done:
  # Build all page tables and copy the user payloads while M is bare.
  call kernel_init

  # FENCE.I writes the D-cache back to SDRAM, making the page tables and
  # payload images visible to the hart being released.
  fence.i

  # Point hart 1 at the common entry and release it.
  la t0, _start
  li t1, 0x80000110
  sw t0, 0(t1)
  li t0, 1
  li t1, 0x80000114
  sw t0, 0(t1)

  # ---------------------------------------------------------------- hart 1
boot_hart1:
  la t0, user_countdown
  lw t0, 0(t0)
  beqz t0, enter_supervisor
  # The compare register resets to zero, so disarm it before enabling MTIE.
  li t0, 0x80000060
  bnez s0, timer_init
  li t0, 0x80000020
timer_init:
  li t1, -1
  sw t1, 4(t0)
  sw t1, 0(t0)
  la t0, timer_scratch
  slli t1, s0, 3
  add t0, t0, t1
  csrw mscratch, t0
  li t0, 0x20            # Delegate supervisor timer interrupts.
  csrw mideleg, t0
  li t0, 0xa0            # Enable machine and supervisor timer sources.
  csrw mie, t0
enter_supervisor:
  # mstatus: MPP=S, interrupts off, MPRV clear.  Satp is still reset (bare);
  # supervisor_main() installs its own page table after entering S mode.
  csrw mstatus, zero
  li t0, 0x00000800       # MPP = supervisor
  csrs mstatus, t0
  la t0, supervisor_main
  csrw mepc, t0

  # C ABI: a0 = hart id, a1 = original (highest) stack address.  sp already
  # points at the same top; the C stack grows downward from there.
  mv a0, s0
  mv a1, s1
  mret

.size _start, . - _start

# ------------------------------------------------------------------------
# Forward the local hardware timer to S mode. Other M-mode traps are fatal.
.balign 4
.type m_trap_vector, @function
m_trap_vector:
  csrrw t0, mscratch, t0
  beqz t0, m_fatal
  sw t1, 0(t0)
  sw t2, 4(t0)
  csrr t1, mcause
  li t2, 0x80000007
  bne t1, t2, m_fatal

  # Disarm the physical interrupt and post STIP. S mode rearms mtimecmp.
  li t1, 0x80000060
  csrr t2, mhartid
  bnez t2, timer_disarm
  li t1, 0x80000020
timer_disarm:
  li t2, -1
  sw t2, 4(t1)
  sw t2, 0(t1)
  li t1, 0x20
  csrs mip, t1
  lw t1, 0(t0)
  lw t2, 4(t0)
  csrrw t0, mscratch, t0
  mret

m_fatal:
  csrr t0, mcause
  csrr t1, mhartid
  slli t1, t1, 8
  or t0, t0, t1
  li t1, 0xbad00000
  or t0, t0, t1
  li t1, 0x80001000
  sw t0, 0(t1)
1:
  j 1b

.size m_trap_vector, . - m_trap_vector

# An impossible hart id is also fatal rather than running off the image.
.balign 4
.type boot_bad_hart, @function
boot_bad_hart:
  li t0, 0xbad00007
  j boot_fail
.size boot_bad_hart, . - boot_bad_hart

boot_image_too_large:
  li t0, 0xbad00008
boot_fail:
  li t1, 0x80001000
  sw t0, 0(t1)
1:
  j 1b

.section .bss
.balign 4
timer_scratch:
  .zero 16
