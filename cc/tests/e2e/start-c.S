# C runtime startup for the roco core testbench.
#
# main() follows the C convention: zero means success. The testbench uses
# tohost value 1 for PASS, so a successful main is converted to 1 while a
# failing return code is written unchanged.

.section .text.init
.globl _start

_start:
  li sp, 0x10008000

  la t0, __bss_start
  la t1, __bss_end
1:
  bgeu t0, t1, 2f
  sb zero, 0(t0)
  addi t0, t0, 1
  j 1b

2:
  call main
  beqz a0, 3f

  li t0, 0x80001000
  sw a0, 0(t0)
4:
  j 4b

3:
  li t0, 0x80001000
  li t1, 1
  sw t1, 0(t0)
5:
  j 5b
