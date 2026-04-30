//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! NON-COMMERCIAL USE (MIT License):
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction for NON-COMMERCIAL purposes, including
//! without limitation the rights to use, copy, modify, merge, publish, distribute,
//! sublicense, and/or sell copies of the Software for non-commercial purposes,
//! and to permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
//!
//! COMMERCIAL USE:
//! Commercial use of this software requires a separate commercial license.
//! Contact info@quantumencoding.io for commercial licensing terms.


// SPDX-License-Identifier: MIT
//
// config.zig - Configuration loader for zig-http-sentinel
//
// Purpose: Load and parse JSON configuration files for filter engine

const std = @import("std");
const filter_engine = @import("filter_engine.zig");

/// Whitelist configuration structure
pub const WhitelistConfig = struct {
    allowed_domains: [][]const u8,

    pub fn deinit(self: WhitelistConfig, allocator: std.mem.Allocator) void {
        for (self.allowed_domains) |domain| {
            allocator.free(domain);
        }
        allocator.free(self.allowed_domains);
    }
};

/// Load whitelist configuration from JSON file
pub fn loadWhitelistConfig(allocator: std.mem.Allocator, path: []const u8) !WhitelistConfig {
    // Read file
    const file = try std.Io.Dir.cwd().openFile(path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const contents = try allocator.alloc(u8, file_size);
    defer allocator.free(contents);

    _ = try file.read(contents);

    // Parse JSON
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        contents,
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value;

    // Extract allowed_domains array
    const domains_array = root.object.get("allowed_domains") orelse return error.MissingAllowedDomains;

    var domains = std.ArrayList([]const u8).empty;
    errdefer {
        for (domains.items) |domain| {
            allocator.free(domain);
        }
        domains.deinit(allocator);
    }

    for (domains_array.array.items) |item| {
        const domain_str = item.string;
        const domain_copy = try allocator.dupe(u8, domain_str);
        try domains.append(allocator, domain_copy);
    }

    return WhitelistConfig{
        .allowed_domains = try domains.toOwnedSlice(allocator),
    };
}

/// Load whitelist into filter
pub fn loadWhitelist(filter: *filter_engine.WhitelistFilter, path: []const u8) !void {
    const config = try loadWhitelistConfig(filter.allocator, path);
    defer config.deinit(filter.allocator);

    for (config.allowed_domains) |domain| {
        try filter.addDomain(domain);
    }
}

// ============================================================
// Tests
// ============================================================

test "config: load whitelist from JSON" {
    const allocator = std.testing.allocator;

    // Create temporary config file
    const test_config =
        \\{
        \\  "allowed_domains": [
        \\    "example.com",
        \\    "test.org",
        \\    "*.github.com"
        \\  ]
        \\}
    ;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var tmp_file = try tmp_dir.dir.createFile("whitelist.json", .{});
    defer tmp_file.close();

    try tmp_file.writeAll(test_config);

    // Load config
    var path_buf: [4096]u8 = undefined;
    const path = try tmp_dir.dir.realpath("whitelist.json", &path_buf);

    const config = try loadWhitelistConfig(allocator, path);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), config.allowed_domains.len);
    try std.testing.expectEqualStrings("example.com", config.allowed_domains[0]);
    try std.testing.expectEqualStrings("test.org", config.allowed_domains[1]);
    try std.testing.expectEqualStrings("*.github.com", config.allowed_domains[2]);
}
