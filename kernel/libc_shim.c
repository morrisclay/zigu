/*
 * Minimal libc shim for MicroPython running in Zigu freestanding kernel.
 * Provides: malloc/free/realloc/calloc, mem*, str*, snprintf, abort, etc.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>

/* ---------- Simple freelist allocator over a static buffer ---------- */

#define LIBC_HEAP_SIZE (8 * 1024 * 1024)  /* 8MB */
static char libc_heap[LIBC_HEAP_SIZE] __attribute__((aligned(16)));

/*
 * Simple bump allocator with a free list.
 * Each allocation is prefixed with an 16-byte header storing the size.
 */
typedef struct block_header {
    size_t size;          /* usable size (not including header) */
    struct block_header *next_free;  /* NULL if in-use */
    size_t magic;         /* 0xDEADBEEF when allocated */
    size_t _pad;          /* alignment padding */
} block_header_t;

#define BLOCK_MAGIC 0xDEADBEEFUL
#define HEADER_SIZE sizeof(block_header_t)
#define ALIGN16(x) (((x) + 15) & ~(size_t)15)

static size_t heap_offset = 0;
static block_header_t *free_list = NULL;

void *malloc(size_t size) {
    if (size == 0) size = 1;
    size = ALIGN16(size);

    /* Try free list first */
    block_header_t **prev = &free_list;
    block_header_t *blk = free_list;
    while (blk) {
        if (blk->size >= size) {
            *prev = blk->next_free;
            blk->next_free = NULL;
            blk->magic = BLOCK_MAGIC;
            return (char *)blk + HEADER_SIZE;
        }
        prev = &blk->next_free;
        blk = blk->next_free;
    }

    /* Bump allocate */
    size_t needed = HEADER_SIZE + size;
    if (heap_offset + needed > LIBC_HEAP_SIZE) {
        return NULL;
    }
    block_header_t *hdr = (block_header_t *)(libc_heap + heap_offset);
    hdr->size = size;
    hdr->next_free = NULL;
    hdr->magic = BLOCK_MAGIC;
    hdr->_pad = 0;
    heap_offset += needed;
    return (char *)hdr + HEADER_SIZE;
}

void free(void *ptr) {
    if (!ptr) return;
    block_header_t *hdr = (block_header_t *)((char *)ptr - HEADER_SIZE);
    if (hdr->magic != BLOCK_MAGIC) return;  /* ignore bad frees */
    hdr->magic = 0;
    hdr->next_free = free_list;
    free_list = hdr;
}

void *realloc(void *ptr, size_t size) {
    if (!ptr) return malloc(size);
    if (size == 0) { free(ptr); return NULL; }

    block_header_t *hdr = (block_header_t *)((char *)ptr - HEADER_SIZE);
    if (hdr->size >= ALIGN16(size)) return ptr;  /* already big enough */

    void *new_ptr = malloc(size);
    if (!new_ptr) return NULL;

    /* Copy old data */
    size_t copy_size = hdr->size < size ? hdr->size : size;
    unsigned char *d = new_ptr;
    const unsigned char *s = ptr;
    for (size_t i = 0; i < copy_size; i++) d[i] = s[i];

    free(ptr);
    return new_ptr;
}

void *calloc(size_t nmemb, size_t size) {
    size_t total = nmemb * size;
    void *ptr = malloc(total);
    if (ptr) {
        unsigned char *p = ptr;
        for (size_t i = 0; i < total; i++) p[i] = 0;
    }
    return ptr;
}

/* ---------- Memory functions ---------- */

void *memcpy(void *dest, const void *src, size_t n) {
    unsigned char *d = dest;
    const unsigned char *s = src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dest;
}

void *memmove(void *dest, const void *src, size_t n) {
    unsigned char *d = dest;
    const unsigned char *s = src;
    if (d < s) {
        for (size_t i = 0; i < n; i++) d[i] = s[i];
    } else if (d > s) {
        for (size_t i = n; i > 0; i--) d[i-1] = s[i-1];
    }
    return dest;
}

void *memset(void *s, int c, size_t n) {
    unsigned char *p = s;
    for (size_t i = 0; i < n; i++) p[i] = (unsigned char)c;
    return s;
}

int memcmp(const void *s1, const void *s2, size_t n) {
    const unsigned char *a = s1, *b = s2;
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i]) return a[i] - b[i];
    }
    return 0;
}

/* ---------- String functions ---------- */

size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

int strcmp(const char *s1, const char *s2) {
    while (*s1 && *s1 == *s2) { s1++; s2++; }
    return (unsigned char)*s1 - (unsigned char)*s2;
}

int strncmp(const char *s1, const char *s2, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (s1[i] != s2[i]) return (unsigned char)s1[i] - (unsigned char)s2[i];
        if (s1[i] == '\0') return 0;
    }
    return 0;
}

char *strchr(const char *s, int c) {
    while (*s) {
        if (*s == (char)c) return (char *)s;
        s++;
    }
    return (c == 0) ? (char *)s : NULL;
}

char *strrchr(const char *s, int c) {
    const char *last = NULL;
    while (*s) {
        if (*s == (char)c) last = s;
        s++;
    }
    if (c == 0) return (char *)s;
    return (char *)last;
}

char *strcpy(char *dest, const char *src) {
    char *d = dest;
    while ((*d++ = *src++));
    return dest;
}

char *strncpy(char *dest, const char *src, size_t n) {
    size_t i;
    for (i = 0; i < n && src[i]; i++) dest[i] = src[i];
    for (; i < n; i++) dest[i] = '\0';
    return dest;
}

char *strstr(const char *haystack, const char *needle) {
    if (!*needle) return (char *)haystack;
    for (; *haystack; haystack++) {
        const char *h = haystack, *n = needle;
        while (*h && *n && *h == *n) { h++; n++; }
        if (!*n) return (char *)haystack;
    }
    return NULL;
}

size_t strnlen(const char *s, size_t maxlen) {
    size_t n = 0;
    while (n < maxlen && s[n]) n++;
    return n;
}

char *strcat(char *dest, const char *src) {
    char *d = dest + strlen(dest);
    while ((*d++ = *src++));
    return dest;
}

/* ---------- Minimal snprintf / vsnprintf ---------- */

static void put_char(char *buf, size_t size, size_t *pos, char c) {
    if (*pos < size - 1) buf[*pos] = c;
    (*pos)++;
}

static void put_string(char *buf, size_t size, size_t *pos, const char *s) {
    while (*s) put_char(buf, size, pos, *s++);
}

static void put_uint(char *buf, size_t size, size_t *pos, unsigned long long val, int base, int width, char pad) {
    char tmp[24];
    int i = 0;
    if (val == 0) { tmp[i++] = '0'; }
    else {
        while (val > 0) {
            int d = val % base;
            tmp[i++] = d < 10 ? '0' + d : 'a' + (d - 10);
            val /= base;
        }
    }
    /* padding */
    for (int w = i; w < width; w++) put_char(buf, size, pos, pad);
    /* digits in reverse */
    while (i > 0) put_char(buf, size, pos, tmp[--i]);
}

static void put_int(char *buf, size_t size, size_t *pos, long long val, int width, char pad) {
    if (val < 0) {
        put_char(buf, size, pos, '-');
        put_uint(buf, size, pos, (unsigned long long)(-val), 10, width > 0 ? width - 1 : 0, pad);
    } else {
        put_uint(buf, size, pos, (unsigned long long)val, 10, width, pad);
    }
}

int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap) {
    size_t pos = 0;
    if (size == 0) return 0;

    while (*fmt) {
        if (*fmt != '%') {
            put_char(buf, size, &pos, *fmt++);
            continue;
        }
        fmt++;  /* skip '%' */

        /* flags */
        char pad = ' ';
        if (*fmt == '0') { pad = '0'; fmt++; }

        /* width */
        int width = 0;
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }

        /* length modifier */
        int is_long = 0;
        int is_size = 0;
        if (*fmt == 'l') { is_long = 1; fmt++; if (*fmt == 'l') { is_long = 2; fmt++; } }
        else if (*fmt == 'z') { is_size = 1; fmt++; }

        switch (*fmt) {
            case 'd':
            case 'i': {
                long long val;
                if (is_long == 2) val = va_arg(ap, long long);
                else if (is_long == 1) val = va_arg(ap, long);
                else val = va_arg(ap, int);
                put_int(buf, size, &pos, val, width, pad);
                break;
            }
            case 'u': {
                unsigned long long val;
                if (is_long == 2) val = va_arg(ap, unsigned long long);
                else if (is_long == 1 || is_size) val = va_arg(ap, unsigned long);
                else val = va_arg(ap, unsigned int);
                put_uint(buf, size, &pos, val, 10, width, pad);
                break;
            }
            case 'x':
            case 'X': {
                unsigned long long val;
                if (is_long == 2) val = va_arg(ap, unsigned long long);
                else if (is_long == 1 || is_size) val = va_arg(ap, unsigned long);
                else val = va_arg(ap, unsigned int);
                put_uint(buf, size, &pos, val, 16, width, pad);
                break;
            }
            case 'p': {
                void *val = va_arg(ap, void *);
                put_string(buf, size, &pos, "0x");
                put_uint(buf, size, &pos, (unsigned long long)(uintptr_t)val, 16, 0, '0');
                break;
            }
            case 's': {
                const char *s = va_arg(ap, const char *);
                if (!s) s = "(null)";
                put_string(buf, size, &pos, s);
                break;
            }
            case 'c': {
                char c = (char)va_arg(ap, int);
                put_char(buf, size, &pos, c);
                break;
            }
            case '%':
                put_char(buf, size, &pos, '%');
                break;
            default:
                put_char(buf, size, &pos, '%');
                put_char(buf, size, &pos, *fmt);
                break;
        }
        fmt++;
    }

    buf[pos < size ? pos : size - 1] = '\0';
    return (int)pos;
}

int snprintf(char *buf, size_t size, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int ret = vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return ret;
}

int printf(const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    int ret = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    extern void serial_write_bytes(const char *ptr, unsigned long len);
    size_t n = ret < (int)sizeof(buf) ? (size_t)ret : sizeof(buf) - 1;
    serial_write_bytes(buf, n);
    return ret;
}

/* ---------- Abort / exit / stack protection ---------- */

void abort(void) {
    extern void serial_write_bytes(const char *ptr, unsigned long len);
    serial_write_bytes("abort() called\n", 15);
    while (1) { __asm__ volatile ("hlt"); }
}

void exit(int status) {
    (void)status;
    while (1) { __asm__ volatile ("hlt"); }
}

void __stack_chk_fail(void) {
    abort();
}

/* ---------- Stubs for functions MicroPython may reference ---------- */

long strtol(const char *nptr, char **endptr, int base) {
    long result = 0;
    int sign = 1;
    const char *s = nptr;

    while (*s == ' ' || *s == '\t' || *s == '\n') s++;
    if (*s == '-') { sign = -1; s++; }
    else if (*s == '+') { s++; }

    if (base == 0) {
        if (*s == '0') {
            s++;
            if (*s == 'x' || *s == 'X') { base = 16; s++; }
            else if (*s == 'b' || *s == 'B') { base = 2; s++; }
            else { base = 8; }
        } else {
            base = 10;
        }
    } else if (base == 16) {
        if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    }

    while (*s) {
        int digit;
        if (*s >= '0' && *s <= '9') digit = *s - '0';
        else if (*s >= 'a' && *s <= 'f') digit = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'F') digit = *s - 'A' + 10;
        else break;
        if (digit >= base) break;
        result = result * base + digit;
        s++;
    }
    if (endptr) *endptr = (char *)s;
    return result * sign;
}

unsigned long strtoul(const char *nptr, char **endptr, int base) {
    /* Reuse strtol for simplicity */
    return (unsigned long)strtol(nptr, endptr, base);
}

long long strtoll(const char *nptr, char **endptr, int base) {
    return (long long)strtol(nptr, endptr, base);
}

unsigned long long strtoull(const char *nptr, char **endptr, int base) {
    return (unsigned long long)strtol(nptr, endptr, base);
}

/* qsort - simple insertion sort */
void qsort(void *base, size_t nmemb, size_t size, int (*compar)(const void *, const void *)) {
    char *arr = base;
    char tmp[256];  /* max element size for swap */
    for (size_t i = 1; i < nmemb; i++) {
        size_t j = i;
        while (j > 0 && compar(arr + j * size, arr + (j - 1) * size) < 0) {
            /* swap arr[j] and arr[j-1] */
            size_t n = size < sizeof(tmp) ? size : sizeof(tmp);
            memcpy(tmp, arr + j * size, n);
            memcpy(arr + j * size, arr + (j - 1) * size, n);
            memcpy(arr + (j - 1) * size, tmp, n);
            j--;
        }
    }
}

/* ---------- math stubs (MicroPython minimal config won't need these but just in case) ---------- */

double __attribute__((weak)) floor(double x) { return (double)(long long)x - (x < 0 && x != (long long)x ? 1 : 0); }
double __attribute__((weak)) ceil(double x) { return (double)(long long)x + (x > 0 && x != (long long)x ? 1 : 0); }
double __attribute__((weak)) fmod(double x, double y) { return x - (long long)(x / y) * y; }
double __attribute__((weak)) sqrt(double x) {
    if (x < 0) return 0;
    double r = x;
    for (int i = 0; i < 20; i++) r = 0.5 * (r + x / r);
    return r;
}
double __attribute__((weak)) pow(double base, double exp) {
    if (exp == 0) return 1.0;
    if (exp == 1) return base;
    /* integer exponent fast path */
    if (exp == (long long)exp && exp > 0) {
        double result = 1.0;
        long long e = (long long)exp;
        double b = base;
        while (e > 0) {
            if (e & 1) result *= b;
            b *= b;
            e >>= 1;
        }
        return result;
    }
    return 0.0;  /* non-integer exponents unsupported */
}
double __attribute__((weak)) log(double x) { (void)x; return 0.0; }
double __attribute__((weak)) exp(double x) { (void)x; return 0.0; }
double __attribute__((weak)) frexp(double x, int *exp) { *exp = 0; return x; }
double __attribute__((weak)) ldexp(double x, int exp) { (void)exp; return x; }
double __attribute__((weak)) modf(double x, double *iptr) { *iptr = (double)(long long)x; return x - *iptr; }
float __attribute__((weak)) floorf(float x) { return (float)(int)x - (x < 0 && x != (int)x ? 1 : 0); }

/* errno stub */
static int _errno_val = 0;
int *__errno_location(void) { return &_errno_val; }
