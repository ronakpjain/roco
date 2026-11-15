// Minimal UART boot smoke image. The full demo lives in main.c; keeping
// this image small keeps the bootloader simulation fast.

#include "roco_io.h"

int main(void) {
  puts("hello, roco\r\n");
  return 0;
}
