const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core zats library module
    const zats_module = b.addModule("zats", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_module = zats_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Helper function to create executable with zats import
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
            exe_module.addImport("zats", module);

            const exe = builder.addExecutable(.{
                .name = name,
                .root_module = exe_module,
            });
            builder.installArtifact(exe);
            return exe;
        }
    }.call;

    // Server
    const server = addExample(b, "zats-server", "src/main_server.zig", target, optimize, zats_module);
    const run_server = b.addRunArtifact(server);
    if (b.args) |args| {
        run_server.addArgs(args);
    }
    const server_step = b.step("run-server", "Run NATS server");
    server_step.dependOn(&run_server.step);

    // Publisher CLI
    const pub_cli = addExample(b, "zats-pub", "src/main_pub.zig", target, optimize, zats_module);
    const run_pub = b.addRunArtifact(pub_cli);
    if (b.args) |args| {
        run_pub.addArgs(args);
    }
    const pub_step = b.step("run-pub", "Run NATS publisher");
    pub_step.dependOn(&run_pub.step);

    // Subscriber CLI
    const sub_cli = addExample(b, "zats-sub", "src/main_sub.zig", target, optimize, zats_module);
    const run_sub = b.addRunArtifact(sub_cli);
    if (b.args) |args| {
        run_sub.addArgs(args);
    }
    const sub_step = b.step("run-sub", "Run NATS subscriber");
    sub_step.dependOn(&run_sub.step);
}
