// Hello world and cache-counter demo for the roco SoC.

#include "roco_io.h"

static unsigned int crc32(const unsigned char *data, unsigned int length) {
  unsigned int crc = 0xffffffffu;
  for (unsigned int i = 0; i < length; i++) {
    crc ^= data[i];
    for (int bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
  }
  return ~crc;
}

static void print_hex(unsigned int value) {
  for (int shift = 28; shift >= 0; shift -= 4) {
    putc("0123456789abcdef"[(value >> shift) & 0xf]);
  }
}

int main(void) {
  unsigned int before;
  unsigned int after;
  unsigned int i;
  unsigned int sum = 0;
  volatile unsigned int *array = (volatile unsigned int *)0x10004000u;

  puts("hello, roco\r\n");

  // Fill 1 KiB with a pattern, then sum it repeatedly. The first pass
  // misses in the D-cache; later passes hit.
  for (i = 0; i < 256; i++) {
    array[i] = i + (i << 8) + 0x5a5a5a5au;
  }
  before = read_mcycle();
  unsigned int inst_before = read_minstret();
  for (i = 0; i < 8; i++) {
    for (unsigned int j = 0; j < 256; j++) {
      sum += array[j];
    }
  }
  after = read_mcycle();
  unsigned int inst_after = read_minstret();

  *(volatile unsigned int *)0x80000048u = after - before;
  *(volatile unsigned int *)0x8000004cu = inst_after - inst_before;

  puts("sum=");
  print_hex(sum);
  puts(" cycles=");
  print_hex((after - before));
  puts(" instret=");
  print_hex((inst_after - inst_before));
  puts("\r\nicache hits=");
  print_hex(ICACHE_HITS);
  puts(" misses=");
  print_hex(ICACHE_MISSES);
  puts("\r\ndcache hits=");
  print_hex(DCACHE_HITS);
  puts(" misses=");
  print_hex(DCACHE_MISSES);
  puts("\r\ncrc32=");
  unsigned int crc = crc32((const unsigned char *)0x10000000u, 64);
  print_hex(crc);
  puts("\r\n");

  LEDS = 0x5;
  return 0;
}
