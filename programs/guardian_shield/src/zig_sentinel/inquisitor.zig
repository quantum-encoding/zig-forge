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


// SPDX-License-Identifier: GPL-3.0
//
// inquisitor.zig - Userspace Controller for The Inquisitor LSM BPF
//
// Purpose: Load, manage, and monitor the Inquisitor eBPF LSM program
// Architecture: Userspace control interface with ring buffer event consumer
//

const std = @import("std");
const time_compat = @import("time_compat.zig");
const emoji_sanitizer = @import("emoji_sanitizer.zig");

const c = @cImport({
    @cInclude("bpf/libbpf.h");
    @cInclude("bpf/bpf.h");
    @cInclude("linux/bpf.h");
    @cInclude("errno.h");
});

const MAX_PATTERN_LEN = 64;
const MAX_BLACKLIST_ENTRIES = 8; // Limited for eBPF verifier compatibility
const MAX_FILENAME_LEN = 256;

/// Blacklist entry structure (must match eBPF side)
const BlacklistEntry = extern struct {
    pattern: [MAX_PATTERN_LEN]u8,
    exact_match: u8,
    enabled: u8,
    reserved: u16,
};

/// Execution event from ring buffer (must match eBPF side)
const ExecEvent = extern struct {
    pid: u32,
    uid: u32,
    gid: u32,
    blocked: u32,
    filename: [MAX_FILENAME_LEN]u8,
    comm: [16]u8,
};

/// Inquisitor manager
pub const Inquisitor = struct {
    obj: ?*c.bpf_object,
    link: ?*c.bpf_link,
    blacklist_map_fd: i32,
    events_fd: i32,
    config_map_fd: i32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Inquisitor {
        return Inquisitor{
            .obj = null,
            .link = null,
            .blacklist_map_fd = -1,
            .events_fd = -1,
            .config_map_fd = -1,
            .allocator = allocator,
        };
    }

    /// Load and attach the Inquisitor eBPF program
    pub fn load(self: *Inquisitor, obj_path: []const u8) !void {
        std.debug.print("🗡️  The Inquisitor - Loading LSM BPF from: {s}\n", .{obj_path});

        // Convert path to null-terminated C string
        const path_z = try self.allocator.dupeZ(u8, obj_path);
        defer self.allocator.free(path_z);

        // Open eBPF object
        self.obj = c.bpf_object__open(path_z) orelse {
            std.debug.print("❌ Failed to open eBPF object: {s}\n", .{obj_path});
            return error.OpenFailed;
        };
        errdefer _ = c.bpf_object__close(self.obj);

        // Find the LSM program
        const prog = c.bpf_object__find_program_by_name(self.obj, "inquisitor_bprm_check") orelse {
            std.debug.print("❌ Failed to find LSM program 'inquisitor_bprm_check'\n", .{});
            return error.ProgramNotFound;
        };

        // Ensure program is set to load
        _ = c.bpf_program__set_autoload(prog, true);

        // Load eBPF program into kernel
        const load_result = c.bpf_object__load(self.obj);
        if (load_result != 0) {
            std.debug.print("❌ Failed to load eBPF object: errno={d}\n", .{-load_result});
            return error.LoadFailed;
        }

        std.debug.print("✓ Inquisitor eBPF program loaded into kernel\n", .{});

        // Find BPF maps
        const blacklist_map = c.bpf_object__find_map_by_name(self.obj, "blacklist_map") orelse {
            std.debug.print("❌ Failed to find blacklist_map\n", .{});
            return error.MapNotFound;
        };

        const events_map = c.bpf_object__find_map_by_name(self.obj, "events") orelse {
            std.debug.print("❌ Failed to find events map\n", .{});
            return error.MapNotFound;
        };

        const config_map = c.bpf_object__find_map_by_name(self.obj, "config_map") orelse {
            std.debug.print("❌ Failed to find config_map\n", .{});
            return error.MapNotFound;
        };

        // Get file descriptors
        self.blacklist_map_fd = c.bpf_map__fd(blacklist_map);
        self.events_fd = c.bpf_map__fd(events_map);
        self.config_map_fd = c.bpf_map__fd(config_map);

        if (self.blacklist_map_fd < 0 or self.events_fd < 0 or self.config_map_fd < 0) {
            std.debug.print("❌ Failed to get map file descriptors\n", .{});
            return error.MapFdFailed;
        }

        std.debug.print("✓ Found BPF maps: blacklist_map={d}, events={d}, config_map={d}\n", .{
            self.blacklist_map_fd,
            self.events_fd,
            self.config_map_fd,
        });

        // Get program FD to verify it's loaded
        const prog_fd = c.bpf_program__fd(prog);
        std.debug.print("📊 Program FD: {d}\n", .{prog_fd});

        std.debug.print("🔗 Attaching LSM program to bprm_check_security hook...\n", .{});
        self.link = c.bpf_program__attach(prog);

        if (self.link == null) {
            const errno = std.c._errno().*;
            std.debug.print("❌ Failed to attach LSM program (errno={d})\n", .{errno});
            std.debug.print("💡 LSM programs may require special kernel configuration\n", .{});
            return error.AttachFailed;
        }

        std.debug.print("✓ Inquisitor LSM hook attached to bprm_check_security\n", .{});
        std.debug.print("🗡️  The Inquisitor is now enforcing the Sovereign Command Blacklist\n", .{});
    }

    /// Set enforcement mode (1 = block, 0 = monitor only)
    pub fn setEnforcementMode(self: *Inquisitor, enforce: bool) !void {
        const key: u32 = 0;
        const value: u32 = if (enforce) 1 else 0;

        const result = c.bpf_map_update_elem(self.config_map_fd, &key, &value, c.BPF_ANY);
        if (result != 0) {
            std.debug.print("❌ Failed to set enforcement mode: errno={d}\n", .{-result});
            return error.MapUpdateFailed;
        }

        const mode_str = if (enforce) "ENFORCE (block mode)" else "MONITOR (log only)";
        std.debug.print("⚙️  Enforcement mode: {s}\n", .{mode_str});
    }

    /// Set whether to log allowed executions (1 = log all, 0 = log blocks only)
    pub fn setLogAllMode(self: *Inquisitor, log_all: bool) !void {
        const key: u32 = 1;
        const value: u32 = if (log_all) 1 else 0;

        const result = c.bpf_map_update_elem(self.config_map_fd, &key, &value, c.BPF_ANY);
        if (result != 0) {
            std.debug.print("❌ Failed to set log mode: errno={d}\n", .{-result});
            return error.MapUpdateFailed;
        }

        const mode_str = if (log_all) "LOG ALL executions" else "LOG BLOCKS ONLY";
        std.debug.print("⚙️  Logging mode: {s}\n", .{mode_str});
    }

    /// Add a command to the blacklist
    /// Add a command to the blacklist with emoji sanitization
    /// DEFENSE: Detects "Metaphysical Smuggling" - malicious emoji with hidden payloads
    pub fn addBlacklistEntry(self: *Inquisitor, index: u32, pattern: []const u8, exact_match: bool) !void {
        if (index >= MAX_BLACKLIST_ENTRIES) {
            return error.IndexOutOfBounds;
        }

        if (pattern.len >= MAX_PATTERN_LEN) {
            return error.PatternTooLong;
        }

        // CRITICAL: Scan pattern for emoji steganography/smuggling
        const anomalies = try emoji_sanitizer.scanText(self.allocator, pattern);
        defer self.allocator.free(anomalies);

        // Log any suspicious emoji detected
        var threats_detected: usize = 0;
        for (anomalies) |info| {
            switch (info.result) {
                .oversized => {
                    std.debug.print("🚨 METAPHYSICAL SMUGGLING DETECTED in blacklist pattern!\n", .{});
                    std.debug.print("   Pattern: '{s}'\n", .{pattern});
                    std.debug.print("   Emoji at offset {d}: Expected {d} bytes, found {d} bytes\n", .{
                        info.offset,
                        info.expected_bytes,
                        info.actual_bytes,
                    });
                    std.debug.print("   Codepoint: U+{X:0>4}\n", .{info.codepoint});
                    std.debug.print("   Hidden payload: {d} extra bytes (potential shellcode/data)\n", .{
                        info.actual_bytes - info.expected_bytes,
                    });
                    threats_detected += 1;
                },
                .zwc_smuggling => {
                    std.debug.print("🚨 ZERO-WIDTH CHARACTER SMUGGLING DETECTED in blacklist pattern!\n", .{});
                    std.debug.print("   Pattern: '{s}'\n", .{pattern});
                    std.debug.print("   Attack Type: Dispersed payload (unicode-injector --disperse)\n", .{});
                    std.debug.print("   Zero-width characters: {d}\n", .{info.zwc_count});
                    std.debug.print("   ZWC density: {d:.1}% (threshold: 10%)\n", .{info.zwc_density * 100.0});
                    std.debug.print("   Total bytes: {d}\n", .{info.actual_bytes});
                    std.debug.print("   Threat: Hidden payload in U+200B/U+200C steganography\n", .{});
                    threats_detected += 1;
                },
                .undersized => {
                    std.debug.print("⚠️  Malformed emoji in blacklist pattern\n", .{});
                    std.debug.print("   Pattern: '{s}' (offset {d})\n", .{ pattern, info.offset });
                    std.debug.print("   Expected {d} bytes, found {d} bytes (truncated)\n", .{
                        info.expected_bytes,
                        info.actual_bytes,
                    });
                },
                .valid, .not_emoji => {},
            }
        }

        if (threats_detected > 0) {
            std.debug.print("🛡️  BLOCKING malicious blacklist entry (contains {d} threats)\n", .{threats_detected});
            return error.MaliciousPattern;
        }

        // Pattern is clean - add to BPF map
        var entry = std.mem.zeroes(BlacklistEntry);
        @memcpy(entry.pattern[0..pattern.len], pattern);
        entry.exact_match = if (exact_match) 1 else 0;
        entry.enabled = 1;
        entry.reserved = 0;

        const result = c.bpf_map_update_elem(self.blacklist_map_fd, &index, &entry, c.BPF_ANY);
        if (result != 0) {
            std.debug.print("❌ Failed to add blacklist entry: errno={d}\n", .{-result});
            return error.MapUpdateFailed;
        }

        const match_type = if (exact_match) "exact" else "substring";
        std.debug.print("🚫 Blacklist[{d}]: '{s}' ({s} match) ✓ emoji-sanitized\n", .{ index, pattern, match_type });
    }

    /// Remove a command from the blacklist
    pub fn removeBlacklistEntry(self: *Inquisitor, index: u32) !void {
        if (index >= MAX_BLACKLIST_ENTRIES) {
            return error.IndexOutOfBounds;
        }

        var entry = std.mem.zeroes(BlacklistEntry);
        entry.enabled = 0;

        const result = c.bpf_map_update_elem(self.blacklist_map_fd, &index, &entry, c.BPF_ANY);
        if (result != 0) {
            std.debug.print("❌ Failed to remove blacklist entry: errno={d}\n", .{-result});
            return error.MapUpdateFailed;
        }

        std.debug.print("✓ Removed blacklist entry {d}\n", .{index});
    }

    /// Load default sovereign command blacklist
    pub fn loadDefaultBlacklist(self: *Inquisitor) !void {
        std.debug.print("📜 Loading Sovereign Command Blacklist...\n", .{});

        // Test configuration: harmless test target for kill-chain validation
        const test_commands = [_]struct { pattern: []const u8, exact: bool }{
            .{ .pattern = "test-target", .exact = true },
        };

        var index: u32 = 0;
        for (test_commands) |cmd| {
            try self.addBlacklistEntry(index, cmd.pattern, cmd.exact);
            index += 1;
        }

        std.debug.print("✓ Loaded {d} blacklist entries\n", .{test_commands.len});
    }

    /// Load production sovereign command blacklist (dangerous commands)
    pub fn loadProductionBlacklist(self: *Inquisitor) !void {
        std.debug.print("📜 Loading Production Sovereign Command Blacklist...\n", .{});

        // Dangerous commands that should never execute (for production use)
        const dangerous_commands = [_]struct { pattern: []const u8, exact: bool }{
            // Disk wipers
            .{ .pattern = "dd", .exact = false },
            .{ .pattern = "mkfs", .exact = false },
            .{ .pattern = "fdisk", .exact = false },
            .{ .pattern = "shred", .exact = false },
        };

        var index: u32 = 0;
        for (dangerous_commands) |cmd| {
            if (index >= MAX_BLACKLIST_ENTRIES) break;
            try self.addBlacklistEntry(index, cmd.pattern, cmd.exact);
            index += 1;
        }

        std.debug.print("✓ Loaded {d} blacklist entries\n", .{dangerous_commands.len});
    }

    /// Cleanup
    pub fn deinit(self: *Inquisitor) void {
        if (self.link) |link| {
            _ = c.bpf_link__destroy(link);
        }
        if (self.obj) |obj| {
            _ = c.bpf_object__close(obj);
        }
        std.debug.print("✓ Inquisitor deactivated\n", .{});
    }
};

/// Ring buffer event handler callback
fn handleExecEvent(ctx: ?*anyopaque, data: ?*anyopaque, size: c_ulong) callconv(.c) c_int {
    _ = ctx;
    _ = size;

    if (data == null) return 0;

    const event: *ExecEvent = @ptrCast(@alignCast(data));

    const filename = std.mem.sliceTo(&event.filename, 0);
    const comm = std.mem.sliceTo(&event.comm, 0);

    if (event.blocked == 1) {
        std.debug.print("🛡️  BLOCKED: pid={d} uid={d} command='{s}' (matched: {s})\n", .{
            event.pid,
            event.uid,
            comm,
            filename,
        });
    } else {
        std.debug.print("✓ ALLOWED: pid={d} uid={d} command='{s}'\n", .{
            event.pid,
            event.uid,
            comm,
        });
    }

    return 0;
}

/// Consume events from the ring buffer
pub fn consumeEvents(inquisitor: *Inquisitor, duration_seconds: u32) !void {
    std.debug.print("👁️  Monitoring exec events for {d} seconds...\n", .{duration_seconds});

    const ring_buffer = c.ring_buffer__new(inquisitor.events_fd, handleExecEvent, null, null) orelse {
        std.debug.print("❌ Failed to create ring buffer\n", .{});
        return error.RingBufferFailed;
    };
    defer c.ring_buffer__free(ring_buffer);

    const start_time = time_compat.timestamp();
    while (time_compat.timestamp() - start_time < duration_seconds) {
        const poll_result = c.ring_buffer__poll(ring_buffer, 100); // 100ms timeout
        if (poll_result < 0) {
            std.debug.print("❌ Ring buffer poll error: {d}\n", .{poll_result});
            return error.PollFailed;
        }
    }

    std.debug.print("✓ Event monitoring complete\n", .{});
}
