const std = @import("std");
const serial = @import("serial.zig");
const builtin = @import("builtin");

pub const u8_t = u8;
pub const u16_t = u16;
pub const u32_t = u32;
pub const u64_t = u64;
pub const i32_t = i32;
pub const i64_t = i64;
pub const size_t = u64;
pub const time_ns = u64;
pub const handle_t = u64;
pub const ptr_t = u64;
pub const result_t = u32;

pub const OK: result_t = 0;
pub const ERR_INVALID: result_t = 1;
pub const ERR_NOENT: result_t = 2;
pub const ERR_NOMEM: result_t = 3;
pub const ERR_BUSY: result_t = 4;
pub const ERR_TIMEOUT: result_t = 5;
pub const ERR_IO: result_t = 6;
pub const ERR_UNSUPPORTED: result_t = 7;
pub const ERR_PERMISSION: result_t = 8;
pub const ERR_WOULD_BLOCK: result_t = 9;
pub const ERR_CLOSED: result_t = 10;

pub const FEAT_VSOCK: u32 = 1 << 0;
pub const FEAT_RNG: u32 = 1 << 1;
pub const FEAT_BALLOON: u32 = 1 << 2;
pub const FEAT_SNAPSHOT: u32 = 1 << 3;
pub const FEAT_TRACING: u32 = 1 << 4;

pub const HANDLE_TASK: u8 = 0x01;
pub const HANDLE_IO: u8 = 0x02;
pub const HANDLE_IPC: u8 = 0x03;
pub const HANDLE_NET: u8 = 0x04;
pub const HANDLE_CAP: u8 = 0x05;
pub const HANDLE_SPAN: u8 = 0x06;

pub const CAP_LOG: u32 = 1;
pub const CAP_TIME: u32 = 2;
pub const CAP_TASK: u32 = 3;
pub const CAP_MEM: u32 = 4;
pub const CAP_IO: u32 = 5;
pub const CAP_IPC: u32 = 6;
pub const CAP_NET: u32 = 7;
pub const CAP_TRACE: u32 = 8;

const ABI_MAJOR: u32 = 0;
const ABI_MINOR: u32 = 2;
const ABI_PATCH: u32 = 0;

const CapKind = enum(u32) {
    log = CAP_LOG,
    time = CAP_TIME,
    task = CAP_TASK,
    mem = CAP_MEM,
    io = CAP_IO,
    ipc = CAP_IPC,
    net = CAP_NET,
    trace = CAP_TRACE,
};

const MaxCaps = 8;
const MaxIpc = 16;
const MaxNet = 16;
const MaxIo = 32;

var policy_mask: u32 = 0;
var issued_mask: u32 = 0;
var active_mask: u32 = 0;
var cap_gen: [MaxCaps]u16 = [_]u16{0} ** MaxCaps;

const HandleEntry = struct {
    in_use: bool = false,
    gen: u16 = 1,
};

var ipc_table: [MaxIpc]HandleEntry = [_]HandleEntry{.{}} ** MaxIpc;
var net_table: [MaxNet]HandleEntry = [_]HandleEntry{.{}} ** MaxNet;
var io_table: [MaxIo]HandleEntry = [_]HandleEntry{.{}} ** MaxIo;

// Memory allocator state
const HEAP_SIZE: usize = 1024 * 1024; // 1MB
var heap: [HEAP_SIZE]u8 align(16) = undefined;
var heap_top: usize = 0;

const MaxAllocs = 256;
const AllocEntry = struct {
    base: usize = 0,
    size: usize = 0,
    in_use: bool = false,
};
var alloc_table: [MaxAllocs]AllocEntry = [_]AllocEntry{.{}} ** MaxAllocs;

const AuditEnabled = !builtin.is_test;

fn audit(msg: []const u8) void {
    if (!AuditEnabled) return;
    serial.writeAll(msg);
}

fn kindIndex(kind: CapKind) usize {
    return @intCast(@intFromEnum(kind) - 1);
}

fn makeCap(kind: CapKind) handle_t {
    const tag: handle_t = @as(handle_t, HANDLE_CAP) << 56;
    const k: handle_t = (@as(handle_t, @intFromEnum(kind)) & 0xFF) << 48;
    const gen: handle_t = cap_gen[kindIndex(kind)];
    return tag | k | gen;
}

fn capKindFrom(handle: handle_t) ?CapKind {
    const tag: u8 = @intCast(handle >> 56);
    if (tag != HANDLE_CAP) return null;
    const id: u32 = @intCast((handle >> 48) & 0xFF);
    return switch (id) {
        CAP_LOG => .log,
        CAP_TIME => .time,
        CAP_TASK => .task,
        CAP_MEM => .mem,
        CAP_IO => .io,
        CAP_IPC => .ipc,
        CAP_NET => .net,
        CAP_TRACE => .trace,
        else => null,
    };
}

fn capGenFrom(handle: handle_t) u16 {
    return @intCast(handle & 0xFFFF);
}

fn capBit(kind: CapKind) u32 {
    const id = @intFromEnum(kind);
    return @as(u32, 1) << @as(u5, @intCast(id - 1));
}

fn allow(kind: CapKind) bool {
    return (active_mask & capBit(kind)) != 0;
}

fn makeHandle(tag: u8, id: u32, gen: u16) handle_t {
    const t: handle_t = @as(handle_t, tag) << 56;
    const idx: handle_t = (@as(handle_t, id) & 0xFFFF_FF) << 32;
    const g: handle_t = @as(handle_t, gen);
    return t | idx | g;
}

fn handleTag(handle: handle_t) u8 {
    return @intCast(handle >> 56);
}

fn handleId(handle: handle_t) u32 {
    return @intCast((handle >> 32) & 0xFFFF_FF);
}

fn handleGen(handle: handle_t) u16 {
    return @intCast(handle & 0xFFFF);
}

fn allocHandle(table: []HandleEntry, tag: u8, handle_out: *handle_t) result_t {
    var i: u32 = 0;
    while (i < table.len) : (i += 1) {
        if (!table[i].in_use) {
            table[i].in_use = true;
            const gen = table[i].gen;
            handle_out.* = makeHandle(tag, i, gen);
            return OK;
        }
    }
    return ERR_BUSY;
}

fn validateHandle(table: []HandleEntry, tag: u8, handle: handle_t) ?u32 {
    if (handleTag(handle) != tag) return null;
    const id = handleId(handle);
    if (id >= table.len) return null;
    if (!table[id].in_use) return null;
    if (table[id].gen != handleGen(handle)) return null;
    return id;
}

fn closeHandle(table: []HandleEntry, tag: u8, handle: handle_t) result_t {
    const id = validateHandle(table, tag, handle) orelse return ERR_INVALID;
    table[id].in_use = false;
    table[id].gen +%= 1;
    return OK;
}

fn rdtsc() u64 {
    if (builtin.cpu.arch != .x86_64) return 0;
    var lo: u32 = 0;
    var hi: u32 = 0;
    asm volatile ("rdtsc" : [lo] "={eax}" (lo), [hi] "={edx}" (hi));
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

export fn cap_acquire(kind: u32, handle_out: ?*handle_t) callconv(.c) result_t {
    if (handle_out == null) return ERR_INVALID;
    switch (kind) {
        CAP_LOG => {
            if ((policy_mask & capBit(.log)) == 0) return ERR_PERMISSION;
            handle_out.?.* = makeCap(.log);
            issued_mask |= capBit(.log);
            audit("cap: acquire log\n");
            return OK;
        },
        CAP_TIME => {
            if ((policy_mask & capBit(.time)) == 0) return ERR_PERMISSION;
            handle_out.?.* = makeCap(.time);
            issued_mask |= capBit(.time);
            audit("cap: acquire time\n");
            return OK;
        },
        CAP_TASK => {
            if ((policy_mask & capBit(.task)) == 0) return ERR_PERMISSION;
            handle_out.?.* = makeCap(.task);
            issued_mask |= capBit(.task);
            audit("cap: acquire task\n");
            return OK;
        },
        CAP_MEM => {
            if ((policy_mask & capBit(.mem)) == 0) return ERR_PERMISSION;
            handle_out.?.* = makeCap(.mem);
            issued_mask |= capBit(.mem);
            audit("cap: acquire mem\n");
            return OK;
        },
        CAP_IO, CAP_IPC, CAP_NET, CAP_TRACE => return ERR_UNSUPPORTED,
        else => return ERR_INVALID,
    }
}

export fn cap_drop(cap: handle_t) callconv(.c) result_t {
    const k = capKindFrom(cap) orelse return ERR_INVALID;
    const idx = kindIndex(k);
    cap_gen[idx] +%= 1;
    issued_mask &= ~capBit(k);
    active_mask &= ~capBit(k);
    audit("cap: drop\n");
    return OK;
}

export fn cap_enter(caps: ?*handle_t, cap_count: u32) callconv(.c) result_t {
    if (cap_count > MaxCaps) return ERR_INVALID;
    if (cap_count > 0 and caps == null) return ERR_INVALID;
    const cap_ptr: [*]handle_t = if (caps) |p| @ptrCast(p) else undefined;
    var mask: u32 = 0;
    var i: u32 = 0;
    while (i < cap_count) : (i += 1) {
        const handle = cap_ptr[i];
        const k = capKindFrom(handle) orelse return ERR_INVALID;
        const bit = capBit(k);
        if (capGenFrom(handle) != cap_gen[kindIndex(k)]) return ERR_PERMISSION;
        if ((issued_mask & bit) == 0) return ERR_PERMISSION;
        if ((policy_mask & bit) == 0) return ERR_PERMISSION;
        mask |= bit;
    }
    active_mask = mask;
    audit("cap: enter\n");
    return OK;
}

export fn cap_exit() callconv(.c) result_t {
    active_mask = 0;
    audit("cap: exit\n");
    return OK;
}

pub fn setCapPolicy(mask: u32) void {
    policy_mask = mask;
    issued_mask &= mask;
    active_mask &= mask;
}

pub fn resetCapsForWorkload(mask: u32) void {
    policy_mask = mask;
    issued_mask = 0;
    active_mask = 0;
    audit("cap: reset\n");
}

export fn abi_version(major: ?*u32, minor: ?*u32, patch: ?*u32) callconv(.c) result_t {
    if (major == null or minor == null or patch == null) return ERR_INVALID;
    major.?.* = ABI_MAJOR;
    minor.?.* = ABI_MINOR;
    patch.?.* = ABI_PATCH;
    return OK;
}

export fn abi_features(bitset_out: ?*u64) callconv(.c) result_t {
    if (bitset_out == null) return ERR_INVALID;
    bitset_out.?.* = 0;
    return OK;
}

export fn abi_feature_enabled(feature_id: u32, enabled_out: ?*u32) callconv(.c) result_t {
    if (enabled_out == null) return ERR_INVALID;
    const features: u64 = 0;
    if (feature_id >= 64) {
        enabled_out.?.* = 0;
        return OK;
    }
    const shift: u6 = @intCast(feature_id);
    const enabled = ((features >> shift) & 1) != 0;
    enabled_out.?.* = if (enabled) 1 else 0;
    return OK;
}

export fn task_spawn(_: ptr_t, _: ptr_t, caps: ?*handle_t, cap_count: u32, _: u32, _: ?*handle_t) callconv(.c) result_t {
    if (!allow(.task)) return ERR_PERMISSION;
    if (cap_count > 0 and caps == null) return ERR_INVALID;
    const cap_ptr: [*]handle_t = if (caps) |p| @ptrCast(p) else undefined;
    var i: u32 = 0;
    while (i < cap_count) : (i += 1) {
        const handle = cap_ptr[i];
        const k = capKindFrom(handle) orelse return ERR_INVALID;
        const bit = capBit(k);
        if ((active_mask & bit) == 0) return ERR_PERMISSION;
        if (capGenFrom(handle) != cap_gen[kindIndex(k)]) return ERR_PERMISSION;
    }
    return ERR_UNSUPPORTED;
}

export fn task_yield() callconv(.c) result_t {
    if (!allow(.task)) return ERR_PERMISSION;
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("pause");
    }
    return OK;
}

export fn task_sleep(duration: time_ns) callconv(.c) result_t {
    if (!allow(.task)) return ERR_PERMISSION;
    if (duration == 0) return OK;
    return ERR_UNSUPPORTED;
}

export fn task_set_priority(_: handle_t, _: u32) callconv(.c) result_t {
    if (!allow(.task)) return ERR_PERMISSION;
    return ERR_UNSUPPORTED;
}

export fn task_get_stats(_: handle_t, _: ptr_t) callconv(.c) result_t {
    if (!allow(.task)) return ERR_PERMISSION;
    return ERR_UNSUPPORTED;
}

export fn task_exit(_: i32) callconv(.c) result_t {
    if (!allow(.task)) return ERR_PERMISSION;
    while (true) {
        if (comptime builtin.cpu.arch == .x86_64) {
            asm volatile ("hlt");
        }
    }
}

export fn time_now(out: ?*time_ns) callconv(.c) result_t {
    if (!allow(.time)) return ERR_PERMISSION;
    if (out == null) return ERR_INVALID;
    out.?.* = rdtsc();
    return OK;
}

export fn time_deadline(_: time_ns, _: ?*handle_t) callconv(.c) result_t {
    if (!allow(.time)) return ERR_PERMISSION;
    return ERR_UNSUPPORTED;
}

export fn mem_alloc(bytes: size_t, flags: u32, out_ptr: ?*ptr_t) callconv(.c) result_t {
    if (!allow(.mem)) return ERR_PERMISSION;
    if (out_ptr == null) return ERR_INVALID;
    if (bytes == 0) return ERR_INVALID;
    _ = flags; // MEM_ZEROED etc. - ignore for now

    // Align to 16 bytes
    const aligned: usize = (bytes + 15) & ~@as(usize, 15);
    if (heap_top + aligned > HEAP_SIZE) return ERR_NOMEM;

    // Find free slot in alloc table
    var slot: ?usize = null;
    for (alloc_table, 0..) |entry, i| {
        if (!entry.in_use) {
            slot = i;
            break;
        }
    }
    if (slot == null) return ERR_NOMEM;

    const ptr = @intFromPtr(&heap[heap_top]);
    alloc_table[slot.?] = .{
        .base = ptr,
        .size = aligned,
        .in_use = true,
    };
    heap_top += aligned;

    out_ptr.?.* = ptr;
    audit("mem: alloc\n");
    return OK;
}

export fn mem_free(ptr: ptr_t) callconv(.c) result_t {
    if (!allow(.mem)) return ERR_PERMISSION;
    if (ptr == 0) return ERR_INVALID;

    // Find allocation in table
    for (&alloc_table) |*entry| {
        if (entry.in_use and entry.base == ptr) {
            entry.in_use = false;
            // If this was the last allocation, reclaim space
            if (entry.base + entry.size == @intFromPtr(&heap[heap_top])) {
                heap_top -= entry.size;
            }
            audit("mem: free\n");
            return OK;
        }
    }
    return ERR_INVALID; // Not found or double-free
}

export fn mem_map(_: ptr_t, _: size_t, _: u32) callconv(.c) result_t {
    if (!allow(.mem)) return ERR_PERMISSION;
    return ERR_UNSUPPORTED;
}

export fn mem_share(_: ptr_t, _: size_t, _: ?*handle_t) callconv(.c) result_t {
    if (!allow(.mem)) return ERR_PERMISSION;
    return ERR_UNSUPPORTED;
}

export fn mem_unshare(_: handle_t) callconv(.c) result_t {
    if (!allow(.mem)) return ERR_PERMISSION;
    return ERR_UNSUPPORTED;
}

export fn io_open(path_ptr: ptr_t, flags: u32, handle_out: ?*handle_t) callconv(.c) result_t {
    if (!allow(.io)) return ERR_PERMISSION;
    _ = flags;
    if (handle_out == null) return ERR_INVALID;
    if (path_ptr == 0) return ERR_INVALID;
    return allocHandle(io_table[0..], HANDLE_IO, handle_out.?);
}

export fn io_read(io: handle_t, buf_ptr: ptr_t, len: size_t, read_out: ?*size_t) callconv(.c) result_t {
    if (!allow(.io)) return ERR_PERMISSION;
    if (validateHandle(io_table[0..], HANDLE_IO, io) == null) return ERR_INVALID;
    if (len > 0 and buf_ptr == 0) return ERR_INVALID;
    if (read_out != null) read_out.?.* = 0;
    return ERR_WOULD_BLOCK;
}

export fn io_write(io: handle_t, buf_ptr: ptr_t, len: size_t, wrote_out: ?*size_t) callconv(.c) result_t {
    if (!allow(.io)) return ERR_PERMISSION;
    if (validateHandle(io_table[0..], HANDLE_IO, io) == null) return ERR_INVALID;
    if (len > 0 and buf_ptr == 0) return ERR_INVALID;
    if (wrote_out != null) wrote_out.?.* = len;
    return OK;
}

export fn io_close(io: handle_t) callconv(.c) result_t {
    if (!allow(.io)) return ERR_PERMISSION;
    return closeHandle(io_table[0..], HANDLE_IO, io);
}

export fn io_poll(handles: ?*handle_t, count: u32, timeout: time_ns, events_out: ptr_t, count_out: ?*u32) callconv(.c) result_t {
    if (!allow(.io)) return ERR_PERMISSION;
    _ = handles;
    _ = count;
    _ = events_out;

    if (count_out != null) count_out.?.* = 0;

    if (timeout == 0) {
        return ERR_WOULD_BLOCK;
    }

    // Treat timeout as cycle budget for now (rdtsc-based).
    var start: time_ns = 0;
    if (time_now(&start) != OK) return ERR_UNSUPPORTED;

    var now: time_ns = 0;
    while (true) {
        if (time_now(&now) != OK) break;
        if (now - start >= timeout) break;
        if (comptime builtin.cpu.arch == .x86_64) {
            asm volatile ("pause");
        }
    }

    return ERR_TIMEOUT;
}

export fn ipc_channel_create(flags: u32, handle_out: ?*handle_t) callconv(.c) result_t {
    if (!allow(.ipc)) return ERR_PERMISSION;
    _ = flags;
    if (handle_out == null) return ERR_INVALID;
    return allocHandle(ipc_table[0..], HANDLE_IPC, handle_out.?);
}

export fn ipc_send(ch: handle_t, buf_ptr: ptr_t, len: size_t, flags: u32) callconv(.c) result_t {
    if (!allow(.ipc)) return ERR_PERMISSION;
    _ = flags;
    if (validateHandle(ipc_table[0..], HANDLE_IPC, ch) == null) return ERR_INVALID;
    if (len > 0 and buf_ptr == 0) return ERR_INVALID;
    return OK;
}

export fn ipc_recv(ch: handle_t, buf_ptr: ptr_t, len: size_t, read_out: ?*size_t, flags: u32) callconv(.c) result_t {
    if (!allow(.ipc)) return ERR_PERMISSION;
    _ = flags;
    if (validateHandle(ipc_table[0..], HANDLE_IPC, ch) == null) return ERR_INVALID;
    if (len > 0 and buf_ptr == 0) return ERR_INVALID;
    if (read_out != null) read_out.?.* = 0;
    return ERR_WOULD_BLOCK;
}

export fn ipc_close(ch: handle_t) callconv(.c) result_t {
    if (!allow(.ipc)) return ERR_PERMISSION;
    return closeHandle(ipc_table[0..], HANDLE_IPC, ch);
}

export fn net_socket(domain: u32, type_: u32, protocol: u32, handle_out: ?*handle_t) callconv(.c) result_t {
    if (!allow(.net)) return ERR_PERMISSION;
    _ = domain;
    _ = type_;
    _ = protocol;
    if (handle_out == null) return ERR_INVALID;
    return allocHandle(net_table[0..], HANDLE_NET, handle_out.?);
}

export fn net_bind(sock: handle_t, addr_ptr: ptr_t, addr_len: u32) callconv(.c) result_t {
    if (!allow(.net)) return ERR_PERMISSION;
    _ = addr_ptr;
    _ = addr_len;
    if (validateHandle(net_table[0..], HANDLE_NET, sock) == null) return ERR_INVALID;
    return OK;
}

export fn net_connect(sock: handle_t, addr_ptr: ptr_t, addr_len: u32) callconv(.c) result_t {
    if (!allow(.net)) return ERR_PERMISSION;
    _ = addr_ptr;
    _ = addr_len;
    if (validateHandle(net_table[0..], HANDLE_NET, sock) == null) return ERR_INVALID;
    return OK;
}

export fn net_send(sock: handle_t, buf_ptr: ptr_t, len: size_t, flags: u32, wrote_out: ?*size_t) callconv(.c) result_t {
    if (!allow(.net)) return ERR_PERMISSION;
    _ = flags;
    if (validateHandle(net_table[0..], HANDLE_NET, sock) == null) return ERR_INVALID;
    if (len > 0 and buf_ptr == 0) return ERR_INVALID;
    if (wrote_out != null) wrote_out.?.* = len;
    return OK;
}

export fn net_recv(sock: handle_t, buf_ptr: ptr_t, len: size_t, flags: u32, read_out: ?*size_t) callconv(.c) result_t {
    if (!allow(.net)) return ERR_PERMISSION;
    _ = flags;
    if (validateHandle(net_table[0..], HANDLE_NET, sock) == null) return ERR_INVALID;
    if (len > 0 and buf_ptr == 0) return ERR_INVALID;
    if (read_out != null) read_out.?.* = 0;
    return ERR_WOULD_BLOCK;
}

export fn net_close(sock: handle_t) callconv(.c) result_t {
    if (!allow(.net)) return ERR_PERMISSION;
    return closeHandle(net_table[0..], HANDLE_NET, sock);
}

export fn log_write(level: u32, msg_ptr: ptr_t, len: size_t) callconv(.c) result_t {
    if (!allow(.log)) return ERR_PERMISSION;
    if (len == 0) return OK;
    if (msg_ptr == 0) return ERR_INVALID;
    logPrefix(level);
    var i: u64 = 0;
    while (i < len) : (i += 1) {
        const byte_ptr = @as(*const u8, @ptrFromInt(msg_ptr + i));
        const b = byte_ptr.*;
        if (b == '\n') {
            serial.writeByte('\r');
        }
        serial.writeByte(b);
    }
    return OK;
}

export fn trace_span_begin(_: ptr_t, _: size_t, _: ?*handle_t) callconv(.c) result_t {
    if (!allow(.trace)) return ERR_PERMISSION;
    return ERR_UNSUPPORTED;
}

export fn trace_span_end(_: handle_t) callconv(.c) result_t {
    if (!allow(.trace)) return ERR_PERMISSION;
    return ERR_UNSUPPORTED;
}

export fn trace_event(_: handle_t, _: ptr_t, _: size_t, _: ptr_t, _: size_t) callconv(.c) result_t {
    if (!allow(.trace)) return ERR_PERMISSION;
    return ERR_UNSUPPORTED;
}

fn capMask(kind: u32) u32 {
    return @as(u32, 1) << @as(u5, @intCast(kind - 1));
}

fn logPrefix(level: u32) void {
    serial.writeAll("[log lvl=");
    writeU32Dec(level);
    serial.writeAll(" cap=0x");
    writeU32Hex(active_mask);
    serial.writeAll("] ");
}

fn writeU32Dec(value: u32) void {
    var buf: [10]u8 = undefined;
    var v = value;
    if (v == 0) {
        serial.writeByte('0');
        return;
    }
    var i: usize = 0;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast('0' + @as(u8, @intCast(v % 10)));
        i += 1;
    }
    while (i > 0) : (i -= 1) {
        serial.writeByte(buf[i - 1]);
    }
}

fn writeU32Hex(value: u32) void {
    var shift: i32 = 28;
    var started = false;
    while (shift >= 0) : (shift -= 4) {
        const nibble: u4 = @intCast((value >> @as(u5, @intCast(shift))) & 0xF);
        if (!started and nibble == 0 and shift != 0) {
            continue;
        }
        started = true;
        const n: u8 = @intCast(nibble);
        const ch: u8 = if (n < 10)
            @intCast('0' + n)
        else
            @intCast('a' + (n - 10));
        serial.writeByte(ch);
    }
    if (!started) serial.writeByte('0');
}

test "caps start empty and deny by default" {
    resetCapsForWorkload(0);

    var handle: handle_t = 0;
    try std.testing.expectEqual(ERR_PERMISSION, cap_acquire(CAP_LOG, &handle));

    var now: time_ns = 0;
    try std.testing.expectEqual(ERR_PERMISSION, time_now(&now));
}

test "policy allows acquire + enter + exit gating" {
    const policy = capMask(CAP_TIME);
    resetCapsForWorkload(policy);

    var handle: handle_t = 0;
    try std.testing.expectEqual(OK, cap_acquire(CAP_TIME, &handle));
    try std.testing.expectEqual(OK, cap_enter(&handle, 1));

    var now: time_ns = 0;
    try std.testing.expectEqual(OK, time_now(&now));

    try std.testing.expectEqual(OK, cap_exit());
    try std.testing.expectEqual(ERR_PERMISSION, time_now(&now));
}

test "policy blocks disallowed cap kinds" {
    const policy = capMask(CAP_LOG);
    resetCapsForWorkload(policy);

    var handle: handle_t = 0;
    try std.testing.expectEqual(ERR_PERMISSION, cap_acquire(CAP_TIME, &handle));
}

test "reset clears issued handles" {
    const policy = capMask(CAP_TIME);
    resetCapsForWorkload(policy);

    var handle: handle_t = 0;
    try std.testing.expectEqual(OK, cap_acquire(CAP_TIME, &handle));

    resetCapsForWorkload(policy);
    try std.testing.expectEqual(ERR_PERMISSION, cap_enter(&handle, 1));
}

test "cap_drop invalidates old handles" {
    const policy = capMask(CAP_TIME);
    resetCapsForWorkload(policy);

    var handle: handle_t = 0;
    try std.testing.expectEqual(OK, cap_acquire(CAP_TIME, &handle));
    try std.testing.expectEqual(OK, cap_enter(&handle, 1));
    try std.testing.expectEqual(OK, cap_drop(handle));

    try std.testing.expectEqual(ERR_PERMISSION, cap_enter(&handle, 1));
}

test "mem_alloc basic" {
    const policy = capMask(CAP_MEM);
    resetCapsForWorkload(policy);
    heap_top = 0; // Reset heap for test

    var cap: handle_t = 0;
    try std.testing.expectEqual(OK, cap_acquire(CAP_MEM, &cap));
    try std.testing.expectEqual(OK, cap_enter(&cap, 1));

    var ptr: ptr_t = 0;
    try std.testing.expectEqual(OK, mem_alloc(64, 0, &ptr));
    try std.testing.expect(ptr != 0);

    try std.testing.expectEqual(OK, mem_free(ptr));
}

test "mem_alloc alignment" {
    const policy = capMask(CAP_MEM);
    resetCapsForWorkload(policy);
    heap_top = 0;
    // Reset alloc table for test
    for (&alloc_table) |*entry| {
        entry.* = .{};
    }

    var cap: handle_t = 0;
    _ = cap_acquire(CAP_MEM, &cap);
    _ = cap_enter(&cap, 1);

    var ptr1: ptr_t = 0;
    var ptr2: ptr_t = 0;
    try std.testing.expectEqual(OK, mem_alloc(1, 0, &ptr1));
    try std.testing.expectEqual(OK, mem_alloc(1, 0, &ptr2));

    // Should be 16-byte aligned
    try std.testing.expectEqual(@as(usize, 16), ptr2 - ptr1);
}

test "mem_alloc nomem" {
    const policy = capMask(CAP_MEM);
    resetCapsForWorkload(policy);
    heap_top = HEAP_SIZE - 8; // Near end

    var cap: handle_t = 0;
    _ = cap_acquire(CAP_MEM, &cap);
    _ = cap_enter(&cap, 1);

    var ptr: ptr_t = 0;
    try std.testing.expectEqual(ERR_NOMEM, mem_alloc(1024, 0, &ptr));
}

test "mem_alloc permission denied without cap" {
    resetCapsForWorkload(0);

    var ptr: ptr_t = 0;
    try std.testing.expectEqual(ERR_PERMISSION, mem_alloc(64, 0, &ptr));
}
