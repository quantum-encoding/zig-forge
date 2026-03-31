const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core zig-socket library module
    const zig_socket_module = b.addModule("zig-socket", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_module = zig_socket_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Helper function to create executable with zig-socket import
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
                .link_libc = true,
            });
            exe_module.addImport("zig-socket", module);

            const exe = builder.addExecutable(.{
                .name = name,
                .root_module = exe_module,
            });
            builder.installArtifact(exe);
            return exe;
        }
    }.call;

    // CLI Demo
    const demo = addExample(b, "socket-demo", "src/main.zig", target, optimize, zig_socket_module);
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |args| {
        run_demo.addArgs(args);
    }
    const demo_step = b.step("demo", "Run socket demo");
    demo_step.dependOn(&run_demo.step);

    // Benchmarks
    const bench = addExample(b, "socket-bench", "src/bench.zig", target, optimize, zig_socket_module);
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run socket benchmarks");
    bench_step.dependOn(&run_bench.step);
}
