const std = @import("std");
const serial = @import("serial.zig");
const abi = @import("abi.zig");
const workload = @import("workload.zig");
const mp_bridge = @import("mp_bridge.zig");
const virtio_blk = @import("virtio_blk.zig");
const tar = @import("tar.zig");

const WorkloadPolicy = struct {
    id: u32,
    allowed_caps: u32,
};

const policies = [_]WorkloadPolicy{
    .{
        .id = workload.WorkloadId,
        .allowed_caps = (1 << (abi.CAP_LOG - 1)) |
            (1 << (abi.CAP_TIME - 1)) |
            (1 << (abi.CAP_TASK - 1)) |
            (1 << (abi.CAP_MEM - 1)) |
            (1 << (abi.CAP_IO - 1)),
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

// _start is defined in pvh_boot.S (64-bit entry point after mode transition).
// Both pvh_boot.S and multiboot.S converge to _start, which calls kernelMain.
export fn kernelMain() noreturn {
    _ = abi;
    serial.init();
    serial.writeAll("Cloud uKernel: booting...\n");
    const policy_mask = policyFor(workload.WorkloadId);
    abi.resetCapsForWorkload(policy_mask);
    workload.workloadMain();

    // Initialize virtio block device
    const has_rootfs = virtio_blk.init();

    // Try to load Python source from rootfs tar
    var py_source: ?[]const u8 = null;
    if (has_rootfs) {
        py_source = tar.findFile("src/main.py");
        if (py_source != null) {
            serial.writeAll("micropython: loaded src/main.py from rootfs\n");
        } else {
            serial.writeAll("micropython: src/main.py not found in rootfs\n");
        }
    }

    // Run MicroPython with loaded source or fallback demo
    const source = py_source orelse "print('hello from micropython')";
    mp_bridge.runMicroPython(source);

    haltForever();
}
