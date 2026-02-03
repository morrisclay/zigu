const abi = @import("abi.zig");
const adapter = @import("adapter.zig");

pub const WorkloadId: u32 = 1;

pub fn workloadMain() void {
    if (abi.cap_exit() != abi.OK) return;

    var caps: [3]abi.handle_t = undefined;
    if (abi.cap_acquire(abi.CAP_LOG, &caps[0]) != abi.OK) return;
    if (abi.cap_acquire(abi.CAP_TIME, &caps[1]) != abi.OK) return;
    if (abi.cap_acquire(abi.CAP_TASK, &caps[2]) != abi.OK) return;
    if (abi.cap_enter(&caps[0], @intCast(caps.len)) != abi.OK) return;

    adapter.launch();

    const hello = "workload: hello from inside the shrinkwrap\n";
    _ = abi.log_write(0, @intFromPtr(hello.ptr), hello.len);

    var t: abi.time_ns = 0;
    _ = abi.time_now(&t);

    const msg1 = "workload: time tick = ";
    _ = abi.log_write(0, @intFromPtr(msg1.ptr), msg1.len);

    var buf: [24]u8 = undefined;
    const len = u64ToDec(t, &buf);
    _ = abi.log_write(0, @intFromPtr(buf[0..len].ptr), len);

    const msg2 = "\nworkload: yield\n";
    _ = abi.log_write(0, @intFromPtr(msg2.ptr), msg2.len);
    _ = abi.task_yield();

    var heartbeat: u64 = 0;
    while (true) {
        const prefix = "workload: heartbeat ";
        _ = abi.log_write(0, @intFromPtr(prefix.ptr), prefix.len);

        var hb_buf: [24]u8 = undefined;
        const hb_len = u64ToDec(heartbeat, &hb_buf);
        _ = abi.log_write(0, @intFromPtr(hb_buf[0..hb_len].ptr), hb_len);

        const suffix = "\n";
        _ = abi.log_write(0, @intFromPtr(suffix.ptr), suffix.len);

        heartbeat += 1;
        spinDelay(100_000_000);
    }
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

fn spinDelay(cycles: u64) void {
    var start: abi.time_ns = 0;
    if (abi.time_now(&start) != abi.OK) {
        var i: u64 = 0;
        while (i < cycles) : (i += 1) {
            _ = abi.task_yield();
        }
        return;
    }

    var now: abi.time_ns = 0;
    while (true) {
        if (abi.time_now(&now) != abi.OK) break;
        if (now - start >= cycles) break;
        _ = abi.task_yield();
    }
}
