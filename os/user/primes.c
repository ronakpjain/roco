#include "syscall.h"

/*
 * Print primes up to 100 and record them in /tmp/primes.txt so the shell
 * can show them after the job completes. Background jobs cannot write to
 * the console unless they own it, so the file is the visible result.
 */

static void put_num(int fd, int value)
{
    char digits[12];
    int at = 12;

    do {
        --at;
        digits[at] = (char)('0' + value % 10);
        value = value / 10;
    } while (value != 0);
    write(fd, digits + at, 12 - at);
    write(fd, "\n", 1);
}

int main(void)
{
    int fd;
    int n;
    int d;
    int prime;

    fd = open("/tmp/primes.txt", O_WRONLY | O_CREAT | O_TRUNC);
    if (fd < 0)
        return 1;
    for (n = 2; n <= 100; ++n) {
        prime = 1;
        for (d = 2; d * d <= n; ++d) {
            if (n % d == 0) {
                prime = 0;
                break;
            }
        }
        if (prime) {
            put_num(fd, n);
            put_num(1, n);
        }
    }
    if (close(fd) != 0)
        return 2;
    return 0;
}
