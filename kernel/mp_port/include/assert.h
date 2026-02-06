#ifndef _ASSERT_H_SHIM
#define _ASSERT_H_SHIM

void abort(void);

#ifdef NDEBUG
#define assert(x) ((void)0)
#else
/* Use expression form so assert() can appear inside expressions (e.g. comma operator) */
#define assert(x) ((void)((x) || (abort(), 0)))
#endif

#endif
