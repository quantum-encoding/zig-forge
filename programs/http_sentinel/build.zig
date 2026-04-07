const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core HTTP Sentinel library module
    const http_sentinel_module = b.addModule("http-sentinel", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_module = http_sentinel_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Helper function to create executable with http-sentinel import
    const addExample = struct {
        fn call(
            builder: *std.Build,
            name: []const u8,
            src: []const u8,
            tgt: std.Build.ResolvedTarget,
            opt: std.builtin.OptimizeMode,
            module: *std.Build.Module,
        ) *std.Build.Step.Compile {
            const exe_module = builder.createModule(.{
                .root_source_file = builder.path(src),
                .target = tgt,
                .optimize = opt,
                .link_libc = false,
            });
            exe_module.addImport("http-sentinel", module);

            const exe = builder.addExecutable(.{
                .name = name,
                .root_module = exe_module,
            });
            builder.installArtifact(exe);
            return exe;
        }
    }.call;

    // CLI Tool
    const cli = addExample(b, "zig-ai", "src/main.zig", target, optimize, http_sentinel_module);

    // Install CLI to system (built-in 'install' step will handle this automatically)
    b.installArtifact(cli);

    // Run CLI
    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| {
        run_cli.addArgs(args);
    }
    const cli_step = b.step("cli", "Run AI Providers CLI");
    cli_step.dependOn(&run_cli.step);

    // Quantum Curl - Universal HTTP Engine
    const quantum_curl = addExample(b, "quantum-curl", "src/quantum_curl.zig", target, optimize, http_sentinel_module);
    b.installArtifact(quantum_curl);

    const run_quantum = b.addRunArtifact(quantum_curl);
    if (b.args) |args| {
        run_quantum.addArgs(args);
    }
    const quantum_step = b.step("quantum", "Run Quantum Curl HTTP Engine");
    quantum_step.dependOn(&run_quantum.step);
}
