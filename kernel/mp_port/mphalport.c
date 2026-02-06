#include "py/mpconfig.h"

// Zig-exported serial functions
extern void serial_write_bytes(const char *ptr, unsigned long len);
extern unsigned char serial_read_byte(void);

// Receive single character (blocks until data available)
int mp_hal_stdin_rx_chr(void) {
    return (int)serial_read_byte();
}

// Send string of given length
mp_uint_t mp_hal_stdout_tx_strn(const char *str, mp_uint_t len) {
    serial_write_bytes(str, len);
    return len;
}
