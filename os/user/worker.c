#include "syscall.h"

/* The loader must place this value in .data. */
int worker_initialized = 0x574f524b;

/* The loader must zero this .bss object before entering _start. */
int worker_bss;

/* roco_cc needs an explicit bound for an initialized string array. */
static const char worker_message[20] = "hart 1 user worker\n";

int main(void) {
  if (gethart() != 1) {
    return 1;
  }

  if (worker_initialized != 0x574f524b) {
    return 2;
  }

  if (worker_bss != 0) {
    return 3;
  }

  /* Both globals must also be writable after loading. */
  worker_initialized = 0x12345678;
  worker_bss = 0x0badf00d;
  if (worker_initialized != 0x12345678) {
    return 4;
  }
  if (worker_bss != 0x0badf00d) {
    return 5;
  }

  if (yield() != 0) {
    return 6;
  }

  /* A null pointer is never valid user memory. */
  if (write((const void *)0, 1) != -1) {
    return 7;
  }

  if (syscall(0x7fffffff, 0, 0) != -1) {
    return 8;
  }

  if (write(worker_message, sizeof(worker_message) - 1) !=
      (int)(sizeof(worker_message) - 1)) {
    return 9;
  }

  return 0;
}
