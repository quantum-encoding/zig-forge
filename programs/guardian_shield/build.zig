const std = @import("std");

pub fn build(b: *std.Build) void {
    // WORKAROUND: Target glibc 2.39 to avoid translate-c bugs with glibc 2.42
    // See: ZIG_BUG_REPORT.md for details
    const target_query = std.Target.Query{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 39, .patch = 0 },
    };
    const target = b.resolveTargetQuery(target_query);

    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // Core Security Libraries
    // ============================================================

    // libwarden.so - Filesystem protection via syscall interception
    const libwarden_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/libwarden/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const libwarden = b.addLibrary(.{
        .name = "warden",
        .root_module = libwarden_module,
        .linkage = .dynamic,
    });
    libwarden.root_module.link_libc = true;
    // WORKAROUND: Undefine and redefine _FORTIFY_SOURCE to avoid __builtin_va_arg_pack issues
    // Zig 0.16.0-dev automatically adds -D_FORTIFY_SOURCE=2 for ReleaseSafe builds,
    // but translate-c doesn't support the GCC builtins used by glibc 2.42+ fortified headers
    libwarden.root_module.addCMacro("_FORTIFY_SOURCE", "0");
    b.installArtifact(libwarden);

    // libwarden_fork.so - Fork bomb protection
    const libwarden_fork_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/libwarden_fork/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const libwarden_fork = b.addLibrary(.{
        .name = "warden-fork",
        .root_module = libwarden_fork_module,
        .linkage = .dynamic,
    });
    libwarden_fork.root_module.link_libc = true;
    // WORKAROUND: Disable _FORTIFY_SOURCE (same issue as libwarden)
    libwarden_fork.root_module.addCMacro("_FORTIFY_SOURCE", "0");
    b.installArtifact(libwarden_fork);

    // ============================================================
    // Optional Monitoring Tools
    // ============================================================

    // zig_sentinel - eBPF-based system monitoring
    const sentinel_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/zig_sentinel/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const sentinel = b.addExecutable(.{
        .name = "zig_sentinel",
        .root_module = sentinel_module,
    });
    sentinel.root_module.link_libc = true;
    sentinel.root_module.linkSystemLibrary("bpf", .{});
    // Add system library and include paths for libbpf
    sentinel.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    sentinel.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    // WORKAROUND: Disable _FORTIFY_SOURCE (same issue as libwarden)
    sentinel.root_module.addCMacro("_FORTIFY_SOURCE", "0");
    b.installArtifact(sentinel);

    // NOTE: the `test-inquisitor` and `test-oracle-advanced` eBPF LSM BPF harness
    // targets were removed here. Their source files
    // (src/zig_sentinel/test-{inquisitor,oracle-advanced}.zig) are gitignored and
    // exist in no clone, so declaring them as install artifacts made `zig build`
    // fail with FileNotFound on every fresh checkout (confirmed on Linux CI). If you
    // have the local harness sources, re-add the two `addExecutable` blocks locally.

    // hardware-detector - Detect system capabilities for adaptive pattern loading
    const hardware_detector_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/zig_sentinel/hardware_detector.zig" },
        .target = target,
        .optimize = optimize,
    });
    const hardware_detector_exe = b.addExecutable(.{
        .name = "hardware-detector",
        .root_module = hardware_detector_module,
    });
    hardware_detector_exe.root_module.link_libc = true;
    // WORKAROUND: Disable _FORTIFY_SOURCE (same translate-c issue as libwarden;
    // only bit under ReleaseSafe/ReleaseFast, where Zig injects -D_FORTIFY_SOURCE=2)
    hardware_detector_exe.root_module.addCMacro("_FORTIFY_SOURCE", "0");
    b.installArtifact(hardware_detector_exe);

    // adaptive-pattern-loader - Load patterns based on hardware capabilities
    const adaptive_loader_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/zig_sentinel/adaptive_pattern_loader.zig" },
        .target = target,
        .optimize = optimize,
    });
    const adaptive_loader_exe = b.addExecutable(.{
        .name = "adaptive-pattern-loader",
        .root_module = adaptive_loader_module,
    });
    adaptive_loader_exe.root_module.link_libc = true;
    // WORKAROUND: Disable _FORTIFY_SOURCE (same issue as libwarden)
    adaptive_loader_exe.root_module.addCMacro("_FORTIFY_SOURCE", "0");
    b.installArtifact(adaptive_loader_exe);

    // ============================================================
    // V8.0: wardenctl - Guardian Shield Control CLI
    // ============================================================

    // wardenctl - Runtime configuration management tool
    const wardenctl_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/wardenctl/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const wardenctl = b.addExecutable(.{
        .name = "wardenctl",
        .root_module = wardenctl_module,
    });
    wardenctl.root_module.link_libc = true;
    // WORKAROUND: Disable _FORTIFY_SOURCE (same issue as libwarden)
    wardenctl.root_module.addCMacro("_FORTIFY_SOURCE", "0");
    b.installArtifact(wardenctl);

    // ============================================================
    // V8.0: Embeddable Warden Module & Static Library
    // ============================================================

    // libwarden_static.a - Static library for linking into applications
    const libwarden_static_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/libwarden/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const libwarden_static = b.addLibrary(.{
        .name = "warden_static",
        .root_module = libwarden_static_module,
        .linkage = .static,
    });
    libwarden_static.root_module.link_libc = true;
    libwarden_static.root_module.addCMacro("_FORTIFY_SOURCE", "0");
    b.installArtifact(libwarden_static);

    // warden module - Embeddable Zig module for programmatic control
    // Programs can: @import("warden") to get protection APIs
    const warden_embed_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/warden/warden.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Example program showing embedded warden usage
    const warden_example_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/warden/example.zig" },
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "warden", .module = warden_embed_module },
        },
    });
    const warden_example = b.addExecutable(.{
        .name = "warden-example",
        .root_module = warden_example_module,
    });
    warden_example.root_module.link_libc = true;
    // WORKAROUND: Disable _FORTIFY_SOURCE (same issue as libwarden; the warden
    // module it imports @cImports fortified glibc headers)
    warden_example.root_module.addCMacro("_FORTIFY_SOURCE", "0");
    warden_embed_module.addCMacro("_FORTIFY_SOURCE", "0");
    b.installArtifact(warden_example);

    // Install the warden module source for external projects to import
    b.installFile("src/warden/warden.zig", "include/warden.zig");

    // ============================================================
    // Tests
    // ============================================================

    const lib_tests_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/libwarden/main.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_tests_module.addCMacro("_FORTIFY_SOURCE", "0");
    const lib_tests = b.addTest(.{
        .root_module = lib_tests_module,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const fork_tests_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/libwarden_fork/main.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fork_tests_module.addCMacro("_FORTIFY_SOURCE", "0");
    const fork_tests = b.addTest(.{
        .root_module = fork_tests_module,
    });
    const run_fork_tests = b.addRunArtifact(fork_tests);

    // Grimoire tests
    const grimoire_tests_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/zig_sentinel/grimoire.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    grimoire_tests_module.addCMacro("_FORTIFY_SOURCE", "0");
    const grimoire_tests = b.addTest(.{
        .root_module = grimoire_tests_module,
    });
    const run_grimoire_tests = b.addRunArtifact(grimoire_tests);

    // Previously-orphaned test blocks: existing `test "..."` declarations that
    // were never wired into `zig build test`. Rooted here so they actually run.
    // NOTE: only files that compile clean under Zig 0.16 are wired. warden.zig,
    // zig_http_sentinel/config.zig, and zig_sentinel/correlation.zig carry
    // pre-existing 0.16 API-drift compile errors and are intentionally left out
    // until that drift is fixed (see TODO below) — wiring them would turn a
    // runtime failure into a compile failure on the whole test step.
    const orphan_test_sources = [_][]const u8{
        "src/zig_http_sentinel/filter_engine.zig",
        "src/zig_sentinel/emoji_database.zig",
        "src/zig_sentinel/emoji_sanitizer.zig",
        // TODO(0.16-drift): re-add after fixing API drift, then verify on a
        // Linux host (this build.zig cross-pins to x86_64-linux):
        //   "src/warden/warden.zig",
        //   "src/zig_http_sentinel/config.zig",
        //   "src/zig_sentinel/correlation.zig",
    };

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_fork_tests.step);
    test_step.dependOn(&run_grimoire_tests.step);

    for (orphan_test_sources) |src_path| {
        const orphan_module = b.createModule(.{
            .root_source_file = .{ .cwd_relative = src_path },
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        orphan_module.addCMacro("_FORTIFY_SOURCE", "0");
        const orphan_tests = b.addTest(.{
            .root_module = orphan_module,
        });
        const run_orphan_tests = b.addRunArtifact(orphan_tests);
        test_step.dependOn(&run_orphan_tests.step);
    }
}
