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

static void run_job(char *args)
{
    char *end = args;
    int id;
    int result;

    while (*end != 0 && *end != ' ' && *end != '\t')
        ++end;
    if (*end != 0) {
        *end = 0;
        ++end;
        while (*end == ' ' || *end == '\t')
            ++end;
    }
    if (*end != '&') {
        print("Usage: run <worker|countdown> &\n");
        return;
    }
    ++end;
    while (*end == ' ' || *end == '\t')
        ++end;
    if (*end != 0) {
        print("Usage: run <worker|countdown> &\n");
        return;
    }
    if (same(args, "worker"))
        id = JOB_WORKER;
    else if (same(args, "countdown"))
        id = JOB_COUNTDOWN;
    else {
        print("No such program.\n");
        return;
    }
    result = syscall(SYS_RUN_JOB, id, 0);
    if (result == 0)
        print("Started on hart 1.\n");
    else if (result == JOB_BUSY)
        print("Hart 1 is busy.\n");
    else
        print("Could not start job.\n");
}

static void show_job(int wait)
{
    int state;
    do {
        state = syscall(SYS_JOB_STATUS, 0, 0);
    } while (wait && (state == JOB_WORKER || state == JOB_COUNTDOWN));

    if (state == JOB_IDLE)
        print("No job yet.\n");
    else if (state == JOB_WORKER)
        print("worker is running on hart 1.\n");
    else if (state == JOB_COUNTDOWN)
        print("countdown is running on hart 1.\n");
    else if (state == JOB_DONE)
        print("Job completed successfully.\n");
    else if (state >= JOB_FAULT)
        print("Job stopped by a user-mode fault.\n");
    else
        print("Job failed.\n");
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
        print("Commands: help, hart, echo [text], run <worker|countdown> &, jobs, wait, exit\n");
    else if (same(line, "hart")) {
        if (gethart() == 0)
            print("hart 0\n");
        else
            print("hart 1\n");
    } else if (same(line, "echo")) {
        print(args);
        print("\n");
    } else if (same(line, "run"))
        run_job(args);
    else if (same(line, "jobs"))
        show_job(0);
    else if (same(line, "wait"))
        show_job(1);
    else if (same(line, "exit"))
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
