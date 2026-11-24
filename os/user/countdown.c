#include "syscall.h"

/* Leave time for commands on hart 0 between the countdown messages. */
static void pause(void)
{
    int i;
    for (i = 0; i < 1800; ++i)
        yield();
}

int main(void)
{
    if (gethart() != 1)
        return 1;
    write("countdown: 3\n", 13);
    pause();
    write("countdown: 2\n", 13);
    pause();
    write("countdown: 1\n", 13);
    pause();
    write("countdown: done\n", 16);
    return 0;
}
