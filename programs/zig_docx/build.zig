const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // DOCX Library Module
    // ============================================================
    const docx_module = b.addModule("docx", .{
        .root_source_file = b.path("src/docx.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ============================================================
    // Executable
    // ============================================================
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("docx", docx_module);
    exe_module.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "zig-docx",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zig-docx");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // Static Library (libzig_docx.a)
    // ============================================================
    const static_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    static_module.link_libc = true;

    const static_lib = b.addLibrary(.{
        .name = "zig_docx",
        .root_module = static_module,
        .linkage = .static,
    });
    static_lib.bundle_compiler_rt = true;
    b.installArtifact(static_lib);

    // ============================================================
    // Dynamic Library (libzig_docx.dylib / .so)
    // Build with: zig build dylib
    // ============================================================
    const dylib_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    dylib_module.link_libc = true;

    const dynamic_lib = b.addLibrary(.{
        .name = "zig_docx",
        .root_module = dylib_module,
        .linkage = .dynamic,
    });

    const dylib_step = b.step("dylib", "Build dynamic library only");
    dylib_step.dependOn(&b.addInstallArtifact(dynamic_lib, .{}).step);

    // ============================================================
    // Tests
    // ============================================================
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/docx.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.link_libc = true;

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // ============================================================
    // WASM Library (zig_docx.wasm)
    //
    // Build with: zig build wasm
    //
    // Targets wasm32-wasi with wasi-libc linked so std.heap.c_allocator
    // and the zip.zig path-based helpers compile unchanged. The module
    // exports the same FFI surface as the native lib (zig_docx_md_to_docx,
    // zig_docx_to_markdown, zig_docx_info, etc.). Path-based file I/O
    // exists in the binary but the FFI never calls it — bytes flow in
    // and out via pointer+length parameters, which the host (e.g.
    // SvelteKit) controls.
    //
    // docx.zig gates the claude_code and pdf re-exports for WASI so
    // nothing in the compile graph references dirent.d_name or
    // std.process.run. ============================================================
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    wasm_module.link_libc = true;
    const wasm_lib = b.addExecutable(.{
        .name = "zig_docx",
        .root_module = wasm_module,
    });
    // Reactor execution model: emits `_initialize` instead of `_start`,
    // which is what hosts like Node's WASI.initialize() and wasmtime
    // --invoke expect for library-style modules. Without this Zig's
    // std.start auto-generates a _start that calls main(), and reactor-
    // mode hosts refuse to load the module via initialize().
    wasm_lib.wasi_exec_model = .reactor;
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;

    const wasm_step = b.step("wasm", "Build WASM library (wasm32-wasi)");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_lib, .{}).step);
}
