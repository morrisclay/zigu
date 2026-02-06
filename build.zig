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

    // --- MicroPython C sources ---
    const mp_root = "lib/micropython/";
    const mp_port = "kernel/mp_port/";

    const mp_c_flags: []const []const u8 = &.{
        "-ffreestanding",
        "-nostdlib",
        "-std=c99",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
        "-Wno-missing-field-initializers",
        "-Wno-old-style-definition",
        "-Wno-implicit-fallthrough",
        "-Wno-return-type",
        "-Wno-unused-variable",
        "-Wno-unused-but-set-variable",
        "-Wno-strict-aliasing",
        "-Wno-override-init",
        "-fno-builtin",
        "-DMICROPY_ROM_TEXT_COMPRESSION=0",
    };

    const mp_include_paths: []const []const u8 = &.{
        mp_port ++ "include/", // libc shim headers (must come first)
        mp_port,
        mp_port ++ "build/",
        mp_root,
        mp_root ++ "py/",
    };

    // MicroPython py/ core sources (matching PY_CORE_O from py.mk)
    const mp_py_sources: []const []const u8 = &.{
        mp_root ++ "py/mpstate.c",
        mp_root ++ "py/nlr.c",
        mp_root ++ "py/nlrx64.c",
        mp_root ++ "py/nlrsetjmp.c",
        mp_root ++ "py/malloc.c",
        mp_root ++ "py/gc.c",
        mp_root ++ "py/pystack.c",
        mp_root ++ "py/qstr.c",
        mp_root ++ "py/vstr.c",
        mp_root ++ "py/mpprint.c",
        mp_root ++ "py/unicode.c",
        mp_root ++ "py/mpz.c",
        mp_root ++ "py/reader.c",
        mp_root ++ "py/lexer.c",
        mp_root ++ "py/parse.c",
        mp_root ++ "py/scope.c",
        mp_root ++ "py/compile.c",
        mp_root ++ "py/emitcommon.c",
        mp_root ++ "py/emitbc.c",
        mp_root ++ "py/asmbase.c",
        mp_root ++ "py/asmx64.c",
        mp_root ++ "py/emitnx64.c",
        mp_root ++ "py/asmx86.c",
        mp_root ++ "py/emitnx86.c",
        mp_root ++ "py/asmthumb.c",
        mp_root ++ "py/emitnthumb.c",
        mp_root ++ "py/emitinlinethumb.c",
        mp_root ++ "py/asmarm.c",
        mp_root ++ "py/emitnarm.c",
        mp_root ++ "py/asmxtensa.c",
        mp_root ++ "py/emitnxtensa.c",
        mp_root ++ "py/emitinlinextensa.c",
        mp_root ++ "py/emitnxtensawin.c",
        mp_root ++ "py/asmrv32.c",
        mp_root ++ "py/emitnrv32.c",
        mp_root ++ "py/emitndebug.c",
        mp_root ++ "py/emitnative.c",
        mp_root ++ "py/formatfloat.c",
        mp_root ++ "py/parsenumbase.c",
        mp_root ++ "py/parsenum.c",
        mp_root ++ "py/emitglue.c",
        mp_root ++ "py/persistentcode.c",
        mp_root ++ "py/runtime.c",
        mp_root ++ "py/runtime_utils.c",
        mp_root ++ "py/scheduler.c",
        mp_root ++ "py/nativeglue.c",
        mp_root ++ "py/pairheap.c",
        mp_root ++ "py/ringbuf.c",
        mp_root ++ "py/cstack.c",
        mp_root ++ "py/stackctrl.c",
        mp_root ++ "py/argcheck.c",
        mp_root ++ "py/warning.c",
        mp_root ++ "py/profile.c",
        mp_root ++ "py/map.c",
        mp_root ++ "py/obj.c",
        mp_root ++ "py/objarray.c",
        mp_root ++ "py/objattrtuple.c",
        mp_root ++ "py/objbool.c",
        mp_root ++ "py/objboundmeth.c",
        mp_root ++ "py/objcell.c",
        mp_root ++ "py/objclosure.c",
        mp_root ++ "py/objcomplex.c",
        mp_root ++ "py/objdeque.c",
        mp_root ++ "py/objdict.c",
        mp_root ++ "py/objenumerate.c",
        mp_root ++ "py/objexcept.c",
        mp_root ++ "py/objfilter.c",
        mp_root ++ "py/objfloat.c",
        mp_root ++ "py/objfun.c",
        mp_root ++ "py/objgenerator.c",
        mp_root ++ "py/objgetitemiter.c",
        mp_root ++ "py/objint.c",
        mp_root ++ "py/objint_longlong.c",
        mp_root ++ "py/objint_mpz.c",
        mp_root ++ "py/objlist.c",
        mp_root ++ "py/objmap.c",
        mp_root ++ "py/objmodule.c",
        mp_root ++ "py/objobject.c",
        mp_root ++ "py/objpolyiter.c",
        mp_root ++ "py/objproperty.c",
        mp_root ++ "py/objnone.c",
        mp_root ++ "py/objnamedtuple.c",
        mp_root ++ "py/objrange.c",
        mp_root ++ "py/objreversed.c",
        mp_root ++ "py/objringio.c",
        mp_root ++ "py/objset.c",
        mp_root ++ "py/objsingleton.c",
        mp_root ++ "py/objslice.c",
        mp_root ++ "py/objstr.c",
        mp_root ++ "py/objstrunicode.c",
        mp_root ++ "py/objstringio.c",
        mp_root ++ "py/objtuple.c",
        mp_root ++ "py/objtype.c",
        mp_root ++ "py/objzip.c",
        mp_root ++ "py/opmethods.c",
        mp_root ++ "py/sequence.c",
        mp_root ++ "py/stream.c",
        mp_root ++ "py/binary.c",
        mp_root ++ "py/builtinimport.c",
        mp_root ++ "py/builtinevex.c",
        mp_root ++ "py/builtinhelp.c",
        mp_root ++ "py/modarray.c",
        mp_root ++ "py/modbuiltins.c",
        mp_root ++ "py/modcollections.c",
        mp_root ++ "py/modgc.c",
        mp_root ++ "py/modio.c",
        mp_root ++ "py/modmath.c",
        mp_root ++ "py/modcmath.c",
        mp_root ++ "py/modmicropython.c",
        mp_root ++ "py/modstruct.c",
        mp_root ++ "py/modsys.c",
        mp_root ++ "py/moderrno.c",
        mp_root ++ "py/modthread.c",
        mp_root ++ "py/vm.c",
        mp_root ++ "py/bc.c",
        mp_root ++ "py/showbc.c",
        mp_root ++ "py/repl.c",
        mp_root ++ "py/smallint.c",
        mp_root ++ "py/frozenmod.c",
    };

    // Port-specific sources
    const mp_port_sources: []const []const u8 = &.{
        mp_port ++ "mphalport.c",
        mp_port ++ "mp_main.c",
        mp_port ++ "modukernel.c",
        "kernel/libc_shim.c",
        mp_root ++ "shared/runtime/stdout_helpers.c",
    };

    for (mp_include_paths) |inc| {
        exe.addIncludePath(b.path(inc));
    }

    exe.addCSourceFiles(.{
        .files = mp_py_sources,
        .flags = mp_c_flags,
    });

    exe.addCSourceFiles(.{
        .files = mp_port_sources,
        .flags = mp_c_flags,
    });

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
