const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.16: Create module with explicit target/optimize
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig-port-scanner",
        .root_module = mod,
    });

    // Link libc for getaddrinfo() DNS resolution
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the port scanner");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---
    //
    // Zig 0.16 note: test-name filters are a *compile-time* option on addTest
    // (`.filters`), NOT a runtime `--test-filter` argument. The stock 0.16.0
    // test runner rejects `--test-filter` on the command line ("unrecognized
    // command line argument"), so each filtered subset needs its own test
    // artifact.
    //
    // Each test artifact gets its own module: a Module cannot be reused as the
    // root of more than one Compile step.

    // `zig build test` — run every test (unit + network integration).
    const test_all_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_all_mod.link_libc = true;
    const test_all = b.addTest(.{ .root_module = test_all_mod });
    const test_step = b.step("test", "Run all tests (unit + network integration)");
    test_step.dependOn(&b.addRunArtifact(test_all).step);

    // `zig build test-unit` — deterministic, offline tests only.
    // Excludes anything requiring network (the `integration:` tests) plus the
    // localhost socket/DNS/timeout tests, so this step is hermetic and safe in
    // isolated CI.
    const test_unit_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_unit_mod.link_libc = true;
    const test_unit = b.addTest(.{
        .root_module = test_unit_mod,
        .filters = &.{ "parse", "service", "status", "IP", "dedup" },
    });
    const unit_test_step = b.step("test-unit", "Run offline unit tests only (no network)");
    unit_test_step.dependOn(&b.addRunArtifact(test_unit).step);

    // `zig build test-integration` — network-dependent tests only.
    const test_int_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_int_mod.link_libc = true;
    const test_int = b.addTest(.{
        .root_module = test_int_mod,
        .filters = &.{"integration"},
    });
    const integration_test_step = b.step("test-integration", "Run network integration tests (requires network)");
    integration_test_step.dependOn(&b.addRunArtifact(test_int).step);
}
