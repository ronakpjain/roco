// Minimal freestanding memory-mapped I/O helpers for the roco SoC.

#ifndef ROCO_IO_H
#define ROCO_IO_H

#define UART_DATA (*(volatile unsigned int *)0x80000000u)
#define UART_STAT (*(volatile unsigned int *)0x80000004u)
#define LEDS (*(volatile unsigned int *)0x80000010u)
#define BUTTONS (*(volatile unsigned int *)0x80000014u)
#define MTIME_LO (*(volatile unsigned int *)0x80000018u)
#define MTIME_HI (*(volatile unsigned int *)0x8000001cu)
#define MTIMECMP_LO (*(volatile unsigned int *)0x80000020u)
#define MTIMECMP_HI (*(volatile unsigned int *)0x80000024u)
#define TIMER_PENDING (*(volatile unsigned int *)0x80000028u)
#define ICACHE_HITS (*(volatile unsigned int *)0x80000030u)
#define ICACHE_MISSES (*(volatile unsigned int *)0x80000034u)
#define DCACHE_HITS (*(volatile unsigned int *)0x80000038u)
#define DCACHE_MISSES (*(volatile unsigned int *)0x8000003cu)
#define BOOT_STATUS (*(volatile unsigned int *)0x80000100u)
#define BOOT_BASE (*(volatile unsigned int *)0x80000104u)
#define TOHOST (*(volatile unsigned int *)0x80001000u)

static inline unsigned int uart_tx_ready(void) {
  return UART_STAT & 1u;
}

static inline unsigned int uart_rx_valid(void) {
  return UART_STAT & 2u;
}

static inline void putc(char c) {
  while (!uart_tx_ready()) {
  }
  UART_DATA = (unsigned int)(unsigned char)c;
}

static inline void puts(const char *s) {
  while (*s) {
    putc(*s++);
  }
}

static inline int getc_nonblocking(void) {
  if (!uart_rx_valid()) {
    return -1;
  }
  return (int)(UART_DATA & 0xffu);
}

unsigned int roco_read_mcycle(void);
unsigned int roco_read_mcycleh(void);
unsigned int roco_read_minstret(void);
unsigned int roco_read_minstreth(void);

static inline unsigned int read_mcycle(void) {
  return roco_read_mcycle();
}

static inline unsigned int read_mcycleh(void) {
  return roco_read_mcycleh();
}

static inline unsigned int read_minstret(void) {
  return roco_read_minstret();
}

static inline unsigned int read_minstreth(void) {
  return roco_read_minstreth();
}

static inline void write_tohost(unsigned int code) {
  TOHOST = code;
}

#endif
