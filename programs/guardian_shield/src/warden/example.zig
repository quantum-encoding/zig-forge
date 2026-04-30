//! Guardian Shield V8.0 - Embedded Warden Example
//!
//! This example demonstrates how to use the warden module to:
//! 1. Protect paths programmatically at runtime
//! 2. Spawn child processes with inherited protection
//! 3. Use scoped protection that auto-cleans up
//!
//! Build: zig build
//! Run: ./zig-out/bin/warden-example

const std = @import("std");
const warden = @import("warden");

const c = @cImport({
    @cInclude("unistd.h");
});

fn writeStdout(data: []const u8) void {
    _ = c.write(c.STDOUT_FILENO, data.ptr, data.len);
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStdout(result);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    writeStdout(
        \\
        \\╔══════════════════════════════════════════════════════════════╗
        \\║  Guardian Shield V8.0 - Embedded Warden Example              ║
        \\╚══════════════════════════════════════════════════════════════╝
        \\
        \\
    );

    // Initialize the warden module
    try warden.init(allocator);
    defer warden.deinit();

    writeStdout("1. Adding runtime protection rules...\n");

    // Example 1: Protect a sensitive directory
    try warden.protect("/tmp/warden-test-sensitive", .{
        .read_only = true,
    });
    writeStdout("   [OK] Protected /tmp/warden-test-sensitive (read-only)\n");

    // Example 2: Protect with specific flags
    try warden.protect("/tmp/warden-test-data", .{
        .no_delete = true,
        .no_truncate = true,
    });
    writeStdout("   [OK] Protected /tmp/warden-test-data (no-delete, no-truncate)\n");

    // Example 3: Check if path is protected
    writeStdout("\n2. Checking protection status...\n");

    const paths_to_check = [_][]const u8{
        "/tmp/warden-test-sensitive/file.txt",
        "/tmp/warden-test-data/important.db",
        "/tmp/unprotected/file.txt",
        "/home/user/documents",
    };

    for (paths_to_check) |path| {
        const protected = warden.isProtected(path);
        const status = if (protected) "PROTECTED" else "unprotected";
        print("   {s}: {s}\n", .{ path, status });
    }

    // Example 4: Check if specific operations would be blocked
    writeStdout("\n3. Checking operation permissions...\n");

    const test_cases = [_]struct { path: []const u8, op: warden.Operation }{
        .{ .path = "/tmp/warden-test-sensitive/file.txt", .op = .write },
        .{ .path = "/tmp/warden-test-sensitive/file.txt", .op = .delete },
        .{ .path = "/tmp/warden-test-data/db.sqlite", .op = .delete },
        .{ .path = "/tmp/warden-test-data/db.sqlite", .op = .write },
        .{ .path = "/tmp/unprotected/file.txt", .op = .delete },
    };

    for (test_cases) |tc| {
        const blocked = warden.wouldBlock(tc.path, tc.op);
        const status = if (blocked) "BLOCKED" else "allowed";
        print("   {s} on {s}: {s}\n", .{ @tagName(tc.op), tc.path, status });
    }

    // Example 5: Scoped protection
    writeStdout("\n4. Demonstrating scoped protection...\n");
    {
        var guard = try warden.ScopedProtection.init("/tmp/warden-scoped", .{
            .no_execute = true,
            .no_symlink = true,
        });
        defer guard.deinit();

        writeStdout("   [OK] Scoped protection active for /tmp/warden-scoped\n");
        print("   Is protected: {}\n", .{warden.isProtected("/tmp/warden-scoped/script.sh")});

        // Protection automatically removed when guard goes out of scope
    }
    writeStdout("   [OK] Scoped protection released\n");
    print("   Is protected after scope: {}\n", .{warden.isProtected("/tmp/warden-scoped/script.sh")});

    // Example 6: Show how to spawn protected child process
    writeStdout("\n5. Child process spawning (demonstration)...\n");
    writeStdout(
        \\   To spawn a protected child process:
        \\
        \\   const child = try warden.spawnProtected(&.{"./untrusted-app"}, .{
        \\       .inherit_rules = true,
        \\       .additional_rules = &.{
        \\           .{ .path = "/secrets", .flags = .{ .read_only = true } },
        \\       },
        \\   });
        \\   _ = try child.wait();
        \\
        \\   The child process will:
        \\   - Inherit all parent protection rules
        \\   - Have LD_PRELOAD set to load libwarden.so
        \\   - Apply any additional rules specified
        \\
    );

    // Example 7: Get all current rules
    writeStdout("\n6. Current protection rules:\n");
    const rules = warden.getRules();
    for (rules) |rule| {
        print("   [PATH] {s}\n", .{rule.path});
        print("      no_delete={}, no_write={}, read_only={}\n", .{
            rule.flags.no_delete,
            rule.flags.no_write,
            rule.flags.read_only,
        });
    }

    // Cleanup
    writeStdout("\n7. Cleaning up...\n");
    try warden.unprotect("/tmp/warden-test-sensitive");
    try warden.unprotect("/tmp/warden-test-data");
    writeStdout("   [OK] Protection rules removed\n");

    writeStdout(
        \\
        \\===================================================================
        \\Example complete!
        \\
        \\To use in your own programs:
        \\
        \\1. Add to build.zig.zon dependencies:
        \\   .warden = .{ .path = "/path/to/guardian_shield/src/warden" }
        \\
        \\2. Import in your code:
        \\   const warden = @import("warden");
        \\
        \\3. Initialize and protect:
        \\   try warden.init(allocator);
        \\   defer warden.deinit();
        \\   try warden.protect("/data", .{ .read_only = true });
        \\
        \\===================================================================
        \\
    );
}
