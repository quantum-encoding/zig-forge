const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http_sentinel_dep = b.dependency("http_sentinel", .{
        .target = target,
        .optimize = optimize,
    });
    const http_sentinel_module = http_sentinel_dep.module("http-sentinel");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("http-sentinel", http_sentinel_module);

    const exe = b.addExecutable(.{
        .name = "qai",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the qai chat client");
    run_step.dependOn(&run_cmd.step);

    // Test step — runs the existing per-file unit tests plus the new
    // FakeProvider harness. Each entry gets its own test binary; the
    // step depends on running all of them. The harness test reads a
    // JSONL fixture from `tests/fixtures/`, so `zig build test` must
    // be invoked from the project root (which is the standard cwd
    // when using `zig build`).
    const test_step = b.step("test", "Run all tests");

    const unit_test_targets = [_][]const u8{
        "src/agent.zig",
        "src/config.zig",
        "src/tools.zig",
        "src/pricing.zig",
        "src/fake_provider.zig",
    };

    inline for (unit_test_targets) |path| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport("http-sentinel", http_sentinel_module);

        const t = b.addTest(.{
            .root_module = test_module,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // Integration test lives outside src/ and references agent.zig as
    // a named module. Zig 0.16 forbids the same file from belonging to
    // two modules, so we declare ONLY the agent module here — anything
    // the test needs from fake_provider/config/pricing is re-exported
    // through `agent`.
    const agent_module = b.createModule(.{
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_module.addImport("http-sentinel", http_sentinel_module);

    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_loop_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_module.addImport("http-sentinel", http_sentinel_module);
    integration_module.addImport("agent", agent_module);

    const integration_test = b.addTest(.{
        .root_module = integration_module,
    });
    test_step.dependOn(&b.addRunArtifact(integration_test).step);
}
