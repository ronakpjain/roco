#include "user/syscall.h"

#define PAGE_SIZE 4096u
#define USER_BASE 0x00400000u
/* The SoC testbench SDRAM model aliases addresses above its first MiB. */
#define USER_RAM 0x10040000u
#define USER_STRIDE 0x8000u
#define STACK_OFFSET (3u * PAGE_SIZE)
#define USER_TOP (USER_BASE + 5u * PAGE_SIZE)

#define PTE_V 0x01u
#define PTE_R 0x02u
#define PTE_W 0x04u
#define PTE_X 0x08u
#define PTE_U 0x10u
#define PTE_A 0x40u
#define PTE_D 0x80u
#define PTE_RW (PTE_R | PTE_W)

#define REG(addr) (*(volatile unsigned *)(addr))
#define UART_DATA REG(0x80000000u)
#define UART_STATUS REG(0x80000004u)
#define MTIME_LOW REG(0x80000018u)
#define TOHOST REG(0x80001000u)

/* Trap frame offsets are the integer register numbers, except slot 0. */
#define TF_HART 0
#define TF_A0 10
#define TF_A1 11
#define TF_A7 17
#define MAX_WRITE 256u

extern unsigned page_tables[4096];
extern const unsigned user_hello[2050];
extern const unsigned user_worker[2050];
void enable_paging(unsigned satp_value);
void enter_user(unsigned pc, unsigned user_sp, unsigned kernel_sp, unsigned hart);
void lock_uart(unsigned *lock);
void unlock_uart(unsigned *lock);

static unsigned uart_lock;
/* Only the owning hart writes its slot; 0 means running, 1 means success. */
static volatile unsigned completed[2];

static unsigned pte(unsigned pa, unsigned flags)
{
    return (pa >> 2) | flags | PTE_V;
}

static void setup_user(unsigned hart, const unsigned *image)
{
    unsigned *root = page_tables + 2048u * hart;
    unsigned *leaf = root + 1024u;
    unsigned pa = USER_RAM + hart * USER_STRIDE;
    unsigned *ram = (unsigned *)pa;
    unsigned text_words = image[0];
    unsigned data_words = image[1];
    unsigned i;

    for (i = 0; i < 5u * PAGE_SIZE / 4u; ++i)
        ram[i] = 0;
    for (i = 0; i < text_words; ++i)
        ram[i] = image[2u + i];
    for (i = 0; i < data_words; ++i)
        ram[PAGE_SIZE / 4u + i] = image[2u + text_words + i];

    root[USER_BASE >> 22] = pte((unsigned)leaf, 0);
    leaf[0] = pte(pa, PTE_R | PTE_X | PTE_U | PTE_A);
    leaf[1] = pte(pa + PAGE_SIZE, PTE_RW | PTE_U | PTE_A | PTE_D);
    /* Page 2 is an unmapped guard between data and the downward stack. */
    leaf[3] = pte(pa + STACK_OFFSET, PTE_RW | PTE_U | PTE_A | PTE_D);
    leaf[4] = pte(pa + 4u * PAGE_SIZE, PTE_RW | PTE_U | PTE_A | PTE_D);

    /* Supervisor-only identity mappings: RAM (kernel, aliases, stacks), MMIO. */
    root[0x10000000u >> 22] = pte(0x10000000u, PTE_RW | PTE_X | PTE_A | PTE_D);
    root[0x80000000u >> 22] = pte(0x80000000u, PTE_RW | PTE_A | PTE_D);
}

void kernel_init(void)
{
    setup_user(0, user_hello);
    setup_user(1, user_worker);
}

void supervisor_main(unsigned hart, unsigned stack_top)
{
    unsigned root = (unsigned)(page_tables + 2048u * hart);
    enable_paging(0x80000000u | (root >> 12));
    enter_user(USER_BASE, USER_TOP, stack_top, hart);
}

static int user_write(unsigned hart, unsigned addr, unsigned len)
{
    unsigned limit;
    unsigned i;
    const unsigned char *src;

    if (len == 0)
        return 0;
    if (len > MAX_WRITE || addr < USER_BASE || addr >= USER_TOP)
        return -1;
    if (addr < USER_BASE + 2u * PAGE_SIZE)
        limit = USER_BASE + 2u * PAGE_SIZE;
    else if (addr >= USER_BASE + STACK_OFFSET)
        limit = USER_TOP;
    else
        return -1;
    if (len > limit - addr)
        return -1;

    /* Read through the private backing pages' S-only alias. SUM stays clear. */
    src = (const unsigned char *)(USER_RAM + hart * USER_STRIDE + (addr - USER_BASE));
    lock_uart(&uart_lock);
    for (i = 0; i < len; ++i) {
        while ((UART_STATUS & 1u) == 0) {}
        UART_DATA = src[i];
    }
    unlock_uart(&uart_lock);
    return (int)len;
}

static void finish(unsigned hart, unsigned status)
{
    unsigned start;

    if (status != 0) {
        TOHOST = 0x200u | (hart << 8) | (status & 0xffu);
        for (;;) {}
    }
    completed[hart] = 1u;
    if (hart == 0) {
        while (completed[1] == 0) {}
        /* TX-ready means space, not empty. Let up to 17 queued bytes drain
           at the board's 115200 baud, even in the 96 MHz testbench. */
        start = MTIME_LOW;
        while (MTIME_LOW - start < 150000u) {}
        TOHOST = 1;
    }
    for (;;) {}
}

void supervisor_trap(unsigned *frame, unsigned cause, unsigned from_supervisor)
{
    unsigned hart = frame[TF_HART];
    unsigned syscall = frame[TF_A7];

    if (from_supervisor != 0 || cause != 8u) {
        TOHOST = 0x400u | (hart << 8) | (cause & 0xffu);
        for (;;) {}
    }
    if (syscall == SYS_WRITE)
        frame[TF_A0] = (unsigned)user_write(hart, frame[TF_A0], frame[TF_A1]);
    else if (syscall == SYS_EXIT)
        finish(hart, frame[TF_A0]);
    else if (syscall == SYS_GETHART)
        frame[TF_A0] = hart;
    else if (syscall == SYS_YIELD)
        frame[TF_A0] = 0;
    else if (syscall == SYS_READCHAR && hart == 0 && (UART_STATUS & 2u) != 0)
        frame[TF_A0] = UART_DATA & 0xffu;
    else
        frame[TF_A0] = (unsigned)-1;
}
