#include "syscall.h"

/* roco_cc needs an explicit bound for an initialized string array. */
static const char hello_message[19] = "hart 0 user hello\n";

int main(void) {
  if (gethart() != 0) {
    return 1;
  }

  if (yield() != 0) {
    return 2;
  }

  /* A null pointer is never valid user memory. */
  if (write(1, (const void *)0, 1) != -1) {
    return 3;
  }

  if (syscall(0x7fffffff, 0, 0) != -1) {
    return 4;
  }

  if (write(1, hello_message, sizeof(hello_message) - 1) !=
      (int)(sizeof(hello_message) - 1)) {
    return 5;
  }

  return 0;
}
