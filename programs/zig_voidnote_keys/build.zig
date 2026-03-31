const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasm_step = b.step("wasm", "Build WebAssembly module for Cloudflare Workers");

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_ffi.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm_lib = b.addExecutable(.{
        .name = "voidnote_keys",
        .root_module = wasm_module,
    });

    // Required for Cloudflare Workers WASM interop
    wasm_lib.export_memory = true;
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;

    const wasm_install = b.addInstallArtifact(wasm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    wasm_step.dependOn(&wasm_install.step);
}
