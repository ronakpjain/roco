#include "editor.h"
#include "syscall.h"

#define ROWS 12
#define COLS 80
#define MAX_NUMBER 999999u

static char document[ROWS * COLS];
static int rows;

static char *word_end(char *s)
{
    while (*s != 0 && *s != ' ' && *s != '\t')
        ++s;
    return s;
}

static char *skip_space(char *s)
{
    while (*s == ' ' || *s == '\t')
        ++s;
    return s;
}

static void copy_line(char *dst, const char *src)
{
    while (*src != 0)
        *dst++ = *src++;
    *dst = 0;
}

static char *number(char *s, unsigned *value)
{
    unsigned n = 0;
    if (*s < '0' || *s > '9')
        return (char *)0;
    while (*s >= '0' && *s <= '9') {
        n = n * 10u + (unsigned)(*s++ - '0');
        if (n > MAX_NUMBER)
            return (char *)0;
    }
    if (*s != 0 && *s != ' ' && *s != '\t')
        return (char *)0;
    *value = n;
    return skip_space(s);
}

static void print_number(unsigned n)
{
    char digits[6];
    int at = 6;
    do {
        --at;
        digits[at] = (char)('0' + n % 10u);
        n = n / 10u;
    } while (n != 0);
    write(digits + at, 6 - at);
}

int editor_line(char *line)
{
    int i;
    unsigned n;
    char *args;

    if (*line != '.') {
        if (rows == ROWS)
            print("Document full.\n");
        else {
            copy_line(document + rows * COLS, line);
            ++rows;
        }
        return 1;
    }
    args = word_end(line);
    if (*args != 0) {
        *args = 0;
        args = skip_space(args + 1);
    }
    if (same(line, ".quit") && *args == 0)
        return 0;
    if (same(line, ".clear") && *args == 0)
        rows = 0;
    else if (same(line, ".list") && *args == 0) {
        for (i = 0; i < rows; ++i) {
            print_number((unsigned)(i + 1));
            print(" ");
            print(document + i * COLS);
            print("\n");
        }
    } else if (same(line, ".set") || same(line, ".del")) {
        args = number(args, &n);
        if (args == (char *)0 || n == 0 || n > (unsigned)rows)
            print("Invalid line number.\n");
        else if (same(line, ".set"))
            copy_line(document + (n - 1u) * COLS, args);
        else if (*args == 0) {
            for (i = (int)n; i < rows; ++i)
                copy_line(document + (i - 1) * COLS, document + i * COLS);
            --rows;
        } else
            print("Usage: .del N\n");
    } else
        print("Use .list, .set N text, .del N, .clear, .quit.\n");
    return 1;
}

void script_run(void)
{
    char line[COLS];
    char *op;
    char *args;
    unsigned value = 0;
    unsigned n;
    int i;

    for (i = 0; i < rows; ++i) {
        copy_line(line, document + i * COLS);
        op = skip_space(line);
        if (*op == 0 || *op == '#')
            continue;
        args = word_end(op);
        if (*args != 0) {
            *args = 0;
            args = skip_space(args + 1);
        }
        if (same(op, "print")) {
            print(args);
            print("\n");
        } else if (same(op, "show") && *args == 0) {
            print_number(value);
            print("\n");
        } else {
            args = number(args, &n);
            if (args == (char *)0)
                break;
            if (same(op, "repeat") && n <= 20u) {
                while (n > 0) {
                    print(args);
                    print("\n");
                    --n;
                }
            } else if (same(op, "set") && *args == 0)
                value = n;
            else if (same(op, "add") && *args == 0 && n <= MAX_NUMBER - value)
                value += n;
            else
                break;
        }
    }
    if (i < rows) {
        print("Script error on line ");
        print_number((unsigned)(i + 1));
        print(".\n");
    }
}
