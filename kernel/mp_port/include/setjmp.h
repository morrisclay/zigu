#ifndef _SETJMP_H_SHIM
#define _SETJMP_H_SHIM

/* jmp_buf for x86_64: save rbx, rbp, r12-r15, rsp, rip = 8 registers */
typedef long jmp_buf[8];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val) __attribute__((noreturn));

#endif
