#include "user/syscall.h"

#define PAGE_SIZE 4096u
#define USER_BASE 0x00400000u
/* The SoC testbench SDRAM model aliases addresses above its first MiB. */
#define USER_RAM 0x10040000u
#define USER_STRIDE 0x8000u
#define DATA_OFFSET (2u * PAGE_SIZE)
#define STACK_OFFSET (4u * PAGE_SIZE)
#define USER_TOP (USER_BASE + 6u * PAGE_SIZE)

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
#define MTIME_HIGH REG(0x8000001cu)
#define TOHOST REG(0x80001000u)

/* Trap frame offsets are the integer register numbers, except slot 0. */
#define TF_HART 0
#define TF_A0 10
#define TF_A1 11
#define TF_A7 17
#define TF_PC 32
#define TF_SAVED 33
#define TF_WORDS 36
#define TICK_CAUSE 0x80000005u
#define SLICE_TICKS 20000u
#define MAX_WRITE 256u

extern unsigned page_tables[6144];
extern const unsigned user_hello[3074];
extern const unsigned user_worker[3074];
extern const unsigned user_countdown[3074];
void enable_paging(unsigned satp_value);
void enter_user(unsigned pc, unsigned user_sp, unsigned kernel_sp, unsigned hart);
void restart_worker(unsigned stack_top, unsigned hart);
void resume_worker(unsigned stack_top, unsigned *context);
void clear_tick(void);
void lock_uart(unsigned *lock);
void unlock_uart(unsigned *lock);

static unsigned uart_lock;
/* Only the owning hart writes its slot; 0 means running, 1 means success. */
static volatile unsigned completed[2];
/* The shell publishes JOB_ACTIVE + target hart in one store. Only that
   hart may run the slot and publish completion, allowing reuse on either. */
static volatile unsigned job_state[3];
static unsigned saved[3];
static unsigned contexts[3 * TF_SAVED];
static unsigned current[2];

static int console_image(void)
{
    return user_countdown[0] != 0;
}

static int valid_job(unsigned id)
{
    return id == JOB_WORKER || id == JOB_COUNTDOWN;
}

static void arm_tick(unsigned hart)
{
    unsigned hi;
    unsigned lo;
    unsigned next;
    volatile unsigned *cmp = (volatile unsigned *)(0x80000020u + hart * 0x40u);

    cmp[1] = 0xffffffffu;
    clear_tick();
    do {
        hi = MTIME_HIGH;
        lo = MTIME_LOW;
    } while (hi != MTIME_HIGH);
    next = lo + SLICE_TICKS;
    cmp[0] = next;
    cmp[1] = hi + (next < lo);
}

static unsigned pte(unsigned pa, unsigned flags)
{
    return (pa >> 2) | flags | PTE_V;
}

static void reset_user(unsigned slot, const unsigned *image)
{
    unsigned *ram = (unsigned *)(USER_RAM + slot * USER_STRIDE);
    unsigned i;

    for (i = DATA_OFFSET / 4u; i < (USER_TOP - USER_BASE) / 4u; ++i)
        ram[i] = 0;
    for (i = 0; i < image[1]; ++i)
        ram[DATA_OFFSET / 4u + i] = image[2u + image[0] + i];
}

static void setup_user(unsigned slot, const unsigned *image)
{
    unsigned *root = page_tables + 2048u * slot;
    unsigned *leaf = root + 1024u;
    unsigned pa = USER_RAM + slot * USER_STRIDE;
    unsigned *ram = (unsigned *)pa;
    unsigned text_words = image[0];
    unsigned i;

    for (i = 0; i < DATA_OFFSET / 4u; ++i)
        ram[i] = 0;
    for (i = 0; i < text_words; ++i)
        ram[i] = image[2u + i];
    reset_user(slot, image);

    root[USER_BASE >> 22] = pte((unsigned)leaf, 0);
    leaf[0] = pte(pa, PTE_R | PTE_X | PTE_U | PTE_A);
    leaf[1] = pte(pa + PAGE_SIZE, PTE_R | PTE_X | PTE_U | PTE_A);
    leaf[2] = pte(pa + DATA_OFFSET, PTE_RW | PTE_U | PTE_A | PTE_D);
    /* The next page is an unmapped guard between data and stack. */
    leaf[4] = pte(pa + STACK_OFFSET, PTE_RW | PTE_U | PTE_A | PTE_D);
    leaf[5] = pte(pa + STACK_OFFSET + PAGE_SIZE, PTE_RW | PTE_U | PTE_A | PTE_D);

    /* Supervisor-only identity mappings: RAM (kernel, aliases, stacks), MMIO. */
    root[0x10000000u >> 22] = pte(0x10000000u, PTE_RW | PTE_X | PTE_A | PTE_D);
    root[0x80000000u >> 22] = pte(0x80000000u, PTE_RW | PTE_A | PTE_D);
}

void kernel_init(void)
{
    setup_user(0, user_hello);
    setup_user(1, user_worker);
    if (console_image())
        setup_user(2, user_countdown);
}

static void switch_space(unsigned slot)
{
    unsigned root = (unsigned)(page_tables + 2048u * slot);
    enable_paging(0x80000000u | (root >> 12));
}

static int runnable(unsigned slot, unsigned hart)
{
    if (slot == 0)
        return hart == 0;
    return job_state[slot] == JOB_ACTIVE + hart;
}

static unsigned next_slot(unsigned hart)
{
    unsigned slot = current[hart];
    unsigned i;
    for (i = 0; i < 3; ++i) {
        ++slot;
        if (slot == 3)
            slot = 0;
        if (runnable(slot, hart))
            return slot;
    }
    return 3;
}

void worker_loop(unsigned stack_top, unsigned hart)
{
    unsigned id;
    unsigned i;
    unsigned *context;
    const unsigned *image;

    do {
        id = next_slot(hart);
    } while (id == 3);
    current[hart] = id;
    context = contexts + id * TF_SAVED;
    if (!saved[id]) {
        if (id == JOB_WORKER)
            image = user_worker;
        else
            image = user_countdown;
        reset_user(id, image);
        for (i = 0; i < TF_SAVED; ++i)
            context[i] = 0;
        context[TF_HART] = hart;
        context[2] = USER_TOP;
        context[TF_PC] = USER_BASE;
    }
    switch_space(id);
    arm_tick(hart);
    resume_worker(stack_top, context);
}

void supervisor_main(unsigned hart, unsigned stack_top)
{
    switch_space(hart);
    if (console_image()) {
        if (hart == 1)
            worker_loop(stack_top, hart);
        arm_tick(hart);
    }
    enter_user(USER_BASE, USER_TOP, stack_top, hart);
}

static int user_write(unsigned hart, unsigned addr, unsigned len)
{
    unsigned limit;
    unsigned i;
    unsigned slot = hart;
    const unsigned char *src;

    if (len == 0)
        return 0;
    if (len > MAX_WRITE || addr < USER_BASE || addr >= USER_TOP)
        return -1;
    if (addr < USER_BASE + DATA_OFFSET + PAGE_SIZE)
        limit = USER_BASE + DATA_OFFSET + PAGE_SIZE;
    else if (addr >= USER_BASE + STACK_OFFSET)
        limit = USER_TOP;
    else
        return -1;
    if (len > limit - addr)
        return -1;

    /* Read through the private backing pages' S-only alias. SUM stays clear. */
    if (console_image())
        slot = current[hart];
    src = (const unsigned char *)(USER_RAM + slot * USER_STRIDE + (addr - USER_BASE));
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
        if (console_image()) {
            while (runnable(JOB_WORKER, 1) || runnable(JOB_COUNTDOWN, 1)) {}
        } else {
            while (completed[1] == 0) {}
        }
        /* TX-ready means space, not empty. Let up to 17 queued bytes drain
           at the board's 115200 baud, even in the 96 MHz testbench. */
        start = MTIME_LOW;
        while (MTIME_LOW - start < 150000u) {}
        TOHOST = 1;
    }
    for (;;) {}
}

static int submit_job(unsigned id, unsigned hart)
{
    if (!valid_job(id) || hart > 1)
        return -1;
    if (runnable(id, 0) || runnable(id, 1))
        return JOB_BUSY;
    job_state[id] = JOB_ACTIVE + hart;
    return 0;
}

static void reschedule(unsigned *frame)
{
    unsigned i;
    unsigned hart = frame[TF_HART];
    unsigned slot = current[hart];
    unsigned *context;

    if (next_slot(hart) != slot) {
        context = contexts + slot * TF_SAVED;
        for (i = 0; i < TF_SAVED; ++i)
            context[i] = frame[i];
        saved[slot] = 1;
        restart_worker((unsigned)(frame + TF_WORDS), hart);
    }
    arm_tick(hart);
}

void supervisor_trap(unsigned *frame, unsigned cause, unsigned from_supervisor)
{
    unsigned hart = frame[TF_HART];
    unsigned syscall = frame[TF_A7];

    if (cause == 8u)
        frame[TF_PC] += 4;
    if (from_supervisor == 0 && console_image()) {
        unsigned slot = current[hart];
        if (cause == TICK_CAUSE) {
            clear_tick();
            reschedule(frame);
            return;
        }
        if (slot != 0 && (cause != 8u || syscall == SYS_EXIT)) {
            saved[slot] = 0;
            if (cause != 8u)
                job_state[slot] = JOB_FAULT | (cause & 0xffu);
            else
                job_state[slot] = JOB_DONE | (frame[TF_A0] & 0xffu);
            restart_worker((unsigned)(frame + TF_WORDS), hart);
        }
    }
    if (from_supervisor != 0 || cause != 8u) {
        TOHOST = 0x400u | (hart << 8) | (cause & 0xffu);
        for (;;) {}
    }
    if (syscall == SYS_WRITE)
        frame[TF_A0] = (unsigned)user_write(hart, frame[TF_A0], frame[TF_A1]);
    else if (syscall == SYS_EXIT) {
        /* Keep the shell schedulable while a local job drains. Retry the
           ecall after the next slice without losing its exit status. */
        if (console_image() && next_slot(0) != 0) {
            frame[TF_PC] -= 4;
            reschedule(frame);
            return;
        }
        finish(hart, frame[TF_A0]);
    } else if (syscall == SYS_GETHART)
        frame[TF_A0] = hart;
    else if (syscall == SYS_YIELD) {
        frame[TF_A0] = 0;
        if (console_image())
            reschedule(frame);
    } else if (syscall == SYS_READCHAR && hart == 0 && current[0] == 0 && (UART_STATUS & 2u) != 0)
        frame[TF_A0] = UART_DATA & 0xffu;
    else if (hart == 0 && current[0] == 0 && syscall == SYS_RUN_JOB && console_image())
        frame[TF_A0] = (unsigned)submit_job(frame[TF_A0], frame[TF_A1]);
    else if (hart == 0 && current[0] == 0 && syscall == SYS_JOB_STATUS && console_image() && valid_job(frame[TF_A0]))
        frame[TF_A0] = job_state[frame[TF_A0]];
    else
        frame[TF_A0] = (unsigned)-1;
}
