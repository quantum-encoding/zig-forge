const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core zig-flight library module
    const zig_flight_module = b.addModule("zig-flight", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_module = zig_flight_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Helper function to create executable with zig-flight import
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
            exe_module.addImport("zig-flight", module);

            const exe = builder.addExecutable(.{
                .name = name,
                .root_module = exe_module,
            });
            builder.installArtifact(exe);
            return exe;
        }
    }.call;

    // Main MFD executable
    const mfd = addExample(b, "zig-flight", "src/main.zig", target, optimize, zig_flight_module);
    const run_mfd = b.addRunArtifact(mfd);
    if (b.args) |args| {
        run_mfd.addArgs(args);
    }
    const mfd_step = b.step("run", "Run MFD client");
    mfd_step.dependOn(&run_mfd.step);

    // Dataref dump utility
    const dump = addExample(b, "zig-flight-dump", "src/main_dump.zig", target, optimize, zig_flight_module);
    const run_dump = b.addRunArtifact(dump);
    if (b.args) |args| {
        run_dump.addArgs(args);
    }
    const dump_step = b.step("run-dump", "Run dataref dumper");
    dump_step.dependOn(&run_dump.step);
}
