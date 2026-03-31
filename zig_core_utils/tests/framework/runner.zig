//! Test Runner Framework for Zig Coreutils
//!
//! Provides a unified test framework for running compatibility and unit tests
//! against Zig coreutils, comparing output with GNU equivalents.
//!
//! Usage:
//!   zig build run -- test zls           # Run tests for zls
//!   zig build run -- test --all         # Run all tests
//!   zig build run -- compare ls zls     # Compare GNU ls vs zls output

const std = @import("std");
const posix = std.posix;

pub const TestResult = struct {
    name: []const u8,
    passed: bool,
    expected: ?[]const u8 = null,
    actual: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,
    duration_ns: u64 = 0,
};

pub const TestSuite = struct {
    name: []const u8,
    tests: []const TestCase,
};

pub const TestCase = struct {
    name: []const u8,
    args: []const []const u8,
    expected_exit: u8 = 0,
    expected_stdout: ?[]const u8 = null,
    expected_stderr: ?[]const u8 = null,
    compare_with_gnu: bool = false,
    timeout_ms: u32 = 5000,
};

pub const CompareResult = struct {
    stdout_match: bool,
    stderr_match: bool,
    exit_match: bool,
    zig_stdout: []const u8,
    gnu_stdout: []const u8,
    zig_stderr: []const u8,
    gnu_stderr: []const u8,
    zig_exit: u8,
    gnu_exit: u8,
};

/// Run a command and capture output
pub fn runCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    timeout_ms: u32,
) !struct { stdout: []u8, stderr: []u8, exit_code: u8 } {
    _ = timeout_ms;

    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readAllAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readAllAlloc(allocator, 1024 * 1024);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
    };
}

/// Compare Zig utility output with GNU equivalent
pub fn compareWithGnu(
    allocator: std.mem.Allocator,
    zig_cmd: []const []const u8,
    gnu_cmd: []const []const u8,
) !CompareResult {
    const zig_result = try runCommand(allocator, zig_cmd, 5000);
    const gnu_result = try runCommand(allocator, gnu_cmd, 5000);

    return CompareResult{
        .stdout_match = std.mem.eql(u8, zig_result.stdout, gnu_result.stdout),
        .stderr_match = std.mem.eql(u8, zig_result.stderr, gnu_result.stderr),
        .exit_match = zig_result.exit_code == gnu_result.exit_code,
        .zig_stdout = zig_result.stdout,
        .gnu_stdout = gnu_result.stdout,
        .zig_stderr = zig_result.stderr,
        .gnu_stderr = gnu_result.stderr,
        .zig_exit = zig_result.exit_code,
        .gnu_exit = gnu_result.exit_code,
    };
}

/// Run a test case
pub fn runTestCase(
    allocator: std.mem.Allocator,
    test_case: TestCase,
    zig_binary: []const u8,
) !TestResult {
    const start = std.time.nanoTimestamp();

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append(zig_binary);
    for (test_case.args) |arg| {
        try args.append(arg);
    }

    const result = runCommand(allocator, args.items, test_case.timeout_ms) catch |err| {
        return TestResult{
            .name = test_case.name,
            .passed = false,
            .error_msg = @errorName(err),
            .duration_ns = @intCast(std.time.nanoTimestamp() - start),
        };
    };

    var passed = true;

    // Check exit code
    if (result.exit_code != test_case.expected_exit) {
        passed = false;
    }

    // Check stdout
    if (test_case.expected_stdout) |expected| {
        if (!std.mem.eql(u8, result.stdout, expected)) {
            passed = false;
        }
    }

    // Check stderr
    if (test_case.expected_stderr) |expected| {
        if (!std.mem.eql(u8, result.stderr, expected)) {
            passed = false;
        }
    }

    return TestResult{
        .name = test_case.name,
        .passed = passed,
        .expected = test_case.expected_stdout,
        .actual = result.stdout,
        .duration_ns = @intCast(std.time.nanoTimestamp() - start),
    };
}

/// Run all tests in a suite
pub fn runTestSuite(
    allocator: std.mem.Allocator,
    suite: TestSuite,
    zig_binary: []const u8,
) !struct { passed: u32, failed: u32, results: []TestResult } {
    var results = std.ArrayList(TestResult).init(allocator);
    var passed: u32 = 0;
    var failed: u32 = 0;

    for (suite.tests) |test_case| {
        const result = try runTestCase(allocator, test_case, zig_binary);
        try results.append(result);
        if (result.passed) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    return .{
        .passed = passed,
        .failed = failed,
        .results = try results.toOwnedSlice(),
    };
}

/// Output test results in JSON format
pub fn outputResultsJson(
    writer: anytype,
    utility: []const u8,
    passed: u32,
    total: u32,
    results: []const TestResult,
) !void {
    try writer.print("{{\n", .{});
    try writer.print("  \"{s}\": {{\n", .{utility});
    try writer.print("    \"tests_passed\": {d},\n", .{passed});
    try writer.print("    \"tests_total\": {d},\n", .{total});
    try writer.print("    \"percentage\": {d},\n", .{if (total > 0) (passed * 100) / total else 0});

    const status = if (total == 0) "none" else if ((passed * 100) / total >= 90) "pass" else if ((passed * 100) / total >= 50) "warn" else "fail";
    try writer.print("    \"status\": \"{s}\",\n", .{status});

    try writer.print("    \"tests\": [\n", .{});
    for (results, 0..) |result, i| {
        try writer.print("      {{\n", .{});
        try writer.print("        \"name\": \"{s}\",\n", .{result.name});
        try writer.print("        \"passed\": {s},\n", .{if (result.passed) "true" else "false"});
        try writer.print("        \"duration_ms\": {d:.3}\n", .{@as(f64, @floatFromInt(result.duration_ns)) / 1_000_000.0});
        try writer.print("      }}{s}\n", .{if (i < results.len - 1) "," else ""});
    }
    try writer.print("    ]\n", .{});
    try writer.print("  }}\n", .{});
    try writer.print("}}\n", .{});
}

// Color output helpers
const Color = struct {
    const reset = "\x1b[0m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const dim = "\x1b[2m";
};

pub fn printTestResult(result: TestResult) void {
    const stdout = std.io.getStdOut().writer();

    if (result.passed) {
        stdout.print("{s}PASS{s} ", .{ Color.green, Color.reset }) catch {};
    } else {
        stdout.print("{s}FAIL{s} ", .{ Color.red, Color.reset }) catch {};
    }

    stdout.print("{s} ", .{result.name}) catch {};

    stdout.print("{s}({d:.2}ms){s}\n", .{
        Color.dim,
        @as(f64, @floatFromInt(result.duration_ns)) / 1_000_000.0,
        Color.reset,
    }) catch {};

    if (!result.passed and result.error_msg != null) {
        stdout.print("       Error: {s}\n", .{result.error_msg.?}) catch {};
    }
}

pub fn printSummary(passed: u32, failed: u32) void {
    const stdout = std.io.getStdOut().writer();
    const total = passed + failed;

    stdout.print("\n", .{}) catch {};
    stdout.print("Results: ", .{}) catch {};
    stdout.print("{s}{d} passed{s}, ", .{ Color.green, passed, Color.reset }) catch {};
    stdout.print("{s}{d} failed{s}, ", .{ if (failed > 0) Color.red else Color.dim, failed, Color.reset }) catch {};
    stdout.print("{d} total\n", .{total}) catch {};
}
