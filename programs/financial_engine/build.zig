const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // WebSocket dependency commented out - implementing without external deps for now
    // const websocket_dep = b.dependency("websocket", .{
    //     .target = target,
    //     .optimize = optimize,
    // });

    // ========================================================================
    // Core FFI Static Library (ZERO DEPENDENCIES)
    // ========================================================================

    const core_module = b.createModule(.{
        .root_source_file = b.path("src/financial_core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "financial_core",
        .root_module = core_module,
    });

    core_lib.root_module.link_libc = true;
    // NO ZMQ, NO EXTERNAL DEPS

    // Install the core library
    b.installArtifact(core_lib);

    const core_step = b.step("core", "Build core FFI static library (zero deps)");
    core_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step);

    // ========================================================================
    // Android ARM64 Cross-Compilation Target (Core Library Only)
    // ========================================================================

    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_core_module = b.createModule(.{
        .root_source_file = b.path("src/financial_core.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });

    const android_core_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "financial_core",
        .root_module = android_core_module,
    });

    android_core_lib.root_module.link_libc = true;
    android_core_lib.root_module.strip = true;

    const android_core_install = b.addInstallArtifact(android_core_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    // Android financial_engine (full FFI, but ZMQ stubbed out at runtime)
    const android_ffi_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });

    const android_ffi_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "financial_engine",
        .root_module = android_ffi_module,
    });

    android_ffi_lib.root_module.link_libc = true;
    // Note: NO ZMQ linking for Android - ZMQ is stubbed in execution.zig
    android_ffi_lib.root_module.strip = true;

    const android_ffi_install = b.addInstallArtifact(android_ffi_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    const android_step = b.step("android", "Build FFI libs for Android ARM64 (ZMQ stubbed)");
    android_step.dependOn(&android_core_install.step);
    android_step.dependOn(&android_ffi_install.step);

    // ========================================================================
    // Full FFI Static Library (with ZMQ dependencies)
    // ========================================================================

    const ffi_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ffi_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "financial_engine",
        .root_module = ffi_module,
    });

    ffi_lib.root_module.link_libc = true;
    ffi_lib.root_module.linkSystemLibrary("zmq", .{});
    ffi_lib.installHeader(b.path("include/financial_engine.h"), "financial_engine.h");

    // Install the static library
    b.installArtifact(ffi_lib);

    const ffi_step = b.step("ffi", "Build full FFI static library (with ZMQ)");
    ffi_step.dependOn(&b.addInstallArtifact(ffi_lib, .{}).step);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zig-financial-engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.link_libc = true;

    // WebSocket module commented out for now
    // exe.root_module.addImport("websocket", websocket_dep.module("websocket"));

    // Install the executable
    b.installArtifact(exe);
    
    // HFT System executable
    const hft_exe = b.addExecutable(.{
        .name = "hft-system",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hft_system.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link with ZMQ library
    hft_exe.root_module.linkSystemLibrary("zmq", .{});
    hft_exe.root_module.link_libc = true;

    b.installArtifact(hft_exe);
    
    // Alpaca test executable (file missing - commented out)
    // const alpaca_exe = b.addExecutable(.{
    //     .name = "alpaca-test",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/alpaca_test.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //     }),
    // });
    //
    // // WebSocket modules commented out for now
    // // alpaca_exe.root_module.addImport("websocket", websocket_dep.module("websocket"));
    //
    // b.installArtifact(alpaca_exe);
    
    // Live trading executable
    const live_exe = b.addExecutable(.{
        .name = "live-trading",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/live_trading.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link with ZMQ library
    live_exe.root_module.linkSystemLibrary("zmq", .{});
    live_exe.root_module.link_libc = true;

    // live_exe.root_module.addImport("websocket", websocket_dep.module("websocket"));

    b.installArtifact(live_exe);

    // Real HFT System executable
    // NOTE: Force ReleaseFast due to Zig 0.16 dev DWARF bug with libwebsockets/libsystemd in Debug mode
    const real_hft_optimize = if (optimize == .Debug) .ReleaseFast else optimize;
    const real_hft_exe = b.addExecutable(.{
        .name = "real-hft-system",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hft_alpaca_real.zig"),
            .target = target,
            .optimize = real_hft_optimize,
        }),
    });

    // Link with libwebsockets for real WebSocket connectivity
    real_hft_exe.root_module.linkSystemLibrary("websockets", .{});
    real_hft_exe.root_module.linkSystemLibrary("zmq", .{});
    real_hft_exe.root_module.link_libc = true;

    b.installArtifact(real_hft_exe);
    
    // Trading API test executable
    const trading_api_exe = b.addExecutable(.{
        .name = "trading-api-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/alpaca_trading_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    trading_api_exe.root_module.link_libc = true;

    b.installArtifact(trading_api_exe);
    
    // Real connection test executable (file missing - commented out)
    // const real_test_exe = b.addExecutable(.{
    //     .name = "real-connection-test",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/real_connection_test.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //     }),
    // });
    //
    // // real_test_exe.root_module.addImport("websocket", websocket_dep.module("websocket"));
    //
    // b.installArtifact(real_test_exe);
    
    // Run commands
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    
    const run_step = b.step("run", "Run the main application");
    run_step.dependOn(&run_cmd.step);
    
    // Test command (commented out - file missing)
    // const alpaca_run_cmd = b.addRunArtifact(alpaca_exe);
    // const alpaca_run_step = b.step("test-alpaca", "Test Alpaca connection");
    // alpaca_run_step.dependOn(&alpaca_run_cmd.step);
    
    // Live trading command
    const live_run_cmd = b.addRunArtifact(live_exe);
    const live_run_step = b.step("live", "Run live trading system");
    live_run_step.dependOn(&live_run_cmd.step);
    
    // Real HFT system command
    const real_hft_run_cmd = b.addRunArtifact(real_hft_exe);
    const real_hft_run_step = b.step("real-hft", "Run real HFT system with Alpaca");
    real_hft_run_step.dependOn(&real_hft_run_cmd.step);
    
    // Trading API test command
    const trading_api_run_cmd = b.addRunArtifact(trading_api_exe);
    const trading_api_run_step = b.step("test-trading-api", "Test Alpaca trading API");
    trading_api_run_step.dependOn(&trading_api_run_cmd.step);

    // ========================================================================
    // Sentient Network Signal Broadcast
    // ========================================================================

    // Signal Broadcast static library (for Rust FFI)
    const signal_module = b.createModule(.{
        .root_source_file = b.path("src/signal_broadcast.zig"),
        .target = target,
        .optimize = optimize,
    });

    const signal_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "signal_broadcast",
        .root_module = signal_module,
    });

    signal_lib.root_module.link_libc = true;
    signal_lib.root_module.linkSystemLibrary("zmq", .{});
    signal_lib.installHeader(b.path("include/signal_broadcast.h"), "signal_broadcast.h");

    b.installArtifact(signal_lib);

    const signal_lib_step = b.step("signal-lib", "Build signal broadcast static library");
    signal_lib_step.dependOn(&b.addInstallArtifact(signal_lib, .{}).step);

    // Signal Broadcast executable (test server/client)
    const signal_exe = b.addExecutable(.{
        .name = "signal-broadcast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/signal_broadcast.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    signal_exe.root_module.link_libc = true;
    signal_exe.root_module.linkSystemLibrary("zmq", .{});

    b.installArtifact(signal_exe);

    // Signal server command
    const signal_server_cmd = b.addRunArtifact(signal_exe);
    signal_server_cmd.addArg("server");
    const signal_server_step = b.step("signal-server", "Run signal broadcast server");
    signal_server_step.dependOn(&signal_server_cmd.step);

    // Signal client command
    const signal_client_cmd = b.addRunArtifact(signal_exe);
    signal_client_cmd.addArg("client");
    const signal_client_step = b.step("signal-client", "Run signal broadcast client");
    signal_client_step.dependOn(&signal_client_cmd.step);

    // ========================================================================
    // Coinbase FIX 5.0 Executor (Institutional Trading)
    // ========================================================================

    // Coinbase FIX static library (for Rust FFI)
    const coinbase_fix_module = b.createModule(.{
        .root_source_file = b.path("src/coinbase_fix_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const coinbase_fix_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "coinbase_fix",
        .root_module = coinbase_fix_module,
    });

    coinbase_fix_lib.root_module.link_libc = true;
    // Link mbedTLS for TLS support
    coinbase_fix_lib.root_module.linkSystemLibrary("mbedtls", .{});
    coinbase_fix_lib.root_module.linkSystemLibrary("mbedcrypto", .{});
    coinbase_fix_lib.root_module.linkSystemLibrary("mbedx509", .{});
    coinbase_fix_lib.installHeader(b.path("include/coinbase_fix.h"), "coinbase_fix.h");

    b.installArtifact(coinbase_fix_lib);

    const coinbase_fix_step = b.step("coinbase-fix", "Build Coinbase FIX static library");
    coinbase_fix_step.dependOn(&b.addInstallArtifact(coinbase_fix_lib, .{}).step);

    // Coinbase FIX test executable
    const coinbase_fix_exe = b.addExecutable(.{
        .name = "coinbase-fix-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/coinbase_executor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    coinbase_fix_exe.root_module.link_libc = true;
    // Link mbedTLS for TLS support
    coinbase_fix_exe.root_module.linkSystemLibrary("mbedtls", .{});
    coinbase_fix_exe.root_module.linkSystemLibrary("mbedcrypto", .{});
    coinbase_fix_exe.root_module.linkSystemLibrary("mbedx509", .{});

    b.installArtifact(coinbase_fix_exe);

    // Coinbase FIX demo command
    const coinbase_fix_run_cmd = b.addRunArtifact(coinbase_fix_exe);
    const coinbase_fix_run_step = b.step("coinbase-fix-demo", "Run Coinbase FIX executor demo");
    coinbase_fix_run_step.dependOn(&coinbase_fix_run_cmd.step);

    // Android ARM64 Coinbase FIX library
    // Note: For Android with TLS, you need to:
    // 1. Cross-compile mbedTLS for Android ARM64 using NDK
    // 2. Link the cross-compiled libraries here
    // For now, Android build works but TLS must be disabled at runtime
    const android_coinbase_fix_module = b.createModule(.{
        .root_source_file = b.path("src/coinbase_fix_ffi.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });

    const android_coinbase_fix_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "coinbase_fix",
        .root_module = android_coinbase_fix_module,
    });

    android_coinbase_fix_lib.root_module.link_libc = true;
    android_coinbase_fix_lib.root_module.strip = true;
    // Android: Link pre-built mbedTLS if available, otherwise TLS disabled at runtime
    // To enable TLS on Android:
    // 1. Build mbedTLS with NDK: cmake -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake -DANDROID_ABI=arm64-v8a ..
    // 2. Uncomment these lines and set library path:
    // android_coinbase_fix_lib.addLibraryPath(.{ .cwd_relative = "deps/mbedtls-android-arm64/lib" });
    // android_coinbase_fix_lib.root_module.linkSystemLibrary("mbedtls", .{});
    // android_coinbase_fix_lib.root_module.linkSystemLibrary("mbedcrypto", .{});
    // android_coinbase_fix_lib.root_module.linkSystemLibrary("mbedx509", .{});

    const android_coinbase_fix_install = b.addInstallArtifact(android_coinbase_fix_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    android_step.dependOn(&android_coinbase_fix_install.step);

    // ========================================================================
    // Tests
    // ========================================================================

    const signal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/signal_broadcast.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    signal_tests.root_module.link_libc = true;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(signal_tests).step);
}