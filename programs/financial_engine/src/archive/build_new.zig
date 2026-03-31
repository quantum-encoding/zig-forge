const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // WebSocket dependency commented out - implementing without external deps for now
    // const websocket_dep = b.dependency("websocket", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    
    // Main executable
    const exe = b.addExecutable(.{
        .name = "zig-financial-engine",
    });
    exe.root_module.target = target;
    exe.root_module.optimize = optimize;
    exe.root_module.root_source_file = b.path("src/main.zig");
    
    // WebSocket module commented out for now
    // exe.root_module.addImport("websocket", websocket_dep.module("websocket"));
    
    // Install the executable
    b.installArtifact(exe);
    
    // HFT System executable
    const hft_exe = b.addExecutable(.{
        .name = "hft-system",
        .target = target,
        .optimize = optimize,
    });
    hft_exe.root_module.root_source_file = b.path("src/hft_system.zig");
    
    b.installArtifact(hft_exe);
    
    // Alpaca test executable
    const alpaca_exe = b.addExecutable(.{
        .name = "alpaca-test",
        .target = target,
        .optimize = optimize,
    });
    alpaca_exe.root_module.root_source_file = b.path("src/alpaca_test.zig");
    
    // WebSocket modules commented out for now
    // alpaca_exe.root_module.addImport("websocket", websocket_dep.module("websocket"));
    
    b.installArtifact(alpaca_exe);
    
    // Live trading executable
    const live_exe = b.addExecutable(.{
        .name = "live-trading",
        .target = target,
        .optimize = optimize,
    });
    live_exe.root_module.root_source_file = b.path("src/live_trading.zig");
    
    // live_exe.root_module.addImport("websocket", websocket_dep.module("websocket"));
    
    b.installArtifact(live_exe);
    
    // Real HFT System executable
    const real_hft_exe = b.addExecutable(.{
        .name = "real-hft-system",
        .target = target,
        .optimize = optimize,
    });
    real_hft_exe.root_module.root_source_file = b.path("src/hft_alpaca_real.zig");

    // Link with libwebsockets for real WebSocket connection
    real_hft_exe.linkSystemLibrary("websockets");
    real_hft_exe.linkLibC();

    b.installArtifact(real_hft_exe);
    
    // Trading API test executable
    const trading_api_exe = b.addExecutable(.{
        .name = "trading-api-test",
        .target = target,
        .optimize = optimize,
    });
    trading_api_exe.root_module.root_source_file = b.path("src/alpaca_trading_api.zig");
    
    b.installArtifact(trading_api_exe);
    
    // Real connection test executable
    const real_test_exe = b.addExecutable(.{
        .name = "real-connection-test",
        .target = target,
        .optimize = optimize,
    });
    real_test_exe.root_module.root_source_file = b.path("src/real_connection_test.zig");

    // real_test_exe.root_module.addImport("websocket", websocket_dep.module("websocket"));

    b.installArtifact(real_test_exe);

    // WebSocket test executable
    const ws_test_exe = b.addExecutable(.{
        .name = "test-websocket",
    });
    ws_test_exe.root_module.target = target;
    ws_test_exe.root_module.optimize = optimize;
    ws_test_exe.root_module.root_source_file = b.path("src/test_websocket.zig");

    // Link with libwebsockets
    ws_test_exe.linkSystemLibrary("websockets");
    ws_test_exe.linkLibC();

    b.installArtifact(ws_test_exe);
    
    // Run commands
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    
    const run_step = b.step("run", "Run the main application");
    run_step.dependOn(&run_cmd.step);
    
    // Test command
    const alpaca_run_cmd = b.addRunArtifact(alpaca_exe);
    const alpaca_run_step = b.step("test-alpaca", "Test Alpaca connection");
    alpaca_run_step.dependOn(&alpaca_run_cmd.step);
    
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
    
    // Real connection test command
    const real_test_run_cmd = b.addRunArtifact(real_test_exe);
    const real_test_run_step = b.step("test-real-connections", "Test real Alpaca connections");
    real_test_run_step.dependOn(&real_test_run_cmd.step);

    // WebSocket test command
    const ws_test_run_cmd = b.addRunArtifact(ws_test_exe);
    const ws_test_run_step = b.step("test-websocket", "Test WebSocket connection with libwebsockets");
    ws_test_run_step.dependOn(&ws_test_run_cmd.step);
}