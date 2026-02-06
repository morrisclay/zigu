const serial = @import("serial.zig");
const builtin = @import("builtin");

// Virtio-MMIO register offsets
pub const MMIO_MAGIC: u32 = 0x00;
pub const MMIO_VERSION: u32 = 0x04;
pub const MMIO_DEVICE_ID: u32 = 0x08;
pub const MMIO_VENDOR_ID: u32 = 0x0c;
pub const MMIO_DEVICE_FEATURES: u32 = 0x10;
pub const MMIO_DEVICE_FEATURES_SEL: u32 = 0x14;
pub const MMIO_DRIVER_FEATURES: u32 = 0x20;
pub const MMIO_DRIVER_FEATURES_SEL: u32 = 0x24;
pub const MMIO_QUEUE_SEL: u32 = 0x30;
pub const MMIO_QUEUE_NUM_MAX: u32 = 0x34;
pub const MMIO_QUEUE_NUM: u32 = 0x38;
pub const MMIO_QUEUE_READY: u32 = 0x44;
pub const MMIO_QUEUE_NOTIFY: u32 = 0x50;
pub const MMIO_INTERRUPT_STATUS: u32 = 0x60;
pub const MMIO_INTERRUPT_ACK: u32 = 0x64;
pub const MMIO_STATUS: u32 = 0x70;
pub const MMIO_QUEUE_DESC_LOW: u32 = 0x80;
pub const MMIO_QUEUE_DESC_HIGH: u32 = 0x84;
pub const MMIO_QUEUE_AVAIL_LOW: u32 = 0x90;
pub const MMIO_QUEUE_AVAIL_HIGH: u32 = 0x94;
pub const MMIO_QUEUE_USED_LOW: u32 = 0xa0;
pub const MMIO_QUEUE_USED_HIGH: u32 = 0xa4;

// Virtio status bits
pub const STATUS_ACKNOWLEDGE: u32 = 1;
pub const STATUS_DRIVER: u32 = 2;
pub const STATUS_FEATURES_OK: u32 = 8;
pub const STATUS_DRIVER_OK: u32 = 4;
pub const STATUS_FAILED: u32 = 128;

// Virtio magic value
pub const MAGIC_VALUE: u32 = 0x74726976; // "virt" little-endian

// Device types
pub const DEVICE_BLOCK: u32 = 2;

// Firecracker MMIO device base addresses
// Firecracker v1.x places up to 8 devices starting at 0xd0000000
const MMIO_BASE: u64 = 0xd0000000;
const MMIO_STRIDE: u64 = 0x1000;
const MAX_DEVICES: u32 = 8;

// Virtqueue descriptor
pub const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const VRING_DESC_F_NEXT: u16 = 1;
pub const VRING_DESC_F_WRITE: u16 = 2;

// Virtqueue available ring
pub const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    // ring: [queue_size]u16 follows
};

// Virtqueue used element
pub const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};

// Virtqueue used ring
pub const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    // ring: [queue_size]VirtqUsedElem follows
};

pub const VirtioDevice = struct {
    base: u64,
    device_id: u32,
    // Virtqueue state
    desc: [*]VirtqDesc,
    avail: *VirtqAvail,
    used: *VirtqUsed,
    queue_size: u16,
    avail_idx: u16,
    last_used_idx: u16,
};

fn mmioRead32(base: u64, offset: u32) u32 {
    if (comptime builtin.cpu.arch != .x86_64) return 0;
    const addr: *volatile u32 = @ptrFromInt(base + offset);
    return addr.*;
}

fn mmioWrite32(base: u64, offset: u32, value: u32) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    const addr: *volatile u32 = @ptrFromInt(base + offset);
    addr.* = value;
}

pub fn probe(device_type: u32) ?VirtioDevice {
    var i: u32 = 0;
    while (i < MAX_DEVICES) : (i += 1) {
        const base = MMIO_BASE + @as(u64, i) * MMIO_STRIDE;
        const magic = mmioRead32(base, MMIO_MAGIC);
        if (magic != MAGIC_VALUE) continue;

        const version = mmioRead32(base, MMIO_VERSION);
        if (version != 2) continue; // We only support modern virtio

        const dev_id = mmioRead32(base, MMIO_DEVICE_ID);
        if (dev_id == 0) continue; // No device
        if (dev_id != device_type) continue;

        return VirtioDevice{
            .base = base,
            .device_id = dev_id,
            .desc = undefined,
            .avail = undefined,
            .used = undefined,
            .queue_size = 0,
            .avail_idx = 0,
            .last_used_idx = 0,
        };
    }
    return null;
}

// Static memory for virtqueue (queue_size=16)
const QUEUE_SIZE = 16;
var vq_desc: [QUEUE_SIZE]VirtqDesc align(16) = undefined;
var vq_avail_buf: [6 + 2 * QUEUE_SIZE]u8 align(2) = undefined;
var vq_used_buf: [6 + 8 * QUEUE_SIZE]u8 align(4) = undefined;

pub fn setupVirtqueue(dev: *VirtioDevice) bool {
    const base = dev.base;

    // Reset device
    mmioWrite32(base, MMIO_STATUS, 0);

    // Acknowledge
    mmioWrite32(base, MMIO_STATUS, STATUS_ACKNOWLEDGE);
    mmioWrite32(base, MMIO_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // Feature negotiation — accept no optional features for simplicity
    mmioWrite32(base, MMIO_DEVICE_FEATURES_SEL, 0);
    _ = mmioRead32(base, MMIO_DEVICE_FEATURES);
    mmioWrite32(base, MMIO_DRIVER_FEATURES_SEL, 0);
    mmioWrite32(base, MMIO_DRIVER_FEATURES, 0);

    mmioWrite32(base, MMIO_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);

    // Check features ok
    const status = mmioRead32(base, MMIO_STATUS);
    if ((status & STATUS_FEATURES_OK) == 0) {
        serial.writeAll("virtio: features negotiation failed\n");
        return false;
    }

    // Select queue 0
    mmioWrite32(base, MMIO_QUEUE_SEL, 0);
    const max_size = mmioRead32(base, MMIO_QUEUE_NUM_MAX);
    if (max_size == 0) {
        serial.writeAll("virtio: queue not available\n");
        return false;
    }

    const qsize: u16 = if (max_size >= QUEUE_SIZE) QUEUE_SIZE else @intCast(max_size);
    mmioWrite32(base, MMIO_QUEUE_NUM, qsize);

    // Zero out buffers
    for (&vq_avail_buf) |*b| b.* = 0;
    for (&vq_used_buf) |*b| b.* = 0;
    for (&vq_desc) |*d| d.* = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };

    // Set queue addresses
    const desc_addr = @intFromPtr(&vq_desc);
    const avail_addr = @intFromPtr(&vq_avail_buf);
    const used_addr = @intFromPtr(&vq_used_buf);

    mmioWrite32(base, MMIO_QUEUE_DESC_LOW, @truncate(desc_addr));
    mmioWrite32(base, MMIO_QUEUE_DESC_HIGH, @truncate(desc_addr >> 32));
    mmioWrite32(base, MMIO_QUEUE_AVAIL_LOW, @truncate(avail_addr));
    mmioWrite32(base, MMIO_QUEUE_AVAIL_HIGH, @truncate(avail_addr >> 32));
    mmioWrite32(base, MMIO_QUEUE_USED_LOW, @truncate(used_addr));
    mmioWrite32(base, MMIO_QUEUE_USED_HIGH, @truncate(used_addr >> 32));

    mmioWrite32(base, MMIO_QUEUE_READY, 1);

    // Driver ok
    mmioWrite32(base, MMIO_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);

    dev.desc = &vq_desc;
    dev.avail = @ptrCast(@alignCast(&vq_avail_buf));
    dev.used = @ptrCast(@alignCast(&vq_used_buf));
    dev.queue_size = qsize;
    dev.avail_idx = 0;
    dev.last_used_idx = 0;

    return true;
}

pub fn submitAndWait(dev: *VirtioDevice) void {
    // Notify the device (queue 0)
    mmioWrite32(dev.base, MMIO_QUEUE_NOTIFY, 0);

    // Poll the used ring until the device processes our request
    const used_ptr: [*]volatile u8 = @ptrCast(dev.used);
    while (true) {
        // used.idx is at offset 2
        const used_idx_ptr: *volatile u16 = @ptrCast(@alignCast(used_ptr + 2));
        if (used_idx_ptr.* != dev.last_used_idx) {
            dev.last_used_idx = used_idx_ptr.*;
            break;
        }
        if (comptime builtin.cpu.arch == .x86_64) {
            asm volatile ("pause");
        }
    }

    // Acknowledge interrupt
    const isr = mmioRead32(dev.base, MMIO_INTERRUPT_STATUS);
    if (isr != 0) {
        mmioWrite32(dev.base, MMIO_INTERRUPT_ACK, isr);
    }
}

pub fn addAvail(dev: *VirtioDevice, desc_idx: u16) void {
    // avail ring: flags(2) idx(2) ring[](2 each)
    const avail_bytes: [*]volatile u8 = @ptrCast(dev.avail);
    // ring starts at offset 4
    const ring_offset = 4 + @as(usize, dev.avail_idx % dev.queue_size) * 2;
    const ring_entry: *volatile u16 = @ptrCast(@alignCast(avail_bytes + ring_offset));
    ring_entry.* = desc_idx;

    dev.avail_idx +%= 1;

    // Write new avail idx (at offset 2)
    const idx_ptr: *volatile u16 = @ptrCast(@alignCast(avail_bytes + 2));
    idx_ptr.* = dev.avail_idx;
}
