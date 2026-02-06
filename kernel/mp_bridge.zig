const serial = @import("serial.zig");
const builtin = @import("builtin");

// --- Exported functions for MicroPython C code to call ---

export fn serial_write_bytes(ptr: [*]const u8, len: usize) callconv(.c) void {
    if (len == 0) return;
    for (ptr[0..len]) |b| {
        if (b == '\n') {
            serial.writeByte('\r');
        }
        serial.writeByte(b);
    }
}

export fn serial_read_byte() callconv(.c) u8 {
    // Block until data available
    while (!serial.rxReady()) {
        if (comptime builtin.cpu.arch == .x86_64) {
            asm volatile ("pause");
        }
    }
    return serial.readByte();
}

export fn kernel_ticks_ms() callconv(.c) u64 {
    // rdtsc-based milliseconds (approximate: assume ~2GHz TSC)
    if (comptime builtin.cpu.arch == .x86_64) {
        var lo: u32 = 0;
        var hi: u32 = 0;
        asm volatile ("rdtsc"
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
        );
        const tsc = (@as(u64, hi) << 32) | @as(u64, lo);
        return tsc / 2_000_000; // ~2GHz TSC -> ms
    }
    return 0;
}

// --- MicroPython C API declarations ---
// Use opaque pointers to avoid Zig struct type mismatches with C types

extern fn mp_init() callconv(.c) void;
extern fn mp_deinit() callconv(.c) void;

// do_str implemented in C to avoid complex Zig-C interop
extern fn mp_do_str(src: [*]const u8, len: usize) callconv(.c) void;

// GC
extern fn gc_init(start: [*]u8, end: [*]u8) callconv(.c) void;
extern fn gc_collect_start() callconv(.c) void;
extern fn gc_collect_root(ptrs: *anyopaque, len: usize) callconv(.c) void;
extern fn gc_collect_end() callconv(.c) void;

// GC heap — separate from kernel ABI heap and libc shim heap
var mp_gc_heap: [4 * 1024 * 1024]u8 align(16) = undefined;

// Stack top for GC root scanning
var stack_top_ptr: usize = 0;

pub fn runMicroPython(source: []const u8) void {
    serial.writeAll("micropython: init\n");

    // Record stack top for GC
    var stack_dummy: u8 = 0;
    stack_top_ptr = @intFromPtr(&stack_dummy);

    // Initialize GC heap
    const heap_start: [*]u8 = @ptrCast(&mp_gc_heap);
    const heap_end: [*]u8 = @ptrFromInt(@intFromPtr(heap_start) + mp_gc_heap.len);
    gc_init(heap_start, heap_end);

    mp_init();
    mp_do_str(source.ptr, source.len);
    mp_deinit();

    serial.writeAll("micropython: done\n");
}

// GC collect — called by MicroPython's gc_collect
export fn gc_collect() callconv(.c) void {
    gc_collect_start();
    var dummy: usize = 0;
    const sp = @intFromPtr(&dummy);
    if (stack_top_ptr > sp and sp != 0) {
        const n_words = (stack_top_ptr - sp) / @sizeOf(usize);
        if (n_words > 0) {
            gc_collect_root(@ptrFromInt(sp), n_words);
        }
    }
    gc_collect_end();
}
