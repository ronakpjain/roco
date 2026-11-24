#include "syscall.h"

/* Deliberately make no syscalls here: another job needs a timer tick to run. */
static int pause(void)
{
    unsigned i;
    unsigned sum = 0;
    for (i = 0; i < 30000u; ++i)
        sum += i;
    return sum == 449985000u;
}

int main(void)
{
    if (gethart() != 1)
        return 1;
    write("countdown: 3\n", 13);
    if (!pause())
        return 2;
    write("countdown: 2\n", 13);
    if (!pause())
        return 2;
    write("countdown: 1\n", 13);
    if (!pause())
        return 2;
    write("countdown: done\n", 16);
    return 0;
}
