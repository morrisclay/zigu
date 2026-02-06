#ifndef _STDLIB_H_SHIM
#define _STDLIB_H_SHIM

#include <stddef.h>

void *malloc(size_t size);
void free(void *ptr);
void *realloc(void *ptr, size_t size);
void *calloc(size_t nmemb, size_t size);

void abort(void) __attribute__((noreturn));
void exit(int status) __attribute__((noreturn));

long strtol(const char *nptr, char **endptr, int base);
unsigned long strtoul(const char *nptr, char **endptr, int base);
long long strtoll(const char *nptr, char **endptr, int base);
unsigned long long strtoull(const char *nptr, char **endptr, int base);

void qsort(void *base, size_t nmemb, size_t size,
           int (*compar)(const void *, const void *));

#define RAND_MAX 2147483647

static inline int abs(int x) { return x < 0 ? -x : x; }

#endif
