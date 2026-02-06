#ifndef _UNISTD_H_SHIM
#define _UNISTD_H_SHIM

#include <stddef.h>

typedef long ssize_t;

#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif

static inline int write(int fd, const void *buf, size_t count) { (void)fd; (void)buf; (void)count; return -1; }
static inline int read(int fd, void *buf, size_t count) { (void)fd; (void)buf; (void)count; return -1; }

#endif
