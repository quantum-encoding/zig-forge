const std = @import("std");

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
    if (b.args) |args| run_cmd.addArgs(args);

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

    // macOS targets
    const macos_targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
        .{ .cpu_arch = .x86_64, .os_tag = .macos, .abi = .none },
    };

    const macos_names = [_][]const u8{
        "aarch64-macos",
        "x86_64-macos",
    };

    // iOS targets (device)
    const ios_targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .none },
    };

    const ios_names = [_][]const u8{
        "aarch64-ios",
    };

    // iOS Simulator targets
    const ios_sim_targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator },
        .{ .cpu_arch = .x86_64, .os_tag = .ios, .abi = .simulator },
    };

    const ios_sim_names = [_][]const u8{
        "aarch64-ios-simulator",
        "x86_64-ios-simulator",
    };

    // Build step for all Android libraries
    const android_step = b.step("android", "Build libraries for all Android targets");

    for (android_targets, android_names) |t, name| {
        const resolved = b.resolveTargetQuery(t);

        const android_static = b.addLibrary(.{
            .linkage = .static,
            .name = b.fmt("zsss-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = resolved,
                .optimize = .ReleaseFast,
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
                .optimize = .ReleaseFast,
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
                .optimize = .ReleaseFast,
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
                .optimize = .ReleaseFast,
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
                .optimize = .ReleaseFast,
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
                .optimize = .ReleaseFast,
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
                .optimize = .ReleaseFast,
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
                .optimize = .ReleaseFast,
                .pic = true,
            }),
        });
        const ios_sim_install = b.addInstallArtifact(ios_sim_static, .{});
        ios_step.dependOn(&ios_sim_install.step);
    }

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
}
