.section .text
.globl enable_paging, enter_user, restart_worker, resume_worker, clear_tick
.globl s_trap_vector, spin_lock, spin_unlock, flush_icache, set_scratch

enable_paging:
    # Hart 0 published these immutable tables before releasing hart 1.
    # On roco, a SATP write invalidates the local TLBs. Do not broadcast
    # a redundant SFENCE.VMA while the other hart is executing.
    csrw satp, a0
    ret

# Drop the old user trap and kernel call frames before taking another job.
restart_worker:
    mv sp, a0
    tail worker_loop

clear_tick:
    li t0, 0x20
    csrc sip, t0
    ret

# Copy a saved context into the common return frame. No caller will return.
resume_worker:
    addi sp, a0, -144
    mv t0, sp
    addi t1, a1, 132
1:  lw t2, 0(a1)
    sw t2, 0(t0)
    addi a1, a1, 4
    addi t0, t0, 4
    bne a1, t1, 1b
    # Resumed contexts always return to U, with S-mode interrupts masked.
    li t0, 0x40122
    csrc sstatus, t0
    j restore_user

# The trap frame lives at the top of this hart's supervisor stack.
enter_user:
    csrw sepc, a0
    sw a3, -144(a2)
    csrw sscratch, a2
    li t0, 0x40122  # SUM, SPP, SPIE, SIE
    csrc sstatus, t0
    mv sp, a1
    li ra, 0
    li gp, 0
    li tp, 0
    li t0, 0
    li t1, 0
    li t2, 0
    li s0, 0
    li s1, 0
    li a0, 0
    li a1, 0
    li a2, 0
    li a3, 0
    li a4, 0
    li a5, 0
    li a6, 0
    li a7, 0
    li s2, 0
    li s3, 0
    li s4, 0
    li s5, 0
    li s6, 0
    li s7, 0
    li s8, 0
    li s9, 0
    li s10, 0
    li s11, 0
    li t3, 0
    li t4, 0
    li t5, 0
    li t6, 0
    sret

.balign 4
s_trap_vector:
    csrrw sp, sscratch, sp
    beqz sp, s_double_trap
    addi sp, sp, -144
    sw ra, 4(sp)
    sw gp, 12(sp)
    sw tp, 16(sp)
    sw t0, 20(sp)
    sw t1, 24(sp)
    sw t2, 28(sp)
    sw s0, 32(sp)
    sw s1, 36(sp)
    sw a0, 40(sp)
    sw a1, 44(sp)
    sw a2, 48(sp)
    sw a3, 52(sp)
    sw a4, 56(sp)
    sw a5, 60(sp)
    sw a6, 64(sp)
    sw a7, 68(sp)
    sw s2, 72(sp)
    sw s3, 76(sp)
    sw s4, 80(sp)
    sw s5, 84(sp)
    sw s6, 88(sp)
    sw s7, 92(sp)
    sw s8, 96(sp)
    sw s9, 100(sp)
    sw s10, 104(sp)
    sw s11, 108(sp)
    sw t3, 112(sp)
    sw t4, 116(sp)
    sw t5, 120(sp)
    sw t6, 124(sp)
    csrrw t0, sscratch, zero
    sw t0, 8(sp)
    csrr t0, sepc
    sw t0, 128(sp)
    la gp, __global_pointer$
    mv a0, sp
    csrr a1, scause
    csrr a2, sstatus
    andi a2, a2, 0x100
    call supervisor_trap

restore_user:
    lw t0, 128(sp)
    csrw sepc, t0
    addi t0, sp, 144
    csrw sscratch, t0
    lw ra, 4(sp)
    lw gp, 12(sp)
    lw tp, 16(sp)
    lw t0, 20(sp)
    lw t1, 24(sp)
    lw t2, 28(sp)
    lw s0, 32(sp)
    lw s1, 36(sp)
    lw a0, 40(sp)
    lw a1, 44(sp)
    lw a2, 48(sp)
    lw a3, 52(sp)
    lw a4, 56(sp)
    lw a5, 60(sp)
    lw a6, 64(sp)
    lw a7, 68(sp)
    lw s2, 72(sp)
    lw s3, 76(sp)
    lw s4, 80(sp)
    lw s5, 84(sp)
    lw s6, 88(sp)
    lw s7, 92(sp)
    lw s8, 96(sp)
    lw s9, 100(sp)
    lw s10, 104(sp)
    lw s11, 108(sp)
    lw t3, 112(sp)
    lw t4, 116(sp)
    lw t5, 120(sp)
    lw t6, 124(sp)
    lw sp, 8(sp)
    sret

s_double_trap:
    csrw sscratch, zero
    csrr t0, scause
    andi t0, t0, 255
    ori t0, t0, 0x600
    li t1, 0x80001000
    sw t0, 0(t1)
1:  j 1b

spin_lock:
    li t0, 1
1:  lw t1, 0(a0)
    bnez t1, 1b
    amoswap.w.aq t1, t0, (a0)
    bnez t1, 1b
    ret

spin_unlock:
    amoswap.w.rl zero, zero, (a0)
    ret

# Make freshly loaded user text visible to instruction fetch: write back
# the D-cache and invalidate the I-cache. Boot already fences once after
# kernel_init; runtime reloads in worker_loop and exec need it per load.
flush_icache:
    fence.i
    ret

# Publish the supervisor stack top before first use, so an early S-mode
# trap reports through the normal fatal path instead of double-trapping
# on a zero sscratch.
set_scratch:
    csrw sscratch, a0
    ret

.section .bss
.balign 4096
.globl page_tables
page_tables:
    .zero 24576
