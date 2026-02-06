/*
 * MicroPython 'ukernel' module — exposes kernel ABI to Python.
 *
 * Python usage:
 *   import ukernel
 *   ukernel.log("hello from python")
 *   ms = ukernel.time_ms()
 *   ukernel.sleep_ms(100)
 */

#include "py/runtime.h"
#include "py/obj.h"

/* Zig ABI exports (C calling convention) */
extern unsigned int log_write(unsigned int level, unsigned long msg_ptr, unsigned long len);
extern unsigned int time_now(unsigned long *out);
extern unsigned int io_poll(void *handles, unsigned int count,
                            unsigned long timeout, unsigned long events_out,
                            unsigned int *count_out);
extern unsigned int cap_acquire(unsigned int kind, unsigned long *handle_out);
extern unsigned int cap_enter(unsigned long *caps, unsigned int cap_count);
extern unsigned int cap_exit(void);
extern unsigned int io_open(unsigned long path_ptr, unsigned int flags, unsigned long *handle_out);
extern unsigned int io_write(unsigned long handle, unsigned long buf_ptr,
                             unsigned long len, unsigned long *wrote_out);
extern unsigned int io_close(unsigned long handle);

extern unsigned long long kernel_ticks_ms(void);
extern void serial_write_bytes(const char *ptr, unsigned long len);

/* Capability constants */
#define ABI_CAP_LOG  1
#define ABI_CAP_TIME 2
#define ABI_CAP_TASK 3
#define ABI_CAP_MEM  4
#define ABI_CAP_IO   5

/* ukernel.log(msg, level=0) — write message to serial via ABI log_write */
static mp_obj_t mod_ukernel_log(size_t n_args, const mp_obj_t *args) {
    size_t len;
    const char *msg = mp_obj_str_get_data(args[0], &len);
    unsigned int level = 0;
    if (n_args > 1) {
        level = (unsigned int)mp_obj_get_int(args[1]);
    }

    /* Write via kernel serial (bypass ABI caps for simplicity in demo) */
    serial_write_bytes(msg, len);
    serial_write_bytes("\n", 1);

    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(mod_ukernel_log_obj, 1, 2, mod_ukernel_log);

/* ukernel.time_ms() — return milliseconds since boot */
static mp_obj_t mod_ukernel_time_ms(void) {
    unsigned long long ms = kernel_ticks_ms();
    return mp_obj_new_int_from_uint((mp_uint_t)ms);
}
static MP_DEFINE_CONST_FUN_OBJ_0(mod_ukernel_time_ms_obj, mod_ukernel_time_ms);

/* ukernel.sleep_ms(ms) — busy-wait for ms milliseconds using io_poll */
static mp_obj_t mod_ukernel_sleep_ms(mp_obj_t ms_obj) {
    mp_int_t ms = mp_obj_get_int(ms_obj);
    if (ms <= 0) return mp_const_none;

    /* Use rdtsc-based spin wait via io_poll(count=0, timeout) */
    unsigned long long start = kernel_ticks_ms();
    while ((kernel_ticks_ms() - start) < (unsigned long long)ms) {
        __asm__ volatile ("pause");
    }
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(mod_ukernel_sleep_ms_obj, mod_ukernel_sleep_ms);

/* ukernel.version() — return ABI version string */
static mp_obj_t mod_ukernel_version(void) {
    return mp_obj_new_str("0.2.0", 5);
}
static MP_DEFINE_CONST_FUN_OBJ_0(mod_ukernel_version_obj, mod_ukernel_version);

/* Module globals */
static const mp_rom_map_elem_t mp_module_ukernel_globals_table[] = {
    { MP_ROM_QSTR(MP_QSTR___name__), MP_ROM_QSTR(MP_QSTR_ukernel) },
    { MP_ROM_QSTR(MP_QSTR_log), MP_ROM_PTR(&mod_ukernel_log_obj) },
    { MP_ROM_QSTR(MP_QSTR_time_ms), MP_ROM_PTR(&mod_ukernel_time_ms_obj) },
    { MP_ROM_QSTR(MP_QSTR_sleep_ms), MP_ROM_PTR(&mod_ukernel_sleep_ms_obj) },
    { MP_ROM_QSTR(MP_QSTR_version), MP_ROM_PTR(&mod_ukernel_version_obj) },

    /* Capability constants */
    { MP_ROM_QSTR(MP_QSTR_CAP_LOG), MP_ROM_INT(ABI_CAP_LOG) },
    { MP_ROM_QSTR(MP_QSTR_CAP_TIME), MP_ROM_INT(ABI_CAP_TIME) },
    { MP_ROM_QSTR(MP_QSTR_CAP_TASK), MP_ROM_INT(ABI_CAP_TASK) },
    { MP_ROM_QSTR(MP_QSTR_CAP_MEM), MP_ROM_INT(ABI_CAP_MEM) },
    { MP_ROM_QSTR(MP_QSTR_CAP_IO), MP_ROM_INT(ABI_CAP_IO) },
};

static MP_DEFINE_CONST_DICT(mp_module_ukernel_globals, mp_module_ukernel_globals_table);

const mp_obj_module_t mp_module_ukernel = {
    .base = { &mp_type_module },
    .globals = (mp_obj_dict_t *)&mp_module_ukernel_globals,
};

MP_REGISTER_MODULE(MP_QSTR_ukernel, mp_module_ukernel);
