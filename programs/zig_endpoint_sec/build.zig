const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const darwin_kit = b.dependency("darwin_kit", .{ .target = target, .optimize = optimize });
    const darwin_kit_mod = darwin_kit.module("darwin_kit");

    // Library module, importable as "endpoint_sec".
    const mod = b.addModule("endpoint_sec", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "darwin_kit", .module = darwin_kit_mod }},
    });
    // libEndpointSecurity.dylib lives in /usr/lib, not in a framework bundle.
    mod.linkSystemLibrary("EndpointSecurity", .{});

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "endpoint_sec",
        .root_module = mod,
    });

    // Tests: layout anchors need no entitlement; client tests exercise the
    // real es_new_client path and expect NOT_ENTITLED / NOT_PERMITTED.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "darwin_kit", .module = darwin_kit_mod }},
    });
    test_mod.linkSystemLibrary("EndpointSecurity", .{});
    test_mod.addIncludePath(b.path("include"));
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests and layout anchors (macOS only)");
    test_step.dependOn(&run_tests.step);

    // C ABI static library (the zes_* half of include/es_core.h) for Swift/C hosts.
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "darwin_kit", .module = darwin_kit_mod }},
    });
    capi_mod.addIncludePath(b.path("include"));
    const capi = b.addLibrary(.{
        .linkage = .static,
        .name = "es_core_zig",
        .root_module = capi_mod,
    });
    capi.installHeader(b.path("include/es_core.h"), "es_core.h");

    // zig-out/lib/libes_core_zig.a and zig-out/lib/libendpoint_sec.a are the
    // archives libs.toml row `endpoint_sec` stamps (scripts/build-macos-lib.sh,
    // scripts/build-consumed-libs.sh). Only the `lib` step writes those paths,
    // and only in a release mode; build-macos-lib.sh runs `zig build lib`.
    // `zig build` and any -Doptimize install the archives under zig-out/lib/dev/,
    // and `zig build xcode` under zig-out/lib/xcode/, so neither replaces the
    // stamped release archives.
    const lib_step = b.step("lib", "Build the archives libs.toml stamps into zig-out/lib/ (release modes only; use scripts/build-macos-lib.sh)");
    switch (optimize) {
        .ReleaseSmall, .ReleaseFast => {
            lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
            lib_step.dependOn(&b.addInstallArtifact(capi, .{}).step);
        },
        .Debug, .ReleaseSafe => lib_step.dependOn(&b.addFail(b.fmt(
            "zig build lib writes zig-out/lib/libes_core_zig.a and libendpoint_sec.a, the archives libs.toml stamps; " ++
                "a {t} build keeps Zig's panic machinery and is never those archives. " ++
                "Run scripts/build-macos-lib.sh programs/zig_endpoint_sec ReleaseFast from the repo root " ++
                "(repacked, stamped), plain `zig build` for zig-out/lib/dev/, or `zig build xcode` for zig-out/lib/xcode/",
            .{optimize},
        )).step),
    }
    const dev_dir: std.Build.Step.InstallArtifact.Options = .{ .dest_dir = .{ .override = .{ .custom = "lib/dev" } } };
    b.getInstallStep().dependOn(&b.addInstallArtifact(lib, dev_dir).step);
    b.getInstallStep().dependOn(&b.addInstallArtifact(capi, dev_dir).step);

    // `zig build xcode` (MetatronSecurity's es-core/build.sh, any -Doptimize):
    // install both archives under zig-out/lib/xcode/, then repack them so
    // Apple's ld accepts them.
    const xcode_dir: std.Build.InstallDir = .{ .custom = "lib/xcode" };
    const repack = b.addSystemCommand(&.{
        "../../scripts/repack-for-xcode.sh",
        b.getInstallPath(xcode_dir, "libes_core_zig.a"),
        b.getInstallPath(xcode_dir, "libendpoint_sec.a"),
    });
    repack.step.dependOn(&b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = xcode_dir } }).step);
    repack.step.dependOn(&b.addInstallArtifact(capi, .{ .dest_dir = .{ .override = xcode_dir } }).step);
    const xcode_step = b.step("xcode", "Build and repack the static libraries into zig-out/lib/xcode/ for linking from Xcode");
    xcode_step.dependOn(&repack.step);

    // Example: subscribe to a few NOTIFY events and print them. Needs the ES
    // entitlement, Developer ID signing and root to actually receive events.
    const tap_mod = b.createModule(.{
        .root_source_file = b.path("examples/es_tap.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "endpoint_sec", .module = mod },
            .{ .name = "darwin_kit", .module = darwin_kit_mod },
        },
    });
    const tap = b.addExecutable(.{ .name = "es-tap", .root_module = tap_mod });
    b.installArtifact(tap);

    // Regenerate src/layout_anchors.zig and src/enums.zig from the active SDK.
    const gen = b.addSystemCommand(&.{ "python3", "tools/gen_layout_anchors.py" });
    const gen_step = b.step("gen-anchors", "Regenerate layout anchors and enums from the SDK headers (needs Xcode clang)");
    gen_step.dependOn(&gen.step);
}
