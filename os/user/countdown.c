#include "syscall.h"

/* Deliberately make no syscalls here: another job needs a timer tick to run. */
static int pause(void)
{
    unsigned i;
    unsigned sum = 0;
    for (i = 0; i < 3000u; ++i)
        sum += i;
    return sum == 4498500u;
}

int main(void)
{
    if (gethart() == 0)
        write(1, "countdown: hart 0\n", 18);
    write(1, "countdown: 3\n", 13);
    if (!pause())
        return 2;
    write(1, "countdown: 2\n", 13);
    if (!pause())
        return 2;
    write(1, "countdown: 1\n", 13);
    if (!pause())
        return 2;
    write(1, "countdown: done\n", 16);
    return 0;
}
