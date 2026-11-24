# Common user-mode startup for the roco demos.
#
# Each demo is linked independently at 0x00400000 with its own copy of
# this file and syscall.S. The loader is responsible for loading .data
# and zeroing .bss; startup deliberately does not clear .bss so the worker
# demo can verify the loader's handling of both sections.
#
# The user-mode entry path supplies sp pointing at the top of the mapped
# user stack, so startup preserves it instead of choosing its own stack.
# main() follows the usual C convention: zero means success.

.section .text.init
.globl _start
.type _start, @function

_start:
  la gp, __global_pointer$
  call main
  tail exit             # status remains in a0
.size _start, . - _start
