#include "syscall.h"

/* Keep the second hart's user-mode check without interrupting the prompt. */
int main(void)
{
    if (gethart() != 1 || readchar() != -1)
        return 1;
    return 0;
}
