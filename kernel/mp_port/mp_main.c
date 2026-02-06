/*
 * MicroPython port entry point and support functions for Zigu kernel.
 * Provides: mp_do_str, mp_lexer_new_from_file, mp_import_stat, nlr_jump_fail
 */

#include <string.h>
#include "py/compile.h"
#include "py/runtime.h"
#include "py/gc.h"
#include "py/mperrno.h"
#include "py/builtin.h"

extern void serial_write_bytes(const char *ptr, unsigned long len);

/* Compile and execute a Python source string */
void mp_do_str(const char *src, size_t len) {
    nlr_buf_t nlr;
    if (nlr_push(&nlr) == 0) {
        mp_lexer_t *lex = mp_lexer_new_from_str_len(MP_QSTR__lt_stdin_gt_, src, len, 0);
        qstr source_name = lex->source_name;
        mp_parse_tree_t parse_tree = mp_parse(lex, MP_PARSE_FILE_INPUT);
        mp_obj_t module_fun = mp_compile(&parse_tree, source_name, false);
        mp_call_function_0(module_fun);
        nlr_pop();
    } else {
        /* Uncaught exception — print it */
        mp_obj_print_exception(&mp_plat_print, (mp_obj_t)nlr.ret_val);
    }
}

/* Required by MicroPython — we don't support loading from files */
mp_lexer_t *mp_lexer_new_from_file(qstr filename) {
    mp_raise_OSError(MP_ENOENT);
}

/* Required by MicroPython — report no files exist */
mp_import_stat_t mp_import_stat(const char *path) {
    return MP_IMPORT_STAT_NO_EXIST;
}

/* Called when NLR (non-local return) jump fails — should never happen */
void nlr_jump_fail(void *val) {
    (void)val;
    const char *msg = "nlr_jump_fail\n";
    serial_write_bytes(msg, 14);
    while (1) {
        __asm__ volatile ("hlt");
    }
}

void NORETURN __fatal_error(const char *msg) {
    serial_write_bytes(msg, strlen(msg));
    while (1) {
        __asm__ volatile ("hlt");
    }
}

#ifndef NDEBUG
void __assert_func(const char *file, int line, const char *func, const char *expr) {
    (void)file;
    (void)line;
    (void)func;
    const char *prefix = "assert fail: ";
    serial_write_bytes(prefix, 13);
    serial_write_bytes(expr, strlen(expr));
    serial_write_bytes("\n", 1);
    __fatal_error("assertion failed");
}
#endif
