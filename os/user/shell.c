#include "lib.h"
#include "editor.h"

static void job_line(const char *name, int state);
static const char *slot_name(int slot);
static void show_job(int wait);

#define LINE_CAP 80
#define HIST_COUNT 8

/* Command history for the shell prompt (editor lines are not recorded).
   Up recalls older entries, down moves toward a blank line. */
static char history[HIST_COUNT][LINE_CAP];
static int hist_used;
static int hist_pos;

static void history_push(const char *line)
{
    int i;

    if (*line == 0)
        return;
    if (hist_used == HIST_COUNT) {
        for (i = 1; i < HIST_COUNT; ++i)
            strcpy(history[i - 1], history[i]);
        --hist_used;
    }
    strcpy(history[hist_used], line);
    ++hist_used;
    hist_pos = hist_used;
}

static void history_move(char *line, int *n, int direction)
{
    int old = *n;

    hist_pos += direction;
    if (hist_pos < 0)
        hist_pos = 0;
    if (hist_pos > hist_used)
        hist_pos = hist_used;
    if (hist_pos == hist_used) {
        *n = 0;
    } else {
        strcpy(line, history[hist_pos]);
        *n = (int)strlen(line);
    }
    print("\rroco_os> ");
    line[*n] = 0;
    print(line);
    while (old > *n) {
        print(" ");
        --old;
    }
    print("\rroco_os> ");
    print(line);
}

/* Read the rest of an arrow-key sequence after ESC. Accepts both the
   ANSI form (ESC [ A) and the application-cursor form (ESC O A) that
   xterm-style terminals send after leaving programs like bash. Yields
   while waiting so background jobs keep running; gives up on anything
   unexpected (already-consumed bytes are dropped). */
static int read_arrow(void)
{
    int tries = 0;
    int ch;

    while (tries < 5000) {
        ch = readchar();
        if (ch == '[' || ch == 'O')
            break;
        if (ch >= 0)
            return 0;
        if ((tries & 63) == 0)
            yield();
        ++tries;
    }
    if (ch != '[' && ch != 'O')
        return 0;
    tries = 0;
    for (;;) {
        ch = readchar();
        if (ch == 'A')
            return -1;
        if (ch == 'B')
            return 1;
        if (ch >= 0)
            return 0;
        if ((tries & 63) == 0)
            yield();
        ++tries;
        if (tries > 5000)
            return 0;
    }
}

static void show_file(const char *path)
{
    char buffer[128];
    int fd;
    int n;

    fd = open(path, O_RDONLY);
    if (fd < 0) {
        print("cat: cannot open ");
        print(path);
        print(".\n");
        return;
    }
    for (;;) {
        n = read(fd, buffer, sizeof(buffer));
        if (n <= 0)
            break;
        write(1, buffer, n);
    }
    close(fd);
}

static void show_motd(void)
{
    show_file("/motd");
}

static void list_dir(char *path)
{
    char name[32];
    int fd;
    int type;
    int index;

    if (*path == 0)
        path = ".";
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        print("ls: cannot open ");
        print(path);
        print(".\n");
        return;
    }
    for (index = 0; ; ++index) {
        type = readdir(fd, index, name, sizeof(name));
        if (type == 0)
            break;
        if (type < 0) {
            print("ls: not a directory.\n");
            break;
        }
        if (type == FS_DIR)
            print("d ");
        else
            print("- ");
        print(name);
        print("\n");
    }
    close(fd);
}

static void show_cwd(void)
{
    char path[96];
    if (getcwd(path, sizeof(path)) == 0) {
        print(path);
        print("\n");
    } else
        print("pwd: failed.\n");
}

static void change_dir(char *path)
{
    if (*path == 0)
        path = "/";
    if (chdir(path) != 0) {
        print("cd: cannot enter ");
        print(path);
        print(".\n");
    }
}

static void make_dir(char *path)
{
    if (*path == 0)
        print("Usage: mkdir <path>\n");
    else if (mkdir(path) != 0)
        print("mkdir: cannot create directory.\n");
}

static void remove_dir(char *path)
{
    if (*path == 0)
        print("Usage: rmdir <path>\n");
    else if (rmdir(path) != 0)
        print("rmdir: cannot remove directory.\n");
}

static void move_file(char *args)
{
    char *from = args;
    char *to = args;

    while (*to != 0 && *to != ' ' && *to != '\t')
        ++to;
    if (*to == 0) {
        print("Usage: mv <from> <to>\n");
        return;
    }
    *to = 0;
    ++to;
    while (*to == ' ' || *to == '\t')
        ++to;
    if (*from == 0 || *to == 0) {
        print("Usage: mv <from> <to>\n");
        return;
    }
    if (rename(from, to) != 0)
        print("mv: cannot move file.\n");
}

static void remove_file(char *path)
{
    if (*path == 0)
        print("Usage: rm <path>\n");
    else if (unlink(path) != 0)
        print("rm: cannot remove file.\n");
}

static void show_space(void)
{
    int info[4];
    if (fsinfo(info) != 0) {
        print("df: failed.\n");
        return;
    }
    print("blocks ");
    print_num(info[1]);
    print("/");
    print_num(info[0]);
    print(" free, inodes ");
    print_num(info[3]);
    print("/");
    print_num(info[2]);
    print(" free\n");
}

static char job_name[3][32];

static void started_on(int hart)
{
    if (hart == 0)
        print("Started on hart 0.\n");
    else
        print("Started on hart 1.\n");
}

static void run_job(char *args)
{
    char prog[32];
    char path[96];
    int n = 0;
    int id = 0;
    int result;
    int hart = 1;
    int background = 0;
    int slot = 0;

    while (*args != 0 && *args != ' ' && *args != '\t') {
        if (n + 1 < 32)
            prog[n++] = *args;
        ++args;
    }
    prog[n] = 0;
    while (*args == ' ' || *args == '\t')
        ++args;
    if ((*args == '0' || *args == '1') &&
        (args[1] == ' ' || args[1] == '\t' || args[1] == '&' ||
         args[1] == 0)) {
        hart = *args - '0';
        ++args;
        while (*args == ' ' || *args == '\t')
            ++args;
    }
    background = (*args == '&');
    if (background) {
        ++args;
        while (*args == ' ' || *args == '\t')
            ++args;
    }
    if (*args != 0) {
        print("Usage: run <worker|countdown|path> [0|1] [&]\n");
        return;
    }
    if (strcmp(prog, "worker") == 0)
        id = JOB_WORKER;
    else if (strcmp(prog, "countdown") == 0)
        id = JOB_COUNTDOWN;
    if (id != 0) {
        result = syscall(SYS_RUN_JOB, id, hart);
        if (result == 0) {
            strcpy(job_name[id], prog);
            slot = id;
        } else if (result == JOB_BUSY)
            print("That program is already active.\n");
        else
            print("Could not start job.\n");
        if (slot == 0)
            return;
        if (background)
            started_on(hart);
        else if (syscall(SYS_FG, slot, 0) == 0)
            show_job(1);
        else
            print("Could not start job.\n");
        return;
    }
    if (prog[0] == '/')
        strcpy(path, prog);
    else {
        strcpy(path, "/bin/");
        strcat(path, prog);
    }
    {
        int info[4];
        if (stat(path, info) != 0 || info[STAT_TYPE] != FS_FILE) {
            print("No such program.\n");
            return;
        }
    }
    result = syscall(SYS_SPAWN, (int)path, hart);
    if (result == JOB_WORKER || result == JOB_COUNTDOWN)
        slot = result;
    else if (result == JOB_BUSY)
        print("No free job slot; wait for a job to finish.\n");
    else
        print("Could not start job.\n");
    if (slot == 0)
        return;
    strcpy(job_name[slot], prog);
    if (background)
        started_on(hart);
    else if (syscall(SYS_FG, slot, 0) == 0)
        show_job(1);
    else
        print("Could not start job.\n");
}

static void show_ps(void)
{
    int status;

    print("pid 1 shell: active on hart 0.\n");
    status = syscall(SYS_JOB_STATUS, JOB_WORKER, 0);
    print("pid 2 ");
    job_line(slot_name(JOB_WORKER), status);
    status = syscall(SYS_JOB_STATUS, JOB_COUNTDOWN, 0);
    print("pid 3 ");
    job_line(slot_name(JOB_COUNTDOWN), status);
}

static void kill_job(char *args)
{
    int pid = 0;

    while (*args >= '0' && *args <= '9') {
        pid = pid * 10 + (*args - '0');
        ++args;
    }
    while (*args == ' ' || *args == '\t')
        ++args;
    if (pid < 2 || pid > 3 || *args != 0)
        print("Usage: kill <pid>\n");
    else if (syscall(SYS_KILL, pid, 0) != 0)
        print("kill: failed.\n");
}

static void sleep_ticks(char *args)
{
    unsigned ticks = 0;

    if (*args < '0' || *args > '9') {
        print("Usage: sleep <ticks>\n");
        return;
    }
    while (*args >= '0' && *args <= '9') {
        ticks = ticks * 10u + (unsigned)(*args - '0');
        ++args;
    }
    while (*args == ' ' || *args == '\t')
        ++args;
    if (*args != 0) {
        print("Usage: sleep <ticks>\n");
        return;
    }
    sleep(ticks);
}

static void show_uptime(void)
{
    print("ticks ");
    print_unum(uptime());
    print("\n");
}

static const char *slot_name(int slot)
{
    if (job_name[slot][0] != 0)
        return job_name[slot];
    if (slot == JOB_WORKER)
        return "worker";
    return "countdown";
}

static void job_line(const char *name, int state)
{
    if (state == JOB_IDLE)
        return;
    print(name);
    if (state == JOB_ACTIVE)
        print(": active on hart 0.\n");
    else if (state == JOB_ACTIVE + 1)
        print(": active on hart 1.\n");
    else if (state == JOB_DONE)
        print(": completed successfully.\n");
    else if (state >= JOB_FAULT) {
        print(": stopped by a user-mode fault (cause ");
        print_num(state - JOB_FAULT);
        print(").\n");
    }
    else
        print(": failed.\n");
}

static void show_job(int wait)
{
    int worker;
    int countdown;
    do {
        worker = syscall(SYS_JOB_STATUS, JOB_WORKER, 0);
        countdown = syscall(SYS_JOB_STATUS, JOB_COUNTDOWN, 0);
    } while (wait && (worker == JOB_ACTIVE || worker == JOB_ACTIVE + 1 ||
                      countdown == JOB_ACTIVE || countdown == JOB_ACTIVE + 1));

    if (worker == JOB_IDLE && countdown == JOB_IDLE)
        print("No job yet.\n");
    job_line(slot_name(JOB_WORKER), worker);
    job_line(slot_name(JOB_COUNTDOWN), countdown);
}

static int command(char *line, int *editing)
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

    if (strcmp(line, "help") == 0)
        print("Commands: help, hart, echo, ls, cat, pwd, cd, mkdir, rmdir, mv, rm, df, run, jobs, ps, kill, sleep, uptime, wait, edit, script, exit\n"
        "run takes worker, countdown, or a /bin program path, with & for background.\n");
    else if (strcmp(line, "hart") == 0) {
        if (gethart() == 0)
            print("hart 0\n");
        else
            print("hart 1\n");
    } else if (strcmp(line, "echo") == 0) {
        print(args);
        print("\n");
    } else if (strcmp(line, "ls") == 0)
        list_dir(args);
    else if (strcmp(line, "cat") == 0)
        show_file(args);
    else if (strcmp(line, "pwd") == 0)
        show_cwd();
    else if (strcmp(line, "cd") == 0)
        change_dir(args);
    else if (strcmp(line, "mkdir") == 0)
        make_dir(args);
    else if (strcmp(line, "rmdir") == 0)
        remove_dir(args);
    else if (strcmp(line, "mv") == 0)
        move_file(args);
    else if (strcmp(line, "rm") == 0)
        remove_file(args);
    else if (strcmp(line, "df") == 0)
        show_space();
    else if (strcmp(line, "ps") == 0 && *args == 0)
        show_ps();
    else if (strcmp(line, "kill") == 0)
        kill_job(args);
    else if (strcmp(line, "sleep") == 0)
        sleep_ticks(args);
    else if (strcmp(line, "uptime") == 0 && *args == 0)
        show_uptime();
    else if (strcmp(line, "run") == 0)
        run_job(args);
    else if (strcmp(line, "jobs") == 0)
        show_job(0);
    else if (strcmp(line, "wait") == 0)
        show_job(1);
    else if (strcmp(line, "edit") == 0) {
        editor_open(args);
        *editing = 1;
        if (*args != 0) {
            print("Editing ");
            print(args);
            print(".\n");
        }
        print("Append text or use .list, .set N text, .del N, .clear, .save, .quit.\n");
    } else if (strcmp(line, "script") == 0 && *args == 0)
        script_run();
    else if (strcmp(line, "exit") == 0)
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
    int editing = 0;

    if (gethart() != 0)
        return 1;
    show_motd();
    print("roco_os user shell; type help.\nroco_os> ");
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
                /* command() NUL-terminates the command word in place,
                   so keep a copy for history first. */
                char full[LINE_CAP];
                int done;
                line[n] = 0;
                if (editing) {
                    editing = editor_line(line);
                } else {
                    strcpy(full, line);
                    done = command(line, &editing);
                    if (done)
                        break;
                    if (!editing)
                        history_push(full);
                }
            }
            n = 0;
            overflow = 0;
            if (editing)
                print("edit> ");
            else
                print("roco_os> ");
        } else if (!overflow) {
            if (ch == 27 && !editing) {
                int move = read_arrow();
                if (move != 0)
                    history_move(line, &n, move);
            } else if (ch == 8 || ch == 127) {
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
