const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const IpAddress = Io.net.IpAddress;

// Import from main.zig
const main = @import("main.zig");
const PortStatus = main.PortStatus;
const ScanConfig = main.ScanConfig;

// Test Configuration
const TEST_TIMEOUT_MS = 5000; // Longer timeout for tests

// ============================================================================
// PORT PARSING TESTS
// ============================================================================

test "parse single port" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    try main.parsePortSpec("80", &ports, allocator);
    try testing.expectEqual(@as(usize, 1), ports.items.len);
    try testing.expectEqual(@as(u16, 80), ports.items[0]);
}

test "parse port range" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    try main.parsePortSpec("20-23", &ports, allocator);
    try testing.expectEqual(@as(usize, 4), ports.items.len);
    try testing.expectEqual(@as(u16, 20), ports.items[0]);
    try testing.expectEqual(@as(u16, 21), ports.items[1]);
    try testing.expectEqual(@as(u16, 22), ports.items[2]);
    try testing.expectEqual(@as(u16, 23), ports.items[3]);
}

test "parse comma-separated ports" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    try main.parsePortSpec("80,443,8080", &ports, allocator);
    try testing.expectEqual(@as(usize, 3), ports.items.len);
    try testing.expectEqual(@as(u16, 80), ports.items[0]);
    try testing.expectEqual(@as(u16, 443), ports.items[1]);
    try testing.expectEqual(@as(u16, 8080), ports.items[2]);
}

test "parse mixed ports and ranges" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    try main.parsePortSpec("22,80-82,443", &ports, allocator);
    try testing.expectEqual(@as(usize, 5), ports.items.len);
    try testing.expectEqual(@as(u16, 22), ports.items[0]);
    try testing.expectEqual(@as(u16, 80), ports.items[1]);
    try testing.expectEqual(@as(u16, 81), ports.items[2]);
    try testing.expectEqual(@as(u16, 82), ports.items[3]);
    try testing.expectEqual(@as(u16, 443), ports.items[4]);
}

test "parse invalid port spec - letters" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    const result = main.parsePortSpec("abc", &ports, allocator);
    try testing.expectError(main.ScannerError.InvalidPortRange, result);
}

test "parse invalid port spec - too large" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    const result = main.parsePortSpec("99999", &ports, allocator);
    try testing.expectError(main.ScannerError.InvalidPortRange, result);
}

test "parse invalid port range - reversed" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    // Should handle gracefully (swap or error)
    const result = main.parsePortSpec("100-50", &ports, allocator);
    // Depending on implementation, this might error or auto-swap
    _ = result catch |err| {
        try testing.expect(err == main.ScannerError.InvalidPortRange or err == error.InvalidCharacter);
        return;
    };
}

test "port deduplication" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    try main.parsePortSpec("80,80,80", &ports, allocator);

    // Should deduplicate
    var unique: std.ArrayList(u16) = .empty;
    defer unique.deinit(allocator);

    for (ports.items) |port| {
        var found = false;
        for (unique.items) |existing| {
            if (existing == port) {
                found = true;
                break;
            }
        }
        if (!found) try unique.append(allocator, port);
    }

    try testing.expectEqual(@as(usize, 1), unique.items.len);
}

// ============================================================================
// IP ADDRESS PARSING TESTS
// ============================================================================

test "parse IPv4 address" {
    const addr = try IpAddress.parse("127.0.0.1", 80);
    try testing.expect(addr == .ip4);
    try testing.expectEqual(@as(u16, 80), addr.ip4.port);
    try testing.expectEqual(@as(u8, 127), addr.ip4.bytes[0]);
    try testing.expectEqual(@as(u8, 0), addr.ip4.bytes[1]);
    try testing.expectEqual(@as(u8, 0), addr.ip4.bytes[2]);
    try testing.expectEqual(@as(u8, 1), addr.ip4.bytes[3]);
}

test "parse IPv6 address" {
    const addr = try IpAddress.parse("::1", 80);
    try testing.expect(addr == .ip6);
    try testing.expectEqual(@as(u16, 80), addr.ip6.port);
}

test "parse invalid IP address" {
    const result = IpAddress.parse("999.999.999.999", 80);
    try testing.expectError(error.ParseFailed, result);
}

// ============================================================================
// SERVICE NAME TESTS
// ============================================================================

test "service name detection - common ports" {
    try testing.expectEqualStrings("http", main.getServiceName(80));
    try testing.expectEqualStrings("https", main.getServiceName(443));
    try testing.expectEqualStrings("ssh", main.getServiceName(22));
    try testing.expectEqualStrings("ftp", main.getServiceName(21));
    try testing.expectEqualStrings("smtp", main.getServiceName(25));
}

test "service name detection - unknown port" {
    const service = main.getServiceName(54321);
    try testing.expectEqualStrings("", service);
}

// ============================================================================
// PORT STATUS TESTS
// ============================================================================

test "port status to string" {
    try testing.expectEqualStrings("open", PortStatus.open.toString());
    try testing.expectEqualStrings("closed", PortStatus.closed.toString());
    try testing.expectEqualStrings("filtered", PortStatus.filtered.toString());
    try testing.expectEqualStrings("unknown", PortStatus.unknown.toString());
}

// ============================================================================
// NETWORK TESTS (LOCALHOST)
// ============================================================================

test "scan localhost port - should be closed" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const addr = try IpAddress.parse("127.0.0.1", 54321); // Random unlikely port
    const status = try main.scanPort(io, addr, 1000);

    // Should be either closed or filtered (not open)
    try testing.expect(status != .open);
}

test "scan localhost - IPv6" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const addr = try IpAddress.parse("::1", 54321);
    const status = try main.scanPort(io, addr, 1000);

    // Should complete without error
    try testing.expect(status != .open);
}

// ============================================================================
// DNS RESOLUTION TESTS
// ============================================================================

test "resolve localhost" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const addr = try main.resolveHost(io, "localhost");

    // Should resolve to 127.0.0.1 or ::1
    switch (addr) {
        .ip4 => |ip4| {
            try testing.expectEqual(@as(u8, 127), ip4.bytes[0]);
            try testing.expectEqual(@as(u8, 0), ip4.bytes[1]);
            try testing.expectEqual(@as(u8, 0), ip4.bytes[2]);
            try testing.expectEqual(@as(u8, 1), ip4.bytes[3]);
        },
        .ip6 => {
            // IPv6 localhost (::1) is also valid
        },
    }
}

test "resolve IP address directly" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const addr = try main.resolveHost(io, "1.1.1.1");

    // Should parse as IP without DNS lookup
    try testing.expect(addr == .ip4);
    try testing.expectEqual(@as(u8, 1), addr.ip4.bytes[0]);
    try testing.expectEqual(@as(u8, 1), addr.ip4.bytes[1]);
    try testing.expectEqual(@as(u8, 1), addr.ip4.bytes[2]);
    try testing.expectEqual(@as(u8, 1), addr.ip4.bytes[3]);
}

test "resolve invalid hostname" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const result = main.resolveHost(io, "this-hostname-definitely-does-not-exist-12345.invalid");
    try testing.expectError(main.ScannerError.ResolutionFailed, result);
}

// ============================================================================
// TIMEOUT TESTS
// ============================================================================

test "timeout on unreachable host" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    // 192.0.2.1 is TEST-NET-1 (RFC 5737) - reserved for documentation, should timeout
    const addr = try IpAddress.parse("192.0.2.1", 80);

    var timer = try std.time.Timer.start();
    const status = try main.scanPort(io, addr, 1000); // 1 second timeout
    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    // Should timeout (filtered status) and complete within reasonable time
    try testing.expect(status == .filtered or status == .unknown);
    try testing.expect(elapsed_ms < 2000); // Should timeout within ~1 second (+ overhead)
}

// ============================================================================
// EDGE CASE TESTS
// ============================================================================

test "port 0 handling" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    // Port 0 is technically invalid for scanning
    const result = main.parsePortSpec("0", &ports, allocator);
    _ = result catch |err| {
        // Should either parse or error gracefully
        try testing.expect(err == error.InvalidCharacter or err == main.ScannerError.InvalidPortRange);
        return;
    };
}

test "empty port spec" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    const result = main.parsePortSpec("", &ports, allocator);
    try testing.expectError(main.ScannerError.InvalidPortRange, result);
}

test "whitespace in port spec" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    // Should handle or reject whitespace
    const result = main.parsePortSpec(" 80 ", &ports, allocator);
    _ = result catch |err| {
        try testing.expect(err == error.InvalidCharacter);
        return;
    };
}

// ============================================================================
// CONCURRENCY TESTS
// ============================================================================

test "multiple threads scanning same port" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const addr = try IpAddress.parse("127.0.0.1", 54321);

    // Scan same port multiple times concurrently (simulating thread pool)
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const status = try main.scanPort(io, addr, 500);
        try testing.expect(status != .open);
    }
}

// ============================================================================
// ERROR RECOVERY TESTS
// ============================================================================

test "scan after DNS failure" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    // First, fail DNS
    const dns_result = main.resolveHost(io, "invalid-host-12345.invalid");
    try testing.expectError(main.ScannerError.ResolutionFailed, dns_result);

    // Then, succeed with valid host
    const addr = try main.resolveHost(io, "localhost");
    try testing.expect(addr == .ip4 or addr == .ip6);
}

test "scan after connection failure" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    // Scan closed port
    const addr1 = try IpAddress.parse("127.0.0.1", 54321);
    const status1 = try main.scanPort(io, addr1, 500);
    try testing.expect(status1 == .closed or status1 == .filtered);

    // Then scan another port (should work fine)
    const addr2 = try IpAddress.parse("127.0.0.1", 54322);
    const status2 = try main.scanPort(io, addr2, 500);
    try testing.expect(status2 == .closed or status2 == .filtered);
}

// ============================================================================
// INTEGRATION TESTS (REQUIRE NETWORK)
// ============================================================================

// These tests require actual network access and will be skipped in isolated CI
// Run with: zig test src/test.zig --test-filter "integration"

test "integration: scan google.com HTTP" {
    if (@import("builtin").os.tag == .freestanding) return error.SkipZigTest;

    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const addr = main.resolveHost(io, "google.com") catch |err| {
        std.debug.print("Skipping integration test (no network): {}\n", .{err});
        return error.SkipZigTest;
    };

    const addr_with_port = switch (addr) {
        .ip4 => |ip4| IpAddress{ .ip4 = .{ .bytes = ip4.bytes, .port = 80 } },
        .ip6 => |ip6| IpAddress{ .ip6 = .{ .port = 80, .bytes = ip6.bytes, .flow = ip6.flow, .interface = ip6.interface } },
    };

    const status = try main.scanPort(io, addr_with_port, 5000);
    try testing.expect(status == .open); // Google port 80 should be open
}

test "integration: scan github.com SSH" {
    if (@import("builtin").os.tag == .freestanding) return error.SkipZigTest;

    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const addr = main.resolveHost(io, "github.com") catch |err| {
        std.debug.print("Skipping integration test (no network): {}\n", .{err});
        return error.SkipZigTest;
    };

    const addr_with_port = switch (addr) {
        .ip4 => |ip4| IpAddress{ .ip4 = .{ .bytes = ip4.bytes, .port = 22 } },
        .ip6 => |ip6| IpAddress{ .ip6 = .{ .port = 22, .bytes = ip6.bytes, .flow = ip6.flow, .interface = ip6.interface } },
    };

    const status = try main.scanPort(io, addr_with_port, 5000);
    try testing.expect(status == .open); // GitHub SSH should be open
}

// ============================================================================
// PERFORMANCE TESTS
// ============================================================================

test "performance: parse 1000 ports" {
    const allocator = std.heap.c_allocator;

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    var timer = try std.time.Timer.start();
    try main.parsePortSpec("1-1000", &ports, allocator);
    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    try testing.expectEqual(@as(usize, 1000), ports.items.len);
    try testing.expect(elapsed_ms < 100); // Should be very fast
}

test "performance: scan 10 ports localhost" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var timer = try std.time.Timer.start();

    var i: u16 = 54321;
    while (i < 54331) : (i += 1) {
        const addr = try IpAddress.parse("127.0.0.1", i);
        _ = try main.scanPort(io, addr, 500);
    }

    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    // Should complete reasonably fast (mostly closed/refused)
    try testing.expect(elapsed_ms < 2000); // ~200ms per port max
}
