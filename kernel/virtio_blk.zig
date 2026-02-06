const virtio = @import("virtio.zig");
const serial = @import("serial.zig");
const builtin = @import("builtin");

// Virtio block request types
const VIRTIO_BLK_T_IN: u32 = 0;  // Read
const VIRTIO_BLK_T_OUT: u32 = 1; // Write

// Virtio block request header
const VirtioBlkReqHeader = extern struct {
    type_: u32,
    reserved: u32,
    sector: u64,
};

// Block device state
var dev: virtio.VirtioDevice = undefined;
var initialized: bool = false;

// Static buffers for block I/O
var req_header: VirtioBlkReqHeader align(16) = undefined;
var req_status: u8 align(1) = 0;

pub fn init() bool {
    serial.writeAll("virtio_blk: probing...\n");

    if (virtio.probe(virtio.DEVICE_BLOCK)) |found| {
        dev = found;
        serial.writeAll("virtio_blk: found block device\n");

        if (!virtio.setupVirtqueue(&dev)) {
            serial.writeAll("virtio_blk: virtqueue setup failed\n");
            return false;
        }

        initialized = true;
        serial.writeAll("virtio_blk: ready\n");
        return true;
    } else {
        serial.writeAll("virtio_blk: no block device found\n");
        return false;
    }
}

pub fn isReady() bool {
    return initialized;
}

/// Read sectors from the block device.
/// start_sector: first sector to read (512 bytes per sector)
/// count: number of sectors to read
/// buf: output buffer (must be at least count * 512 bytes)
/// Returns true on success.
pub fn readSectors(start_sector: u64, count: u32, buf: [*]u8) bool {
    if (!initialized) return false;
    if (count == 0) return true;

    // Read sectors one at a time for simplicity
    var sector = start_sector;
    var offset: usize = 0;
    var remaining = count;

    while (remaining > 0) : ({
        remaining -= 1;
        sector += 1;
        offset += 512;
    }) {
        if (!readOneSector(sector, buf + offset)) return false;
    }
    return true;
}

fn readOneSector(sector: u64, buf: [*]u8) bool {
    // Set up request header
    req_header = .{
        .type_ = VIRTIO_BLK_T_IN,
        .reserved = 0,
        .sector = sector,
    };
    req_status = 0xFF; // sentinel

    // Descriptor chain: header -> data -> status
    // Descriptor 0: request header (device reads)
    dev.desc[0] = .{
        .addr = @intFromPtr(&req_header),
        .len = @sizeOf(VirtioBlkReqHeader),
        .flags = virtio.VRING_DESC_F_NEXT,
        .next = 1,
    };

    // Descriptor 1: data buffer (device writes)
    dev.desc[1] = .{
        .addr = @intFromPtr(buf),
        .len = 512,
        .flags = virtio.VRING_DESC_F_NEXT | virtio.VRING_DESC_F_WRITE,
        .next = 2,
    };

    // Descriptor 2: status byte (device writes)
    dev.desc[2] = .{
        .addr = @intFromPtr(&req_status),
        .len = 1,
        .flags = virtio.VRING_DESC_F_WRITE,
        .next = 0,
    };

    // Add to available ring and notify
    virtio.addAvail(&dev, 0);
    virtio.submitAndWait(&dev);

    return req_status == 0;
}

/// Read raw bytes from the block device at a byte offset.
/// Handles alignment to 512-byte sectors internally.
pub fn readBytes(byte_offset: u64, len: usize, out: [*]u8) bool {
    if (!initialized) return false;
    if (len == 0) return true;

    var sector_buf: [512]u8 = undefined;
    var offset = byte_offset;
    var remaining = len;
    var dest_offset: usize = 0;

    while (remaining > 0) {
        const sector = offset / 512;
        const sector_off: usize = @intCast(offset % 512);

        if (!readOneSector(sector, &sector_buf)) return false;

        const available = 512 - sector_off;
        const to_copy = if (remaining < available) remaining else available;

        for (0..to_copy) |i| {
            out[dest_offset + i] = sector_buf[sector_off + i];
        }

        dest_offset += to_copy;
        offset += to_copy;
        remaining -= to_copy;
    }

    return true;
}
