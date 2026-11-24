#include "syscall.h"
#include "lib.h"

/*
 * Exercise the heap: allocate, fill with patterns, verify, free, and
 * reuse. Any failure returns nonzero; success records /tmp/alloc.ok.
 */

int main(void)
{
    char *text;
    int *numbers;
    char *reuse;
    unsigned i;
    int fd;

    text = (char *)malloc(100);
    numbers = (int *)malloc(1000);
    if (text == (char *)0 || numbers == (int *)0)
        return 1;
    for (i = 0; i < 100u; ++i)
        text[i] = (char)(i * 7u + 3u);
    for (i = 0; i < 250u; ++i)
        numbers[i] = (int)(i * 3u + 1u);
    for (i = 0; i < 100u; ++i) {
        if (text[i] != (char)(i * 7u + 3u))
            return 2;
    }
    for (i = 0; i < 250u; ++i) {
        if (numbers[i] != (int)(i * 3u + 1u))
            return 3;
    }
    free(text);
    reuse = (char *)malloc(50);
    if (reuse == (char *)0)
        return 4;
    for (i = 0; i < 50u; ++i)
        reuse[i] = (char)i;
    for (i = 0; i < 50u; ++i) {
        if (reuse[i] != (char)i)
            return 5;
    }
    free(reuse);
    free(numbers);
    {
        int *zeroed = (int *)calloc(64, 4);
        if (zeroed == (int *)0)
            return 6;
        for (i = 0; i < 64u; ++i) {
            if (zeroed[i] != 0)
                return 7;
        }
        free(zeroed);
    }
    /* Growing past the 8 KiB heap must fail cleanly. */
    if (malloc(65536) != (void *)0)
        return 8;
    fd = open("/tmp/alloc.ok", O_WRONLY | O_CREAT | O_TRUNC);
    if (fd < 0)
        return 9;
    if (write(fd, "alloc ok\n", 9) != 9)
        return 10;
    if (close(fd) != 0)
        return 11;
    return 0;
}
