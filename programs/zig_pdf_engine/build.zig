const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core PDF Engine library module
    // Uses Zig's built-in std.compress for FlateDecode - no external zlib needed
    const pdf_engine_module = b.addModule("pdf-engine", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    pdf_engine_module.link_libc = true;

    // ========================================================================
    // Core FFI Static Library (for native target)
    // Uses Zig's built-in std.compress - no external zlib dependency
    // ========================================================================
    const core_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "pdf_engine_core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    core_lib.root_module.link_libc = true;

    b.installArtifact(core_lib);

    const core_step = b.step("core", "Build pdf_engine_core static library");
    core_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step);

    // ========================================================================
    // Android ARM64 Cross-Compilation Target (using musl - compatible with Android)
    // Uses Zig's built-in std.compress - zero external dependencies
    // ========================================================================
    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .musl,
    });

    const android_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });

    const android_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "pdf_engine_core",
        .root_module = android_module,
    });

    android_lib.root_module.link_libc = true;
    android_lib.root_module.strip = true;

    const android_install = b.addInstallArtifact(android_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    const android_step = b.step("android", "Build for Android ARM64 (aarch64-linux-musl)");
    android_step.dependOn(&android_install.step);

    // ========================================================================
    // Android ARM64 Shared Library (for JNI)
    // ========================================================================
    const android_shared_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });

    const android_shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "pdf_renderer",
        .root_module = android_shared_module,
    });

    android_shared.root_module.link_libc = true;
    android_shared.root_module.strip = true;

    const android_shared_install = b.addInstallArtifact(android_shared, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    const android_shared_step = b.step("android-shared", "Build shared library for Android ARM64");
    android_shared_step.dependOn(&android_shared_install.step);

    // ========================================================================
    // Native Shared Library (for desktop testing)
    // ========================================================================
    const native_shared_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const native_shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "pdf_renderer",
        .root_module = native_shared_module,
    });

    native_shared.root_module.link_libc = true;

    b.installArtifact(native_shared);

    const shared_step = b.step("shared", "Build native shared library");
    shared_step.dependOn(&b.addInstallArtifact(native_shared, .{}).step);

    // ========================================================================
    // Android ARM32 Cross-Compilation (for older devices)
    // ========================================================================
    const android_arm32_target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .musleabihf,
    });

    const android_arm32_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = android_arm32_target,
        .optimize = .ReleaseFast,
    });

    const android_arm32_shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "pdf_renderer",
        .root_module = android_arm32_module,
    });

    android_arm32_shared.root_module.link_libc = true;
    android_arm32_shared.root_module.strip = true;

    const android_arm32_install = b.addInstallArtifact(android_arm32_shared, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm32" } },
    });

    const android_arm32_step = b.step("android-arm32", "Build shared library for Android ARM32");
    android_arm32_step.dependOn(&android_arm32_install.step);

    // ========================================================================
    // Android x86_64 Cross-Compilation (for emulators)
    // ========================================================================
    const android_x86_64_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });

    const android_x86_64_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = android_x86_64_target,
        .optimize = .ReleaseFast,
    });

    const android_x86_64_shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "pdf_renderer",
        .root_module = android_x86_64_module,
    });

    android_x86_64_shared.root_module.link_libc = true;
    android_x86_64_shared.root_module.strip = true;

    const android_x86_64_install = b.addInstallArtifact(android_x86_64_shared, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-x86_64" } },
    });

    const android_x86_64_step = b.step("android-x86_64", "Build shared library for Android x86_64");
    android_x86_64_step.dependOn(&android_x86_64_install.step);

    // ========================================================================
    // Build all Android architectures
    // ========================================================================
    const android_all_step = b.step("android-all", "Build for all Android architectures");
    android_all_step.dependOn(&android_shared_install.step);
    android_all_step.dependOn(&android_arm32_install.step);
    android_all_step.dependOn(&android_x86_64_install.step);

    // ========================================================================
    // Library tests
    // ========================================================================
    const lib_unit_tests = b.addTest(.{
        .root_module = pdf_engine_module,
    });
    lib_unit_tests.root_module.link_libc = true;
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // ========================================================================
    // Real PDF file tests (integration tests using actual PDF files)
    // ========================================================================
    const real_pdf_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/real_pdf_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    real_pdf_test_module.link_libc = true;
    real_pdf_test_module.addImport("pdf-engine", pdf_engine_module);

    const real_pdf_tests = b.addTest(.{
        .root_module = real_pdf_test_module,
    });
    const run_real_pdf_tests = b.addRunArtifact(real_pdf_tests);
    const real_test_step = b.step("test-real", "Run tests with real PDF files");
    real_test_step.dependOn(&run_real_pdf_tests.step);

    // All tests (unit + integration)
    const all_tests_step = b.step("test-all", "Run all tests including real PDF tests");
    all_tests_step.dependOn(&run_lib_unit_tests.step);
    all_tests_step.dependOn(&run_real_pdf_tests.step);

    // Helper to create executables with pdf-engine import
    const addTool = struct {
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
            });
            exe_module.addImport("pdf-engine", module);
            exe_module.link_libc = true;

            const exe = builder.addExecutable(.{
                .name = name,
                .root_module = exe_module,
            });
            builder.installArtifact(exe);
            return exe;
        }
    }.call;

    // CLI Tools
    const pdf_info = addTool(b, "pdf-info", "src/tools/pdf_info.zig", target, optimize, pdf_engine_module);
    const pdf_text = addTool(b, "pdf-text", "src/tools/pdf_text.zig", target, optimize, pdf_engine_module);
    const render_debug = addTool(b, "render-debug", "src/tools/render_debug.zig", target, optimize, pdf_engine_module);

    // Run commands for pdf-info
    const run_info = b.addRunArtifact(pdf_info);
    if (b.args) |args| {
        run_info.addArgs(args);
    }
    const info_step = b.step("info", "Run pdf-info tool");
    info_step.dependOn(&run_info.step);

    // Run commands for pdf-text
    const run_text = b.addRunArtifact(pdf_text);
    if (b.args) |args| {
        run_text.addArgs(args);
    }
    const text_step = b.step("text", "Run pdf-text tool");
    text_step.dependOn(&run_text.step);

    // Run commands for render-debug
    const run_render = b.addRunArtifact(render_debug);
    if (b.args) |args| {
        run_render.addArgs(args);
    }
    const render_step = b.step("render", "Run render-debug tool");
    render_step.dependOn(&run_render.step);
}
