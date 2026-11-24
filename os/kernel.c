#include "user/syscall.h"
#include "kernel_fs.h"

#define PAGE_SIZE 4096u
/* The SoC testbench SDRAM model aliases addresses above its first MiB. */
#define USER_RAM 0x10040000u
#define USER_STRIDE USER_SLOT_BYTES
#define DATA_OFFSET (USER_DATA_BASE - USER_BASE)
#define STACK_OFFSET (USER_STACK_BASE - USER_BASE)

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
#define TF_A2 12
#define TF_A3 13
#define TF_A7 17
#define TF_PC 32
#define TF_SAVED 33
#define TF_WORDS 36
#define TICK_CAUSE 0x80000005u
#define SLICE_TICKS 20000u
#define MAX_PROCS 3
#define MAX_FDS 8
#define MAX_CONSOLE_WRITE 256u
#define MAX_FILE_WRITE 4096u

#define FD_FREE 0
#define FD_CONSOLE 1
#define FD_FILE 2

#define EXEC_MAGIC 0x4f434f52u

extern unsigned page_tables[6144];
extern const unsigned rootfs_count;
extern const unsigned rootfs_entries[256];
extern const char rootfs_names[8192];
extern const unsigned rootfs_data[49152];

void enable_paging(unsigned satp_value);
void enter_user(unsigned pc, unsigned user_sp, unsigned kernel_sp, unsigned hart);
void restart_worker(unsigned stack_top, unsigned hart);
void resume_worker(unsigned stack_top, unsigned *context);
void clear_tick(void);
void spin_lock(unsigned *lock);
void spin_unlock(unsigned *lock);
void flush_icache(void);

/* Only the owning hart writes its slot; 0 means running, 1 means success. */
static volatile unsigned completed[2];
/* The shell publishes JOB_ACTIVE + target hart in one store. Only that
   hart may run the slot and publish completion, allowing reuse on either. */
static volatile unsigned job_state[MAX_PROCS];
static unsigned saved[MAX_PROCS];
static unsigned contexts[MAX_PROCS * TF_SAVED];
static unsigned current[2];

/*
 * The UART is one shared console: both harts can reach it and the host can
 * send a byte at any time. uart_lock serializes every register access, and
 * only the owning process may write. Background jobs that want their output
 * must redirect it to a file; this keeps a shell prompt and a foreground
 * command's output free of unrelated lines.
 */
static unsigned uart_lock;
static unsigned console_owner = 1;

static unsigned fd_kind[MAX_PROCS][MAX_FDS];
static unsigned fd_obj[MAX_PROCS][MAX_FDS];
static unsigned fd_off[MAX_PROCS][MAX_FDS];
static unsigned fd_flags[MAX_PROCS][MAX_FDS];
static unsigned proc_cwd[MAX_PROCS];
static unsigned proc_ino[MAX_PROCS];
static unsigned sleep_start[MAX_PROCS];
static unsigned sleep_ticks[MAX_PROCS];
static unsigned proc_brk[MAX_PROCS];

static int console_image(void)
{
    return fs_lookup_path(0, "/bin/shell") >= 0;
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

static void put_byte(char c)
{
    while ((UART_STATUS & 1u) == 0) {}
    UART_DATA = (unsigned char)c;
}

static void console_write(unsigned pid, const char *src, unsigned len)
{
    unsigned i;

    if (console_image() && pid != console_owner)
        return;
    spin_lock(&uart_lock);
    for (i = 0; i < len; ++i)
        put_byte(src[i]);
    spin_unlock(&uart_lock);
}

static int console_readchar(void)
{
    int value = -1;

    spin_lock(&uart_lock);
    if ((UART_STATUS & 2u) != 0)
        value = (int)(UART_DATA & 0xffu);
    spin_unlock(&uart_lock);
    return value;
}

/* Load an mkfs executable into a slot's backing RAM: zero the whole
   64 KiB slab, then copy text and data words after the header. */
static int load_program(unsigned slot, int ino)
{
    unsigned header[4];
    unsigned text_words;
    unsigned data_words;
    unsigned *ram = (unsigned *)(USER_RAM + slot * USER_STRIDE);
    unsigned i;

    if (ino < 0 || fs_type(ino) != FS_TYPE_FILE)
        return -1;
    if (fs_read(ino, 0, header, 16) != 16 || header[0] != EXEC_MAGIC)
        return -1;
    text_words = header[1];
    data_words = header[2];
    if (text_words > USER_TEXT_BYTES / 4u || data_words > USER_DATA_BYTES / 4u)
        return -1;
    for (i = 0; i < USER_SLOT_BYTES / 4u; ++i)
        ram[i] = 0;
    if (text_words != 0 &&
        fs_read(ino, 16, ram, text_words * 4u) != (int)(text_words * 4u))
        return -1;
    if (data_words != 0 &&
        fs_read(ino, 16 + text_words * 4u, (char *)ram + DATA_OFFSET,
                data_words * 4u) != (int)(data_words * 4u))
        return -1;
    flush_icache();
    return 0;
}

static void setup_space(unsigned slot)
{
    unsigned *root = page_tables + 2048u * slot;
    unsigned *leaf = root + 1024u;
    unsigned pa = USER_RAM + slot * USER_STRIDE;
    unsigned i;

    for (i = 0; i < 1024u; ++i)
        leaf[i] = 0;
    /* Leaf slots mirror the virtual layout: text, data, heap, one
       unmapped guard page, then the stack. */
    for (i = 0; i < USER_TEXT_PAGES; ++i)
        leaf[i] = pte(pa + i * PAGE_SIZE, PTE_R | PTE_X | PTE_U | PTE_A);
    for (i = 0; i < USER_DATA_PAGES; ++i)
        leaf[USER_TEXT_PAGES + i] = pte(pa + (USER_TEXT_PAGES + i) * PAGE_SIZE,
                                       PTE_RW | PTE_U | PTE_A | PTE_D);
    for (i = 0; i < USER_HEAP_PAGES; ++i)
        leaf[USER_TEXT_PAGES + USER_DATA_PAGES + i] =
            pte(pa + (USER_TEXT_PAGES + USER_DATA_PAGES + i) * PAGE_SIZE,
                PTE_RW | PTE_U | PTE_A | PTE_D);
    for (i = 0; i < USER_STACK_PAGES; ++i)
        leaf[(USER_GUARD_BASE - USER_BASE) / PAGE_SIZE + 1u + i] =
            pte(pa + ((USER_GUARD_BASE - USER_BASE) / PAGE_SIZE + 1u + i) * PAGE_SIZE,
                PTE_RW | PTE_U | PTE_A | PTE_D);

    root[USER_BASE >> 22] = pte((unsigned)leaf, 0);
    /* Supervisor-only identity mappings: RAM (kernel, aliases, stacks), MMIO. */
    root[0x10000000u >> 22] = pte(0x10000000u, PTE_RW | PTE_X | PTE_A | PTE_D);
    root[0x80000000u >> 22] = pte(0x80000000u, PTE_RW | PTE_A | PTE_D);
}

static int setup_user(unsigned slot, const char *first, const char *fallback)
{
    int ino = fs_lookup_path(0, first);
    if (ino < 0)
        ino = fs_lookup_path(0, fallback);
    if (ino < 0)
        return -1;
    setup_space(slot);
    if (load_program(slot, ino) != 0)
        return -1;
    proc_ino[slot] = (unsigned)ino;
    return 0;
}

static void fd_reset(unsigned slot)
{
    unsigned fd;

    for (fd = 0; fd < MAX_FDS; ++fd) {
        fd_kind[slot][fd] = FD_FREE;
        fd_obj[slot][fd] = 0;
        fd_off[slot][fd] = 0;
        fd_flags[slot][fd] = 0;
    }
    fd_kind[slot][0] = FD_CONSOLE;
    fd_flags[slot][0] = FS_O_RDONLY;
    fd_kind[slot][1] = FD_CONSOLE;
    fd_flags[slot][1] = FS_O_WRONLY;
    fd_kind[slot][2] = FD_CONSOLE;
    fd_flags[slot][2] = FS_O_WRONLY;
    proc_cwd[slot] = 0;
    proc_brk[slot] = USER_HEAP_BASE;
}

void kernel_init(void)
{
    unsigned slot;

    put_byte('A');
    {
        int mounted = fs_init(&rootfs_count, rootfs_entries, rootfs_names, rootfs_data);
        if (mounted != 0) {
            TOHOST = 0xbad00100u | (unsigned)mounted;
            for (;;) {}
        }
    }
    put_byte('B');
    for (slot = 0; slot < MAX_PROCS; ++slot)
        fd_reset(slot);
    put_byte('C');
    /* The manifest decides the image: a shell means console, a probe
       means the fault test, otherwise the fixed hello/worker pair. */
    if (setup_user(0, "/bin/shell", "/bin/hello") != 0 ||
        setup_user(1, "/bin/probe", "/bin/worker") != 0) {
        TOHOST = 0xbad00200u;
        for (;;) {}
    }
    put_byte('D');
    if (fs_lookup_path(0, "/bin/countdown") >= 0 &&
        setup_user(2, "/bin/countdown", "/bin/countdown") != 0) {
        TOHOST = 0xbad00201u;
        for (;;) {}
    }
    put_byte('E');
}

static void switch_space(unsigned slot)
{
    unsigned root = (unsigned)(page_tables + 2048u * slot);
    enable_paging(0x80000000u | (root >> 12));
}

static int sleeping(unsigned slot)
{
    /* Wrap-safe: the low 32 bits of mtime lap every 45 seconds at the
       simulation clock, so compare elapsed time against the duration. */
    return sleep_ticks[slot] != 0 &&
        (MTIME_LOW - sleep_start[slot]) < sleep_ticks[slot];
}

static int runnable(unsigned slot, unsigned hart)
{
    if (slot == 0)
        return hart == 0 && !sleeping(0);
    return job_state[slot] == JOB_ACTIVE + hart && !sleeping(slot);
}

static unsigned next_slot(unsigned hart)
{
    unsigned slot = current[hart];
    unsigned i;
    for (i = 1; i <= MAX_PROCS; ++i) {
        slot = (slot + 1u) % MAX_PROCS;
        if (runnable(slot, hart))
            return slot;
    }
    return MAX_PROCS;
}

void worker_loop(unsigned stack_top, unsigned hart)
{
    unsigned id;
    unsigned i;
    unsigned *context;

    do {
        id = next_slot(hart);
    } while (id == MAX_PROCS);
    current[hart] = id;
    context = contexts + id * TF_SAVED;
    sleep_start[id] = 0;
    sleep_ticks[id] = 0;
    if (!saved[id]) {
        if (load_program(id, (int)proc_ino[id]) != 0) {
            job_state[id] = JOB_FAULT;
            saved[id] = 0;
            restart_worker(stack_top, hart);
        }
        fd_reset(id);
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

static unsigned current_slot(unsigned hart)
{
    return console_image() ? current[hart] : hart;
}

static int user_buffer(unsigned slot, unsigned addr, unsigned len, unsigned write)
{
    unsigned end = addr + len;
    unsigned text_end = USER_BASE + USER_TEXT_BYTES;
    unsigned data_end = USER_DATA_BASE + USER_DATA_BYTES;
    unsigned heap_end = USER_HEAP_BASE + USER_HEAP_BYTES;

    (void)slot;
    if (len == 0)
        return 1;
    if (end < addr)
        return 0;
    if (addr >= USER_BASE && end <= text_end)
        return !write;
    if (addr >= USER_DATA_BASE && end <= data_end)
        return 1;
    if (addr >= USER_HEAP_BASE && end <= heap_end)
        return 1;
    if (addr >= USER_STACK_BASE && end <= USER_TOP)
        return 1;
    return 0;
}

static char *user_alias(unsigned slot, unsigned addr)
{
    return (char *)(USER_RAM + slot * USER_STRIDE + (addr - USER_BASE));
}

static int user_str(unsigned slot, unsigned addr, char *buffer, unsigned cap)
{
    unsigned i;

    if (cap == 0)
        return -1;
    for (i = 0; i + 1 < cap; ++i) {
        if (!user_buffer(slot, addr + i, 1, 0))
            return -1;
        buffer[i] = *user_alias(slot, addr + i);
        if (buffer[i] == 0)
            return (int)i;
    }
    buffer[cap - 1] = 0;
    return -1;
}

static int user_put_words(unsigned slot, unsigned addr, const unsigned *words, unsigned n)
{
    unsigned i;
    unsigned *dst;

    if (!user_buffer(slot, addr, n * 4u, 1))
        return -1;
    dst = (unsigned *)user_alias(slot, addr);
    for (i = 0; i < n; ++i)
        dst[i] = words[i];
    return 0;
}

static int user_put_string(unsigned slot, unsigned addr, unsigned cap, const char *s)
{
    unsigned n = 0;
    unsigned i;

    while (s[n] != 0)
        ++n;
    if (n + 1u > cap || !user_buffer(slot, addr, n + 1u, 1))
        return -1;
    for (i = 0; i <= n; ++i)
        *user_alias(slot, addr + i) = s[i];
    return 0;
}

static int fd_alloc(unsigned slot)
{
    unsigned fd;
    for (fd = 3; fd < MAX_FDS; ++fd) {
        if (fd_kind[slot][fd] == FD_FREE)
            return (int)fd;
    }
    return -1;
}

static int fd_readable(unsigned flags)
{
    return (flags & 3u) != FS_O_WRONLY;
}

static int fd_writable(unsigned flags)
{
    return (flags & 3u) != FS_O_RDONLY;
}

static int sys_write(unsigned hart, unsigned fd, unsigned addr, unsigned len)
{
    unsigned slot = current_slot(hart);
    const char *src;
    int n;

    if (fd >= MAX_FDS || fd_kind[slot][fd] == FD_FREE || !fd_writable(fd_flags[slot][fd]))
        return -1;
    if (len == 0)
        return 0;
    if (fd_kind[slot][fd] == FD_CONSOLE) {
        if (len > MAX_CONSOLE_WRITE || !user_buffer(slot, addr, len, 0))
            return -1;
        src = user_alias(slot, addr);
        console_write(slot + 1, src, len);
        return (int)len;
    }
    if (len > MAX_FILE_WRITE || !user_buffer(slot, addr, len, 0))
        return -1;
    src = user_alias(slot, addr);
    if ((fd_flags[slot][fd] & FS_O_APPEND) != 0)
        fd_off[slot][fd] = (unsigned)fs_size((int)fd_obj[slot][fd]);
    n = fs_write((int)fd_obj[slot][fd], fd_off[slot][fd], src, len);
    if (n > 0)
        fd_off[slot][fd] += (unsigned)n;
    return n;
}

static int sys_read(unsigned hart, unsigned fd, unsigned addr, unsigned len)
{
    unsigned slot = current_slot(hart);
    int n;

    if (fd >= MAX_FDS || fd_kind[slot][fd] == FD_FREE || !fd_readable(fd_flags[slot][fd]))
        return -1;
    if (len == 0)
        return 0;
    if (!user_buffer(slot, addr, len, 1))
        return -1;
    if (fd_kind[slot][fd] == FD_CONSOLE) {
        unsigned i;
        char *dst = user_alias(slot, addr);
        if (fd != 0 || (console_image() && slot + 1u != console_owner))
            return -1;
        for (i = 0; i < len; ++i) {
            n = console_readchar();
            if (n < 0)
                break;
            dst[i] = (char)n;
        }
        return i == 0 ? SYS_AGAIN : (int)i;
    }
    n = fs_read((int)fd_obj[slot][fd], fd_off[slot][fd], user_alias(slot, addr), len);
    if (n > 0)
        fd_off[slot][fd] += (unsigned)n;
    return n;
}

static int sys_open(unsigned hart, unsigned path_va, unsigned flags)
{
    unsigned slot = current_slot(hart);
    char path[FS_MAX_PATH];
    int ino;
    int fd;

    if ((flags & ~0x1ffu) != 0)
        return -1;
    if (user_str(slot, path_va, path, FS_MAX_PATH) < 0)
        return -1;
    ino = fs_open_path((int)proc_cwd[slot], path, flags);
    if (ino < 0)
        return -1;
    fd = fd_alloc(slot);
    if (fd < 0)
        return -1;
    fd_kind[slot][fd] = FD_FILE;
    fd_obj[slot][fd] = (unsigned)ino;
    fd_flags[slot][fd] = flags;
    fd_off[slot][fd] = (flags & FS_O_APPEND) != 0 ? (unsigned)fs_size(ino) : 0;
    return fd;
}

static int sys_close(unsigned hart, unsigned fd)
{
    unsigned slot = current_slot(hart);

    if (fd >= MAX_FDS || fd_kind[slot][fd] == FD_FREE)
        return -1;
    fd_kind[slot][fd] = FD_FREE;
    return 0;
}

static int sys_seek(unsigned hart, unsigned fd, int offset, unsigned whence)
{
    unsigned slot = current_slot(hart);
    int base;
    int next;

    if (fd >= MAX_FDS || fd_kind[slot][fd] != FD_FILE)
        return -1;
    if (whence == SEEK_SET)
        base = 0;
    else if (whence == SEEK_CUR)
        base = (int)fd_off[slot][fd];
    else if (whence == SEEK_END)
        base = fs_size((int)fd_obj[slot][fd]);
    else
        return -1;
    next = base + offset;
    if (next < 0)
        return -1;
    fd_off[slot][fd] = (unsigned)next;
    return next;
}

static int sys_sbrk(unsigned hart, int increment)
{
    unsigned slot = current_slot(hart);
    unsigned old = proc_brk[slot];
    unsigned next = old + (unsigned)increment;

    if (increment > 0) {
        if (increment > (int)(USER_HEAP_BASE + USER_HEAP_BYTES - old))
            return -1;
    } else if (increment < 0) {
        if ((unsigned)(-increment) > old - USER_HEAP_BASE)
            return -1;
    }
    if (next < USER_HEAP_BASE || next > USER_HEAP_BASE + USER_HEAP_BYTES)
        return -1;
    proc_brk[slot] = next;
    return (int)old;
}

static int sys_stat_path(unsigned hart, unsigned path_va, unsigned info_va)
{
    unsigned slot = current_slot(hart);
    char path[FS_MAX_PATH];
    unsigned info[4];
    int ino;

    if (user_str(slot, path_va, path, FS_MAX_PATH) < 0)
        return -1;
    ino = fs_lookup_path((int)proc_cwd[slot], path);
    if (ino < 0)
        return -1;
    if (fs_stat(ino, info) != 0)
        return -1;
    return user_put_words(slot, info_va, info, 4);
}

static int sys_fstat(unsigned hart, unsigned fd, unsigned info_va)
{
    unsigned slot = current_slot(hart);
    unsigned info[4];

    if (fd >= MAX_FDS || fd_kind[slot][fd] == FD_FREE)
        return -1;
    if (fd_kind[slot][fd] == FD_CONSOLE) {
        info[0] = FS_DEV;
        info[1] = 0;
        info[2] = 0;
        info[3] = 0;
    } else if (fs_stat((int)fd_obj[slot][fd], info) != 0)
        return -1;
    return user_put_words(slot, info_va, info, 4);
}

static int sys_readdir(unsigned hart, unsigned fd, unsigned index,
                       unsigned name_va, unsigned cap)
{
    unsigned slot = current_slot(hart);
    char name[FS_MAX_NAME];
    int type;

    if (fd >= MAX_FDS || fd_kind[slot][fd] != FD_FILE || cap == 0)
        return -1;
    if (fs_type((int)fd_obj[slot][fd]) != FS_TYPE_DIR)
        return -1;
    type = fs_readdir((int)fd_obj[slot][fd], index, name, FS_MAX_NAME);
    if (type <= 0)
        return type < 0 ? -1 : 0;
    if (user_put_string(slot, name_va, cap, name) < 0)
        return -1;
    return type;
}

static int sys_path(unsigned hart, unsigned path_va, unsigned op)
{
    unsigned slot = current_slot(hart);
    char path[FS_MAX_PATH];
    int result;

    if (user_str(slot, path_va, path, FS_MAX_PATH) < 0)
        return -1;
    if (op == SYS_UNLINK)
        result = fs_unlink_path((int)proc_cwd[slot], path);
    else if (op == SYS_MKDIR)
        result = fs_create_path((int)proc_cwd[slot], path, FS_TYPE_DIR, 0, 0);
    else if (op == SYS_RMDIR)
        result = fs_rmdir_path((int)proc_cwd[slot], path);
    else if (op == SYS_CHDIR) {
        result = fs_lookup_path((int)proc_cwd[slot], path);
        if (result >= 0 && fs_type(result) != FS_TYPE_DIR)
            result = FS_ENOTDIR;
        if (result >= 0)
            proc_cwd[slot] = (unsigned)result;
    } else
        result = FS_EINVAL;
    return result < 0 ? -1 : 0;
}

static int sys_rename(unsigned hart, unsigned from_va, unsigned to_va)
{
    unsigned slot = current_slot(hart);
    char from[FS_MAX_PATH];
    char to[FS_MAX_PATH];
    int result;

    if (user_str(slot, from_va, from, FS_MAX_PATH) < 0)
        return -1;
    if (user_str(slot, to_va, to, FS_MAX_PATH) < 0)
        return -1;
    result = fs_rename_path((int)proc_cwd[slot], from, to);
    return result < 0 ? -1 : 0;
}

static int sys_getcwd(unsigned hart, unsigned buf_va, unsigned cap)
{
    unsigned slot = current_slot(hart);
    char path[FS_MAX_PATH];

    if (fs_cwd_path((int)proc_cwd[slot], path, FS_MAX_PATH) != 0)
        return -1;
    return user_put_string(slot, buf_va, cap, path);
}

static int sys_fsinfo(unsigned hart, unsigned info_va)
{
    unsigned slot = current_slot(hart);
    unsigned info[4];

    info[0] = fs_total_blocks();
    info[1] = fs_free_blocks();
    info[2] = fs_total_inodes();
    info[3] = fs_free_inodes();
    return user_put_words(slot, info_va, info, 4);
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
    int ino;

    if (!valid_job(id) || hart > 1)
        return -1;
    if (runnable(id, 0) || runnable(id, 1))
        return JOB_BUSY;
    ino = fs_lookup_path(0, id == JOB_WORKER ? "/bin/worker" : "/bin/countdown");
    if (ino < 0)
        return -1;
    proc_ino[id] = (unsigned)ino;
    saved[id] = 0;
    job_state[id] = JOB_ACTIVE + hart;
    return 0;
}

static int sys_kill(unsigned hart, unsigned pid)
{
    unsigned slot;

    (void)hart;
    if (pid < 2u || pid > MAX_PROCS)
        return -1;
    slot = pid - 1u;
    saved[slot] = 0;
    sleep_start[slot] = 0;
    sleep_ticks[slot] = 0;
    job_state[slot] = JOB_IDLE;
    if (console_owner == slot + 1u)
        console_owner = 1;
    return 0;
}

static int sys_fg(unsigned hart, unsigned slot)
{
    (void)hart;
    if (slot < 1u || slot >= MAX_PROCS)
        return -1;
    if (job_state[slot] != JOB_ACTIVE && job_state[slot] != JOB_ACTIVE + 1u)
        return -1;
    console_owner = slot + 1u;
    return 0;
}

static int spawn_job(unsigned hart, const char *path)
{
    int ino = fs_lookup_path(0, path);
    unsigned slot;

    if (ino < 0 || fs_type(ino) != FS_TYPE_FILE)
        return -1;
    for (slot = 1; slot < MAX_PROCS; ++slot) {
        if (runnable(slot, 0) || runnable(slot, 1))
            continue;
        proc_ino[slot] = (unsigned)ino;
        saved[slot] = 0;
        job_state[slot] = JOB_ACTIVE + hart;
        return (int)slot;
    }
    return JOB_BUSY;
}

/* Replace the calling program with the executable at path. Files and the
   working directory survive; registers and the stack do not. */
static void exec_self(unsigned hart, unsigned slot, const char *path,
                       unsigned *frame)
{
    int ino = fs_lookup_path(0, path);
    unsigned *context;
    unsigned i;

    if (ino < 0 || fs_type(ino) != FS_TYPE_FILE || load_program(slot, ino) != 0) {
        frame[TF_A0] = (unsigned)-1;
        return;
    }
    proc_ino[slot] = (unsigned)ino;
    proc_brk[slot] = USER_HEAP_BASE;
    context = contexts + slot * TF_SAVED;
    for (i = 0; i < TF_SAVED; ++i)
        context[i] = 0;
    context[TF_HART] = hart;
    context[2] = USER_TOP;
    context[TF_PC] = USER_BASE;
    switch_space(slot);
    arm_tick(hart);
    resume_worker((unsigned)(frame + TF_WORDS), context);
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
    unsigned slot = current_slot(hart);

    if (cause == 8u)
        frame[TF_PC] += 4;
    if (from_supervisor == 0 && console_image()) {
        if (cause == TICK_CAUSE) {
            clear_tick();
            reschedule(frame);
            return;
        }
        if (slot != 0 && (cause != 8u || syscall == SYS_EXIT)) {
            saved[slot] = 0;
            if (console_owner == slot + 1u)
                console_owner = 1;
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
        frame[TF_A0] = (unsigned)sys_write(hart, frame[TF_A0], frame[TF_A1], frame[TF_A2]);
    else if (syscall == SYS_READ)
        frame[TF_A0] = (unsigned)sys_read(hart, frame[TF_A0], frame[TF_A1], frame[TF_A2]);
    else if (syscall == SYS_OPEN)
        frame[TF_A0] = (unsigned)sys_open(hart, frame[TF_A0], frame[TF_A1]);
    else if (syscall == SYS_CLOSE)
        frame[TF_A0] = (unsigned)sys_close(hart, frame[TF_A0]);
    else if (syscall == SYS_SEEK)
        frame[TF_A0] = (unsigned)sys_seek(hart, frame[TF_A0], (int)frame[TF_A1], frame[TF_A2]);
    else if (syscall == SYS_STAT)
        frame[TF_A0] = (unsigned)sys_stat_path(hart, frame[TF_A0], frame[TF_A1]);
    else if (syscall == SYS_FSTAT)
        frame[TF_A0] = (unsigned)sys_fstat(hart, frame[TF_A0], frame[TF_A1]);
    else if (syscall == SYS_UNLINK || syscall == SYS_MKDIR ||
             syscall == SYS_RMDIR || syscall == SYS_CHDIR)
        frame[TF_A0] = (unsigned)sys_path(hart, frame[TF_A0], syscall);
    else if (syscall == SYS_RENAME)
        frame[TF_A0] = (unsigned)sys_rename(hart, frame[TF_A0], frame[TF_A1]);
    else if (syscall == SYS_READDIR)
        frame[TF_A0] = (unsigned)sys_readdir(hart, frame[TF_A0], frame[TF_A1],
                                             frame[TF_A2], frame[TF_A3]);
    else if (syscall == SYS_FSINFO)
        frame[TF_A0] = (unsigned)sys_fsinfo(hart, frame[TF_A0]);
    else if (syscall == SYS_GETCWD)
        frame[TF_A0] = (unsigned)sys_getcwd(hart, frame[TF_A0], frame[TF_A1]);
    else if (syscall == SYS_GETPID)
        frame[TF_A0] = slot + 1u;
    else if (syscall == SYS_GETPPID)
        frame[TF_A0] = 0;
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
    } else if (syscall == SYS_READCHAR && hart == 0 && current[0] == 0)
        frame[TF_A0] = (unsigned)console_readchar();
    else if (hart == 0 && current[0] == 0 && syscall == SYS_RUN_JOB && console_image())
        frame[TF_A0] = (unsigned)submit_job(frame[TF_A0], frame[TF_A1]);
    else if (hart == 0 && current[0] == 0 && syscall == SYS_SPAWN && console_image()) {
        char path[FS_MAX_PATH];
        if (user_str(slot, frame[TF_A0], path, FS_MAX_PATH) < 0)
            frame[TF_A0] = (unsigned)-1;
        else if (frame[TF_A1] > 1)
            frame[TF_A0] = (unsigned)-1;
        else
            frame[TF_A0] = (unsigned)spawn_job(frame[TF_A1], path);
    } else if (syscall == SYS_EXEC && console_image()) {
        char path[FS_MAX_PATH];
        if (user_str(slot, frame[TF_A0], path, FS_MAX_PATH) < 0)
            frame[TF_A0] = (unsigned)-1;
        else
            exec_self(hart, slot, path, frame);
    } else if (syscall == SYS_SLEEP) {
        frame[TF_A0] = 0;
        if (frame[TF_A1] != 0 && console_image()) {
            sleep_start[slot] = MTIME_LOW;
            sleep_ticks[slot] = frame[TF_A1];
            reschedule(frame);
        }
    } else if (syscall == SYS_UPTIME)
        frame[TF_A0] = MTIME_LOW;
    else if (syscall == SYS_SBRK)
        frame[TF_A0] = (unsigned)sys_sbrk(hart, (int)frame[TF_A0]);
    else if (syscall == SYS_FG && console_image() && hart == 0 && current[0] == 0)
        frame[TF_A0] = (unsigned)sys_fg(hart, frame[TF_A0]);
    else if (syscall == SYS_KILL && console_image() && hart == 0 && current[0] == 0)
        frame[TF_A0] = (unsigned)sys_kill(hart, frame[TF_A0]);
    else if (hart == 0 && current[0] == 0 && syscall == SYS_JOB_STATUS && console_image() && valid_job(frame[TF_A0]))
        frame[TF_A0] = job_state[frame[TF_A0]];
    else
        frame[TF_A0] = (unsigned)-1;
}
