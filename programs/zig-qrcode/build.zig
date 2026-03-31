const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Cross-Platform Target Definitions
    // ========================================================================

    const CrossTarget = struct {
        name: []const u8,
        query: std.Target.Query,
    };

    const cross_targets = [_]CrossTarget{
        .{ .name = "macos-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "macos-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
        .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux } },
        .{ .name = "ios-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .ios } },
        .{ .name = "android-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android } },
        .{ .name = "android-arm32", .query = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .android } },
    };

    // ========================================================================
    // ZigQR FFI Library (Static)
    // ========================================================================

    const ffi_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const ffi_static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigqr",
        .root_module = ffi_lib_mod,
    });
    b.installArtifact(ffi_static_lib);

    // ========================================================================
    // ZigQR FFI Library (Shared)
    // ========================================================================

    const ffi_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const ffi_shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zigqr_shared",
        .root_module = ffi_shared_mod,
    });
    b.installArtifact(ffi_shared_lib);

    // ========================================================================
    // CLI Executable
    // ========================================================================

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const cli_exe = b.addExecutable(.{
        .name = "zigqr",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    const run_cli = b.addRunArtifact(cli_exe);
    if (b.args) |args| {
        run_cli.addArgs(args);
    }
    const run_step = b.step("run", "Run the zigqr CLI");
    run_step.dependOn(&run_cli.step);

    // ========================================================================
    // Cross-Compilation Targets
    // ========================================================================

    const cross_step = b.step("cross", "Build for all cross-compilation targets");

    inline for (cross_targets) |ct| {
        const cross_target = b.resolveTargetQuery(ct.query);

        const opt_mode: std.builtin.OptimizeMode = if (ct.query.os_tag == .ios)
            .ReleaseFast
        else
            .ReleaseSafe;

        const cross_mod = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = cross_target,
            .optimize = opt_mode,
            .link_libc = true,
            .strip = if (ct.query.os_tag == .ios) true else false,
        });

        const cross_lib = b.addLibrary(.{
            .linkage = .static,
            .name = "zigqr_" ++ ct.name,
            .root_module = cross_mod,
        });

        b.installArtifact(cross_lib);
        cross_step.dependOn(&cross_lib.step);
    }

    // ========================================================================
    // WASM Build
    // ========================================================================

    const wasm_step = b.step("wasm", "Build WASM module");

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSmall,
    });

    const wasm_lib = b.addExecutable(.{
        .name = "zigqr",
        .root_module = wasm_mod,
    });
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;

    const wasm_install = b.addInstallArtifact(wasm_lib, .{
        .dest_sub_path = "zigqr.wasm",
    });
    wasm_step.dependOn(&wasm_install.step);

    // ========================================================================
    // Header Generation Tool
    // ========================================================================

    const gen_header_step = b.step("gen-header", "Generate C header file");

    const gen_header_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_header.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zigqr_ffi", .module = b.createModule(.{
                .root_source_file = b.path("src/ffi.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }) },
        },
    });

    const gen_header_exe = b.addExecutable(.{
        .name = "gen_header",
        .root_module = gen_header_mod,
    });

    const run_gen_header = b.addRunArtifact(gen_header_exe);
    gen_header_step.dependOn(&run_gen_header.step);

    // ========================================================================
    // Tests
    // ========================================================================

    // QR core tests
    const qr_test_mod = b.createModule(.{
        .root_source_file = b.path("src/qrcode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const qr_tests = b.addTest(.{
        .root_module = qr_test_mod,
    });
    const run_qr_tests = b.addRunArtifact(qr_tests);

    // PNG encoder tests
    const png_test_mod = b.createModule(.{
        .root_source_file = b.path("src/png.zig"),
        .target = target,
        .optimize = optimize,
    });
    const png_tests = b.addTest(.{
        .root_module = png_test_mod,
    });
    const run_png_tests = b.addRunArtifact(png_tests);

    // FFI tests
    const ffi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ffi_tests = b.addTest(.{
        .root_module = ffi_test_mod,
    });
    const run_ffi_tests = b.addRunArtifact(ffi_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_qr_tests.step);
    test_step.dependOn(&run_png_tests.step);
    test_step.dependOn(&run_ffi_tests.step);

    // ========================================================================
    // Package for Distribution
    // ========================================================================

    const package_step = b.step("package", "Create distribution package");
    package_step.dependOn(cross_step);
    package_step.dependOn(gen_header_step);
}
