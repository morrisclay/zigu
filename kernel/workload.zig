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

    serial.writeAll("workload: done\n");
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
