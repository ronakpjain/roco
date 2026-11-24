#include "syscall.h"

/*
 * A job that never finishes on its own: it yields forever until the
 * shell kills it. Exercises kill and wait without a timing race.
 */

int main(void)
{
    for (;;)
        yield();
    return 0;
}
