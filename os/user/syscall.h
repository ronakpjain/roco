#ifndef USER_SYSCALL_H
#define USER_SYSCALL_H

/*
 * roco user-mode system call ABI.
 *
 * The trap number is passed in a7, up to three arguments in a0-a2, and
 * the result comes back in a0. File descriptors 0, 1, and 2 are the
 * console unless a program redirects them.
 *
 *   1: write(fd, buffer, length)   -> bytes written, or -1
 *   2: read(fd, buffer, length)    -> bytes read, 0 at EOF, -2 if no data
 *   3: exit(status)                -> does not return
 *   4: yield(void)                 -> 0
 *   5: gethart(void)               -> hart id (0 or 1)
 *   6: readchar(void)              -> next console byte, or -1
 *   7: run_job(a0 = job ID, a1 = hart) -> 0, JOB_BUSY, or -1
 *   8: job_status(a0 = job ID)     -> idle, active, or completion
 *
 * All other trap numbers return -1.
 */

#define SYS_WRITE 1
#define SYS_READ 2
#define SYS_EXIT 3
#define SYS_YIELD 4
#define SYS_GETHART 5
#define SYS_READCHAR 6
#define SYS_RUN_JOB 7
#define SYS_JOB_STATUS 8

/* Job syscalls are only available to hart 0 in the console image. */
#define JOB_IDLE 0
#define JOB_ACTIVE 1  /* Add the target hart number for an active slot. */
#define JOB_WORKER 1
#define JOB_COUNTDOWN 2
#define JOB_DONE 256  /* Completion is JOB_DONE plus the low 8 exit-status bits. */
#define JOB_FAULT 512 /* Fault is JOB_FAULT plus the exception cause. */
#define JOB_BUSY -2

/* read() and pipe writes use -2 for "nothing available, try again". */
#define SYS_AGAIN -2

/*
 * User virtual memory layout. A process gets 64 KiB of address space;
 * the kernel backs it with a private, contiguous 64 KiB slab of SDRAM.
 *
 *   0x00400000  text and read-only data   16 KiB, read/execute
 *   0x00404000  data and bss               8 KiB, read/write
 *   0x00406000  heap                      12 KiB, read/write
 *   0x00409000  guard page                      unmapped
 *   0x0040a000  stack                     24 KiB, read/write
 *   0x00410000  end of user space
 */
#define USER_BASE 0x00400000u
#define USER_TEXT_BYTES 0x4000u
#define USER_DATA_BASE 0x00404000u
#define USER_DATA_BYTES 0x2000u
#define USER_HEAP_BASE 0x00406000u
#define USER_HEAP_BYTES 0x3000u
#define USER_GUARD_BASE 0x00409000u
#define USER_STACK_BASE 0x0040a000u
#define USER_TOP 0x00410000u
#define USER_SLOT_BYTES 0x00010000u
#define USER_TEXT_PAGES 4u
#define USER_DATA_PAGES 2u
#define USER_HEAP_PAGES 3u
#define USER_STACK_PAGES 6u

int write(int fd, const void *buffer, int length);
int read(int fd, void *buffer, int length);
void exit(int status);
int gethart(void);
int yield(void);
int readchar(void);

/* Generic up-to-three-argument form, useful for exercising unknown calls. */
int syscall(int number, int arg0, int arg1);
int syscall3(int number, int arg0, int arg1, int arg2);

/* Prefixed aliases for callers that do not want short global names. */
int sys_write(int fd, const void *buffer, int length);
int sys_read(int fd, void *buffer, int length);
void sys_exit(int status);
int sys_gethart(void);
int sys_yield(void);
int sys_readchar(void);
int sys_call(int number, int arg0, int arg1);

#endif
