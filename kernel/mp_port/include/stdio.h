#ifndef _STDIO_H_SHIM
#define _STDIO_H_SHIM

#include <stddef.h>
#include <stdarg.h>

int printf(const char *fmt, ...);
int snprintf(char *buf, size_t size, const char *fmt, ...);
int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);

#define FILE void
#define stdout ((FILE *)1)
#define stderr ((FILE *)2)
#define EOF (-1)

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

static inline int fprintf(FILE *f, const char *fmt, ...) { (void)f; (void)fmt; return 0; }
static inline int fflush(FILE *f) { (void)f; return 0; }

#endif
