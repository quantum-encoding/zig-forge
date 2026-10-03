const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // LLD links ELF (see the exe below for why it is wanted there); it cannot
    // link Mach-O, so Apple targets use Zig's own linker.
    const use_lld = !target.result.os.tag.isDarwin();

    // ============================================================
    // Core Module
    // ============================================================

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ============================================================
    // Static Library (for FFI integration with Rust/Tauri)
    // ============================================================

    const static_lib = b.addLibrary(.{
        .name = "zdedupe",
        .root_module = lib_module,
        .linkage = .static,
    });
    // Windows has no C runtime Zig can link for an MSVC host; the core calls
    // Win32 there instead (src/sys_windows.zig).
    const link_libc = target.result.os.tag != .windows;
    static_lib.root_module.link_libc = link_libc;
    static_lib.root_module.strip = optimize != .Debug;
    // The results session parses its queries with std.json, whose integer
    // path falls back to f128 (`sliceToInt`), and f128 arithmetic is
    // compiler_rt (__divtf3, __fixtfti, roundq, ...). Nothing in a host's
    // toolchain provides those, so without this the archive links under
    // `zig build` and fails under Xcode's ld and Rust's linker alike.
    static_lib.bundle_compiler_rt = true;
    b.installArtifact(static_lib);

    // ============================================================
    // Shared Library (for dynamic linking)
    // ============================================================

    const shared_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const shared_lib = b.addLibrary(.{
        .name = "zdedupe",
        .root_module = shared_module,
        .linkage = .dynamic,
        .use_llvm = true,
        .use_lld = use_lld,
    });
    shared_lib.root_module.link_libc = link_libc;
    shared_lib.root_module.strip = optimize != .Debug;

    const shared_install = b.addInstallArtifact(shared_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/shared" } },
    });

    const shared_step = b.step("shared", "Build shared library");
    shared_step.dependOn(&shared_install.step);

    // ============================================================
    // CLI Tool
    // ============================================================

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Everything that links against the system libc is pinned to LLVM + LLD.
    // Zig's self-hosted ELF linker (the Debug default on x86_64) rejects the
    // R_X86_64_PC64 relocations in the `.sframe` section that glibc >= 2.44 /
    // binutils >= 2.47 put in crt1.o, so Debug builds and `zig build test`
    // fail at link time on current rolling distros. LLD handles them.
    const exe = b.addExecutable(.{
        .name = "zdedupe",
        .root_module = exe_module,
        .use_llvm = true,
        .use_lld = use_lld,
    });
    exe.root_module.link_libc = link_libc;
    // The CLI is a POSIX tool; on Windows only the library is built.
    if (target.result.os.tag != .windows) b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the CLI tool");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // Tests
    // ============================================================

    const test_step = b.step("test", "Run unit tests");

    // Test each module
    const test_modules = [_][]const u8{
        "src/types.zig",
        "src/hasher.zig",
        "src/pstat.zig",
        "src/testing_scratch.zig",
        "src/walker.zig",
        "src/dirstream.zig",
        "src/chunked.zig",
        "src/fast_walker.zig",
        "src/parallel.zig",
        "src/dedupe.zig",
        "src/dirs.zig",
        "src/store.zig",
        "src/compare.zig",
        "src/report.zig",
        "src/filters.zig",
        "src/protect.zig",
        "src/keep.zig",
        "src/removed.zig",
        "src/session.zig",
        // The results session end to end: the real engine into a real store,
        // then the session over it (see the file header).
        "src/session_test.zig",
        // Disk-space scans end to end, the same way.
        "src/space.zig",
        "src/space_test.zig",
        "src/lib.zig",
        // External anchors + end-to-end contract tests (see file header).
        "src/tier1_anchors.zig",
    };

    for (test_modules) |mod| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });

        const mod_test = b.addTest(.{
            .root_module = test_mod,
            .use_llvm = true,
            .use_lld = use_lld,
        });
        mod_test.root_module.link_libc = link_libc;
        test_step.dependOn(&b.addRunArtifact(mod_test).step);
    }

    // ============================================================
    // Format check
    // ============================================================

    const fmt_step = b.step("fmt", "Format source files");
    const fmt = b.addFmt(.{
        .paths = &.{"src"},
    });
    fmt_step.dependOn(&fmt.step);

    // ============================================================
    // Header install
    // ============================================================

    const header_step = b.step("header", "Install C header for FFI");
    const header_install = b.addInstallFile(b.path("include/zdedupe.h"), "include/zdedupe.h");
    header_step.dependOn(&header_install.step);
}
