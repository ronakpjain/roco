.section .text
.globl main

# A U-mode load from an identity-mapped, S-only kernel page must trap to S.
main:
    li t0, 0x10000000
    lw t1, 0(t0)
    li a0, 1  # Reaching this point is a test failure, not the expected trap.
    ret
