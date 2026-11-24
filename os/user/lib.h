#ifndef USER_LIB_H
#define USER_LIB_H

#include "syscall.h"

/* Freestanding C helpers shared by the bundled user programs. */

unsigned strlen(const char *s);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, unsigned n);
char *strcpy(char *dst, const char *src);
char *strncpy(char *dst, const char *src, unsigned n);
char *strcat(char *dst, const char *src);
char *strchr(const char *s, int c);
void *memcpy(void *dst, const void *src, unsigned n);
void *memset(void *dst, int value, unsigned n);
int atoi(const char *s);
int atoi_span(const char *s, unsigned n);

int print(const char *s);
int print_num(int value);
int print_unum(unsigned value);
int print_hex(unsigned value);

int write_all(int fd, const void *buffer, unsigned length);
int read_byte(int fd);
int read_line(int fd, char *buffer, int capacity);

void *malloc(unsigned n);
void free(void *p);
void *calloc(unsigned elements, unsigned size);

#endif
