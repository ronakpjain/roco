#include "syscall.h"

#define LINE_CAP 80

static void print(const char *s)
{
    int len = 0;
    while (s[len] != 0)
        ++len;
    write(s, len);
}

static int same(const char *a, const char *b)
{
    while (*a == *b) {
        if (*a == 0)
            return 1;
        ++a;
        ++b;
    }
    return 0;
}

static int command(char *line)
{
    char *args;

    while (*line == ' ' || *line == '\t')
        ++line;
    if (*line == 0)
        return 0;
    args = line;
    while (*args != 0 && *args != ' ' && *args != '\t')
        ++args;
    if (*args != 0) {
        *args = 0;
        ++args;
        while (*args == ' ' || *args == '\t')
            ++args;
    }

    if (same(line, "help"))
        print("Commands: help, hart, echo [text], exit\n");
    else if (same(line, "hart")) {
        if (gethart() == 0)
            print("hart 0\n");
        else
            print("hart 1\n");
    } else if (same(line, "echo")) {
        print(args);
        print("\n");
    } else if (same(line, "exit"))
        return 1;
    else
        print("Unknown command; try help.\n");
    return 0;
}

int main(void)
{
    char line[LINE_CAP];
    int n = 0;
    int overflow = 0;
    int saw_cr = 0;
    int ch;

    if (gethart() != 0)
        return 1;
    print("ROCO user shell; type help.\nroco> ");
    for (;;) {
        ch = readchar();
        if (ch < 0)
            continue;
        if (ch == 4)  /* Host EOF is sent as EOT. */
            break;
        if (ch == '\n' && saw_cr) {
            saw_cr = 0;
            continue;
        }
        saw_cr = (ch == '\r');
        if (ch == '\r' || ch == '\n') {
            if (overflow)
                print("Line too long.\n");
            else {
                line[n] = 0;
                if (command(line))
                    break;
            }
            n = 0;
            overflow = 0;
            print("roco> ");
        } else if (!overflow) {
            if (ch == 8 || ch == 127) {
                if (n > 0)
                    --n;
            } else if ((ch >= 32 && ch < 127) || ch == '\t') {
                if (n < LINE_CAP - 1)
                    line[n++] = (char)ch;
                else
                    overflow = 1;
            }
        }
    }
    print("Bye.\n");
    return 0;
}
