/*
 * MicroPython 'ukernel' module — exposes kernel ABI to Python.
 *
 * Python usage:
 *   import ukernel
 *   ukernel.log("hello from python")
 *   ms = ukernel.time_ms()
 *   ukernel.sleep_ms(100)
 *   sock = ukernel.net_udp_socket()
 *   ukernel.net_connect(sock, "172.16.0.1", 9000)
 *   ukernel.net_send(sock, b"hello")
 *   ukernel.net_close(sock)
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

extern unsigned int net_socket(unsigned int domain, unsigned int type,
                               unsigned int protocol, unsigned long *handle_out);
extern unsigned int net_bind(unsigned long sock, unsigned long addr_ptr, unsigned int addr_len);
extern unsigned int net_connect(unsigned long sock, unsigned long addr_ptr, unsigned int addr_len);
extern unsigned int net_send(unsigned long sock, unsigned long buf_ptr,
                             unsigned long len, unsigned int flags, unsigned long *wrote_out);
extern unsigned int net_recv(unsigned long sock, unsigned long buf_ptr,
                             unsigned long len, unsigned int flags, unsigned long *read_out);
extern unsigned int net_close(unsigned long sock);

extern unsigned long long kernel_ticks_ms(void);
extern void serial_write_bytes(const char *ptr, unsigned long len);

/* Capability constants */
#define ABI_CAP_LOG  1
#define ABI_CAP_TIME 2
#define ABI_CAP_TASK 3
#define ABI_CAP_MEM  4
#define ABI_CAP_IO   5
#define ABI_CAP_NET  7

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

/* --- Networking functions --- */

/* Helper: parse "a.b.c.d" IP string into 4-byte array, return 0 on success */
static int parse_ip(const char *s, size_t len, unsigned char ip[4]) {
    unsigned int parts[4] = {0, 0, 0, 0};
    int part = 0;
    size_t i;
    for (i = 0; i < len && part < 4; i++) {
        if (s[i] == '.') {
            part++;
        } else if (s[i] >= '0' && s[i] <= '9') {
            parts[part] = parts[part] * 10 + (s[i] - '0');
            if (parts[part] > 255) return -1;
        } else {
            return -1;
        }
    }
    if (part != 3) return -1;
    for (int j = 0; j < 4; j++) ip[j] = (unsigned char)parts[j];
    return 0;
}

/* Build net_addr_v4_t: ip[4] + port(u16 big-endian) = 6 bytes */
static void build_addr(unsigned char buf[6], const unsigned char ip[4], unsigned int port) {
    buf[0] = ip[0]; buf[1] = ip[1]; buf[2] = ip[2]; buf[3] = ip[3];
    buf[4] = (unsigned char)(port >> 8);
    buf[5] = (unsigned char)(port & 0xFF);
}

/* ukernel.net_udp_socket() — create a UDP socket, returns handle */
static mp_obj_t mod_ukernel_net_udp_socket(void) {
    unsigned long handle = 0;
    unsigned int rc = net_socket(2, 2, 17, &handle); /* AF_INET, SOCK_DGRAM, UDP */
    if (rc != 0) mp_raise_OSError((int)rc);
    return mp_obj_new_int_from_uint((mp_uint_t)handle);
}
static MP_DEFINE_CONST_FUN_OBJ_0(mod_ukernel_net_udp_socket_obj, mod_ukernel_net_udp_socket);

/* ukernel.net_bind(sock, ip_str, port) */
static mp_obj_t mod_ukernel_net_bind(mp_obj_t sock_obj, mp_obj_t ip_obj, mp_obj_t port_obj) {
    unsigned long sock = (unsigned long)mp_obj_get_int(sock_obj);
    size_t ip_len;
    const char *ip_str = mp_obj_str_get_data(ip_obj, &ip_len);
    unsigned int port = (unsigned int)mp_obj_get_int(port_obj);

    unsigned char ip[4];
    if (parse_ip(ip_str, ip_len, ip) != 0) {
        mp_raise_ValueError(MP_ERROR_TEXT("invalid IP address"));
    }

    unsigned char addr[6];
    build_addr(addr, ip, port);

    unsigned int rc = net_bind(sock, (unsigned long)addr, 6);
    if (rc != 0) mp_raise_OSError((int)rc);
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_3(mod_ukernel_net_bind_obj, mod_ukernel_net_bind);

/* ukernel.net_connect(sock, ip_str, port) */
static mp_obj_t mod_ukernel_net_connect(mp_obj_t sock_obj, mp_obj_t ip_obj, mp_obj_t port_obj) {
    unsigned long sock = (unsigned long)mp_obj_get_int(sock_obj);
    size_t ip_len;
    const char *ip_str = mp_obj_str_get_data(ip_obj, &ip_len);
    unsigned int port = (unsigned int)mp_obj_get_int(port_obj);

    unsigned char ip[4];
    if (parse_ip(ip_str, ip_len, ip) != 0) {
        mp_raise_ValueError(MP_ERROR_TEXT("invalid IP address"));
    }

    unsigned char addr[6];
    build_addr(addr, ip, port);

    unsigned int rc = net_connect(sock, (unsigned long)addr, 6);
    if (rc != 0) mp_raise_OSError((int)rc);
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_3(mod_ukernel_net_connect_obj, mod_ukernel_net_connect);

/* ukernel.net_send(sock, data) → bytes_sent */
static mp_obj_t mod_ukernel_net_send(mp_obj_t sock_obj, mp_obj_t data_obj) {
    unsigned long sock = (unsigned long)mp_obj_get_int(sock_obj);
    mp_buffer_info_t buf_info;
    mp_get_buffer_raise(data_obj, &buf_info, MP_BUFFER_READ);

    unsigned long wrote = 0;
    unsigned int rc = net_send(sock, (unsigned long)buf_info.buf, buf_info.len, 0, &wrote);
    if (rc != 0) mp_raise_OSError((int)rc);
    return mp_obj_new_int_from_uint((mp_uint_t)wrote);
}
static MP_DEFINE_CONST_FUN_OBJ_2(mod_ukernel_net_send_obj, mod_ukernel_net_send);

/* ukernel.net_recv(sock, bufsize) → bytes or None */
static mp_obj_t mod_ukernel_net_recv(mp_obj_t sock_obj, mp_obj_t size_obj) {
    unsigned long sock = (unsigned long)mp_obj_get_int(sock_obj);
    mp_int_t bufsize = mp_obj_get_int(size_obj);
    if (bufsize <= 0 || bufsize > 2048) bufsize = 2048;

    unsigned char buf[2048];
    unsigned long nread = 0;
    unsigned int rc = net_recv(sock, (unsigned long)buf, (unsigned long)bufsize, 0, &nread);
    if (rc == 9) { /* ERR_WOULD_BLOCK */
        return mp_const_none;
    }
    if (rc != 0) mp_raise_OSError((int)rc);
    return mp_obj_new_bytes(buf, (size_t)nread);
}
static MP_DEFINE_CONST_FUN_OBJ_2(mod_ukernel_net_recv_obj, mod_ukernel_net_recv);

/* ukernel.net_close(sock) */
static mp_obj_t mod_ukernel_net_close(mp_obj_t sock_obj) {
    unsigned long sock = (unsigned long)mp_obj_get_int(sock_obj);
    unsigned int rc = net_close(sock);
    if (rc != 0) mp_raise_OSError((int)rc);
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(mod_ukernel_net_close_obj, mod_ukernel_net_close);

/* Module globals */
static const mp_rom_map_elem_t mp_module_ukernel_globals_table[] = {
    { MP_ROM_QSTR(MP_QSTR___name__), MP_ROM_QSTR(MP_QSTR_ukernel) },
    { MP_ROM_QSTR(MP_QSTR_log), MP_ROM_PTR(&mod_ukernel_log_obj) },
    { MP_ROM_QSTR(MP_QSTR_time_ms), MP_ROM_PTR(&mod_ukernel_time_ms_obj) },
    { MP_ROM_QSTR(MP_QSTR_sleep_ms), MP_ROM_PTR(&mod_ukernel_sleep_ms_obj) },
    { MP_ROM_QSTR(MP_QSTR_version), MP_ROM_PTR(&mod_ukernel_version_obj) },

    /* Networking */
    { MP_ROM_QSTR(MP_QSTR_net_udp_socket), MP_ROM_PTR(&mod_ukernel_net_udp_socket_obj) },
    { MP_ROM_QSTR(MP_QSTR_net_bind), MP_ROM_PTR(&mod_ukernel_net_bind_obj) },
    { MP_ROM_QSTR(MP_QSTR_net_connect), MP_ROM_PTR(&mod_ukernel_net_connect_obj) },
    { MP_ROM_QSTR(MP_QSTR_net_send), MP_ROM_PTR(&mod_ukernel_net_send_obj) },
    { MP_ROM_QSTR(MP_QSTR_net_recv), MP_ROM_PTR(&mod_ukernel_net_recv_obj) },
    { MP_ROM_QSTR(MP_QSTR_net_close), MP_ROM_PTR(&mod_ukernel_net_close_obj) },

    /* Capability constants */
    { MP_ROM_QSTR(MP_QSTR_CAP_LOG), MP_ROM_INT(ABI_CAP_LOG) },
    { MP_ROM_QSTR(MP_QSTR_CAP_TIME), MP_ROM_INT(ABI_CAP_TIME) },
    { MP_ROM_QSTR(MP_QSTR_CAP_TASK), MP_ROM_INT(ABI_CAP_TASK) },
    { MP_ROM_QSTR(MP_QSTR_CAP_MEM), MP_ROM_INT(ABI_CAP_MEM) },
    { MP_ROM_QSTR(MP_QSTR_CAP_IO), MP_ROM_INT(ABI_CAP_IO) },
    { MP_ROM_QSTR(MP_QSTR_CAP_NET), MP_ROM_INT(ABI_CAP_NET) },
};

static MP_DEFINE_CONST_DICT(mp_module_ukernel_globals, mp_module_ukernel_globals_table);

const mp_obj_module_t mp_module_ukernel = {
    .base = { &mp_type_module },
    .globals = (mp_obj_dict_t *)&mp_module_ukernel_globals,
};

MP_REGISTER_MODULE(MP_QSTR_ukernel, mp_module_ukernel);
