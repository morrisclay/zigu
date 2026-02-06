// Hardware abstraction layer for Zigu uKernel port

// Serial I/O — implemented in mphalport.c, delegates to Zig serial exports
int mp_hal_stdin_rx_chr(void);
mp_uint_t mp_hal_stdout_tx_strn(const char *str, mp_uint_t len);

static inline mp_uint_t mp_hal_ticks_ms(void) {
    extern unsigned long long kernel_ticks_ms(void);
    return (mp_uint_t)kernel_ticks_ms();
}

static inline void mp_hal_set_interrupt_char(char c) {
    (void)c;
}
