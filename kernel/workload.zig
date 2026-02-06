const abi = @import("abi.zig");
const serial = @import("serial.zig");

pub const WorkloadId: u32 = 1;

pub fn workloadMain() void {
    serial.writeAll("workload: starting\n");

    if (abi.cap_exit() != abi.OK) {
        serial.writeAll("workload: cap_exit failed\n");
        return;
    }

    var caps: [3]abi.handle_t = [_]abi.handle_t{0} ** 3;

    if (abi.cap_acquire(abi.CAP_LOG, &caps[0]) != abi.OK) {
        serial.writeAll("workload: acquire LOG failed\n");
        return;
    }
    if (abi.cap_acquire(abi.CAP_TIME, &caps[1]) != abi.OK) {
        serial.writeAll("workload: acquire TIME failed\n");
        return;
    }
    if (abi.cap_acquire(abi.CAP_TASK, &caps[2]) != abi.OK) {
        serial.writeAll("workload: acquire TASK failed\n");
        return;
    }

    if (abi.cap_enter(&caps[0], 3) != abi.OK) {
        serial.writeAll("workload: cap_enter failed\n");
        return;
    }
    serial.writeAll("workload: entered sandbox\n");

    const hello = "workload: hello from inside the sandbox\n";
    _ = abi.log_write(0, @intFromPtr(hello.ptr), hello.len);

    var t: abi.time_ns = 0;
    _ = abi.time_now(&t);

    const msg1 = "workload: time = ";
    _ = abi.log_write(0, @intFromPtr(msg1.ptr), msg1.len);

    var buf: [24]u8 = undefined;
    const len = u64ToDec(t, &buf);
    _ = abi.log_write(0, @intFromPtr(buf[0..len].ptr), len);

    const newline = "\n";
    _ = abi.log_write(0, @intFromPtr(newline.ptr), newline.len);

    var heartbeat: u64 = 0;
    while (heartbeat < 3) : (heartbeat += 1) {
        const prefix = "workload: heartbeat ";
        _ = abi.log_write(0, @intFromPtr(prefix.ptr), prefix.len);

        var hb_buf: [24]u8 = undefined;
        const hb_len = u64ToDec(heartbeat, &hb_buf);
        _ = abi.log_write(0, @intFromPtr(hb_buf[0..hb_len].ptr), hb_len);

        const suffix = "\n";
        _ = abi.log_write(0, @intFromPtr(suffix.ptr), suffix.len);

        _ = abi.task_yield();
    }

    // --- io_poll demo ---
    // Re-enter sandbox with IO capability added
    _ = abi.cap_exit();

    var io_caps: [4]abi.handle_t = [_]abi.handle_t{0} ** 4;
    if (abi.cap_acquire(abi.CAP_LOG, &io_caps[0]) != abi.OK) {
        serial.writeAll("workload: acquire LOG failed (io demo)\n");
        return;
    }
    if (abi.cap_acquire(abi.CAP_TIME, &io_caps[1]) != abi.OK) {
        serial.writeAll("workload: acquire TIME failed (io demo)\n");
        return;
    }
    if (abi.cap_acquire(abi.CAP_TASK, &io_caps[2]) != abi.OK) {
        serial.writeAll("workload: acquire TASK failed (io demo)\n");
        return;
    }
    if (abi.cap_acquire(abi.CAP_IO, &io_caps[3]) != abi.OK) {
        serial.writeAll("workload: acquire IO failed\n");
        return;
    }
    if (abi.cap_enter(&io_caps[0], 4) != abi.OK) {
        serial.writeAll("workload: cap_enter failed (io demo)\n");
        return;
    }

    // Open serial via ABI
    var io_handle: abi.handle_t = 0;
    const serial_path = "serial";
    if (abi.io_open(@intFromPtr(serial_path.ptr), 0, &io_handle) != abi.OK) {
        serial.writeAll("workload: io_open serial failed\n");
        return;
    }
    serial.writeAll("workload: io_open serial ok\n");

    // Poll for events (non-blocking)
    var events: [1]abi.io_event_t = [_]abi.io_event_t{.{ .handle = 0, .events = 0 }} ** 1;
    var ev_count: u32 = 0;
    const poll_rc = abi.io_poll(&io_handle, 1, 0, @intFromPtr(&events[0]), &ev_count);
    if (poll_rc == abi.OK and ev_count > 0) {
        serial.writeAll("workload: io_poll got events=0x");
        writeU32Hex(events[0].events);
        serial.writeAll("\n");
    } else {
        serial.writeAll("workload: io_poll no events\n");
    }

    // Write via ABI
    const io_msg = "workload: hello via io_write\n";
    var wrote: abi.size_t = 0;
    if (abi.io_write(io_handle, @intFromPtr(io_msg.ptr), io_msg.len, &wrote) == abi.OK) {
        serial.writeAll("workload: io_write ok\n");
    }

    _ = abi.io_close(io_handle);
    serial.writeAll("workload: done\n");
}

fn writeU32Hex(value: u32) void {
    var shift: i32 = 28;
    var started = false;
    while (shift >= 0) : (shift -= 4) {
        const nibble: u4 = @intCast((value >> @as(u5, @intCast(shift))) & 0xF);
        if (!started and nibble == 0 and shift != 0) continue;
        started = true;
        const n: u8 = @intCast(nibble);
        const ch: u8 = if (n < 10) @intCast('0' + n) else @intCast('a' + (n - 10));
        serial.writeByte(ch);
    }
    if (!started) serial.writeByte('0');
}

fn u64ToDec(value: u64, out: *[24]u8) usize {
    if (value == 0) {
        out[0] = '0';
        return 1;
    }

    var tmp: [24]u8 = undefined;
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        tmp[i] = @intCast('0' + @as(u8, @intCast(v % 10)));
        i += 1;
    }

    var j: usize = 0;
    while (i > 0) : (i -= 1) {
        out[j] = tmp[i - 1];
        j += 1;
    }
    return j;
}
