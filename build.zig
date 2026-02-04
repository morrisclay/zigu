const std = @import("std");

pub fn build(b: *std.Build) void {
    const target_query = std.Target.Query{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };
    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .code_model = .kernel,
        .pic = false,
    });
    const exe = b.addExecutable(.{
        .name = "ukernel",
        .root_module = exe_module,
    });

    // Add PVH boot assembly for QEMU/Firecracker direct boot
    exe.addAssemblyFile(b.path("kernel/pvh_boot.S"));

    // Add multiboot2 header for QEMU/GRUB boot
    exe.addAssemblyFile(b.path("kernel/multiboot.S"));

    // Use pvh_start as entry for Firecracker - it enables SSE before jumping to _start
    exe.entry = .{ .symbol_name = "pvh_start" };
    exe.pie = false;
    exe.setLinkerScript(b.path("kernel/linker.ld"));

    // Force linker to use our PHDRS
    exe.linkage = .static;

    b.installArtifact(exe);

    const test_target = b.standardTargetOptions(.{});
    const abi_module = b.createModule(.{
        .root_source_file = b.path("kernel/abi.zig"),
        .target = test_target,
        .optimize = optimize,
    });
    const abi_tests = b.addTest(.{
        .root_module = abi_module,
    });
    const run_abi_tests = b.addRunArtifact(abi_tests);
    const test_step = b.step("test", "Run kernel unit tests");
    test_step.dependOn(&run_abi_tests.step);
}
