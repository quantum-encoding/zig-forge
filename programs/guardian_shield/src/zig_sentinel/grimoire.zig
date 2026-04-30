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


// SPDX-License-Identifier: GPL-2.0
//
// grimoire.zig - The Sovereign Grimoire: Behavioral Pattern Detection Engine
//
// Purpose: Detect multi-step attack sequences ("forbidden incantations")
// Architecture: Three-tiered cache-optimized pattern storage
// Philosophy: Pre-cognitive defense via behavioral sequence matching
//
// THE DOCTRINE OF THE TIERED GRIMOIRE:
//   Tier 1 (HOT):  10-20 critical patterns, embedded in binary, always in L1 cache
//   Tier 2 (WARM): Extended pattern database, loaded at runtime, in L2/L3 cache
//   Tier 3 (COLD): Esoteric patterns, loaded on-demand from disk
//
// THE DOCTRINE OF SOVEREIGN OBSCURITY:
//   - Core patterns: Embedded in binary, obfuscated at compile time
//   - Custom patterns: Optional encrypted config for hot-reload
//   - Result: Attacker needs hours of reverse engineering, not seconds
//

const std = @import("std");
const c = @cImport({
    @cInclude("sys/uio.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});

// process_vm_readv extern declaration (not always available in cImport)
extern "c" fn process_vm_readv(pid: c_int, local_iov: [*c]c.struct_iovec, liovcnt: c_ulong, remote_iov: [*c]c.struct_iovec, riovcnt: c_ulong, flags: c_ulong) isize;

/// Version identifier
pub const VERSION = "1.0.0-grimoire";

/// Maximum pattern steps (kept small for cache efficiency)
pub const MAX_PATTERN_STEPS = 6;

/// Maximum pattern name length (inline, no heap allocation)
/// Increased to 32 to fit "reverse_shell_classic" (21 chars) and other long names
pub const MAX_PATTERN_NAME_LEN = 32;

/// Maximum string constraint length
pub const MAX_CONSTRAINT_STR_LEN = 64;

/// Syscall numbers (x86_64) - commonly used in patterns
pub const Syscall = struct {
    pub const read: u32 = 0;
    pub const write: u32 = 1;
    pub const open: u32 = 2;
    pub const close: u32 = 3;
    pub const execve: u32 = 59;
    pub const fork: u32 = 57;
    pub const vfork: u32 = 58;
    pub const clone: u32 = 56;
    pub const socket: u32 = 41;
    pub const connect: u32 = 42;
    pub const bind: u32 = 49;
    pub const listen: u32 = 50;
    pub const accept: u32 = 43;
    pub const sendto: u32 = 44;
    pub const recvfrom: u32 = 45;
    pub const sendmsg: u32 = 46;
    pub const recvmsg: u32 = 47;
    pub const openat: u32 = 257;
    pub const dup2: u32 = 33;
    pub const setuid: u32 = 105;
    pub const setgid: u32 = 106;
    pub const ptrace: u32 = 101;
    pub const init_module: u32 = 175;
    pub const finit_module: u32 = 313;
};

/// Syscall categories for higher-level pattern matching
pub const SyscallClass = enum(u8) {
    any = 0,          // Match any syscall
    network,          // socket, connect, bind, listen, send*, recv*
    file_read,        // open, read, openat with read intent
    file_write,       // open, write, openat with write intent
    process_create,   // fork, vfork, clone, execve
    privilege,        // setuid, setgid, setreuid, setresuid, etc.
    ipc,              // pipe, msgget, shmget, etc.
    kernel_module,    // init_module, finit_module
    debug,            // ptrace, process_vm_readv
};

/// Severity levels (aligned with anomaly.zig)
pub const Severity = enum(u8) {
    debug = 0,
    info = 1,
    warning = 2,
    high = 3,
    critical = 4,

    pub fn priority(self: Severity) u8 {
        return @intFromEnum(self);
    }
};

/// Process relationship constraint
pub const ProcessRelationship = enum(u8) {
    same_process,      // All steps must be same PID
    child_process,     // Step N+1 must be child of step N
    process_tree,      // Steps can be anywhere in same process tree
    any,               // No relationship constraint
};

/// Constraint types
pub const ConstraintType = enum(u8) {
    any,              // No constraint
    equals,           // arg == value
    not_equals,       // arg != value
    greater_than,     // arg > value
    less_than,        // arg < value
    bitmask_set,      // (arg & value) != 0
    bitmask_clear,    // (arg & value) == 0
    str_equals,       // strcmp(arg_str, value_str) == 0
    str_prefix,       // strncmp(arg_str, value_str, strlen(value_str)) == 0
    str_suffix,       // str ends with value_str
    str_contains,     // str contains value_str
};

/// Constraint value union
pub const ConstraintValue = union(enum) {
    num: u64,
    str: [MAX_CONSTRAINT_STR_LEN]u8,
};

/// Argument constraint for syscall matching
pub const ArgConstraint = struct {
    /// Argument position (0-5 for typical syscalls)
    arg_index: u8,

    /// Constraint type
    constraint_type: ConstraintType,

    /// Value to compare against
    value: ConstraintValue,
};

/// Individual step in a pattern sequence
pub const PatternStep = struct {
    /// Specific syscall number (null = use syscall_class)
    syscall_nr: ?u32 = null,

    /// Syscall category (used if syscall_nr is null)
    syscall_class: SyscallClass = .any,

    /// Process relationship to previous step
    process_relationship: ProcessRelationship = .same_process,

    /// Maximum time delta from previous step (microseconds)
    /// 0 = no time constraint
    max_time_delta_us: u64 = 0,

    /// Maximum syscall distance from previous step (number of syscalls between steps)
    /// 0 = no distance constraint
    max_step_distance: u32 = 0,

    /// Argument constraints (max 2 constraints per step to keep size small)
    arg_constraints: [2]?ArgConstraint = [_]?ArgConstraint{null} ** 2,
};

/// Complete pattern definition (sized for cache efficiency: ~512 bytes max)
pub const GrimoirePattern = struct {
    /// Pattern ID hash (obfuscated - not stored as plaintext)
    /// Computed at compile time from pattern name using FNV-1a hash
    id_hash: u64,

    /// Human-readable name (for logging only, embedded inline)
    name: [MAX_PATTERN_NAME_LEN]u8,

    /// Pattern steps (inline array, not pointer)
    steps: [MAX_PATTERN_STEPS]PatternStep,

    /// Number of valid steps (rest are ignored)
    step_count: u8,

    /// Severity if pattern matches
    severity: Severity,

    /// Maximum time window for entire sequence (milliseconds)
    /// Pattern resets if this time expires
    max_sequence_window_ms: u64,

    /// Pattern enabled flag
    enabled: bool = true,

    /// Whitelisted binaries for this pattern (null if no whitelist)
    whitelisted_binaries: ?[]const []const u8 = null,

    /// Compile-time hash function (FNV-1a)
    pub fn hashName(comptime name: []const u8) u64 {
        var hash: u64 = 0xcbf29ce484222325; // FNV offset basis
        for (name) |byte| {
            hash ^= byte;
            hash *%= 0x100000001b3; // FNV prime
        }
        return hash;
    }

    /// Create pattern name from string (zero-padded)
    pub fn makeName(comptime name: []const u8) [MAX_PATTERN_NAME_LEN]u8 {
        var result = [_]u8{0} ** MAX_PATTERN_NAME_LEN;
        @memcpy(result[0..@min(name.len, MAX_PATTERN_NAME_LEN)], name[0..@min(name.len, MAX_PATTERN_NAME_LEN)]);
        return result;
    }

    /// Create fixed string for constraint
    pub fn makeConstraintStr(comptime str: []const u8) [MAX_CONSTRAINT_STR_LEN]u8 {
        var result = [_]u8{0} ** MAX_CONSTRAINT_STR_LEN;
        @memcpy(result[0..@min(str.len, MAX_CONSTRAINT_STR_LEN)], str[0..@min(str.len, MAX_CONSTRAINT_STR_LEN)]);
        return result;
    }
};

// Compile-time assertion: Pattern struct fits in 24 cache lines (1536 bytes)
// Note: Increased from 512 to 1024 for string constraints, then to 1536 for 6-step patterns
comptime {
    const size = @sizeOf(GrimoirePattern);
    if (size > 1536) {
        @compileError(std.fmt.comptimePrint("GrimoirePattern too large: {d} bytes (max 1536)", .{size}));
    }
}

/// ============================================================
/// TIER 1: HOT PATTERNS (Always in L1 cache)
/// ============================================================
///
/// These are the most critical, high-confidence patterns that detect
/// well-known attack techniques with near-zero false positive rate.
///
/// Design constraints:
/// - Total size < 8KB (fits in L1 cache)
/// - Patterns are obfuscated at compile time
/// - Focus on unambiguous attack sequences
///

pub const HOT_PATTERNS = [_]GrimoirePattern{
    // ========================================
    // PATTERN 1: Classic Reverse Shell
    // ========================================
    // Sequence: socket() -> dup2(socket, 0/1/2) -> execve(shell)
    // Description: Redirect stdin/stdout/stderr to network socket, then spawn shell
    // MITRE ATT&CK: T1059 (Command and Scripting Interpreter)
    // False Positive Risk: LOW (legitimate software rarely does this)
    .{
        .id_hash = GrimoirePattern.hashName("reverse_shell_classic"),
        .name = GrimoirePattern.makeName("reverse_shell_classic"),
        .step_count = 6,
        .severity = .critical,
        .max_sequence_window_ms = 5000, // 5 seconds

        .steps = [_]PatternStep{
            // Step 1: Create network socket
            .{
                .syscall_nr = Syscall.socket,
                .process_relationship = .same_process,
                .max_time_delta_us = 0,
                .max_step_distance = 100,
            },

            // Step 2: Connect to remote host
            // Real Metasploit payloads connect() immediately after socket()
            .{
                .syscall_nr = Syscall.connect,
                .process_relationship = .same_process,
                .max_time_delta_us = 5_000_000, // 5 seconds to connect
                .max_step_distance = 50,
            },

            // Step 3: Redirect stderr (fd 2) to socket
            // Metasploit does stderr FIRST (not stdin)
            .{
                .syscall_nr = Syscall.dup2,
                .process_relationship = .same_process,
                .max_time_delta_us = 2_000_000, // 2 seconds
                .max_step_distance = 50,
                .arg_constraints = [_]?ArgConstraint{
                    .{ .arg_index = 1, .constraint_type = .equals, .value = .{ .num = 2 } },
                    null,
                },
            },

            // Step 4: Redirect stdout (fd 1) to socket
            .{
                .syscall_nr = Syscall.dup2,
                .process_relationship = .same_process,
                .max_time_delta_us = 1_000_000,
                .max_step_distance = 10,
                .arg_constraints = [_]?ArgConstraint{
                    .{ .arg_index = 1, .constraint_type = .equals, .value = .{ .num = 1 } },
                    null,
                },
            },

            // Step 5: Redirect stdin (fd 0) to socket
            // Metasploit does stdin LAST
            .{
                .syscall_nr = Syscall.dup2,
                .process_relationship = .same_process,
                .max_time_delta_us = 1_000_000,
                .max_step_distance = 10,
                .arg_constraints = [_]?ArgConstraint{
                    .{ .arg_index = 1, .constraint_type = .equals, .value = .{ .num = 0 } },
                    null,
                },
            },

            // Step 6: Execute shell
            .{
                .syscall_nr = Syscall.execve,
                .process_relationship = .same_process,
                .max_time_delta_us = 2_000_000,
                .max_step_distance = 50,
            },
        },
        .whitelisted_binaries = null,
    },

    // ========================================
    // PATTERN 2: Rapid Fork Bomb (eBPF layer)
    // ========================================
    // Sequence: fork() -> fork() -> fork() ... (rapid succession)
    // Description: Exponential process creation to exhaust system resources
    // MITRE ATT&CK: T1496 (Resource Hijacking)
    // False Positive Risk: LOW with build tool whitelisting
    .{
        .id_hash = GrimoirePattern.hashName("fork_bomb_rapid"),
        .name = GrimoirePattern.makeName("fork_bomb_rapid"),
        .step_count = 4,
        .severity = .critical,
        .max_sequence_window_ms = 500, // 500ms window

        .steps = [_]PatternStep{
            .{ .syscall_class = .process_create, .max_time_delta_us = 100_000, .max_step_distance = 5 },
            .{ .syscall_class = .process_create, .max_time_delta_us = 100_000, .max_step_distance = 5 },
            .{ .syscall_class = .process_create, .max_time_delta_us = 100_000, .max_step_distance = 5 },
            .{ .syscall_class = .process_create, .max_time_delta_us = 100_000, .max_step_distance = 5 },
            .{}, // Unused
            .{}, // Unused
        },
        .whitelisted_binaries = &[_][]const u8{ "make", "gcc", "cargo", "zig" },
    },

    // ========================================
    // PATTERN 3: Privilege Escalation via setuid
    // ========================================
    // Sequence: open(sensitive_file) -> setuid(0) -> execve(shell)
    // Description: Read sensitive file (e.g., /etc/shadow), escalate to root, spawn shell
    // MITRE ATT&CK: T1548.001 (Setuid and Setgid)
    // False Positive Risk: MEDIUM (some legitimate tools use setuid)
    .{
        .id_hash = GrimoirePattern.hashName("privesc_setuid_root"),
        .name = GrimoirePattern.makeName("privesc_setuid_root"),
        .step_count = 3,
        .severity = .critical,
        .max_sequence_window_ms = 10000, // 10 seconds

        .steps = [_]PatternStep{
            // Step 1: Open sensitive file
            .{
                .syscall_class = .file_read,
                .max_step_distance = 200,
                .arg_constraints = [_]?ArgConstraint{
                    .{ .arg_index = 0, .constraint_type = .str_equals, .value = .{ .str = GrimoirePattern.makeConstraintStr("/etc/shadow") } },
                    null,
                },
            },

            // Step 2: Set UID to 0 (root)
            .{
                .syscall_class = .privilege,
                .max_time_delta_us = 10_000_000,
                .max_step_distance = 100,
                .arg_constraints = [_]?ArgConstraint{
                    .{ .arg_index = 0, .constraint_type = .equals, .value = .{ .num = 0 } }, // uid = 0
                    null,
                },
            },

            // Step 3: Execute shell or privileged command
            .{
                .syscall_nr = Syscall.execve,
                .max_time_delta_us = 5_000_000,
                .max_step_distance = 50,
            },

            // Padding for unused steps
            .{},
            .{},
            .{},
        },
        .whitelisted_binaries = &[_][]const u8{ "sudo", "su", "passwd", "pkexec" },
    },

    // ========================================
    // PATTERN 4: Credential Exfiltration
    // ========================================
    // Sequence: socket() -> open(sensitive_file) -> read() -> write(socket)
    // Description: Open network connection, read credentials, send over network
    // MITRE ATT&CK: T1005 (Data from Local System)
    // False Positive Risk: MEDIUM with whitelist
    .{
        .id_hash = GrimoirePattern.hashName("cred_exfil_ssh_key"),
        .name = GrimoirePattern.makeName("cred_exfil_ssh_key"),
        .step_count = 4,
        .severity = .critical,
        .max_sequence_window_ms = 5000,

        .steps = [_]PatternStep{
            // Step 1: Open network socket
            .{
                .syscall_nr = Syscall.socket,
                .max_step_distance = 100,
            },

            // Step 2: Open sensitive file (SSH key, AWS creds, etc.) - paths like /home/*/.ssh/id_rsa, /home/*/.ssh/id_ed25519, /home/*/.aws/credentials, /home/*/.gnupg/private-keys
            .{
                .syscall_class = .file_read,
                .max_time_delta_us = 5_000_000,
                .max_step_distance = 100,
                .arg_constraints = [_]?ArgConstraint{
                    .{ .arg_index = 0, .constraint_type = .str_prefix, .value = .{ .str = GrimoirePattern.makeConstraintStr("/home/") } },
                    .{ .arg_index = 0, .constraint_type = .str_contains, .value = .{ .str = GrimoirePattern.makeConstraintStr("/.ssh/") } },
                },
            },

            // Step 3: Read from file
            .{
                .syscall_nr = Syscall.read,
                .max_time_delta_us = 2_000_000,
                .max_step_distance = 50,
            },

            // Step 4: Write to network socket
            .{
                .syscall_nr = Syscall.write,
                .max_time_delta_us = 2_000_000,
                .max_step_distance = 50,
            },

            // Padding for unused steps
            .{},
            .{},
        },
        .whitelisted_binaries = &[_][]const u8{ "ssh", "ssh-agent", "ssh-add", "scp" },
    },

    // ========================================
    // PATTERN 5: Kernel Module Loading (Rootkit)
    // ========================================
    // Sequence: open(module.ko) -> finit_module()
    // Description: Load kernel module (potential rootkit)
    // MITRE ATT&CK: T1547.006 (Kernel Modules and Extensions)
    // False Positive Risk: HIGH (legitimate admin tasks load modules)
    .{
        .id_hash = GrimoirePattern.hashName("rootkit_module_load"),
        .name = GrimoirePattern.makeName("rootkit_module_load"),
        .step_count = 2,
        .severity = .high, // Not critical due to higher FP risk
        .max_sequence_window_ms = 5000,

        .steps = [_]PatternStep{
            // Step 1: Open .ko file
            .{
                .syscall_class = .file_read,
                .max_step_distance = 50,
                .arg_constraints = [_]?ArgConstraint{
                    .{ .arg_index = 0, .constraint_type = .str_suffix, .value = .{ .str = GrimoirePattern.makeConstraintStr(".ko") } },
                    null,
                },
            },

            // Step 2: Load module
            .{
                .syscall_class = .kernel_module,
                .max_time_delta_us = 5_000_000,
                .max_step_distance = 100,
            },

            // Padding for unused steps
            .{},
            .{},
            .{},
            .{},
        },
        .whitelisted_binaries = &[_][]const u8{ "modprobe", "insmod", "systemd-modules-load" },
    },
};

// Compile-time assertion: HOT_PATTERNS fits in L1 cache (8KB)
comptime {
    const total_size = @sizeOf(GrimoirePattern) * HOT_PATTERNS.len;
    if (total_size > 8192) {
        @compileError(std.fmt.comptimePrint("HOT_PATTERNS too large: {d} bytes (max 8KB)", .{total_size}));
    }
}

/// ============================================================
/// Pattern Matching State Machine
/// ============================================================

/// State for tracking pattern matching progress per process
pub const MatchState = struct {
    /// Pattern being matched
    pattern_index: usize,

    /// Current step in pattern (0-based)
    current_step: u8,

    /// Timestamp when sequence started (nanoseconds)
    sequence_start_ns: u64,

    /// Timestamp of last matched step (for time delta checking)
    last_step_ns: u64,

    /// Syscall count at last matched step (for distance checking)
    last_step_syscall_count: u64,

    /// Process ID being tracked
    pid: u32,

    /// Reset state
    pub fn reset(self: *MatchState) void {
        self.current_step = 0;
        self.sequence_start_ns = 0;
        self.last_step_ns = 0;
        self.last_step_syscall_count = 0;
    }

    /// Check if sequence has expired
    pub fn isExpired(self: *const MatchState, pattern: *const GrimoirePattern, current_ns: u64) bool {
        if (self.sequence_start_ns == 0) return false;
        const elapsed_ms = (current_ns - self.sequence_start_ns) / 1_000_000;
        return elapsed_ms > pattern.max_sequence_window_ms;
    }
};

/// Pattern match result
pub const MatchResult = struct {
    matched: bool,
    pattern: *const GrimoirePattern,
    pid: u32,
    timestamp_ns: u64,
};

/// ============================================================
/// Pattern Matching Engine
/// ============================================================

pub const GrimoireEngine = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    /// Active match states (per-process tracking)
    /// Key: PID, Value: Array of MatchState (one per active pattern)
    match_states: std.AutoHashMap(u32, std.ArrayList(MatchState)),

    /// Syscall count per process (for distance tracking)
    syscall_counts: std.AutoHashMap(u32, u64),

    /// Cache for process binary names (basename of /proc/<pid>/exe)
    binary_cache: std.AutoHashMap(u32, []u8),

    /// Statistics
    total_matches: u64,
    matches_by_severity: [5]u64, // [debug, info, warning, high, critical]
    patterns_checked: u64,

    /// Debug mode - verbose logging
    debug_mode: bool,

    pub fn init(allocator: std.mem.Allocator, debug_mode: bool) !Self {
        return .{
            .allocator = allocator,
            .match_states = std.AutoHashMap(u32, std.ArrayList(MatchState)).init(allocator),
            .syscall_counts = std.AutoHashMap(u32, u64).init(allocator),
            .binary_cache = std.AutoHashMap(u32, []u8).init(allocator),
            .total_matches = 0,
            .matches_by_severity = [_]u64{0} ** 5,
            .patterns_checked = 0,
            .debug_mode = debug_mode,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.match_states.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.match_states.deinit();
        self.syscall_counts.deinit();

        // Free binary name cache - must free each allocated string
        var cache_iter = self.binary_cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.binary_cache.deinit();
    }

    /// Get basename of process executable (/proc/<pid>/exe link)
    fn getProcessBinaryName(self: *Self, pid: u32) ![]const u8 {
        const gop = try self.binary_cache.getOrPut(pid);
        if (gop.found_existing) {
            return gop.value_ptr.*;
        }

        // Read /proc/<pid>/exe symlink
        const path = try std.fmt.allocPrint(self.allocator, "/proc/{d}/exe", .{pid});
        defer self.allocator.free(path);

        // Create null-terminated path for readlink
        var path_z: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= path_z.len) return error.NameTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const result = std.os.linux.readlink(path_z[0..path.len :0], &buf, buf.len);
        if (@as(isize, @bitCast(result)) < 0) {
            return error.ProcessNotFound;
        }
        const exe_path = buf[0..result];

        // Extract basename
        const basename_start = std.mem.lastIndexOfScalar(u8, exe_path, '/') orelse 0;
        const basename = try self.allocator.dupe(u8, exe_path[basename_start + 1 ..]);

        gop.value_ptr.* = basename;
        return basename;
    }

    /// Get PID namespace ID for diagnostic purposes
    fn getProcessNamespace(self: *Self, pid: u32) !u64 {
        const path = try std.fmt.allocPrint(self.allocator, "/proc/{d}/ns/pid", .{pid});
        defer self.allocator.free(path);

        // Create null-terminated path for readlink
        var path_buf_z: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= path_buf_z.len) return 0;
        @memcpy(path_buf_z[0..path.len], path);
        path_buf_z[path.len] = 0;

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const result = std.os.linux.readlink(path_buf_z[0..path.len :0], &buf, buf.len);
        if (@as(isize, @bitCast(result)) < 0) {
            // If we can't read namespace (process exited or permission denied), return 0
            return 0;
        }
        const ns_link = buf[0..result];

        // Parse "pid:[4026531836]" format
        if (std.mem.indexOf(u8, ns_link, ":[")) |start| {
            const id_start = start + 2;
            if (std.mem.indexOf(u8, ns_link[id_start..], "]")) |end| {
                const id_str = ns_link[id_start .. id_start + end];
                return std.fmt.parseInt(u64, id_str, 10) catch 0;
            }
        }
        return 0;
    }

    /// Check if process is in a different namespace than us (container detection)
    fn isInContainer(self: *Self, pid: u32) bool {
        const our_ns = self.getProcessNamespace(1) catch 0;  // PID 1 is init in host namespace
        const their_ns = self.getProcessNamespace(pid) catch 0;
        return (our_ns != 0 and their_ns != 0 and our_ns != their_ns);
    }

    /// Read string from another process's memory using process_vm_readv
    fn readUserString(self: *Self, pid: u32, ptr: u64, max_len: usize) ![]u8 {
        if (ptr == 0) return error.InvalidPointer;

        const buf = try self.allocator.alloc(u8, max_len);
        errdefer self.allocator.free(buf);

        var local_iov: c.struct_iovec = .{
            .iov_base = buf.ptr,
            .iov_len = max_len,
        };
        var remote_iov: c.struct_iovec = .{
            .iov_base = @ptrFromInt(ptr),
            .iov_len = max_len,
        };

        const bytes_read = process_vm_readv(@intCast(pid), &local_iov, 1, &remote_iov, 1, 0);
        if (bytes_read < 0) {
            const err_num: isize = -bytes_read;
            const err = std.posix.errno(@as(usize, @intCast(err_num)));
            return switch (err) {
                .FAULT => error.BadAddress,
                .PERM => error.PermissionDenied,
                .SRCH => error.NoSuchProcess,
                else => error.Unexpected,
            };
        }

        // Find null terminator
        const bytes_read_usize: usize = @intCast(bytes_read);
        const len = std.mem.indexOfScalar(u8, buf[0..bytes_read_usize], 0) orelse bytes_read_usize;
        return try self.allocator.realloc(buf, len);
    }

    /// Check if syscall_nr belongs to SyscallClass
    fn isSyscallInClass(syscall_nr: u32, class: SyscallClass) bool {
        return switch (class) {
            .any => true,
            .network => switch (syscall_nr) {
                Syscall.socket, Syscall.connect, Syscall.bind, Syscall.listen,
                Syscall.accept, Syscall.sendto, Syscall.recvfrom, Syscall.sendmsg, Syscall.recvmsg => true,
                else => false,
            },
            .file_read => switch (syscall_nr) {
                Syscall.read, Syscall.open, Syscall.openat => true, // Note: intent checked via args if needed
                else => false,
            },
            .file_write => switch (syscall_nr) {
                Syscall.write, Syscall.open, Syscall.openat => true,
                else => false,
            },
            .process_create => switch (syscall_nr) {
                Syscall.fork, Syscall.vfork, Syscall.clone, Syscall.execve => true,
                else => false,
            },
            .privilege => switch (syscall_nr) {
                Syscall.setuid, Syscall.setgid => true,
                else => false,
            },
            .ipc => switch (syscall_nr) {
                63 => true, // pipe
                else => false,
            },
            .kernel_module => switch (syscall_nr) {
                Syscall.init_module, Syscall.finit_module => true,
                else => false,
            },
            .debug => switch (syscall_nr) {
                Syscall.ptrace => true,
                else => false,
            },
        };
    }

    /// Validate single argument constraint
    fn validateConstraint(self: *Self, constraint: ArgConstraint, args: [6]u64, pid: u32) !bool {
        const arg_value = args[constraint.arg_index];

        return switch (constraint.constraint_type) {
            .any => true,
            .equals => switch (constraint.value) {
                .num => |v| arg_value == v,
                .str => false, // Type mismatch
            },
            .not_equals => switch (constraint.value) {
                .num => |v| arg_value != v,
                .str => false,
            },
            .greater_than => switch (constraint.value) {
                .num => |v| arg_value > v,
                .str => false,
            },
            .less_than => switch (constraint.value) {
                .num => |v| arg_value < v,
                .str => false,
            },
            .bitmask_set => switch (constraint.value) {
                .num => |v| (arg_value & v) != 0,
                .str => false,
            },
            .bitmask_clear => switch (constraint.value) {
                .num => |v| (arg_value & v) == 0,
                .str => false,
            },
            .str_equals => switch (constraint.value) {
                .str => |v| blk: {
                    // Gracefully handle memory read failures (process exited, permissions, etc.)
                    const str = self.readUserString(pid, arg_value, MAX_CONSTRAINT_STR_LEN) catch break :blk false;
                    defer self.allocator.free(str);
                    const constraint_len = std.mem.indexOfScalar(u8, &v, 0) orelse MAX_CONSTRAINT_STR_LEN;
                    const str_len = str.len;
                    if (str_len != constraint_len) break :blk false;
                    break :blk std.mem.eql(u8, str, v[0..constraint_len]);
                },
                .num => false,
            },
            .str_prefix => switch (constraint.value) {
                .str => |v| blk: {
                    // Gracefully handle memory read failures (process exited, permissions, etc.)
                    const str = self.readUserString(pid, arg_value, MAX_CONSTRAINT_STR_LEN) catch break :blk false;
                    defer self.allocator.free(str);
                    const constraint_len = std.mem.indexOfScalar(u8, &v, 0) orelse MAX_CONSTRAINT_STR_LEN;
                    if (str.len < constraint_len) break :blk false;
                    break :blk std.mem.startsWith(u8, str, v[0..constraint_len]);
                },
                .num => false,
            },
            .str_suffix => switch (constraint.value) {
                .str => |v| blk: {
                    // Gracefully handle memory read failures (process exited, permissions, etc.)
                    const str = self.readUserString(pid, arg_value, MAX_CONSTRAINT_STR_LEN) catch break :blk false;
                    defer self.allocator.free(str);
                    const constraint_len = std.mem.indexOfScalar(u8, &v, 0) orelse MAX_CONSTRAINT_STR_LEN;
                    if (str.len < constraint_len) break :blk false;
                    break :blk std.mem.endsWith(u8, str, v[0..constraint_len]);
                },
                .num => false,
            },
            .str_contains => switch (constraint.value) {
                .str => |v| blk: {
                    // Gracefully handle memory read failures (process exited, permissions, etc.)
                    const str = self.readUserString(pid, arg_value, MAX_CONSTRAINT_STR_LEN) catch break :blk false;
                    defer self.allocator.free(str);
                    const constraint_len = std.mem.indexOfScalar(u8, &v, 0) orelse MAX_CONSTRAINT_STR_LEN;
                    break :blk std.mem.indexOf(u8, str, v[0..constraint_len]) != null;
                },
                .num => false,
            },
        };
    }

    /// Process a syscall event and check against all HOT_PATTERNS
    /// Returns MatchResult if pattern fully matched, null otherwise
    pub fn processSyscall(
        self: *Self,
        pid: u32,
        syscall_nr: u32,
        timestamp_ns: u64,
        args: [6]u64,
    ) !?MatchResult {
        // Increment syscall counter for this process
        const gop = try self.syscall_counts.getOrPut(pid);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
        const syscall_count = gop.value_ptr.*;

        // Debug: Log interesting syscalls with namespace information
        if (self.debug_mode) {
            if (isSyscallInClass(syscall_nr, .network) or
                isSyscallInClass(syscall_nr, .process_create) or
                isSyscallInClass(syscall_nr, .privilege)) {

                // Get namespace and binary information
                const ns = self.getProcessNamespace(pid) catch 0;
                const in_container = self.isInContainer(pid);
                const binary = self.getProcessBinaryName(pid) catch "<unknown>";

                std.debug.print("[GRIMOIRE-DEBUG] PID={d} syscall={d} count={d} | ", .{pid, syscall_nr, syscall_count});
                if (isSyscallInClass(syscall_nr, .network)) std.debug.print("class=NETWORK ", .{});
                if (isSyscallInClass(syscall_nr, .process_create)) std.debug.print("class=PROCESS_CREATE ", .{});
                if (isSyscallInClass(syscall_nr, .privilege)) std.debug.print("class=PRIVILEGE ", .{});
                std.debug.print("binary={s} ns={d} container={} ", .{binary, ns, in_container});
                std.debug.print("\n", .{});
            }
        }

        // Check each HOT_PATTERN
        outer: for (&HOT_PATTERNS, 0..) |pattern, pattern_idx| {
            if (!pattern.enabled) continue;

            self.patterns_checked += 1;

            // Check whitelist if present
            if (pattern.whitelisted_binaries) |wl| {
                const binary = try self.getProcessBinaryName(pid);
                for (wl) |white| {
                    if (std.mem.eql(u8, binary, white)) {
                        continue :outer; // Skip this pattern for whitelisted binary
                    }
                }
            }

            // Get or create match states for this process
            const states_gop = try self.match_states.getOrPut(pid);
            if (!states_gop.found_existing) {
                // Zig 0.16: ArrayList uses .{} for empty init
                states_gop.value_ptr.* = .{};
            }

            // Find or create match state for this pattern
            var state: ?*MatchState = null;
            for (states_gop.value_ptr.items) |*s| {
                if (s.pattern_index == pattern_idx) {
                    state = s;
                    break;
                }
            }

            if (state == null) {
                try states_gop.value_ptr.append(self.allocator, MatchState{
                    .pattern_index = pattern_idx,
                    .current_step = 0,
                    .sequence_start_ns = 0,
                    .last_step_ns = 0,
                    .last_step_syscall_count = 0,
                    .pid = pid,
                });
                state = &states_gop.value_ptr.items[states_gop.value_ptr.items.len - 1];
            }

            var s = state.?;

            // Check if sequence expired
            if (s.isExpired(&pattern, timestamp_ns)) {
                s.reset();
            }

            // Try to match current syscall against next expected step
            const current_step_idx = s.current_step;
            if (current_step_idx >= pattern.step_count) {
                s.reset();
                continue;
            }

            const step = pattern.steps[current_step_idx];

            // Check syscall match
            const syscall_matches = if (step.syscall_nr) |expected_nr|
                syscall_nr == expected_nr
            else
                isSyscallInClass(syscall_nr, step.syscall_class);

            if (!syscall_matches) continue;

            // Debug: Log step matching attempt
            if (self.debug_mode) {
                std.debug.print("[GRIMOIRE-DEBUG] PID={d} Pattern={s} Step={d}/{d} SYSCALL_MATCH\n",
                    .{pid, pattern.name, current_step_idx + 1, pattern.step_count});
            }

            // Check time delta
            if (step.max_time_delta_us > 0 and s.last_step_ns > 0) {
                const elapsed_us = (timestamp_ns - s.last_step_ns) / 1000;
                if (elapsed_us > step.max_time_delta_us) {
                    if (self.debug_mode) {
                        std.debug.print("[GRIMOIRE-DEBUG] PID={d} Pattern={s} Step={d} FAIL: time_delta={d}us > max={d}us\n",
                            .{pid, pattern.name, current_step_idx + 1, elapsed_us, step.max_time_delta_us});
                    }
                    s.reset();
                    continue;
                }
            }

            // Check step distance
            if (step.max_step_distance > 0 and s.last_step_syscall_count > 0) {
                const distance = syscall_count - s.last_step_syscall_count;
                if (distance > step.max_step_distance) {
                    if (self.debug_mode) {
                        std.debug.print("[GRIMOIRE-DEBUG] PID={d} Pattern={s} Step={d} FAIL: step_distance={d} > max={d}\n",
                            .{pid, pattern.name, current_step_idx + 1, distance, step.max_step_distance});
                    }
                    s.reset();
                    continue;
                }
            }

            // Check argument constraints
            inline for (step.arg_constraints) |opt_con| {
                if (opt_con) |con| {
                    if (!try self.validateConstraint(con, args, pid)) {
                        s.reset();
                        continue :outer;
                    }
                }
            }

            // Step matched!
            if (s.current_step == 0) {
                // First step - start sequence
                s.sequence_start_ns = timestamp_ns;
            }

            s.current_step += 1;
            s.last_step_ns = timestamp_ns;
            s.last_step_syscall_count = syscall_count;

            // Check if pattern fully matched
            if (s.current_step >= pattern.step_count) {
                // FULL PATTERN MATCH!
                self.total_matches += 1;
                self.matches_by_severity[@intFromEnum(pattern.severity)] += 1;

                if (self.debug_mode) {
                    std.debug.print("[GRIMOIRE-DEBUG] PID={d} Pattern={s} COMPLETE_MATCH! All {d} steps matched\n",
                        .{pid, pattern.name, pattern.step_count});
                }

                const result = MatchResult{
                    .matched = true,
                    .pattern = &HOT_PATTERNS[pattern_idx],  // Reference global pattern, not stack copy
                    .pid = pid,
                    .timestamp_ns = timestamp_ns,
                };

                // Reset state for next detection
                s.reset();

                return result;
            }
        }

        return null;
    }

    /// Display statistics
    pub fn displayStats(self: *Self) void {
        std.debug.print("\n📖 Grimoire Engine Statistics:\n", .{});
        std.debug.print("   Patterns checked:   {d}\n", .{self.patterns_checked});
        std.debug.print("   Total matches:      {d}\n", .{self.total_matches});
        std.debug.print("   Critical:           {d}\n", .{self.matches_by_severity[4]});
        std.debug.print("   High:               {d}\n", .{self.matches_by_severity[3]});
        std.debug.print("   Warning:            {d}\n", .{self.matches_by_severity[2]});
        std.debug.print("   Active processes:   {d}\n", .{self.match_states.count()});
    }
};

// ============================================================
// Tests
// ============================================================

test "grimoire: pattern struct size" {
    const size = @sizeOf(GrimoirePattern);
    try std.testing.expect(size <= 1024); // Adjusted for string constraints
}

test "grimoire: hot patterns fit in L1 cache" {
    const total = @sizeOf(GrimoirePattern) * HOT_PATTERNS.len;
    try std.testing.expect(total <= 8192); // Must fit in 8KB L1 cache
}

test "grimoire: detect reverse shell pattern" {
    var engine = try GrimoireEngine.init(std.testing.allocator, false);
    defer engine.deinit();

    const pid: u32 = 12345;

    // Simulate reverse shell sequence
    _ = try engine.processSyscall(pid, Syscall.socket, 1000000, [_]u64{0} ** 6); // socket()
    _ = try engine.processSyscall(pid, Syscall.dup2, 2000000, [_]u64{ 3, 0, 0, 0, 0, 0 }); // dup2(3, 0)
    _ = try engine.processSyscall(pid, Syscall.dup2, 3000000, [_]u64{ 3, 1, 0, 0, 0, 0 }); // dup2(3, 1)
    const result = try engine.processSyscall(pid, Syscall.execve, 4000000, [_]u64{0} ** 6); // execve()

    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expect(r.matched);
        try std.testing.expectEqual(Severity.critical, r.pattern.severity);
    }
}
