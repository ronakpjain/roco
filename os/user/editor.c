#include "editor.h"
#include "lib.h"

#define ROWS 12
#define COLS 80
#define MAX_NUMBER 999999u
#define PATH_CAP 96

static char document[ROWS * COLS];
static char file_name[PATH_CAP];
static int have_file;
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

static void add_line(const char *text)
{
    if (rows == ROWS)
        return;
    strcpy(document + rows * COLS, text);
    ++rows;
}

const char *editor_name(void)
{
    return have_file ? file_name : "";
}

int editor_open(const char *path)
{
    char line[COLS];
    char c;
    int fd;
    int n = 0;
    int ch;

    /* With no path the current document survives; .clear empties it. */
    if (path == 0 || *path == 0)
        return 0;
    rows = 0;
    have_file = 0;
    file_name[0] = 0;
    strncpy(file_name, path, PATH_CAP);
    have_file = 1;
    fd = open(path, O_RDONLY);
    if (fd < 0)
        return 0;
    for (;;) {
        ch = read(fd, &c, 1);
        if (ch <= 0)
            break;
        if (c == '\r')
            continue;
        if (c == '\n') {
            line[n] = 0;
            add_line(line);
            n = 0;
        } else if (n < COLS - 1) {
            line[n++] = c;
        }
    }
    if (n != 0) {
        line[n] = 0;
        add_line(line);
    }
    close(fd);
    return 0;
}

int editor_save(void)
{
    int fd;
    int i;
    unsigned len;

    if (!have_file)
        return -1;
    fd = open(file_name, O_WRONLY | O_CREAT | O_TRUNC);
    if (fd < 0)
        return -1;
    for (i = 0; i < rows; ++i) {
        len = strlen(document + i * COLS);
        if (write(fd, document + i * COLS, (int)len) != (int)len) {
            close(fd);
            return -1;
        }
        if (write(fd, "\n", 1) != 1) {
            close(fd);
            return -1;
        }
    }
    close(fd);
    return 0;
}

int editor_line(char *line)
{
    int i;
    unsigned n;
    char *args;

    if (*line != '.') {
        if (rows == ROWS)
            print("Document full.\n");
        else
            add_line(line);
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
    } else if (strcmp(line, ".save") == 0) {
        if (*args != 0) {
            strncpy(file_name, args, PATH_CAP);
            have_file = 1;
        }
        if (!have_file)
            print("No file name: use .save <path>.\n");
        else if (editor_save() == 0) {
            print("Saved ");
            print(file_name);
            print(".\n");
        } else
            print("Could not save file.\n");
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
        print("Use .list, .set N text, .del N, .clear, .save [path], .quit.\n");
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
