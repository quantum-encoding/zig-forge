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
// filter_engine.zig - Core Filter Engine for zig-http-sentinel
//
// Purpose: Sequential inspection pipeline for outbound HTTP requests
// Architecture: Fail-fast filter chain with audit logging
//
// The Sovereign Egress Protocol: "No untrusted process speaks to the outside world directly."

const std = @import("std");

/// Version identifier
pub const VERSION = "1.0.0";

/// HTTP request structure for inspection
pub const HttpRequest = struct {
    method: []const u8,          // GET, POST, PUT, DELETE, etc.
    url: []const u8,             // Full URL
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,           // Optional request body
    pid: u32,                    // Process ID making the request

    pub fn init(allocator: std.mem.Allocator, method: []const u8, url: []const u8, pid: u32) HttpRequest {
        return .{
            .method = method,
            .url = url,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = null,
            .pid = pid,
        };
    }

    pub fn deinit(self: *HttpRequest) void {
        self.headers.deinit();
    }
};

/// Filter result - either allowed or blocked with reason
pub const FilterResult = union(enum) {
    allowed: void,
    blocked: BlockReason,

    pub fn isBlocked(self: FilterResult) bool {
        return switch (self) {
            .allowed => false,
            .blocked => true,
        };
    }
};

/// Reason why a request was blocked
pub const BlockReason = struct {
    filter_name: []const u8,
    severity: Severity,
    reason: []const u8,
    evidence: ?[]const u8,       // Optional evidence (may be sensitive)
    recommendation: []const u8,
    is_owned: bool,              // Whether strings need to be freed

    pub fn deinit(self: BlockReason, allocator: std.mem.Allocator) void {
        if (self.is_owned) {
            allocator.free(self.reason);
            if (self.evidence) |ev| {
                allocator.free(ev);
            }
        }
    }

    /// Format block reason as human-readable string
    pub fn format(self: BlockReason, allocator: std.mem.Allocator) ![]const u8 {
        const severity_emoji = switch (self.severity) {
            .info => "ℹ️",
            .warning => "⚠️",
            .high => "🔶",
            .critical => "🔴",
        };

        const severity_str = switch (self.severity) {
            .info => "INFO",
            .warning => "WARNING",
            .high => "HIGH",
            .critical => "CRITICAL",
        };

        if (self.evidence) |ev| {
            return try std.fmt.allocPrint(
                allocator,
                "{s} BLOCKED: {s}\nSeverity: {s}\nReason: {s}\nEvidence: {s}\nRecommendation: {s}",
                .{ severity_emoji, self.filter_name, severity_str, self.reason, ev, self.recommendation },
            );
        } else {
            return try std.fmt.allocPrint(
                allocator,
                "{s} BLOCKED: {s}\nSeverity: {s}\nReason: {s}\nRecommendation: {s}",
                .{ severity_emoji, self.filter_name, severity_str, self.reason, self.recommendation },
            );
        }
    }
};

/// Alert severity levels
pub const Severity = enum {
    info,
    warning,
    high,
    critical,

    pub fn priority(self: Severity) u8 {
        return switch (self) {
            .info => 1,
            .warning => 2,
            .high => 3,
            .critical => 4,
        };
    }
};

/// Filter engine configuration
pub const FilterConfig = struct {
    /// Enable the filter engine
    enabled: bool,

    /// Audit log path
    audit_log_path: []const u8,

    /// Enable individual filters
    enable_whitelist: bool,
    enable_trojan_link: bool,
    enable_crown_jewels: bool,
    enable_poisoned_pixel: bool,

    pub fn init() FilterConfig {
        return .{
            .enabled = true,
            .audit_log_path = "/var/log/zig-http-sentinel/blocks.json",
            .enable_whitelist = true,
            .enable_trojan_link = false,  // Not implemented yet
            .enable_crown_jewels = false, // Not implemented yet
            .enable_poisoned_pixel = false, // Not implemented yet
        };
    }
};

/// Main filter engine - coordinates all inspection filters
pub const FilterEngine = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: FilterConfig,

    // Filter modules
    whitelist_filter: ?WhitelistFilter,

    // Statistics
    total_requests: u64,
    allowed_requests: u64,
    blocked_requests: u64,
    blocks_by_filter: [4]u64,  // [whitelist, trojan_link, crown_jewels, poisoned_pixel]

    pub fn init(allocator: std.mem.Allocator, config: FilterConfig) !Self {
        var engine = Self{
            .allocator = allocator,
            .config = config,
            .whitelist_filter = null,
            .total_requests = 0,
            .allowed_requests = 0,
            .blocked_requests = 0,
            .blocks_by_filter = [_]u64{0} ** 4,
        };

        // Initialize whitelist filter if enabled
        if (config.enable_whitelist) {
            engine.whitelist_filter = try WhitelistFilter.init(allocator);
        }

        return engine;
    }

    pub fn deinit(self: *Self) void {
        if (self.whitelist_filter) |*filter| {
            filter.deinit();
        }
    }

    /// Inspect an HTTP request through all enabled filters
    pub fn inspect(self: *Self, request: *HttpRequest) !FilterResult {
        self.total_requests += 1;

        // Filter 1: Destination whitelist
        if (self.config.enable_whitelist) {
            if (self.whitelist_filter) |*filter| {
                if (try filter.check(request)) |block| {
                    self.blocked_requests += 1;
                    self.blocks_by_filter[0] += 1;
                    try self.logBlock(request, block);
                    return FilterResult{ .blocked = block };
                }
            }
        }

        // Future filters will be added here:
        // - Trojan Link detector
        // - Crown Jewels matcher
        // - Poisoned Pixel heuristic

        // All filters passed
        self.allowed_requests += 1;
        return FilterResult{ .allowed = {} };
    }

    /// Log a blocked request to audit log (JSON format to stderr)
    fn logBlock(self: *Self, request: *HttpRequest, block: BlockReason) !void {
        _ = self;

        const severity_str: []const u8 = switch (block.severity) {
            .info => "info",
            .warning => "warning",
            .high => "high",
            .critical => "critical",
        };

        // Build JSON audit log entry to stderr
        // Format: {"event":"http_block","pid":1234,"method":"GET","url":"...","filter":"...","severity":"...","reason":"..."[,"evidence":"..."]}
        if (block.evidence) |ev| {
            std.debug.print(
                "{{\"event\":\"http_block\",\"pid\":{d},\"method\":\"{s}\",\"url\":\"{s}\"," ++
                "\"filter\":\"{s}\",\"severity\":\"{s}\",\"reason\":\"{s}\",\"evidence\":\"{s}\"}}\n",
                .{
                    request.pid,
                    request.method,
                    request.url,
                    block.filter_name,
                    severity_str,
                    block.reason,
                    ev,
                },
            );
        } else {
            std.debug.print(
                "{{\"event\":\"http_block\",\"pid\":{d},\"method\":\"{s}\",\"url\":\"{s}\"," ++
                "\"filter\":\"{s}\",\"severity\":\"{s}\",\"reason\":\"{s}\"}}\n",
                .{
                    request.pid,
                    request.method,
                    request.url,
                    block.filter_name,
                    severity_str,
                    block.reason,
                },
            );
        }
    }

    /// Display filter engine statistics
    pub fn displayStats(self: *Self) void {
        std.debug.print("🚪 zig-http-sentinel Filter Engine Statistics:\n", .{});
        std.debug.print("   Total requests:       {d}\n", .{self.total_requests});
        std.debug.print("   Allowed requests:     {d}\n", .{self.allowed_requests});
        std.debug.print("   Blocked requests:     {d}\n", .{self.blocked_requests});
        if (self.blocked_requests > 0) {
            std.debug.print("\n   Blocks by filter:\n", .{});
            std.debug.print("     Destination Whitelist:  {d}\n", .{self.blocks_by_filter[0]});
            std.debug.print("     Trojan Link Detector:   {d}\n", .{self.blocks_by_filter[1]});
            std.debug.print("     Crown Jewels Matcher:   {d}\n", .{self.blocks_by_filter[2]});
            std.debug.print("     Poisoned Pixel:         {d}\n", .{self.blocks_by_filter[3]});
        }
    }
};

// ============================================================
// Filter 1: Destination Whitelist
// ============================================================

/// Whitelist filter - only allow requests to approved domains
pub const WhitelistFilter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    allowed_domains: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) !Self {
        var filter = Self{
            .allocator = allocator,
            .allowed_domains = std.StringHashMap(void).init(allocator),
        };

        // Default whitelist (will be loaded from config file in production)
        try filter.addDomain("google.com");
        try filter.addDomain("github.com");
        try filter.addDomain("anthropic.com");
        try filter.addDomain("stackoverflow.com");
        try filter.addDomain("pypi.org");

        return filter;
    }

    pub fn deinit(self: *Self) void {
        // Free all domain strings
        var iter = self.allowed_domains.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.allowed_domains.deinit();
    }

    /// Add a domain to the whitelist
    pub fn addDomain(self: *Self, domain: []const u8) !void {
        const domain_copy = try self.allocator.dupe(u8, domain);
        try self.allowed_domains.put(domain_copy, {});
    }

    /// Check if request destination is whitelisted
    pub fn check(self: *Self, request: *HttpRequest) !?BlockReason {
        const host = try extractHost(self.allocator, request.url);
        defer self.allocator.free(host);

        // Check exact match
        if (self.allowed_domains.contains(host)) {
            return null;  // ALLOW
        }

        // Check wildcard matches (e.g., subdomain.github.com matches github.com)
        var iter = self.allowed_domains.keyIterator();
        while (iter.next()) |domain| {
            if (isSubdomainOf(host, domain.*)) {
                return null;  // ALLOW
            }
        }

        // Not whitelisted → BLOCK
        const reason = try std.fmt.allocPrint(
            self.allocator,
            "Destination '{s}' not on whitelist",
            .{host},
        );

        return BlockReason{
            .filter_name = "Destination Whitelist",
            .severity = .critical,
            .reason = reason,
            .evidence = null,
            .recommendation = "Add domain to whitelist if this is a legitimate service",
            .is_owned = true,
        };
    }
};

/// Extract hostname from URL
fn extractHost(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);

    // Extract host from authority
    if (uri.host) |host| {
        return try allocator.dupe(u8, host.percent_encoded);
    }

    return error.InvalidUrl;
}

/// Check if host is a subdomain of domain (e.g., api.github.com is subdomain of github.com)
fn isSubdomainOf(host: []const u8, domain: []const u8) bool {
    if (std.mem.eql(u8, host, domain)) {
        return true;  // Exact match
    }

    // Check if host ends with .domain
    if (host.len > domain.len + 1) {
        const suffix_start = host.len - domain.len;
        if (host[suffix_start - 1] == '.' and std.mem.eql(u8, host[suffix_start..], domain)) {
            return true;
        }
    }

    return false;
}

// ============================================================
// Tests
// ============================================================

test "whitelist: exact domain match" {
    const allocator = std.testing.allocator;

    var filter = try WhitelistFilter.init(allocator);
    defer filter.deinit();

    var request = HttpRequest.init(allocator, "GET", "https://github.com/user/repo", 1234);
    defer request.deinit();

    const result = try filter.check(&request);
    try std.testing.expect(result == null);  // Should be allowed
}

test "whitelist: subdomain match" {
    const allocator = std.testing.allocator;

    var filter = try WhitelistFilter.init(allocator);
    defer filter.deinit();

    var request = HttpRequest.init(allocator, "GET", "https://api.github.com/repos", 1234);
    defer request.deinit();

    const result = try filter.check(&request);
    try std.testing.expect(result == null);  // Should be allowed
}

test "whitelist: blocked domain" {
    const allocator = std.testing.allocator;

    var filter = try WhitelistFilter.init(allocator);
    defer filter.deinit();

    var request = HttpRequest.init(allocator, "GET", "https://evil-c2-server.com/exfil", 1234);
    defer request.deinit();

    const result = try filter.check(&request);
    try std.testing.expect(result != null);  // Should be blocked

    if (result) |block| {
        try std.testing.expectEqual(Severity.critical, block.severity);
        try std.testing.expectEqualStrings("Destination Whitelist", block.filter_name);
        block.deinit(allocator);
    }
}

test "filter engine: allow whitelisted request" {
    const allocator = std.testing.allocator;

    const config = FilterConfig.init();
    var engine = try FilterEngine.init(allocator, config);
    defer engine.deinit();

    var request = HttpRequest.init(allocator, "GET", "https://github.com/user/repo", 1234);
    defer request.deinit();

    const result = try engine.inspect(&request);
    try std.testing.expect(!result.isBlocked());
    try std.testing.expectEqual(@as(u64, 1), engine.total_requests);
    try std.testing.expectEqual(@as(u64, 1), engine.allowed_requests);
    try std.testing.expectEqual(@as(u64, 0), engine.blocked_requests);
}

test "filter engine: block non-whitelisted request" {
    const allocator = std.testing.allocator;

    const config = FilterConfig.init();
    var engine = try FilterEngine.init(allocator, config);
    defer engine.deinit();

    var request = HttpRequest.init(allocator, "POST", "https://evil.com/upload", 1234);
    defer request.deinit();

    const result = try engine.inspect(&request);
    try std.testing.expect(result.isBlocked());
    try std.testing.expectEqual(@as(u64, 1), engine.total_requests);
    try std.testing.expectEqual(@as(u64, 0), engine.allowed_requests);
    try std.testing.expectEqual(@as(u64, 1), engine.blocked_requests);
    try std.testing.expectEqual(@as(u64, 1), engine.blocks_by_filter[0]);

    if (result.blocked.is_owned) {
        result.blocked.deinit(allocator);
    }
}
