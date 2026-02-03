const abi = @import("abi.zig");
const entry = @import("entrypoint.zig");

pub fn loadEntrypoint() []const u8 {
    // Placeholder for bundle/metadata lookup.
    return entry.entrypoint;
}

pub fn announce(entry: []const u8) void {
    const prefix = "adapter: entrypoint ";
    _ = abi.log_write(0, @intFromPtr(prefix.ptr), prefix.len);
    _ = abi.log_write(0, @intFromPtr(entry.ptr), entry.len);
    const suffix = " (stub)\n";
    _ = abi.log_write(0, @intFromPtr(suffix.ptr), suffix.len);
}

pub fn launch() void {
    const entrypoint = loadEntrypoint();
    announce(entrypoint);
}
