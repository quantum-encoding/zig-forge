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

    // ============================================================
    // Freestanding WASM module for the browser / edge (zig_docx_web.wasm)
    //
    // Build with: zig build wasm-web
    //
    // Targets wasm32-freestanding with NO libc and NO WASI. The module
    // imports nothing from the host, so the website instantiates it with
    // an empty import object (no WASI shim) — same pattern as
    // zig_pdf_generator. Root is src/wasm.zig, which exposes the Fire Risk
    // Assessment generator via a wasm_alloc + (ptr,len)->ptr ABI. Disk-
    // backed photo evidence is skipped (no filesystem); everything else in
    // the FRA renders identically to the native generator.
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
        .name = "zig_docx_web",
        .root_module = web_wasm_module,
    });
    // Library-style reactor: no _start, export the marked symbols, and
    // surface linear memory to the host so JS can read/write the buffers.
    web_wasm.entry = .disabled;
    web_wasm.rdynamic = true;
    web_wasm.export_memory = true;

    const web_wasm_step = b.step("wasm-web", "Build freestanding WASM module for the browser (FRA)");
    web_wasm_step.dependOn(&b.addInstallArtifact(web_wasm, .{}).step);

    // ============================================================
    // Android cross-compilation (NDK / JNI)
    //
    // Build with: zig build android        (static .a for all ABIs below)
    //         or: zig build android-arm64  (static .a, one ABI)
    //         or: zig build android-so     (shared .so for all ABIs — needs NDK)
    //
    // `android` emits a static libzig_docx.a per ABI (compiler-rt bundled).
    // This needs NO Android NDK — Zig archives the objects and the libc
    // symbols the FFI uses (std.heap.c_allocator malloc/free, the photo
    // reader's fopen) are left undefined for the app's linker to resolve
    // against Bionic. Drop each .a into an NDK/CMake project as an IMPORTED
    // STATIC library and link it into your JNI shim:
    //
    //     add_library(zig_docx STATIC IMPORTED)
    //     set_target_properties(zig_docx PROPERTIES IMPORTED_LOCATION
    //         ${CMAKE_SOURCE_DIR}/libs/${ANDROID_ABI}/libzig_docx.a)
    //     target_link_libraries(your_jni zig_docx)   # Bionic libc links in here
    //
    // `android-so` additionally produces a ready-to-ship shared libzig_docx.so
    // per ABI (System.loadLibrary). Producing a .so requires linking Bionic at
    // build time, so this step needs the Android NDK available to Zig (e.g.
    // `--sysroot $NDK/toolchains/llvm/prebuilt/<host>/sysroot`); it is kept out
    // of the default `android` step so a plain checkout always builds.
    //
    // Artifacts install under zig-out/lib/android/<abi>/, where <abi> is the
    // exact jniLibs / ANDROID_ABI directory name. The C surface (src/ffi.zig)
    // is identical to the desktop build; see include/zig_docx.h.
    const AndroidAbi = struct {
        jni: []const u8, // jniLibs / ANDROID_ABI dir name
        arch: std.Target.Cpu.Arch,
        abi: std.Target.Abi,
        a_step: []const u8, // per-ABI static-lib step name
        // ARMv7-A baseline for armeabi-v7a; arch default for the 64-bit ABIs.
        cpu_model: std.Target.Query.CpuModel,
    };
    const android_abis = [_]AndroidAbi{
        .{ .jni = "arm64-v8a", .arch = .aarch64, .abi = .android, .a_step = "android-arm64", .cpu_model = .determined_by_arch_os },
        .{ .jni = "armeabi-v7a", .arch = .arm, .abi = .androideabi, .a_step = "android-arm", .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 } },
        .{ .jni = "x86_64", .arch = .x86_64, .abi = .android, .a_step = "android-x64", .cpu_model = .determined_by_arch_os },
    };

    const android_step = b.step("android", "Build static zig_docx .a for all Android ABIs (no NDK needed)");
    const android_so_step = b.step("android-so", "Build shared zig_docx .so for all Android ABIs (requires NDK)");

    for (android_abis) |aabi| {
        const android_target = b.resolveTargetQuery(.{
            .cpu_arch = aabi.arch,
            .os_tag = .linux,
            .abi = aabi.abi,
            .cpu_model = aabi.cpu_model,
        });
        const custom_path = b.fmt("lib/android/{s}", .{aabi.jni});

        // Static library (.a) — NDK-free; linked into the app's JNI .so.
        const a_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = android_target,
            .optimize = .ReleaseFast,
        });
        a_module.link_libc = true;
        a_module.strip = true;
        const a_lib = b.addLibrary(.{
            .linkage = .static,
            .name = "zig_docx",
            .root_module = a_module,
        });
        a_lib.bundle_compiler_rt = true;
        const a_install = b.addInstallArtifact(a_lib, .{ .dest_dir = .{ .override = .{ .custom = custom_path } } });

        const per_abi_step = b.step(aabi.a_step, b.fmt("Build static zig_docx .a for Android {s}", .{aabi.jni}));
        per_abi_step.dependOn(&a_install.step);
        android_step.dependOn(&a_install.step);

        // Shared library (.so) — ready to ship, but needs the NDK to link Bionic.
        const so_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = android_target,
            .optimize = .ReleaseFast,
        });
        so_module.link_libc = true; // links Bionic libc (malloc/fopen used by the FFI)
        so_module.strip = true;
        const so_lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "zig_docx",
            .root_module = so_module,
        });
        const so_install = b.addInstallArtifact(so_lib, .{ .dest_dir = .{ .override = .{ .custom = custom_path } } });
        android_so_step.dependOn(&so_install.step);
    }
}
