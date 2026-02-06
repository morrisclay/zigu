const serial = @import("serial.zig");
const virtio_blk = @import("virtio_blk.zig");

// Tar header (POSIX ustar format) — 512 bytes
const TAR_BLOCK_SIZE = 512;

const TarHeader = extern struct {
    name: [100]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    size: [12]u8, // Octal ASCII
    mtime: [12]u8,
    checksum: [8]u8,
    typeflag: u8, // '0' or '\0' = regular file, '5' = directory
    linkname: [100]u8,
    magic: [6]u8, // "ustar" for POSIX
    version: [2]u8,
    uname: [32]u8,
    gname: [32]u8,
    devmajor: [8]u8,
    devminor: [8]u8,
    prefix: [155]u8,
    _pad: [12]u8,
};

comptime {
    if (@sizeOf(TarHeader) != 512) @compileError("TarHeader must be 512 bytes");
}

/// Parse an octal ASCII field (as used in tar headers)
fn parseOctal(field: []const u8) usize {
    var result: usize = 0;
    for (field) |c| {
        if (c == 0 or c == ' ') break;
        if (c < '0' or c > '7') break;
        result = result * 8 + (c - '0');
    }
    return result;
}

/// Check if a tar header name matches a target filename.
/// Handles leading "./" prefix that tar may add.
fn nameMatch(header_name: []const u8, target: []const u8) bool {
    // Find the actual name end (null-terminated)
    var name_len: usize = 0;
    while (name_len < header_name.len and header_name[name_len] != 0) : (name_len += 1) {}
    const name = header_name[0..name_len];

    // Direct match
    if (strEql(name, target)) return true;

    // Match with "./" prefix stripped
    if (name.len > 2 and name[0] == '.' and name[1] == '/') {
        if (strEql(name[2..], target)) return true;
    }

    return false;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn isZeroBlock(buf: []const u8) bool {
    for (buf) |b| {
        if (b != 0) return false;
    }
    return true;
}

// Maximum file size we'll load from tar (1MB)
const MAX_FILE_SIZE = 1024 * 1024;

// Static buffer for loaded file content
var file_buf: [MAX_FILE_SIZE]u8 = undefined;

/// Find and load a file from a tar archive stored on the virtio block device.
/// Returns the file contents as a slice, or null if not found.
pub fn findFile(filename: []const u8) ?[]const u8 {
    if (!virtio_blk.isReady()) {
        serial.writeAll("tar: block device not ready\n");
        return null;
    }

    var byte_offset: u64 = 0;
    var header_buf: [TAR_BLOCK_SIZE]u8 = undefined;
    var zero_blocks: u32 = 0;

    while (true) {
        // Read tar header
        if (!virtio_blk.readBytes(byte_offset, TAR_BLOCK_SIZE, &header_buf)) {
            serial.writeAll("tar: read error\n");
            return null;
        }

        // End of archive: two consecutive zero blocks
        if (isZeroBlock(&header_buf)) {
            zero_blocks += 1;
            if (zero_blocks >= 2) break;
            byte_offset += TAR_BLOCK_SIZE;
            continue;
        }
        zero_blocks = 0;

        const header: *const TarHeader = @ptrCast(&header_buf);

        // Parse file size
        const file_size = parseOctal(&header.size);

        // Check if this is our target file
        const is_regular = (header.typeflag == '0' or header.typeflag == 0);

        if (is_regular and nameMatch(&header.name, filename)) {
            if (file_size > MAX_FILE_SIZE) {
                serial.writeAll("tar: file too large\n");
                return null;
            }

            // Read file data
            const data_offset = byte_offset + TAR_BLOCK_SIZE;
            if (!virtio_blk.readBytes(data_offset, file_size, &file_buf)) {
                serial.writeAll("tar: failed to read file data\n");
                return null;
            }

            return file_buf[0..file_size];
        }

        // Skip to next header: data is padded to 512-byte blocks
        const data_blocks = (file_size + TAR_BLOCK_SIZE - 1) / TAR_BLOCK_SIZE;
        byte_offset += TAR_BLOCK_SIZE + data_blocks * TAR_BLOCK_SIZE;
    }

    return null;
}
