const virtio = @import("virtio.zig");
const serial = @import("serial.zig");
const builtin = @import("builtin");

// Virtio net header — prepended to every frame
const VirtioNetHdr = extern struct {
    flags: u8,
    gso_type: u8,
    hdr_len: u16,
    gso_size: u16,
    csum_start: u16,
    csum_offset: u16,
};

const NET_HDR_SIZE = @sizeOf(VirtioNetHdr);

// Feature bits
const VIRTIO_NET_F_MAC: u32 = 1 << 5;

// Queue indices
const RX_QUEUE: u32 = 0;
const TX_QUEUE: u32 = 1;

// Queue sizes
const QUEUE_SIZE = 16;
const NUM_RX_BUFS = 8;

// Max frame: 10 (net_hdr) + 14 (eth) + 1500 (MTU) + 2 (pad)
const MAX_FRAME_SIZE = 1526;

// Device state
var base_addr: u64 = 0;
var mac_addr: [6]u8 = undefined;
var initialized: bool = false;

// RX queue state
var rx_desc: [QUEUE_SIZE]virtio.VirtqDesc align(16) = undefined;
var rx_avail_buf: [6 + 2 * QUEUE_SIZE]u8 align(2) = undefined;
var rx_used_buf: [6 + 8 * QUEUE_SIZE]u8 align(4) = undefined;
var rx_avail_idx: u16 = 0;
var rx_last_used_idx: u16 = 0;

// TX queue state
var tx_desc: [QUEUE_SIZE]virtio.VirtqDesc align(16) = undefined;
var tx_avail_buf: [6 + 2 * QUEUE_SIZE]u8 align(2) = undefined;
var tx_used_buf: [6 + 8 * QUEUE_SIZE]u8 align(4) = undefined;
var tx_avail_idx: u16 = 0;
var tx_last_used_idx: u16 = 0;

// RX buffers — pre-posted for device to fill
var rx_bufs: [NUM_RX_BUFS][MAX_FRAME_SIZE]u8 align(16) = undefined;

// TX buffer
var tx_buf: [MAX_FRAME_SIZE]u8 align(16) = undefined;

fn setupQueue(queue_idx: u32, desc: [*]virtio.VirtqDesc, avail: [*]u8, used: [*]u8) bool {
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_SEL, queue_idx);
    const max_size = virtio.mmioRead32(base_addr, virtio.MMIO_QUEUE_NUM_MAX);
    if (max_size == 0) {
        serial.writeAll("virtio_net: queue not available\n");
        return false;
    }

    const qsize: u16 = if (max_size >= QUEUE_SIZE) QUEUE_SIZE else @intCast(max_size);
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_NUM, qsize);

    // Zero out buffers
    const avail_len = 6 + 2 * QUEUE_SIZE;
    const used_len = 6 + 8 * QUEUE_SIZE;
    for (0..avail_len) |i| avail[i] = 0;
    for (0..used_len) |i| used[i] = 0;
    for (0..QUEUE_SIZE) |i| desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };

    // Set queue addresses
    const desc_addr = @intFromPtr(desc);
    const avail_addr = @intFromPtr(avail);
    const used_addr = @intFromPtr(used);

    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_DESC_LOW, @truncate(desc_addr));
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_DESC_HIGH, @truncate(desc_addr >> 32));
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_AVAIL_LOW, @truncate(avail_addr));
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_AVAIL_HIGH, @truncate(avail_addr >> 32));
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_USED_LOW, @truncate(used_addr));
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_USED_HIGH, @truncate(used_addr >> 32));

    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_READY, 1);
    return true;
}

fn addAvailRx(desc_idx: u16) void {
    const avail_bytes: [*]volatile u8 = @ptrCast(&rx_avail_buf);
    const ring_offset = 4 + @as(usize, rx_avail_idx % QUEUE_SIZE) * 2;
    const ring_entry: *volatile u16 = @ptrCast(@alignCast(avail_bytes + ring_offset));
    ring_entry.* = desc_idx;
    rx_avail_idx +%= 1;
    const idx_ptr: *volatile u16 = @ptrCast(@alignCast(avail_bytes + 2));
    idx_ptr.* = rx_avail_idx;
}

fn addAvailTx(desc_idx: u16) void {
    const avail_bytes: [*]volatile u8 = @ptrCast(&tx_avail_buf);
    const ring_offset = 4 + @as(usize, tx_avail_idx % QUEUE_SIZE) * 2;
    const ring_entry: *volatile u16 = @ptrCast(@alignCast(avail_bytes + ring_offset));
    ring_entry.* = desc_idx;
    tx_avail_idx +%= 1;
    const idx_ptr: *volatile u16 = @ptrCast(@alignCast(avail_bytes + 2));
    idx_ptr.* = tx_avail_idx;
}

fn postRxBuf(idx: u16) void {
    rx_desc[idx] = .{
        .addr = @intFromPtr(&rx_bufs[idx]),
        .len = MAX_FRAME_SIZE,
        .flags = virtio.VRING_DESC_F_WRITE,
        .next = 0,
    };
    addAvailRx(idx);
}

pub fn init() bool {
    serial.writeAll("virtio_net: probing...\n");

    // Probe for net device
    const dev = virtio.probe(virtio.DEVICE_NET) orelse {
        serial.writeAll("virtio_net: no net device found\n");
        return false;
    };
    base_addr = dev.base;
    serial.writeAll("virtio_net: found net device\n");

    // Reset device
    virtio.mmioWrite32(base_addr, virtio.MMIO_STATUS, 0);

    // Acknowledge
    virtio.mmioWrite32(base_addr, virtio.MMIO_STATUS, virtio.STATUS_ACKNOWLEDGE);
    virtio.mmioWrite32(base_addr, virtio.MMIO_STATUS, virtio.STATUS_ACKNOWLEDGE | virtio.STATUS_DRIVER);

    // Feature negotiation — acknowledge MAC feature
    virtio.mmioWrite32(base_addr, virtio.MMIO_DEVICE_FEATURES_SEL, 0);
    const dev_features = virtio.mmioRead32(base_addr, virtio.MMIO_DEVICE_FEATURES);
    _ = dev_features;
    virtio.mmioWrite32(base_addr, virtio.MMIO_DRIVER_FEATURES_SEL, 0);
    virtio.mmioWrite32(base_addr, virtio.MMIO_DRIVER_FEATURES, VIRTIO_NET_F_MAC);

    virtio.mmioWrite32(base_addr, virtio.MMIO_STATUS, virtio.STATUS_ACKNOWLEDGE | virtio.STATUS_DRIVER | virtio.STATUS_FEATURES_OK);

    // Check features ok
    const status = virtio.mmioRead32(base_addr, virtio.MMIO_STATUS);
    if ((status & virtio.STATUS_FEATURES_OK) == 0) {
        serial.writeAll("virtio_net: features negotiation failed\n");
        return false;
    }

    // Read MAC address from device config (offset 0x100)
    const config_base: u64 = base_addr + 0x100;
    for (0..6) |i| {
        const addr: *volatile u8 = @ptrFromInt(config_base + i);
        mac_addr[i] = addr.*;
    }

    serial.writeAll("virtio_net: mac=");
    for (mac_addr, 0..) |b, i| {
        writeHexByte(b);
        if (i < 5) serial.writeByte(':');
    }
    serial.writeAll("\n");

    // Setup RX queue (queue 0)
    if (!setupQueue(RX_QUEUE, &rx_desc, &rx_avail_buf, &rx_used_buf)) {
        serial.writeAll("virtio_net: RX queue setup failed\n");
        return false;
    }

    // Setup TX queue (queue 1)
    if (!setupQueue(TX_QUEUE, &tx_desc, &tx_avail_buf, &tx_used_buf)) {
        serial.writeAll("virtio_net: TX queue setup failed\n");
        return false;
    }

    // Driver ok
    virtio.mmioWrite32(base_addr, virtio.MMIO_STATUS, virtio.STATUS_ACKNOWLEDGE | virtio.STATUS_DRIVER | virtio.STATUS_FEATURES_OK | virtio.STATUS_DRIVER_OK);

    // Pre-post RX buffers
    for (0..NUM_RX_BUFS) |i| {
        postRxBuf(@intCast(i));
    }
    // Notify device about RX buffers
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_SEL, RX_QUEUE);
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_NOTIFY, RX_QUEUE);

    initialized = true;
    serial.writeAll("virtio_net: ready\n");
    return true;
}

pub fn isReady() bool {
    return initialized;
}

pub fn getMac() [6]u8 {
    return mac_addr;
}

/// Transmit a raw Ethernet frame. The caller provides the complete frame
/// (dst_mac + src_mac + ethertype + payload). This function prepends the
/// virtio net header.
pub fn txPacket(frame: []const u8) bool {
    if (!initialized) return false;
    if (frame.len == 0 or frame.len > MAX_FRAME_SIZE - NET_HDR_SIZE) return false;

    // Build buffer: net_hdr + frame
    const net_hdr = VirtioNetHdr{
        .flags = 0,
        .gso_type = 0,
        .hdr_len = 0,
        .gso_size = 0,
        .csum_start = 0,
        .csum_offset = 0,
    };
    const hdr_bytes: *const [NET_HDR_SIZE]u8 = @ptrCast(&net_hdr);
    for (0..NET_HDR_SIZE) |i| {
        tx_buf[i] = hdr_bytes[i];
    }
    for (0..frame.len) |i| {
        tx_buf[NET_HDR_SIZE + i] = frame[i];
    }

    const total_len: u32 = @intCast(NET_HDR_SIZE + frame.len);

    // Set up TX descriptor
    tx_desc[0] = .{
        .addr = @intFromPtr(&tx_buf),
        .len = total_len,
        .flags = 0, // device reads
        .next = 0,
    };

    // Submit
    addAvailTx(0);
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_SEL, TX_QUEUE);
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_NOTIFY, TX_QUEUE);

    // Poll TX used ring
    const used_ptr: [*]volatile u8 = @ptrCast(&tx_used_buf);
    while (true) {
        const used_idx_ptr: *volatile u16 = @ptrCast(@alignCast(used_ptr + 2));
        if (used_idx_ptr.* != tx_last_used_idx) {
            tx_last_used_idx = used_idx_ptr.*;
            break;
        }
        if (comptime builtin.cpu.arch == .x86_64) {
            asm volatile ("pause");
        }
    }

    // Acknowledge interrupt
    const isr = virtio.mmioRead32(base_addr, virtio.MMIO_INTERRUPT_STATUS);
    if (isr != 0) {
        virtio.mmioWrite32(base_addr, virtio.MMIO_INTERRUPT_ACK, isr);
    }

    return true;
}

/// Poll for received frames. Returns the raw Ethernet frame data (after
/// stripping the virtio net header), or null if no frame available.
/// The returned slice points into a static RX buffer and is valid until
/// the next call to rxPoll().
pub fn rxPoll() ?[]u8 {
    if (!initialized) return null;

    // Check RX used ring
    const used_ptr: [*]volatile u8 = @ptrCast(&rx_used_buf);
    const used_idx_ptr: *volatile u16 = @ptrCast(@alignCast(used_ptr + 2));
    if (used_idx_ptr.* == rx_last_used_idx) return null;

    // Read used element
    const used_ring_offset = 4 + @as(usize, rx_last_used_idx % QUEUE_SIZE) * 8;
    const used_id_ptr: *volatile u32 = @ptrCast(@alignCast(used_ptr + used_ring_offset));
    const used_len_ptr: *volatile u32 = @ptrCast(@alignCast(used_ptr + used_ring_offset + 4));
    const buf_idx = used_id_ptr.*;
    const total_len = used_len_ptr.*;

    rx_last_used_idx +%= 1;

    // Acknowledge interrupt
    const isr = virtio.mmioRead32(base_addr, virtio.MMIO_INTERRUPT_STATUS);
    if (isr != 0) {
        virtio.mmioWrite32(base_addr, virtio.MMIO_INTERRUPT_ACK, isr);
    }

    // Validate
    if (buf_idx >= NUM_RX_BUFS or total_len <= NET_HDR_SIZE) {
        // Re-post buffer and skip
        if (buf_idx < NUM_RX_BUFS) postRxBuf(@intCast(buf_idx));
        virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_SEL, RX_QUEUE);
        virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_NOTIFY, RX_QUEUE);
        return null;
    }

    const frame_len = total_len - NET_HDR_SIZE;
    if (frame_len > MAX_FRAME_SIZE - NET_HDR_SIZE) {
        postRxBuf(@intCast(buf_idx));
        virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_SEL, RX_QUEUE);
        virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_NOTIFY, RX_QUEUE);
        return null;
    }

    // Return slice into the rx buffer, past the net header
    const result = rx_bufs[buf_idx][NET_HDR_SIZE .. NET_HDR_SIZE + frame_len];

    // Re-post buffer for reuse
    postRxBuf(@intCast(buf_idx));
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_SEL, RX_QUEUE);
    virtio.mmioWrite32(base_addr, virtio.MMIO_QUEUE_NOTIFY, RX_QUEUE);

    return result;
}

fn writeHexByte(b: u8) void {
    const hi: u8 = b >> 4;
    const lo: u8 = b & 0x0F;
    serial.writeByte(if (hi < 10) '0' + hi else 'A' + hi - 10);
    serial.writeByte(if (lo < 10) '0' + lo else 'A' + lo - 10);
}
