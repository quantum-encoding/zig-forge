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
// oracle-advanced.zig - The All-Seeing Eye: Multi-Hook Defense Grid Controller
//
// THE DOCTRINE: Omniscient observation across all critical kernel interactions
// THE IMPACT: Distributed, redundant web of tripwires vs single point failure
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
const MAX_BLACKLIST_ENTRIES = 32;
const MAX_FILENAME_LEN = 256;

/// Compute FNV-1a hash of a pattern for fast matching in eBPF
fn computePatternHash(pattern: []const u8) u32 {
    // FNV-1a 32-bit hash — deterministic, fast, good distribution
    var hash: u32 = 0x811c9dc5; // FNV offset basis for 32-bit
    for (pattern) |byte| {
        hash ^= @as(u32, byte);
        hash *%= 0x01000193; // FNV prime for 32-bit
    }
    return hash;
}

/// Event Types - The Oracle's Vision Spectrum
const EventType = enum(u32) {
    EXECUTION = 0x01,    // Program execution
    FILE_ACCESS = 0x02,  // File open/read/write
    PROC_CREATE = 0x03,  // Process creation
    NETWORK = 0x04,      // Network connections
    MEMORY = 0x05,       // Memory mapping
};

/// Sovereign Codex Entry (must match eBPF side)
const SovereignCodexEntry = extern struct {
    pattern: [MAX_PATTERN_LEN]u8,
    match_type: u8,      // 0=exact, 1=substring, 2=hash, 3=path
    severity: u8,        // 0=info, 1=warning, 2=critical
    enabled: u8,
    reserved: u8,
    hash: u32,           // Truncated SHA-256
    flags: u16,          // Case-insensitive, recursive, etc.
};

/// Unified Event Structure (must match eBPF side)
const OracleEvent = extern struct {
    event_type: u32,
    pid: u32,
    uid: u32,
    gid: u32,
    blocked: u32,
    timestamp: u64,
    target: [MAX_FILENAME_LEN]u8,
    comm: [16]u8,
    parent_comm: [16]u8,
};

/// The All-Seeing Eye - Advanced Oracle Manager
pub const OracleAdvanced = struct {
    obj: ?*c.bpf_object,
    links: [3]?*c.bpf_link,  // Multiple hooks
    sovereign_codex_fd: i32,
    oracle_events_fd: i32,
    oracle_config_fd: i32,
    process_chain_fd: i32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !OracleAdvanced {
        return OracleAdvanced{
            .obj = null,
            .links = .{ null, null, null },
            .sovereign_codex_fd = -1,
            .oracle_events_fd = -1,
            .oracle_config_fd = -1,
            .process_chain_fd = -1,
            .allocator = allocator,
        };
    }

    /// Load and attach the All-Seeing Eye eBPF program
    pub fn load(self: *OracleAdvanced, obj_path: []const u8) !void {
        std.debug.print("👁️  THE ALL-SEEING EYE - Forging Multi-Hook Defense Grid\n", .{});
        std.debug.print("   Loading from: {s}\n", .{obj_path});

        // Convert path to null-terminated C string
        const path_z = try self.allocator.dupeZ(u8, obj_path);
        defer self.allocator.free(path_z);

        // Open eBPF object
        self.obj = c.bpf_object__open(path_z) orelse {
            std.debug.print("❌ Failed to open eBPF object: {s}\n", .{obj_path});
            return error.OpenFailed;
        };
        errdefer _ = c.bpf_object__close(self.obj);

        // Load eBPF program into kernel
        const load_result = c.bpf_object__load(self.obj);
        if (load_result != 0) {
            std.debug.print("❌ Failed to load eBPF object: errno={d}\n", .{-load_result});
            return error.LoadFailed;
        }

        std.debug.print("✓ Oracle eBPF program loaded into kernel\n", .{});

        // Find BPF maps
        const sovereign_codex_map = c.bpf_object__find_map_by_name(self.obj, "sovereign_codex") orelse {
            std.debug.print("❌ Failed to find sovereign_codex map\n", .{});
            return error.MapNotFound;
        };

        const oracle_events_map = c.bpf_object__find_map_by_name(self.obj, "oracle_events") orelse {
            std.debug.print("❌ Failed to find oracle_events map\n", .{});
            return error.MapNotFound;
        };

        const oracle_config_map = c.bpf_object__find_map_by_name(self.obj, "oracle_config") orelse {
            std.debug.print("❌ Failed to find oracle_config map\n", .{});
            return error.MapNotFound;
        };

        const process_chain_map = c.bpf_object__find_map_by_name(self.obj, "process_chain_map") orelse {
            std.debug.print("❌ Failed to find process_chain_map\n", .{});
            return error.MapNotFound;
        };

        // Get file descriptors
        self.sovereign_codex_fd = c.bpf_map__fd(sovereign_codex_map);
        self.oracle_events_fd = c.bpf_map__fd(oracle_events_map);
        self.oracle_config_fd = c.bpf_map__fd(oracle_config_map);
        self.process_chain_fd = c.bpf_map__fd(process_chain_map);

        if (self.sovereign_codex_fd < 0 or self.oracle_events_fd < 0 or
            self.oracle_config_fd < 0 or self.process_chain_fd < 0) {
            std.debug.print("❌ Failed to get map file descriptors\n", .{});
            return error.MapFdFailed;
        }

        std.debug.print("✓ Found BPF maps: sovereign_codex={d}, events={d}, config={d}, process_chain={d}\n", .{
            self.sovereign_codex_fd,
            self.oracle_events_fd,
            self.oracle_config_fd,
            self.process_chain_fd,
        });

        // Attach multiple LSM hooks
        try self.attachHook("oracle_execution_hook", 0);    // bprm_check_security
        try self.attachHook("oracle_file_open_hook", 1);    // file_open
        try self.attachHook("oracle_task_alloc_hook", 2);   // task_alloc

        std.debug.print("👁️  THE ALL-SEEING EYE IS NOW WATCHING:\n", .{});
        std.debug.print("   • Program execution (bprm_check_security)\n", .{});
        std.debug.print("   • File access monitoring (file_open)\n", .{});
        std.debug.print("   • Process creation tracking (task_alloc)\n", .{});
        std.debug.print("   • Multi-hook defense grid ACTIVE\n", .{});
    }

    /// Attach individual LSM hook
    fn attachHook(self: *OracleAdvanced, prog_name: []const u8, link_index: usize) !void {
        const prog_name_z = try self.allocator.dupeZ(u8, prog_name);
        defer self.allocator.free(prog_name_z);

        const prog = c.bpf_object__find_program_by_name(self.obj, prog_name_z) orelse {
            std.debug.print("❌ Failed to find LSM program '{s}'\n", .{prog_name});
            return error.ProgramNotFound;
        };

        _ = c.bpf_program__set_autoload(prog, true);

        std.debug.print("🔗 Attaching LSM hook: {s}...\n", .{prog_name});
        self.links[link_index] = c.bpf_program__attach(prog);

        if (self.links[link_index] == null) {
            const errno = std.c._errno().*;
            std.debug.print("❌ Failed to attach LSM program '{s}' (errno={d})\n", .{ prog_name, errno });
            return error.AttachFailed;
        }

        std.debug.print("✓ LSM hook attached: {s}\n", .{prog_name});
    }

    /// Set enforcement mode (1 = block, 0 = monitor only)
    pub fn setEnforcementMode(self: *OracleAdvanced, enforce: bool) !void {
        const key: u32 = 0;
        const value: u32 = if (enforce) 1 else 0;

        const result = c.bpf_map_update_elem(self.oracle_config_fd, &key, &value, c.BPF_ANY);
        if (result != 0) {
            std.debug.print("❌ Failed to set enforcement mode: errno={d}\n", .{-result});
            return error.MapUpdateFailed;
        }

        const mode_str = if (enforce) "ENFORCE (block mode)" else "MONITOR (log only)";
        std.debug.print("⚙️  Enforcement mode: {s}\n", .{mode_str});
    }

    /// Set logging mode (1 = log all, 0 = log threats only)
    pub fn setLoggingMode(self: *OracleAdvanced, log_all: bool) !void {
        const key: u32 = 1;
        const value: u32 = if (log_all) 1 else 0;

        const result = c.bpf_map_update_elem(self.oracle_config_fd, &key, &value, c.BPF_ANY);
        if (result != 0) {
            std.debug.print("❌ Failed to set logging mode: errno={d}\n", .{-result});
            return error.MapUpdateFailed;
        }

        const mode_str = if (log_all) "LOG ALL events" else "LOG THREATS ONLY";
        std.debug.print("⚙️  Logging mode: {s}\n", .{mode_str});
    }

    /// Add entry to Sovereign Codex with emoji sanitization
    pub fn addSovereignCodexEntry(self: *OracleAdvanced, index: u32, pattern: []const u8,
                                 match_type: u8, severity: u8) !void {
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
                    std.debug.print("🚨 METAPHYSICAL SMUGGLING DETECTED in Sovereign Codex!\n", .{});
                    std.debug.print("   Pattern: '{s}'\n", .{pattern});
                    std.debug.print("   Emoji at offset {d}: Expected {d} bytes, found {d} bytes\n", .{
                        info.offset,
                        info.expected_bytes,
                        info.actual_bytes,
                    });
                    std.debug.print("   Hidden payload: {d} extra bytes\n", .{
                        info.actual_bytes - info.expected_bytes,
                    });
                    threats_detected += 1;
                },
                .zwc_smuggling => {
                    std.debug.print("🚨 ZERO-WIDTH CHARACTER SMUGGLING DETECTED!\n", .{});
                    std.debug.print("   Pattern: '{s}'\n", .{pattern});
                    std.debug.print("   Zero-width characters: {d}\n", .{info.zwc_count});
                    threats_detected += 1;
                },
                .undersized, .valid, .not_emoji => {},
            }
        }

        if (threats_detected > 0) {
            std.debug.print("🛡️  BLOCKING malicious Sovereign Codex entry (contains {d} threats)\n", .{threats_detected});
            return error.MaliciousPattern;
        }

        // Pattern is clean - add to Sovereign Codex
        var entry = std.mem.zeroes(SovereignCodexEntry);
        @memcpy(entry.pattern[0..pattern.len], pattern);
        entry.match_type = match_type;
        entry.severity = severity;
        entry.enabled = 1;
        entry.reserved = 0;
        entry.hash = computePatternHash(pattern);
        entry.flags = 0;

        const result = c.bpf_map_update_elem(self.sovereign_codex_fd, &index, &entry, c.BPF_ANY);
        if (result != 0) {
            std.debug.print("❌ Failed to add Sovereign Codex entry: errno={d}\n", .{-result});
            return error.MapUpdateFailed;
        }

        const match_types = [_][]const u8{ "exact", "substring", "hash", "path" };
        const severities = [_][]const u8{ "info", "warning", "critical" };

        std.debug.print("📜 Sovereign Codex[{d}]: '{s}' ({s} match, {s} severity) ✓ emoji-sanitized\n", .{
            index,
            pattern,
            match_types[entry.match_type],
            severities[entry.severity]
        });
    }

    /// Load default Sovereign Codex (dangerous commands + sensitive files)
    pub fn loadDefaultSovereignCodex(self: *OracleAdvanced) !void {
        std.debug.print("📜 Loading Default Sovereign Codex...\n", .{});

        const default_entries = [_]struct {
            pattern: []const u8,
            match_type: u8,
            severity: u8
        }{
            // Dangerous commands (critical severity)
            .{ .pattern = "test-target", .match_type = 0, .severity = 2 },
            .{ .pattern = "dd", .match_type = 1, .severity = 2 },
            .{ .pattern = "mkfs", .match_type = 1, .severity = 2 },
            .{ .pattern = "shred", .match_type = 1, .severity = 2 },
            .{ .pattern = "fdisk", .match_type = 1, .severity = 2 },

            // Sensitive files (warning severity)
            .{ .pattern = "/etc/shadow", .match_type = 0, .severity = 1 },
            .{ .pattern = "/etc/passwd", .match_type = 0, .severity = 1 },
            .{ .pattern = "/etc/sudoers", .match_type = 0, .severity = 1 },
        };

        var index: u32 = 0;
        for (default_entries) |entry| {
            if (index >= MAX_BLACKLIST_ENTRIES) break;
            try self.addSovereignCodexEntry(index, entry.pattern, entry.match_type, entry.severity);
            index += 1;
        }

        std.debug.print("✓ Loaded {d} Sovereign Codex entries\n", .{default_entries.len});
    }

    /// Cleanup
    pub fn deinit(self: *OracleAdvanced) void {
        for (self.links) |link| {
            if (link) |l| {
                _ = c.bpf_link__destroy(l);
            }
        }
        if (self.obj) |obj| {
            _ = c.bpf_object__close(obj);
        }
        std.debug.print("✓ The All-Seeing Eye stands down\n", .{});
    }
};

/// Ring buffer event handler callback
fn handleOracleEvent(ctx: ?*anyopaque, data: ?*anyopaque, size: c_ulong) callconv(.c) c_int {
    _ = ctx;
    _ = size;

    if (data == null) return 0;

    const event: *OracleEvent = @ptrCast(@alignCast(data));

    const target = std.mem.sliceTo(&event.target, 0);
    const comm = std.mem.sliceTo(&event.comm, 0);
    const parent_comm = std.mem.sliceTo(&event.parent_comm, 0);

    const event_types = [_][]const u8{ "UNKNOWN", "EXECUTION", "FILE_ACCESS", "PROC_CREATE", "NETWORK", "MEMORY" };
    const event_type_str = if (event.event_type < event_types.len)
        event_types[event.event_type] else "UNKNOWN";

    if (event.blocked == 1) {
        std.debug.print("🛡️  BLOCKED [{s}]: pid={d} command='{s}' target='{s}' parent='{s}'\n", .{
            event_type_str,
            event.pid,
            comm,
            target,
            parent_comm,
        });
    } else {
        std.debug.print("👁️  DETECTED [{s}]: pid={d} command='{s}' target='{s}' parent='{s}'\n", .{
            event_type_str,
            event.pid,
            comm,
            target,
            parent_comm,
        });
    }

    return 0;
}

/// Consume events from the ring buffer
pub fn consumeOracleEvents(oracle: *OracleAdvanced, duration_seconds: u32) !void {
    std.debug.print("👁️  The All-Seeing Eye monitoring all events for {d} seconds...\n", .{duration_seconds});

    const ring_buffer = c.ring_buffer__new(oracle.oracle_events_fd, handleOracleEvent, null, null) orelse {
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

    std.debug.print("✓ Oracle event monitoring complete\n", .{});
}
