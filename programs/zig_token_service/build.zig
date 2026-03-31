const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // Import dependencies from local packages
    // ==========================================================================
    const uuid_dep = b.dependency("zig_uuid", .{ .target = target, .optimize = optimize });
    const jwt_dep = b.dependency("zig_jwt", .{ .target = target, .optimize = optimize });
    const ratelimit_dep = b.dependency("zig_ratelimit", .{ .target = target, .optimize = optimize });
    const metrics_dep = b.dependency("zig_metrics", .{ .target = target, .optimize = optimize });
    const bloom_dep = b.dependency("zig_bloom", .{ .target = target, .optimize = optimize });
    const base58_dep = b.dependency("zig_base58", .{ .target = target, .optimize = optimize });

    // ==========================================================================
    // Token Service Library
    // ==========================================================================
    const lib_module = b.addModule("token_service", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add all dependency imports
    lib_module.addImport("uuid", uuid_dep.module("uuid"));
    lib_module.addImport("jwt", jwt_dep.module("jwt"));
    lib_module.addImport("ratelimit", ratelimit_dep.module("ratelimit"));
    lib_module.addImport("metrics", metrics_dep.module("metrics"));
    lib_module.addImport("bloom", bloom_dep.module("bloom"));
    lib_module.addImport("base58", base58_dep.module("base58"));

    // Static library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "token_service",
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // ==========================================================================
    // Demo CLI
    // ==========================================================================
    const demo_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_module.addImport("token_service", lib_module);
    demo_module.addImport("uuid", uuid_dep.module("uuid"));
    demo_module.addImport("jwt", jwt_dep.module("jwt"));
    demo_module.addImport("ratelimit", ratelimit_dep.module("ratelimit"));
    demo_module.addImport("metrics", metrics_dep.module("metrics"));
    demo_module.addImport("bloom", bloom_dep.module("bloom"));
    demo_module.addImport("base58", base58_dep.module("base58"));

    const demo = b.addExecutable(.{
        .name = "token-service",
        .root_module = demo_module,
    });
    b.installArtifact(demo);

    const run_cmd = b.addRunArtifact(demo);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the token service demo");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // WASM Target for Web Auth
    // ==========================================================================
    const wasm_step = b.step("wasm", "Build WebAssembly module for browser auth");

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // WASM module is standalone - no dependencies (all crypto inline)
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_ffi.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm_lib = b.addExecutable(.{
        .name = "token_service",
        .root_module = wasm_module,
    });

    // Export memory and functions for JS interop
    wasm_lib.export_memory = true;
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;

    const wasm_install = b.addInstallArtifact(wasm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    wasm_step.dependOn(&wasm_install.step);

    // ==========================================================================
    // Tests
    // ==========================================================================
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = lib_module,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
