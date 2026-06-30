const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // XLSX Library Module
    // ============================================================
    const xlsx_module = b.addModule("xlsx", .{
        .root_source_file = b.path("src/xlsx.zig"),
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
    exe_module.addImport("xlsx", xlsx_module);
    exe_module.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "zig-xlsx",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zig-xlsx");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // Tests
    // ============================================================
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/xlsx.zig"),
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
    // Freestanding WASM module for the browser / edge (zig_xlsx_web.wasm)
    //
    // Build with: zig build wasm-web
    //
    // Targets wasm32-freestanding with NO libc and NO WASI — instantiated
    // with an empty import object (same pattern as zig_docx_web). Root is
    // src/wasm.zig, which drives the zip/workbook/sharedStrings/worksheet
    // modules directly (NOT xlsx.zig, whose JsonWriter re-export pulls in
    // libc) and exposes `xlsx_to_json` via a wasm_alloc + (ptr,len)->ptr ABI.
    // ============================================================
    const web_wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const web_wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = web_wasm_target,
        .optimize = .ReleaseSmall,
    });
    const web_wasm = b.addExecutable(.{
        .name = "zig_xlsx_web",
        .root_module = web_wasm_module,
    });
    web_wasm.entry = .disabled;
    web_wasm.rdynamic = true;
    web_wasm.export_memory = true;

    const web_wasm_step = b.step("wasm-web", "Build freestanding WASM module for the browser");
    web_wasm_step.dependOn(&b.addInstallArtifact(web_wasm, .{}).step);
}
