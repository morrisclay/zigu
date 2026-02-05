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

    // ELF entry point is _start (set by ENTRY(_start) in linker.ld).
    // _start is self-contained: sets up segments, SSE, stack, then calls kernelMain.
    // Works for both Firecracker (enters at ELF entry in 64-bit mode) and
    // multiboot (transitions to 64-bit then jumps to _start).
    // PVH note is in pvh_boot.S but LLD strips it; a post-build step injects PT_NOTE.
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
