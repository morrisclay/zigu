#include <stdint.h>

// Use the minimal starting configuration (disables all optional features).
#define MICROPY_CONFIG_ROM_LEVEL (MICROPY_CONFIG_ROM_LEVEL_MINIMUM)

#define MICROPY_ENABLE_COMPILER     (1)
#define MICROPY_ENABLE_GC           (1)
#define MICROPY_HELPER_REPL         (0)
#define MICROPY_ERROR_REPORTING     (MICROPY_ERROR_REPORTING_TERSE)
#define MICROPY_ALLOC_PATH_MAX      (256)
#define MICROPY_ALLOC_PARSE_CHUNK_INIT (16)

// Disable features we don't need in freestanding kernel
#define MICROPY_PY_BUILTINS_STR_UNICODE (0)
#define MICROPY_PY_SYS              (1)
#define MICROPY_PY_IO               (0)
#define MICROPY_PY_ASYNCIO          (0)
#define MICROPY_ENABLE_EXTERNAL_IMPORT (0)
#define MICROPY_MODULE_FROZEN_MPY   (0)
#define MICROPY_READER_POSIX        (0)
#define MICROPY_READER_VFS          (0)
#define MICROPY_VFS                 (0)

// Disable REPL-related features
#define MICROPY_REPL_EVENT_DRIVEN   (0)

// Type definitions for x86_64 freestanding
typedef intptr_t mp_int_t;
typedef uintptr_t mp_uint_t;
typedef long mp_off_t;

// Heap size: 4MB for MicroPython GC
#ifndef MICROPY_HEAP_SIZE
#define MICROPY_HEAP_SIZE (4 * 1024 * 1024)
#endif

// Board identification
#define MICROPY_HW_BOARD_NAME "zigu-ukernel"
#define MICROPY_HW_MCU_NAME "x86_64"

// alloca: provide our own since we have no libc
void *alloca(unsigned long size);
#define alloca __builtin_alloca

// Port state
#define MP_STATE_PORT MP_STATE_VM
