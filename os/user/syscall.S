# roco user-mode system call wrappers.
#
# The C ABI already places the first three arguments in a0-a2, so the
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

.globl read
.globl sys_read
.type read, @function
.type sys_read, @function
read:
sys_read:
  li a7, 2              # SYS_READ
  ecall
  ret
.size read, . - read
.size sys_read, . - sys_read

.globl exit
.globl sys_exit
.type exit, @function
.type sys_exit, @function
exit:
sys_exit:
  li a7, 3              # SYS_EXIT
  ecall
1:
  j 1b                  # exit must not return
.size exit, . - exit
.size sys_exit, . - sys_exit

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

.globl gethart
.globl sys_gethart
.type gethart, @function
.type sys_gethart, @function
gethart:
sys_gethart:
  li a7, 5              # SYS_GETHART
  ecall
  ret
.size gethart, . - gethart
.size sys_gethart, . - sys_gethart

.globl readchar
.globl sys_readchar
.type readchar, @function
.type sys_readchar, @function
readchar:
sys_readchar:
  li a7, 6              # SYS_READCHAR
  ecall
  ret
.size readchar, . - readchar
.size sys_readchar, . - sys_readchar

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

.globl syscall3
.type syscall3, @function
syscall3:
  mv a7, a0             # trap number
  mv a0, a1             # arg0
  mv a1, a2             # arg1
  mv a2, a3             # arg2
  ecall
  ret
.size syscall3, . - syscall3

.globl open
.globl sys_open
.type open, @function
.type sys_open, @function
open:
sys_open:
  li a7, 7              # SYS_OPEN
  ecall
  ret
.size open, . - open
.size sys_open, . - sys_open

.globl close
.globl sys_close
.type close, @function
.type sys_close, @function
close:
sys_close:
  li a7, 8              # SYS_CLOSE
  ecall
  ret
.size close, . - close
.size sys_close, . - sys_close

.globl seek
.globl sys_seek
.type seek, @function
.type sys_seek, @function
seek:
sys_seek:
  li a7, 9              # SYS_SEEK
  ecall
  ret
.size seek, . - seek
.size sys_seek, . - sys_seek

.globl stat
.globl sys_stat
.type stat, @function
.type sys_stat, @function
stat:
sys_stat:
  li a7, 10             # SYS_STAT
  ecall
  ret
.size stat, . - stat
.size sys_stat, . - sys_stat

.globl fstat
.globl sys_fstat
.type fstat, @function
.type sys_fstat, @function
fstat:
sys_fstat:
  li a7, 11             # SYS_FSTAT
  ecall
  ret
.size fstat, . - fstat
.size sys_fstat, . - sys_fstat

.globl unlink
.globl sys_unlink
.type unlink, @function
.type sys_unlink, @function
unlink:
sys_unlink:
  li a7, 12             # SYS_UNLINK
  ecall
  ret
.size unlink, . - unlink
.size sys_unlink, . - sys_unlink

.globl mkdir
.globl sys_mkdir
.type mkdir, @function
.type sys_mkdir, @function
mkdir:
sys_mkdir:
  li a7, 13             # SYS_MKDIR
  ecall
  ret
.size mkdir, . - mkdir
.size sys_mkdir, . - sys_mkdir

.globl rmdir
.globl sys_rmdir
.type rmdir, @function
.type sys_rmdir, @function
rmdir:
sys_rmdir:
  li a7, 14             # SYS_RMDIR
  ecall
  ret
.size rmdir, . - rmdir
.size sys_rmdir, . - sys_rmdir

.globl rename
.globl sys_rename
.type rename, @function
.type sys_rename, @function
rename:
sys_rename:
  li a7, 15             # SYS_RENAME
  ecall
  ret
.size rename, . - rename
.size sys_rename, . - sys_rename

.globl readdir
.globl sys_readdir
.type readdir, @function
.type sys_readdir, @function
readdir:
sys_readdir:
  li a7, 16             # SYS_READDIR
  ecall
  ret
.size readdir, . - readdir
.size sys_readdir, . - sys_readdir

.globl fsinfo
.globl sys_fsinfo
.type fsinfo, @function
.type sys_fsinfo, @function
fsinfo:
sys_fsinfo:
  li a7, 17             # SYS_FSINFO
  ecall
  ret
.size fsinfo, . - fsinfo
.size sys_fsinfo, . - sys_fsinfo

.globl chdir
.globl sys_chdir
.type chdir, @function
.type sys_chdir, @function
chdir:
sys_chdir:
  li a7, 18             # SYS_CHDIR
  ecall
  ret
.size chdir, . - chdir
.size sys_chdir, . - sys_chdir

.globl getcwd
.globl sys_getcwd
.type getcwd, @function
.type sys_getcwd, @function
getcwd:
sys_getcwd:
  li a7, 19             # SYS_GETCWD
  ecall
  ret
.size getcwd, . - getcwd
.size sys_getcwd, . - sys_getcwd

.globl getpid
.globl sys_getpid
.type getpid, @function
.type sys_getpid, @function
getpid:
sys_getpid:
  li a7, 20             # SYS_GETPID
  ecall
  ret
.size getpid, . - getpid
.size sys_getpid, . - sys_getpid

.globl getppid
.globl sys_getppid
.type getppid, @function
.type sys_getppid, @function
getppid:
sys_getppid:
  li a7, 21             # SYS_GETPPID
  ecall
  ret
.size getppid, . - getppid
.size sys_getppid, . - sys_getppid

.globl exec
.globl sys_exec
.type exec, @function
.type sys_exec, @function
exec:
sys_exec:
  li a7, 22             # SYS_EXEC
  ecall
  ret
.size exec, . - exec
.size sys_exec, . - sys_exec

.globl spawn
.globl sys_spawn
.type spawn, @function
.type sys_spawn, @function
spawn:
sys_spawn:
  li a7, 23             # SYS_SPAWN
  ecall
  ret
.size spawn, . - spawn
.size sys_spawn, . - sys_spawn

.globl sleep
.globl sys_sleep
.type sleep, @function
.type sys_sleep, @function
sleep:
sys_sleep:
  li a7, 24             # SYS_SLEEP
  ecall
  ret
.size sleep, . - sleep
.size sys_sleep, . - sys_sleep

.globl kill
.globl sys_kill
.type kill, @function
.type sys_kill, @function
kill:
sys_kill:
  li a7, 25             # SYS_KILL
  ecall
  ret
.size kill, . - kill
.size sys_kill, . - sys_kill

.globl uptime
.globl sys_uptime
.type uptime, @function
.type sys_uptime, @function
uptime:
sys_uptime:
  li a7, 26             # SYS_UPTIME
  ecall
  ret
.size uptime, . - uptime
.size sys_uptime, . - sys_uptime
