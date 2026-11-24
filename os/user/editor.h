#ifndef EDITOR_H
#define EDITOR_H

int editor_line(char *line);
void script_run(void);
int editor_open(const char *path);
int editor_save(void);
const char *editor_name(void);

#endif
