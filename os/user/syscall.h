#ifndef USER_SYSCALL_H
#define USER_SYSCALL_H

/*
 * roco user-mode system call ABI.
 *
 * The trap number is passed in a7:
 *   1: write(a0 = buffer, a1 = length) -> bytes written, or -1
 *   2: exit(a0 = status)               -> does not return
 *   3: gethart(void)                   -> hart id (0 or 1)
 *   4: yield(void)                     -> 0
 *
 * All other trap numbers return -1.
 */

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_GETHART 3
#define SYS_YIELD 4

int write(const void *buffer, int length);
void exit(int status);
int gethart(void);
int yield(void);

/* Generic two-argument form, useful for exercising unknown syscalls. */
int syscall(int number, int arg0, int arg1);

/* Prefixed aliases for callers that do not want short global names. */
int sys_write(const void *buffer, int length);
void sys_exit(int status);
int sys_gethart(void);
int sys_yield(void);
int sys_call(int number, int arg0, int arg1);

#endif
