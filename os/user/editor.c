#include "editor.h"
#include "lib.h"

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

int editor_line(char *line)
{
    int i;
    unsigned n;
    char *args;

    if (*line != '.') {
        if (rows == ROWS)
            print("Document full.\n");
        else {
            strcpy(document + rows * COLS, line);
            ++rows;
        }
        return 1;
    }
    args = word_end(line);
    if (*args != 0) {
        *args = 0;
        args = skip_space(args + 1);
    }
    if (strcmp(line, ".quit") == 0 && *args == 0)
        return 0;
    if (strcmp(line, ".clear") == 0 && *args == 0)
        rows = 0;
    else if (strcmp(line, ".list") == 0 && *args == 0) {
        for (i = 0; i < rows; ++i) {
            print_unum((unsigned)(i + 1));
            print(" ");
            print(document + i * COLS);
            print("\n");
        }
    } else if (strcmp(line, ".set") == 0 || strcmp(line, ".del") == 0) {
        args = number(args, &n);
        if (args == (char *)0 || n == 0 || n > (unsigned)rows)
            print("Invalid line number.\n");
        else if (strcmp(line, ".set") == 0)
            strcpy(document + (n - 1u) * COLS, args);
        else if (*args == 0) {
            for (i = (int)n; i < rows; ++i)
                strcpy(document + (i - 1) * COLS, document + i * COLS);
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
        strcpy(line, document + i * COLS);
        op = skip_space(line);
        if (*op == 0 || *op == '#')
            continue;
        args = word_end(op);
        if (*args != 0) {
            *args = 0;
            args = skip_space(args + 1);
        }
        if (strcmp(op, "print") == 0) {
            print(args);
            print("\n");
        } else if (strcmp(op, "show") == 0 && *args == 0) {
            print_unum(value);
            print("\n");
        } else {
            args = number(args, &n);
            if (args == (char *)0)
                break;
            if (strcmp(op, "repeat") == 0 && n <= 20u) {
                while (n > 0) {
                    print(args);
                    print("\n");
                    --n;
                }
            } else if (strcmp(op, "set") == 0 && *args == 0)
                value = n;
            else if (strcmp(op, "add") == 0 && *args == 0 && n <= MAX_NUMBER - value)
                value += n;
            else
                break;
        }
    }
    if (i < rows) {
        print("Script error on line ");
        print_unum((unsigned)(i + 1));
        print(".\n");
    }
}
