# roco user-mode system call wrappers.
#
# The C ABI already places the first two arguments in a0 and a1, so the
# named wrappers only need to load the trap number into a7. syscall()
# rearranges its C arguments (number, arg0, arg1) into (a7, a0, a1).

.section .text

.globl write
.globl sys_write
.type write, @function
.type sys_write, @function
write:
sys_write:
  li a7, 1              # SYS_WRITE
  ecall
  ret
.size write, . - write
.size sys_write, . - sys_write

.globl exit
.globl sys_exit
.type exit, @function
.type sys_exit, @function
exit:
sys_exit:
  li a7, 2              # SYS_EXIT
  ecall
1:
  j 1b                  # exit must not return
.size exit, . - exit
.size sys_exit, . - sys_exit

.globl gethart
.globl sys_gethart
.type gethart, @function
.type sys_gethart, @function
gethart:
sys_gethart:
  li a7, 3              # SYS_GETHART
  ecall
  ret
.size gethart, . - gethart
.size sys_gethart, . - sys_gethart

.globl yield
.globl sys_yield
.type yield, @function
.type sys_yield, @function
yield:
sys_yield:
  li a7, 4              # SYS_YIELD
  ecall
  ret
.size yield, . - yield
.size sys_yield, . - sys_yield

.globl readchar
.type readchar, @function
readchar:
  li a7, 5              # SYS_READCHAR
  ecall
  ret
.size readchar, . - readchar

.globl syscall
.globl sys_call
.type syscall, @function
.type sys_call, @function
syscall:
sys_call:
  mv a7, a0             # trap number
  mv a0, a1             # arg0
  mv a1, a2             # arg1
  ecall
  ret
.size syscall, . - syscall
.size sys_call, . - sys_call
