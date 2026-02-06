#ifndef _TIME_H_SHIM
#define _TIME_H_SHIM

typedef long time_t;

struct timespec {
    time_t tv_sec;
    long tv_nsec;
};

static inline time_t time(time_t *t) { if (t) *t = 0; return 0; }

#endif
