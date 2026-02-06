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
fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

fn writeCr3(val: u64) void {
    asm volatile ("mov %[val], %%cr3"
        :
        : [val] "r" (val),
    );
}

// Page directory for MMIO region (3-4GB), placed in BSS
var mmio_pd: [512]u64 align(4096) = [_]u64{0} ** 512;

fn mapMmioRegion() void {
    const cr3 = readCr3();
    const pml4: [*]volatile u64 = @ptrFromInt(cr3);
    const pdpt_addr = pml4[0] & 0x000FFFFFFFFFF000;
    const pdpt: [*]volatile u64 = @ptrFromInt(pdpt_addr);

    if (pdpt[3] != 0) return;

    // Fill PD with 2MB identity-mapped entries for 3GB-4GB
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        const phys: u64 = 0xC0000000 + @as(u64, i) * 0x200000;
        mmio_pd[i] = phys | 0x83; // present | writable | 2MB page
    }

    // Set PDPT[3] -> our PD
    pdpt[3] = @intFromPtr(&mmio_pd) | 0x23; // present | writable | user

    // Flush TLB
    writeCr3(cr3);
}

export fn kernelMain() noreturn {
    _ = abi;
    serial.init();
    serial.writeAll("Cloud uKernel: booting...\n");

    // Map MMIO region before virtio probing
    mapMmioRegion();

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
