#include "lib.h"

/*
 * A tiny freestanding runtime. roco_cc supports plain C without structs,
 * varargs, or switch statements, so everything here is deliberately
 * simple and explicit.
 */

unsigned strlen(const char *s)
{
    unsigned n = 0;
    while (s[n] != 0)
        ++n;
    return n;
}

int strcmp(const char *a, const char *b)
{
    while (*a == *b) {
        if (*a == 0)
            return 0;
        ++a;
        ++b;
    }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char *a, const char *b, unsigned n)
{
    while (n != 0 && *a == *b) {
        if (*a == 0)
            return 0;
        ++a;
        ++b;
        --n;
    }
    if (n == 0)
        return 0;
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

char *strcpy(char *dst, const char *src)
{
    char *start = dst;
    while (*src != 0)
        *dst++ = *src++;
    *dst = 0;
    return start;
}

char *strncpy(char *dst, const char *src, unsigned n)
{
    char *start = dst;
    while (n != 0 && *src != 0) {
        *dst++ = *src++;
        --n;
    }
    while (n != 0) {
        *dst++ = 0;
        --n;
    }
    return start;
}

char *strcat(char *dst, const char *src)
{
    char *end = dst + strlen(dst);
    strcpy(end, src);
    return dst;
}

char *strchr(const char *s, int c)
{
    while (*s != 0) {
        if ((unsigned char)*s == (unsigned char)c)
            return (char *)s;
        ++s;
    }
    if (c == 0)
        return (char *)s;
    return (char *)0;
}

void *memcpy(void *dst, const void *src, unsigned n)
{
    char *d = (char *)dst;
    const char *s = (const char *)src;
    while (n != 0) {
        *d++ = *s++;
        --n;
    }
    return dst;
}

void *memset(void *dst, int value, unsigned n)
{
    char *d = (char *)dst;
    while (n != 0) {
        *d++ = (char)value;
        --n;
    }
    return dst;
}

int atoi_span(const char *s, unsigned n)
{
    int sign = 1;
    int value = 0;
    unsigned i = 0;

    if (n != 0 && (s[0] == '-' || s[0] == '+')) {
        sign = s[0] == '-' ? -1 : 1;
        i = 1;
    }
    while (i < n && s[i] >= '0' && s[i] <= '9') {
        value = value * 10 + (s[i] - '0');
        ++i;
    }
    return sign * value;
}

int atoi(const char *s)
{
    return atoi_span(s, strlen(s));
}

int print(const char *s)
{
    return write(1, s, (int)strlen(s));
}

int print_unum(unsigned value)
{
    char digits[12];
    int at = 12;
    do {
        --at;
        digits[at] = (char)('0' + value % 10u);
        value = value / 10u;
    } while (value != 0);
    return write(1, digits + at, 12 - at);
}

int print_num(int value)
{
    if (value < 0) {
        write(1, "-", 1);
        return print_unum((unsigned)(-(value + 1)) + 1u) + 1;
    }
    return print_unum((unsigned)value);
}

int print_hex(unsigned value)
{
    char digits[10];
    int i;
    digits[0] = '0';
    digits[1] = 'x';
    for (i = 0; i < 8; ++i) {
        unsigned nibble = (value >> (28 - i * 4)) & 15u;
        digits[2 + i] = (char)(nibble < 10 ? '0' + nibble : 'a' + nibble - 10);
    }
    return write(1, digits, 10);
}

int write_all(int fd, const void *buffer, unsigned length)
{
    const char *p = (const char *)buffer;
    unsigned done = 0;

    while (done < length) {
        int n = write(fd, p + done, (int)(length - done));
        if (n == SYS_AGAIN) {
            yield();
            continue;
        }
        if (n <= 0)
            return done == 0 ? -1 : (int)done;
        done += (unsigned)n;
    }
    return (int)done;
}

int read_byte(int fd)
{
    unsigned char c;
    for (;;) {
        int n = read(fd, &c, 1);
        if (n == SYS_AGAIN) {
            yield();
            continue;
        }
        if (n != 1)
            return n == 0 ? -1 : n;
        return (int)c;
    }
}

/*
 * First-fit allocator on top of sbrk. Each block starts with two words:
 * total size in bytes (header included) and the next free block, or 0.
 * Payload follows the header. Freed blocks are pushed back to the front
 * of the list and split when the remainder still fits a tiny block.
 */
static unsigned free_head;
static unsigned heap_base;

static unsigned align4(unsigned n)
{
    return (n + 3u) & ~3u;
}

void *malloc(unsigned n)
{
    unsigned need = align4(n) + 8u;
    unsigned *prev = &free_head;
    unsigned cur = free_head;

    if (heap_base == 0) {
        heap_base = (unsigned)sbrk(0);
        if ((int)heap_base == -1)
            return (void *)0;
    }
    while (cur != 0) {
        unsigned *block = (unsigned *)cur;
        unsigned size = block[0];
        if (size >= need) {
            unsigned left = size - need;
            if (left >= 12u) {
                unsigned *rest = (unsigned *)(cur + need);
                rest[0] = left;
                rest[1] = block[1];
                block[0] = need;
                *prev = (unsigned)rest;
            } else {
                *prev = block[1];
            }
            return (void *)(cur + 8u);
        }
        prev = &block[1];
        cur = block[1];
    }
    {
        unsigned *block = (unsigned *)sbrk((int)need);
        if ((int)block == -1)
            return (void *)0;
        block[0] = need;
        block[1] = 0;
        return (void *)((unsigned)block + 8u);
    }
}

void free(void *p)
{
    unsigned cur;
    unsigned *block;

    if (p == (void *)0)
        return;
    cur = (unsigned)p - 8u;
    if (cur < heap_base + 8u || (cur & 3u) != 0)
        return;
    block = (unsigned *)cur;
    block[1] = free_head;
    free_head = cur;
}

void *calloc(unsigned elements, unsigned size)
{
    unsigned total;
    unsigned char *p;
    unsigned i;

    if (elements != 0 && size > 0xffffffffu / elements)
        return (void *)0;
    total = elements * size;
    p = (unsigned char *)malloc(total);
    if (p == (void *)0)
        return (void *)0;
    for (i = 0; i < total; ++i)
        p[i] = 0;
    return (void *)p;
}

int read_line(int fd, char *buffer, int capacity)
{
    int n = 0;
    int saw_cr = 0;

    if (capacity <= 0)
        return -1;
    for (;;) {
        int ch = read_byte(fd);
        if (ch < 0)
            return n == 0 ? -1 : n;
        if (ch == '\n' && saw_cr) {
            saw_cr = 0;
            continue;
        }
        saw_cr = ch == '\r';
        if (ch == '\r' || ch == '\n') {
            buffer[n] = 0;
            return n;
        }
        if (n + 1 < capacity)
            buffer[n++] = (char)ch;
    }
}
