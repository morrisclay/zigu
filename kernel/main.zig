const std = @import("std");
const serial = @import("serial.zig");
const abi = @import("abi.zig");
const workload = @import("workload.zig");

const WorkloadPolicy = struct {
    id: u32,
    allowed_caps: u32,
};

const policies = [_]WorkloadPolicy{
    .{
        .id = workload.WorkloadId,
        .allowed_caps = (1 << (abi.CAP_LOG - 1)) |
            (1 << (abi.CAP_TIME - 1)) |
            (1 << (abi.CAP_TASK - 1)),
    },
};

fn policyFor(id: u32) u32 {
    for (policies) |p| {
        if (p.id == id) return p.allowed_caps;
    }
    return 0;
}

pub const panic = panicHandler;

fn panicHandler(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    serial.writeAll("panic: ");
    serial.writeAll(msg);
    serial.writeAll("\n");
    haltForever();
}

fn haltForever() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

export fn _start() noreturn {
    _ = abi;
    serial.init();
    serial.writeAll("Cloud uKernel: booting...\n");
    serial.writeAll("Build: M1 kernel + ABI stubs\n");
    const policy_mask = policyFor(workload.WorkloadId);
    abi.resetCapsForWorkload(policy_mask);
    workload.workloadMain();
    haltForever();
}
