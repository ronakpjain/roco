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
 *   5: readchar(void)                  -> byte, or -1 if unavailable
 *   6: run_job(a0 = job ID, a1 = hart) -> 0, JOB_BUSY, or -1 if invalid
 *   7: job_status(a0 = job ID)        -> idle, active, or completion
 *
 * All other trap numbers return -1.
 */

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_GETHART 3
#define SYS_YIELD 4
#define SYS_READCHAR 5
#define SYS_RUN_JOB 6
#define SYS_JOB_STATUS 7

/* Job syscalls are only available to hart 0 in the console image. */
#define JOB_IDLE 0
#define JOB_ACTIVE 1  /* Add the target hart number for an active slot. */
#define JOB_WORKER 1
#define JOB_COUNTDOWN 2
#define JOB_DONE 256  /* Completion is JOB_DONE plus the low 8 exit-status bits. */
#define JOB_FAULT 512 /* Fault is JOB_FAULT plus the exception cause. */
#define JOB_BUSY -2

int write(const void *buffer, int length);
void exit(int status);
int gethart(void);
int yield(void);
int readchar(void);

/* Generic two-argument form, useful for exercising unknown syscalls. */
int syscall(int number, int arg0, int arg1);

/* Prefixed aliases for callers that do not want short global names. */
int sys_write(const void *buffer, int length);
void sys_exit(int status);
int sys_gethart(void);
int sys_yield(void);
int sys_call(int number, int arg0, int arg1);

#endif
