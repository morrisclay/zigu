const std = @import("std");
const builtin = @import("builtin");

const Com1: u16 = 0x3F8;

fn outb(port: u16, value: u8) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("outb %[value], %[port]" : : [value] "{al}" (value), [port] "{dx}" (port));
    }
}

fn inb(port: u16) u8 {
    if (comptime builtin.cpu.arch == .x86_64) {
        var value: u8 = 0;
        asm volatile ("inb %[port], %[value]" : [value] "={al}" (value) : [port] "{dx}" (port));
        return value;
    }
    return 0;
}

fn txReady() bool {
    return (inb(Com1 + 5) & 0x20) != 0;
}

pub fn init() void {
    outb(Com1 + 1, 0x00);
    outb(Com1 + 3, 0x80);
    outb(Com1 + 0, 0x01);
    outb(Com1 + 1, 0x00);
    outb(Com1 + 3, 0x03);
    outb(Com1 + 2, 0xC7);
    outb(Com1 + 4, 0x0B);
}

pub fn writeByte(byte: u8) void {
    while (!txReady()) {
        if (comptime builtin.cpu.arch == .x86_64) {
            asm volatile ("pause");
        }
    }
    outb(Com1, byte);
}

pub fn writeAll(msg: []const u8) void {
    for (msg) |b| {
        if (b == '\n') {
            writeByte('\r');
        }
        writeByte(b);
    }
}

pub fn writer() std.io.Writer(void, error{}, writeFn) {
    return .{ .context = {}, .writeFn = writeFn };
}

fn writeFn(_: void, bytes: []const u8) error{}!usize {
    writeAll(bytes);
    return bytes.len;
}
