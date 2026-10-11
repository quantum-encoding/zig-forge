const std = @import("std");

// Zig 0.17 renamed the optimize tags (Debug/ReleaseSafe/ReleaseFast/ReleaseSmall became
// debug/safe/fast/small) and keeps the old names only as declarations on the enum, which an
// enum literal cannot reach; naming them through the type compiles on 0.16 and 0.17.
const Optimize = std.builtin.OptimizeMode;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // CLI Executable
    // ==========================================================================
    const exe = b.addExecutable(.{
        .name = "zsss",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Zig 0.17 removed `b.args` (configure logic can no longer see run arguments) in
    // favour of `addPassthruArgs`, which 0.16 does not have; the comptime branch keeps
    // both compiling.
    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) run_cmd.addPassthruArgs() else if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zsss");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // Library (Static + Shared)
    // ==========================================================================

    // Static library (with PIC for shared library linking)
    const static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zsss",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        }),
    });
    b.installArtifact(static_lib);

    // Shared library
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zsss",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(shared_lib);

    // ==========================================================================
    // Cross-compilation targets
    // ==========================================================================

    // Android targets
    const android_targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android },
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .androideabi },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .android },
        .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .android },
    };

    const android_names = [_][]const u8{
        "aarch64-android",
        "arm-android",
        "x86_64-android",
        "x86-android",
    };

    // Linux targets
    const linux_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    };

    const linux_names = [_][]const u8{
        "x86_64-linux-gnu",
        "aarch64-linux-gnu",
        "x86_64-linux-musl",
        "aarch64-linux-musl",
    };

    // Every Apple target names its deployment floor: an un-versioned one takes Zig's
    // default, which moved from macOS 13 / iOS 15 (0.16) to macOS 15 / iOS 18 (0.17), and
    // an object newer than the app it is linked into makes ld64 warn "built for newer"
    // while the floor silently moves. The fleet's floor is 26.0 on both (Cifra's).
    const apple_floor: std.Target.Query.OsVersion = .{ .semver = .{ .major = 26, .minor = 0, .patch = 0 } };

    // macOS targets
    const macos_targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none, .os_version_min = apple_floor },
        .{ .cpu_arch = .x86_64, .os_tag = .macos, .abi = .none, .os_version_min = apple_floor },
    };

    const macos_names = [_][]const u8{
        "aarch64-macos",
        "x86_64-macos",
    };

    // iOS targets (device)
    const ios_targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .none, .os_version_min = apple_floor },
    };

    const ios_names = [_][]const u8{
        "aarch64-ios",
    };

    // iOS Simulator targets
    const ios_sim_targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator, .os_version_min = apple_floor },
        .{ .cpu_arch = .x86_64, .os_tag = .ios, .abi = .simulator, .os_version_min = apple_floor },
    };

    const ios_sim_names = [_][]const u8{
        "aarch64-ios-simulator",
        "x86_64-ios-simulator",
    };

    // Build step for all Android libraries
    const android_step = b.step("android", "Build libraries for all Android targets");

    for (android_targets, android_names) |t, name| {
        const resolved = b.resolveTargetQuery(t);

        // link_libc = true is required so Zig emits the right TLS
        // access sequences for x86_64 / armv7 (those ABIs use a TLS
        // model that depends on __tls_get_addr from Bionic libc).
        // arm64-v8a uses a libc-free TLS model so it'd link without,
        // but enabling for all four arches keeps the build flag matrix
        // consistent.
        const android_static = b.addLibrary(.{
            .linkage = .static,
            .name = b.fmt("zsss-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = resolved,
                .optimize = Optimize.ReleaseFast,
                .link_libc = true,
                .pic = true,
            }),
        });
        const android_static_install = b.addInstallArtifact(android_static, .{});
        android_step.dependOn(&android_static_install.step);

        const android_shared = b.addLibrary(.{
            .linkage = .dynamic,
            .name = b.fmt("zsss-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = resolved,
                .optimize = Optimize.ReleaseFast,
                .link_libc = true,
            }),
        });
        const android_shared_install = b.addInstallArtifact(android_shared, .{});
        android_step.dependOn(&android_shared_install.step);
    }

    // Build step for all Linux libraries
    const linux_step = b.step("linux", "Build libraries for all Linux targets");

    for (linux_targets, linux_names) |t, name| {
        const resolved = b.resolveTargetQuery(t);

        const linux_static = b.addLibrary(.{
            .linkage = .static,
            .name = b.fmt("zsss-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = resolved,
                .optimize = Optimize.ReleaseFast,
                .pic = true,
            }),
        });
        const linux_static_install = b.addInstallArtifact(linux_static, .{});
        linux_step.dependOn(&linux_static_install.step);

        const linux_shared = b.addLibrary(.{
            .linkage = .dynamic,
            .name = b.fmt("zsss-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = resolved,
                .optimize = Optimize.ReleaseFast,
            }),
        });
        const linux_shared_install = b.addInstallArtifact(linux_shared, .{});
        linux_step.dependOn(&linux_shared_install.step);
    }

    // Build step for all macOS libraries
    const macos_step = b.step("macos", "Build libraries for all macOS targets");

    for (macos_targets, macos_names) |t, name| {
        const resolved = b.resolveTargetQuery(t);

        const macos_static = b.addLibrary(.{
            .linkage = .static,
            .name = b.fmt("zsss-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = resolved,
                .optimize = Optimize.ReleaseFast,
                .pic = true,
            }),
        });
        const macos_static_install = b.addInstallArtifact(macos_static, .{});
        macos_step.dependOn(&macos_static_install.step);

        const macos_shared = b.addLibrary(.{
            .linkage = .dynamic,
            .name = b.fmt("zsss-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = resolved,
                .optimize = Optimize.ReleaseFast,
            }),
        });
        const macos_shared_install = b.addInstallArtifact(macos_shared, .{});
        macos_step.dependOn(&macos_shared_install.step);
    }

    // Build step for all iOS libraries (device + simulator)
    const ios_step = b.step("ios", "Build libraries for all iOS targets");

    // iOS device
    for (ios_targets, ios_names) |t, name| {
        const resolved = b.resolveTargetQuery(t);

        const ios_static = b.addLibrary(.{
            .linkage = .static,
            .name = b.fmt("zsss-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = resolved,
                .optimize = Optimize.ReleaseFast,
                .pic = true,
            }),
        });
        const ios_static_install = b.addInstallArtifact(ios_static, .{});
        ios_step.dependOn(&ios_static_install.step);

        // Note: iOS doesn't support dynamic libraries for apps, only static
    }

    // iOS Simulator
    for (ios_sim_targets, ios_sim_names) |t, name| {
        const resolved = b.resolveTargetQuery(t);

        const ios_sim_static = b.addLibrary(.{
            .linkage = .static,
            .name = b.fmt("zsss-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = resolved,
                .optimize = Optimize.ReleaseFast,
                .pic = true,
            }),
        });
        const ios_sim_install = b.addInstallArtifact(ios_sim_static, .{});
        ios_step.dependOn(&ios_sim_install.step);
    }

    // Windows (MSVC ABI, what Rust's x86_64-pc-windows-msvc links). Zig ships no
    // MSVC libc headers, so this builds on a Windows host with Visual Studio's
    // tools installed, not as a cross-compile. Zig names the archive
    // zsss-x86_64-windows.lib.
    const windows_step = b.step("windows", "Build the static library for Windows x86_64 (MSVC; on a Windows host)");
    const windows_static = b.addLibrary(.{
        .linkage = .static,
        .name = "zsss-x86_64-windows",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc }),
            .optimize = Optimize.ReleaseFast,
            .link_libc = true,
        }),
    });
    windows_step.dependOn(&b.addInstallArtifact(windows_static, .{}).step);

    // Apple combined step
    const apple_step = b.step("apple", "Build libraries for all Apple targets (macOS + iOS)");
    apple_step.dependOn(macos_step);
    apple_step.dependOn(ios_step);

    // Combined step for all platforms
    const all_libs_step = b.step("libs", "Build libraries for all platforms");
    all_libs_step.dependOn(android_step);
    all_libs_step.dependOn(linux_step);
    all_libs_step.dependOn(apple_step);

    // ==========================================================================
    // Tests
    // ==========================================================================
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    // Externally-anchored tests (FIPS-197 GF vectors, independently-generated
    // Shamir shares, PNG-spec crafted inputs, ticket wire-format transcripts).
    const anchor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_anchor_tests = b.addRunArtifact(anchor_tests);
    test_step.dependOn(&run_anchor_tests.step);

    // Official SLIP-0039 test vectors. The archived vector file lives in tests/
    // and is handed to the test module as an anonymous import so that
    // @embedFile can reach it without keeping a second copy under src/.
    const slip39_vectors_module = b.createModule(.{
        .root_source_file = b.path("src/slip39_vectors_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    slip39_vectors_module.addAnonymousImport("slip39_vectors", .{
        .root_source_file = b.path("tests/slip-0039-vectors.json"),
    });

    const slip39_vector_tests = b.addTest(.{ .root_module = slip39_vectors_module });
    const run_slip39_vector_tests = b.addRunArtifact(slip39_vector_tests);
    test_step.dependOn(&run_slip39_vector_tests.step);

    // Hostile-input tests for the PNG decoder (crypto test campaign 2026-10-11, track E).
    // The fixtures are produced by CPython's zlib (tests/make_png_fixtures.py) and handed
    // to the module as anonymous imports, the same way as the SLIP-0039 vectors.
    const stego_hostile_module = b.createModule(.{
        .root_source_file = b.path("src/stego_hostile_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stego_hostile_module.addAnonymousImport("zlib_bomb", .{
        .root_source_file = b.path("tests/zlib-bomb-64mib.zlib"),
    });
    stego_hostile_module.addAnonymousImport("png_gradient", .{
        .root_source_file = b.path("tests/png-gradient-64x64-filtered.png"),
    });

    const stego_hostile_tests = b.addTest(.{ .root_module = stego_hostile_module });
    const run_stego_hostile_tests = b.addRunArtifact(stego_hostile_tests);
    test_step.dependOn(&run_stego_hostile_tests.step);
}
