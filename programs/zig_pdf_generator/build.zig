//! Zig PDF Generator Build Configuration
//!
//! Builds a high-performance PDF generation library with C FFI for cross-platform use.
//! Target platforms: Linux, Android, iOS, macOS, Windows, WebAssembly (Edge)
//!
//! Usage:
//!   zig build              - Build native library and CLI
//!   zig build android      - Build for Android ARM64
//!   zig build wasm         - Build WebAssembly module for edge deployment
//!   zig build test         - Run all tests
//!   zig build -Dtarget=aarch64-linux-android  - Cross-compile for Android ARM64
//!
//! WASM Output:
//!   zig-out/lib/zigpdf.wasm - WebAssembly module for Cloudflare Workers, Deno, etc.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The audited ML-DSA-65 (FIPS 204) module from the sibling crypto program,
    // imported by src/seal.zig for the post-quantum tamper-seal. Native targets
    // only (the seal is desktop/server-side — never WASM). It resolves its own
    // `rng.zig` relative to itself; the seal always passes a seed + deterministic
    // sign, so the RNG path is never exercised.
    const ml_dsa_mod = b.createModule(.{
        .root_source_file = b.path("../zig-quantum-encryption/src/ml_dsa.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The Beacon solar report's 12 brand images. The committed defaults in
    // src/beacon_assets/ are 1x1 placeholders; a client build passes
    // -Dbeacon-assets=<dir> naming a directory OUTSIDE this public repository
    // that holds the real files under the same names.
    const beacon_assets_dir = b.option(
        []const u8,
        "beacon-assets",
        "Directory holding the Beacon solar report's brand images (default: placeholders in src/beacon_assets)",
    );
    const beacon_assets_mod = beaconAssetsModule(b, beacon_assets_dir);

    // zig_legend (typed template text) and the zig_toml parser it loads
    // legends with, imported from their sibling source directories rather
    // than the package manager: apps vendor this engine as a source copy, and
    // a relative module path keeps working in that copy as long as the two
    // sibling `src/` directories travel with it (see ZIG_PDF_SCHEMA.md,
    // "Legend letters"). No target is set, so each root's target applies.
    const toml_mod = b.createModule(.{
        .root_source_file = b.path("../zig_toml/src/lib.zig"),
    });
    const legend_mod = b.createModule(.{
        .root_source_file = b.path("../zig_legend/src/lib.zig"),
        .imports = &.{.{ .name = "zig_toml", .module = toml_mod }},
    });

    // zig_docx (DOCX/XLSX read and write), from its sibling source directory
    // on the same terms. Rooted at docx.zig; the engine's library roots
    // reference its `ffi` so the zig_docx_* C API is exported from libzigpdf
    // too. Its PDF-extraction and Claude Code helpers (which spawn processes)
    // are declared lazily in docx.zig and never referenced, so they are not
    // compiled in.
    const docx_mod = b.createModule(.{
        .root_source_file = b.path("../zig_docx/src/docx.zig"),
    });

    // ==========================================================================
    // Core Library (Static) - Uses ffi.zig as root for C FFI exports
    // ==========================================================================
    const lib = b.addLibrary(.{
        .name = "zigpdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    // Link libc for Android/iOS FFI compatibility
    lib.root_module.link_libc = true;
    // Bundle compiler-rt so static lib is self-contained (f128 ops for JSON parser)
    lib.bundle_compiler_rt = true;

    lib.root_module.addImport("ml_dsa", ml_dsa_mod);
    b.installArtifact(lib);

    // ==========================================================================
    // Consumable Zig module (for in-tree `@import("zigpdf")` consumers).
    // Rooted at the rich library API surface (src/lib.zig), matching the
    // `@import("zigpdf").invoice` usage documented at the top of that file.
    // Additive — does not alter any C-ABI/WASM export.
    // ==========================================================================
    const zigpdf_module = b.addModule("zigpdf", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigpdf_module.addImport("ml_dsa", ml_dsa_mod);

    // ==========================================================================
    // Shared Library (libzigpdf.so for JNI/FFI/Crypto Apps)
    // Build with: zig build shared
    // Output: zig-out/lib/libzigpdf.so
    // ==========================================================================
    const shared_lib = b.addLibrary(.{
        .name = "zigpdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .dynamic,
    });

    shared_lib.root_module.link_libc = true;
    shared_lib.root_module.addImport("ml_dsa", ml_dsa_mod);

    // Always install the shared lib alongside the static lib
    b.installArtifact(shared_lib);

    const shared_step = b.step("shared", "Build shared library (libzigpdf.so) for FFI");
    shared_step.dependOn(&shared_lib.step);

    // ==========================================================================
    // Android ARM64 Cross-Compilation Target (Static Library with FFI)
    // ==========================================================================
    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });

    const android_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigpdf",
        .root_module = android_module,
    });

    android_lib.root_module.link_libc = true;
    android_lib.root_module.strip = true;
    android_lib.root_module.pic = true; // linked into a shared .so (JNI) — must be PIC

    const android_install = b.addInstallArtifact(android_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    const android_step = b.step("android", "Build for Android ARM64 (aarch64-linux-android)");
    android_step.dependOn(&android_install.step);

    // ==========================================================================
    // Android ARM64 Shared Library (libzigpdf.so for JNI)
    // Uses Android ABI (Bionic libc) for proper symbol resolution
    // ==========================================================================
    const android_shared_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_shared_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = android_shared_target,
        .optimize = .ReleaseFast,
    });

    const android_shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zigpdf",
        .root_module = android_shared_module,
    });

    // Don't link libc - Android's Bionic will provide symbols at runtime
    android_shared_lib.root_module.link_libc = false;
    android_shared_lib.root_module.strip = true;

    const android_shared_install = b.addInstallArtifact(android_shared_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    const android_shared_step = b.step("android-shared", "Build shared library for Android ARM64");
    android_shared_step.dependOn(&android_shared_install.step);

    // ==========================================================================
    // Android ARM64 CLI Sidecar Executable (uses musl for static linking)
    // Note: Android doesn't have a system libc we can link against dynamically,
    // so we use musl for a fully static executable that runs on Android.
    // ==========================================================================
    const android_exe_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .musl,
    });

    const android_exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = android_exe_target,
        .optimize = .ReleaseFast,
    });

    const android_exe = b.addExecutable(.{
        .name = "pdf-gen",
        .root_module = android_exe_module,
    });

    android_exe.root_module.strip = true;

    const android_exe_install = b.addInstallArtifact(android_exe, .{
        .dest_dir = .{ .override = .{ .custom = "bin/android-arm64" } },
    });

    const android_exe_step = b.step("android-exe", "Build CLI for Android ARM64");
    android_exe_step.dependOn(&android_exe_install.step);

    // Combined Android step builds both library and executable
    android_step.dependOn(&android_exe_install.step);

    // ==========================================================================
    // iOS ARM64 Cross-Compilation Target (Static Library with FFI)
    // ==========================================================================
    const ios_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .none,
    });

    const ios_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = ios_target,
        .optimize = .ReleaseFast,
    });

    const ios_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigpdf",
        .root_module = ios_module,
    });

    ios_lib.root_module.strip = true;
    // Static consumers (Xcode link) get no Zig runtime — f128 soft-float
    // (roundq et al.) must ride inside the archive, same as the host lib.
    ios_lib.bundle_compiler_rt = true;

    const ios_install = b.addInstallArtifact(ios_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/ios-arm64" } },
    });

    const ios_step = b.step("ios", "Build for iOS ARM64 (aarch64-ios)");
    ios_step.dependOn(&ios_install.step);

    // ==========================================================================
    // iOS Simulator ARM64 (for Apple Silicon Macs running simulator)
    // ==========================================================================
    const ios_sim_arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .simulator,
    });

    const ios_sim_arm_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = ios_sim_arm_target,
        .optimize = .ReleaseFast,
    });

    const ios_sim_arm_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigpdf",
        .root_module = ios_sim_arm_module,
    });

    ios_sim_arm_lib.root_module.strip = true;
    ios_sim_arm_lib.bundle_compiler_rt = true;

    const ios_sim_arm_install = b.addInstallArtifact(ios_sim_arm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/ios-sim-arm64" } },
    });

    const ios_sim_arm_step = b.step("ios-sim", "Build for iOS Simulator ARM64");
    ios_sim_arm_step.dependOn(&ios_sim_arm_install.step);

    // ==========================================================================
    // WebAssembly (WASM) Target for Edge Deployment
    // Cloudflare Workers, Deno, Node.js, Browser
    // Build with: zig build wasm
    // Output: zig-out/lib/zigpdf.wasm
    // ==========================================================================
    // Use WASI for basic system interface support (fd_write for debug, etc.)
    // For pure freestanding WASM without WASI, remove os_tag and abi
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .abi = .none,
    });

    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm_lib = b.addExecutable(.{
        .name = "zigpdf",
        .root_module = wasm_module,
    });

    // WASM-specific settings
    wasm_lib.entry = .disabled; // No _start entry point, just exports
    wasm_lib.rdynamic = true; // Export all `export fn` functions

    // Stack size for WASM. 1MB was "plenty for PDF generation" but the
    // EXTRACTOR's recursive object/content parser blows it on real-world
    // producers (Aspose.Pdf, Oracle Analytics Publisher, PDFium — 765/8008 of
    // the Beacon corpus trapped with "memory access out of bounds"). Native runs
    // the same files fine on the default 8MB thread stack — match it.
    wasm_lib.stack_size = 8 * 1024 * 1024;

    const wasm_install = b.addInstallArtifact(wasm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });

    const wasm_step = b.step("wasm", "Build WebAssembly module for edge deployment");
    wasm_step.dependOn(&wasm_install.step);

    // ==========================================================================
    // Freestanding browser WASM (no WASI, no libc)
    // Build with: zig build wasm-web
    // Output: zig-out/lib/zigpdf_web.wasm
    // --------------------------------------------------------------------------
    // The WASI build above imports 27 wasi_snapshot_preview1 functions, so a
    // browser must supply a WASI shim. This freestanding target imports NOTHING
    // from the host — instantiate it with an empty import object. The allocator
    // is std.heap.wasm_allocator (pure wasm pages, no libc). Suits the
    // (ptr,len)->ptr ABI: wasm_alloc a JSON buffer, call
    // zigpdf_generate_presentation, read the PDF bytes from exported memory,
    // zigpdf_free. Same pattern as zig_docx `wasm-web`.
    //
    // NOTE: encrypted exports (…_encrypted) still need a host-provided CSPRNG
    // seed argument; nothing here calls random_get / clock_time_get, so the
    // presentation / invoice / letter / contract paths link clean.
    // ==========================================================================
    const web_wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const web_wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_web.zig"),
        .target = web_wasm_target,
        .optimize = .ReleaseSmall,
    });
    const web_wasm = b.addExecutable(.{
        .name = "zigpdf_web",
        .root_module = web_wasm_module,
    });
    web_wasm.entry = .disabled;
    web_wasm.rdynamic = true;
    web_wasm.export_memory = true;
    web_wasm.stack_size = 8 * 1024 * 1024;
    const web_wasm_install = b.addInstallArtifact(web_wasm, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });
    const web_wasm_step = b.step("wasm-web", "Build freestanding browser WASM module (no WASI shim)");
    web_wasm_step.dependOn(&web_wasm_install.step);

    // ==========================================================================
    // CLI Tool
    // ==========================================================================
    const exe = b.addExecutable(.{
        .name = "pdf-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.link_libc = true;
    exe.root_module.addImport("ml_dsa", ml_dsa_mod);

    b.installArtifact(exe);

    // ==========================================================================
    // pdf-seal CLI — ML-DSA-65 post-quantum tamper-seal (native only)
    // ==========================================================================
    const seal_exe = b.addExecutable(.{
        .name = "pdf-seal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/seal_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    seal_exe.root_module.link_libc = true;
    seal_exe.root_module.addImport("ml_dsa", ml_dsa_mod);
    b.installArtifact(seal_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the PDF generator CLI");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // Tests
    // ==========================================================================
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    lib_unit_tests.root_module.link_libc = true;
    lib_unit_tests.root_module.addImport("ml_dsa", ml_dsa_mod);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    // Pin cwd to the package root so tests that read checked-in fixtures
    // (templates/legal/*.json in sample_tests.zig) resolve regardless of where
    // `zig build test` is invoked from.
    run_lib_unit_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Every root compiles beacon_solar_report.zig (through lib.zig, wasm.zig or
    // wasm_web.zig), so each one needs the asset module.
    const roots = [_]*std.Build.Module{
        lib.root_module,            zigpdf_module,         shared_lib.root_module,
        android_module,             android_shared_module, android_exe_module,
        ios_module,                 ios_sim_arm_module,    wasm_module,
        web_wasm_module,            exe.root_module,       seal_exe.root_module,
        lib_unit_tests.root_module,
    };
    for (roots) |m| {
        m.addImport("beacon_assets", beacon_assets_mod);
        // letter, legend_letter and docx_bridge are reachable from every root too.
        m.addImport("zig_legend", legend_mod);
        m.addImport("zig_docx", docx_mod);
    }
}

const beacon_asset_files = [_][]const u8{
    "cover_house.jpg",      "quote_photo.jpg",   "medal.png",     "reviews.jpg",
    "logo.png",             "accreditation.png", "canadian1.jpg", "canadian2.jpg",
    "sunsynk_inverter.jpg", "signature.png",     "sunpath.png",   "battery.jpg",
};

/// Copies the asset files into a generated directory beside a generated
/// `beacon_assets.zig` that @embedFile's each one, so the images can come from
/// any directory while the report imports a single module. A file missing
/// from the chosen directory fails the build rather than embedding nothing.
fn beaconAssetsModule(b: *std.Build, dir: ?[]const u8) *std.Build.Module {
    const src: std.Build.LazyPath = if (dir) |d| .{ .cwd_relative = d } else b.path("src/beacon_assets");
    const wf = b.addWriteFiles();
    var zig_src: std.ArrayList(u8) = .empty;
    zig_src.appendSlice(b.allocator, "//! Generated by build.zig from the Beacon asset directory.\n") catch @panic("OOM");
    for (beacon_asset_files) |name| {
        _ = wf.addCopyFile(src.path(b, name), name);
        const ident = name[0..std.mem.indexOfScalar(u8, name, '.').?];
        zig_src.print(b.allocator, "pub const {s} = @embedFile(\"{s}\");\n", .{ ident, name }) catch @panic("OOM");
    }
    const root = wf.add("beacon_assets.zig", zig_src.items);
    return b.createModule(.{ .root_source_file = root });
}
