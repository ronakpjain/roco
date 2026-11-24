#include "syscall.h"

/*
 * Prove exec() by replacing this job with /bin/worker. The marker file
 * shows this program ran; the completed job is the worker's.
 */

int main(void)
{
    int fd = open("/tmp/chained.txt", O_WRONLY | O_CREAT | O_TRUNC);
    if (fd < 0)
        return 1;
    if (write(fd, "chained\n", 8) != 8)
        return 2;
    if (close(fd) != 0)
        return 3;
    if (exec("/bin/worker") != 0)
        return 4;
    return 5;
}
