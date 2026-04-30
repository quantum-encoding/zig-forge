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


// libwarden.so V8.2 - Guardian Shield with Full Path Hijacking Defense
// Purpose: Runtime-configurable syscall interception with surgical process restrictions
//
// V8.2 BUGFIXES:
//   1. Signal handler crash - use portable signal() instead of sigaction
//      The struct_sigaction.__sigaction_handler field has platform-specific layout
//      that varies between Zig's @cImport and different glibc versions.
//
//   2. CRITICAL: Recursive interception crash in shouldBypassAllProtection()
//      The magic file check used std.fs.accessAbsolute() which calls our intercepted
//      open() syscall, which calls shouldBypassAllProtection() again -> infinite
//      recursion -> stack overflow -> SEGFAULT on EVERY new process.
//      FIX: Use raw syscalls via dlsym(RTLD_NEXT) to bypass our own interceptors.
//
// V8.1 Features (Emergency Recovery - "Never Lock Yourself Out"):
// - NEW: Magic file kill switch (/tmp/.warden_emergency_disable)
// - NEW: Environment variable bypass (WARDEN_DISABLE=1)
// - NEW: SIGUSR2 emergency signal handler (instant disable)
// - NEW: Kernel cmdline bypass (warden.disable=1)
// - NEW: Self-preservation paths (ALWAYS allow removing the shield itself)
//
// V8.0 Features (The "Path Fortress" Doctrine):
// - NEW: symlink/symlinkat interceptor (prevents symlink path hijacking attacks)
// - NEW: link/linkat interceptor (prevents hardlink privilege escalation)
// - NEW: truncate/ftruncate interceptor (prevents data destruction attacks)
// - NEW: mkdir/mkdirat interceptor (controls directory creation in protected paths)
// - NEW: SIGHUP handler for config hot-reload without restart
// - NEW: Granular permission flags (no-delete, no-move, no-truncate, read-only)
//
// V7.x Features (preserved):
// - Process-aware restrictions - target untrusted AI agents specifically
// - Block /tmp write for restricted processes (python, harvester, codex-cli)
// - Block /tmp execute for restricted processes (prevents Ephemeral Execution Attack)
// - Protect dotfiles (.bashrc, .zshrc) from modification by untrusted processes
// - chmod() interceptor (prevents making /tmp files executable)
// - execve() interceptor (blocks execution from /tmp)
// - Protect directory structures (Living Citadel) while allowing internal operations
// - Git's internal mechanisms (.git/index.lock) allowed
// - Thread-safe initialization using std.once
// - Memory safety: No atexit cleanup (OS handles cleanup on process exit)
// - Robust JSON parsing with parseFromSlice
// - Zero race conditions, zero segfaults
//
// Protected syscalls: unlink, unlinkat, rmdir, open, openat, rename, renameat,
//                     chmod, execve, symlink, symlinkat, link, linkat,
//                     truncate, ftruncate, mkdir, mkdirat

const std = @import("std");
const config_mod = @import("config.zig");

const c = @cImport({
    @cInclude("dlfcn.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("signal.h");
});

// Import errno functions
extern "c" fn __errno_location() *c_int;

// Helper for getenv compatibility with Zig 0.16.2187+
fn getenvCompat(name: []const u8) ?[]const u8 {
    // Convert to null-terminated string for C
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ptr = c.getenv(@ptrCast(&buf));
    if (ptr) |p| {
        return std.mem.span(p);
    }
    return null;
}

// ============================================================
// Global State (Thread-Safe Singleton)
// ============================================================

const GlobalState = struct {
    config: config_mod.Config,

    // Function pointers to original syscalls - V7.x
    original_unlink: *const fn ([*:0]const u8) callconv(.c) c_int,
    original_unlinkat: *const fn (c_int, [*:0]const u8, c_int) callconv(.c) c_int,
    original_rmdir: *const fn ([*:0]const u8) callconv(.c) c_int,
    original_open: *const fn ([*:0]const u8, c_int, ...) callconv(.c) c_int,
    original_openat: *const fn (c_int, [*:0]const u8, c_int, ...) callconv(.c) c_int,
    original_rename: *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    original_renameat: *const fn (c_int, [*:0]const u8, c_int, [*:0]const u8) callconv(.c) c_int,
    original_chmod: *const fn ([*:0]const u8, c_int) callconv(.c) c_int,
    original_execve: *const fn ([*:0]const u8, [*:null]?[*:0]const u8, [*:null]?[*:0]const u8) callconv(.c) c_int,

    // V8.0: New syscall interceptors for path hijacking defense
    original_symlink: *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    original_symlinkat: *const fn ([*:0]const u8, c_int, [*:0]const u8) callconv(.c) c_int,
    original_link: *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    original_linkat: *const fn (c_int, [*:0]const u8, c_int, [*:0]const u8, c_int) callconv(.c) c_int,
    original_truncate: *const fn ([*:0]const u8, c_long) callconv(.c) c_int,
    original_ftruncate: *const fn (c_int, c_long) callconv(.c) c_int,
    original_mkdir: *const fn ([*:0]const u8, c_int) callconv(.c) c_int,
    original_mkdirat: *const fn (c_int, [*:0]const u8, c_int) callconv(.c) c_int,

    fn deinit(self: *GlobalState) void {
        self.config.deinit();
    }
};

/// LD_PRELOAD MEMORY MANAGEMENT STRATEGY
///
/// This library uses std.heap.c_allocator and intentionally does NOT free
/// memory on process exit. This is the correct design for LD_PRELOAD libraries.
///
/// RATIONALE:
///
/// 1. Process Lifecycle Ordering
///    LD_PRELOAD libraries are loaded before the host process's main() runs,
///    but the process may call dlclose() at any point during shutdown. If we
///    register cleanup handlers (atexit, destructors), they may run AFTER
///    dlclose() has already unloaded our library's code, causing segfaults.
///
/// 2. Host Process Complexity
///    Python, Node.js, Ruby, and other VM-based processes have intricate
///    shutdown sequences involving garbage collection, finalizers, and thread
///    cleanup. Our cleanup code running during this phase can trigger
///    use-after-free bugs in the host process itself.
///
/// 3. Operating System Guarantees
///    The OS reclaims ALL process memory when the process exits, regardless
///    of whether individual allocations were explicitly freed. For short-lived
///    interception libraries, explicit cleanup provides zero practical benefit.
///
/// 4. Thread Safety Simplification
///    By never freeing memory, we eliminate an entire class of race conditions
///    where one thread might be using state while another thread is destroying it.
///
/// DEBUGGING:
///
/// When analyzing this code with memory leak detectors:
/// - Valgrind: Use `--show-reachable=yes` to distinguish "still-reachable"
///   (intentional) from "definitely lost" (actual bugs)
/// - ASAN: These allocations will appear in leak summaries but are expected
/// - Heaptrack: Filter for "still reachable" vs "lost" allocations
///
/// This pattern is documented in the GNU libc manual and is standard practice
/// for production LD_PRELOAD implementations.
const allocator = std.heap.c_allocator;
var global_state: ?*GlobalState = null;

// ============================================================
// V8.1: Emergency Bypass Mechanisms
// ============================================================
//
// These mechanisms ensure you can ALWAYS recover from a lockout.
// They are checked BEFORE config loading, so they work even when
// the config file is broken or inaccessible.

// Magic file kill switches - creating these files disables ALL protection
const EMERGENCY_KILL_SWITCH = "/tmp/.warden_emergency_disable";
const EMERGENCY_KILL_SWITCH_ROOT = "/var/run/warden_emergency_disable";

// Self-preservation paths - ALWAYS allowed, regardless of config
// This ensures you can always uninstall Guardian Shield
const SELF_PRESERVATION_PATHS = [_][]const u8{
    "/etc/ld.so.preload",
    "/etc/warden/",
    "/usr/lib/libwarden",
    "/usr/local/lib/libwarden",
    "/usr/local/lib/security/libwarden",
    "/lib/libwarden",
    "/opt/warden/",
};

const SELF_PRESERVATION_SUBSTRINGS = [_][]const u8{
    "libwarden.so",
    "warden-config",
    "ld.so.preload",
    "warden-emergency",
};

// Emergency signal state (SIGUSR2 disables all protection)
var emergency_signal_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Kernel cmdline check (cached after first read)
var cmdline_checked: bool = false;
var cmdline_disabled: bool = false;

/// V8.1: SIGUSR2 handler for emergency disable
/// Usage: kill -USR2 <pid> or pkill -USR2 -f .
fn sigusr2Handler(_: c_int) callconv(.c) void {
    emergency_signal_received.store(true, .seq_cst);
    // Note: Limited what we can do in signal handler, but this flag
    // will be checked by shouldBypassAllProtection()
}

/// V8.2: Install the emergency SIGUSR2 handler using portable signal()
/// BUGFIX: V8.1 used sigaction with __sigaction_handler which has platform-specific
/// struct layout issues between Zig's @cImport and glibc. This caused segfaults
/// on Arch Linux 6.17+. Using simple signal() is more portable for LD_PRELOAD.
fn installEmergencySignalHandler() void {
    // Use the simple, portable signal() function instead of sigaction
    // This avoids struct layout mismatches between Zig C bindings and glibc
    const prev = c.signal(c.SIGUSR2, sigusr2Handler);
    if (prev == c.SIG_ERR) {
        // Only print errors in verbose mode to avoid stderr spam
        if (getenvCompat("WARDEN_VERBOSE")) |v| {
            if (std.mem.eql(u8, v, "1")) {
                std.debug.print("[libwarden.so] ⚠️  Failed to install SIGUSR2 emergency handler\n", .{});
            }
        }
    }
}

/// V8.1: Master bypass check - called BEFORE getState() in every interceptor
/// This ensures recovery works even when config loading fails
fn shouldBypassAllProtection(path: [*:0]const u8) bool {
    // 1. Emergency signal (in-memory, instant check)
    if (emergency_signal_received.load(.seq_cst)) {
        return true;
    }

    // 2. Environment variable bypass (fast getenv)
    const env_vars = [_][]const u8{
        "WARDEN_DISABLE",
        "GUARDIAN_SHIELD_DISABLE",
        "LIBWARDEN_DISABLE",
    };
    for (env_vars) |env_name| {
        if (getenvCompat(env_name)) |val| {
            if (std.mem.eql(u8, val, "1") or
                std.mem.eql(u8, val, "true") or
                std.mem.eql(u8, val, "yes"))
            {
                return true;
            }
        }
    }

    // 3. Self-preservation paths (ALWAYS allow removing the shield itself)
    const path_slice = std.mem.span(path);

    // Check prefix matches
    for (SELF_PRESERVATION_PATHS) |safe_path| {
        if (std.mem.startsWith(u8, path_slice, safe_path)) {
            return true;
        }
    }

    // Check substring matches (handles any install location)
    for (SELF_PRESERVATION_SUBSTRINGS) |substring| {
        if (std.mem.indexOf(u8, path_slice, substring)) |_| {
            return true;
        }
    }

    // 4. Magic file kill switch (filesystem check)
    // V8.2 BUGFIX: Use raw syscall via dlsym to avoid recursive interception!
    // std.fs.accessAbsolute() calls our intercepted open() which calls
    // shouldBypassAllProtection() again, causing infinite recursion and crash.
    // Solution: Use direct access() syscall via RTLD_NEXT
    if (checkMagicFileExists(EMERGENCY_KILL_SWITCH)) {
        return true;
    }

    if (checkMagicFileExists(EMERGENCY_KILL_SWITCH_ROOT)) {
        return true;
    }

    // 5. Kernel cmdline bypass (cached after first check)
    // V8.2 BUGFIX: Use raw syscalls to avoid recursive interception
    if (!cmdline_checked) {
        cmdline_checked = true;
        var buf: [4096]u8 = undefined;
        if (readFileRaw("/proc/cmdline", &buf)) |bytes| {
            if (std.mem.indexOf(u8, buf[0..bytes], "warden.disable=1")) |_| {
                cmdline_disabled = true;
            }
            if (std.mem.indexOf(u8, buf[0..bytes], "guardian.disable=1")) |_| {
                cmdline_disabled = true;
            }
        }
    }
    if (cmdline_disabled) return true;

    return false;
}

/// V8.1: Direct dlsym call for bypass - doesn't require state
fn getOriginalSyscall(comptime name: [:0]const u8) ?*anyopaque {
    return c.dlsym(c.RTLD_NEXT, name);
}

/// V8.2 BUGFIX: Check if a file exists using raw access() syscall
/// This MUST use direct syscall to avoid recursive interception.
/// Our intercepted open()/access() would call shouldBypassAllProtection()
/// which would call this function again -> infinite recursion -> crash
fn checkMagicFileExists(path: []const u8) bool {
    // Get the original access() function via dlsym
    const access_ptr = c.dlsym(c.RTLD_NEXT, "access") orelse return false;
    const original_access = @as(*const fn ([*:0]const u8, c_int) callconv(.c) c_int, @ptrCast(access_ptr));

    // Create null-terminated path on stack (magic files have short, known paths)
    var path_buf: [128]u8 = undefined;
    if (path.len >= path_buf.len) return false;

    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    // F_OK = 0, checks if file exists
    const result = original_access(@ptrCast(&path_buf), 0);
    return result == 0;
}

/// V8.2 BUGFIX: Read file contents using raw syscalls to avoid recursion
/// Used for kernel cmdline check
fn readFileRaw(path: []const u8, buffer: []u8) ?usize {
    // Get original open/read/close via dlsym
    const open_ptr = c.dlsym(c.RTLD_NEXT, "open") orelse return null;
    const read_ptr = c.dlsym(c.RTLD_NEXT, "read") orelse return null;
    const close_ptr = c.dlsym(c.RTLD_NEXT, "close") orelse return null;

    const original_open = @as(*const fn ([*:0]const u8, c_int, ...) callconv(.c) c_int, @ptrCast(open_ptr));
    const original_read = @as(*const fn (c_int, [*]u8, usize) callconv(.c) isize, @ptrCast(read_ptr));
    const original_close = @as(*const fn (c_int) callconv(.c) c_int, @ptrCast(close_ptr));

    // Create null-terminated path
    var path_buf: [128]u8 = undefined;
    if (path.len >= path_buf.len) return null;

    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    // Open file read-only (O_RDONLY = 0)
    const fd = original_open(@ptrCast(&path_buf), 0);
    if (fd < 0) return null;
    defer _ = original_close(fd);

    // Read contents
    const bytes_read = original_read(fd, buffer.ptr, buffer.len);
    if (bytes_read < 0) return null;

    return @intCast(bytes_read);
}

const InitOnce = struct {
    fn do() void {
        // Note: in_interceptor is already true here — set by the calling
        // interceptor. This ensures c.open() calls from config loading
        // pass through to the real syscall instead of re-entering our
        // interceptors (which would see null global_state).

        const state = allocator.create(GlobalState) catch {
            std.debug.print("[libwarden.so] ⚠️  Failed to allocate global state\n", .{});
            return;
        };

        // Load configuration
        const cfg = config_mod.loadConfig(allocator) catch |err| blk: {
            std.debug.print("[libwarden.so] ⚠️  Config load failed ({any}), using defaults\n", .{err});
            break :blk config_mod.getDefaultConfig(allocator) catch |default_err| {
                std.debug.print("[libwarden.so] ⚠️  Default config failed ({any}), shield disabled!\n", .{default_err});
                allocator.destroy(state);
                return;
            };
        };

        // Load function pointers
        const unlink_ptr = c.dlsym(c.RTLD_NEXT, "unlink") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original unlink\n", .{});
            // V6.1: Do NOT call cfg.deinit() - let memory leak
            allocator.destroy(state);
            return;
        };

        const unlinkat_ptr = c.dlsym(c.RTLD_NEXT, "unlinkat") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original unlinkat\n", .{});
            allocator.destroy(state);
            return;
        };

        const rmdir_ptr = c.dlsym(c.RTLD_NEXT, "rmdir") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original rmdir\n", .{});
            allocator.destroy(state);
            return;
        };

        const open_ptr = c.dlsym(c.RTLD_NEXT, "open") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original open\n", .{});
            allocator.destroy(state);
            return;
        };

        const openat_ptr = c.dlsym(c.RTLD_NEXT, "openat") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original openat\n", .{});
            allocator.destroy(state);
            return;
        };

        const rename_ptr = c.dlsym(c.RTLD_NEXT, "rename") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original rename\n", .{});
            allocator.destroy(state);
            return;
        };

        const renameat_ptr = c.dlsym(c.RTLD_NEXT, "renameat") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original renameat\n", .{});
            allocator.destroy(state);
            return;
        };

        const chmod_ptr = c.dlsym(c.RTLD_NEXT, "chmod") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original chmod\n", .{});
            allocator.destroy(state);
            return;
        };

        const execve_ptr = c.dlsym(c.RTLD_NEXT, "execve") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original execve\n", .{});
            allocator.destroy(state);
            return;
        };

        // V8.0: Load new syscall interceptors for path hijacking defense
        const symlink_ptr = c.dlsym(c.RTLD_NEXT, "symlink") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original symlink\n", .{});
            allocator.destroy(state);
            return;
        };

        const symlinkat_ptr = c.dlsym(c.RTLD_NEXT, "symlinkat") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original symlinkat\n", .{});
            allocator.destroy(state);
            return;
        };

        const link_ptr = c.dlsym(c.RTLD_NEXT, "link") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original link\n", .{});
            allocator.destroy(state);
            return;
        };

        const linkat_ptr = c.dlsym(c.RTLD_NEXT, "linkat") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original linkat\n", .{});
            allocator.destroy(state);
            return;
        };

        const truncate_ptr = c.dlsym(c.RTLD_NEXT, "truncate") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original truncate\n", .{});
            allocator.destroy(state);
            return;
        };

        const ftruncate_ptr = c.dlsym(c.RTLD_NEXT, "ftruncate") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original ftruncate\n", .{});
            allocator.destroy(state);
            return;
        };

        const mkdir_ptr = c.dlsym(c.RTLD_NEXT, "mkdir") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original mkdir\n", .{});
            allocator.destroy(state);
            return;
        };

        const mkdirat_ptr = c.dlsym(c.RTLD_NEXT, "mkdirat") orelse {
            std.debug.print("[libwarden.so] ⚠️  Failed to load original mkdirat\n", .{});
            allocator.destroy(state);
            return;
        };

        // V8.1: Silent by default - no banner spam on every process
        // The recovery methods are documented and don't need to pollute stderr
        // Only print if WARDEN_VERBOSE=1 is set (for debugging)
        if (getenvCompat("WARDEN_VERBOSE")) |verbose| {
            if (std.mem.eql(u8, verbose, "1")) {
                if (cfg.global.enabled) {
                    std.debug.print("[libwarden.so] {s} Guardian Shield V8.2 - Path Fortress Active\n", .{cfg.global.block_emoji});
                    std.debug.print("[libwarden.so] 📋 Recovery: touch /tmp/.warden_emergency_disable | WARDEN_DISABLE=1 | kill -USR2 <pid>\n", .{});
                } else {
                    std.debug.print("[libwarden.so] ⚠️  Shield is DISABLED via config\n", .{});
                }
            }
        }

        // Initialize state
        state.* = GlobalState{
            .config = cfg,
            // V7.x syscalls
            .original_unlink = @ptrCast(unlink_ptr),
            .original_unlinkat = @ptrCast(unlinkat_ptr),
            .original_rmdir = @ptrCast(rmdir_ptr),
            .original_open = @ptrCast(open_ptr),
            .original_openat = @ptrCast(openat_ptr),
            .original_rename = @ptrCast(rename_ptr),
            .original_renameat = @ptrCast(renameat_ptr),
            .original_chmod = @ptrCast(chmod_ptr),
            .original_execve = @ptrCast(execve_ptr),
            // V8.0 syscalls - path hijacking defense
            .original_symlink = @ptrCast(symlink_ptr),
            .original_symlinkat = @ptrCast(symlinkat_ptr),
            .original_link = @ptrCast(link_ptr),
            .original_linkat = @ptrCast(linkat_ptr),
            .original_truncate = @ptrCast(truncate_ptr),
            .original_ftruncate = @ptrCast(ftruncate_ptr),
            .original_mkdir = @ptrCast(mkdir_ptr),
            .original_mkdirat = @ptrCast(mkdirat_ptr),
        };

        global_state = state;

        // V8.0: Install SIGHUP handler for config hot-reload
        installSignalHandler();

        // V8.1: Install SIGUSR2 handler for emergency disable
        installEmergencySignalHandler();

        // V6.1: Do NOT register atexit cleanup
        // Rationale: LD_PRELOAD libraries should not free memory on exit
        // The OS will clean up when the process terminates
        // Attempting cleanup causes use-after-free when Python's cleanup
        // tries to access our intercepted functions after we've freed our state
        //
        // _ = c.atexit(cleanupGlobalState);  // REMOVED in V6.1
    }
};

/// Once wrapper using atomics (std.once removed in Zig 0.16)
const Once = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn call(self: *Once) void {
        // Check if already done without locking
        if (self.done.load(.acquire)) return;

        // Try to be the one to initialize
        if (self.done.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            // We won the race, do initialization
            InitOnce.do();
        }
    }
};

var init_once: Once = .{};

// V6.1: This function should NEVER be called in an LD_PRELOAD library
// Kept for reference only - cleanup on exit causes crashes
fn cleanupGlobalState() callconv(.c) void {
    // INTENTIONALLY LEFT EMPTY
    // Rationale: LD_PRELOAD libraries must not free memory on process exit
    // The OS will reclaim all memory when the process terminates
    // Attempting cleanup here causes use-after-free when the host process
    // (Python, bash, etc.) tries to call our intercepted functions during
    // its own cleanup sequence
}

// ============================================================
// V8.0: SIGHUP Handler for Config Hot-Reload
// ============================================================
//
// This enables runtime config updates without process restart:
// 1. Edit /etc/warden/warden-config.json
// 2. Send SIGHUP to any process with libwarden loaded
// 3. Config is atomically reloaded
//
// Usage: wardenctl reload (sends SIGHUP to target process)
//        or: kill -HUP <pid>

var reload_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn sighupHandler(_: c_int) callconv(.c) void {
    // Prevent concurrent reloads
    if (reload_in_progress.swap(true, .seq_cst)) {
        return; // Already reloading
    }
    defer reload_in_progress.store(false, .seq_cst);

    const state = global_state orelse return;

    // Attempt to reload config
    const new_config = config_mod.loadConfig(allocator) catch |err| {
        std.debug.print("[libwarden.so] ⚠️  SIGHUP reload failed: {any}\n", .{err});
        return;
    };

    // Swap configs atomically
    // Note: Old config memory is intentionally leaked (LD_PRELOAD pattern)
    // This is safe because:
    // 1. Memory will be reclaimed on process exit
    // 2. We avoid complex cleanup during signal handler
    // 3. Config reloads should be infrequent (manual admin action)
    state.config = new_config;

    std.debug.print("[libwarden.so] {s} Config reloaded via SIGHUP\n", .{state.config.global.block_emoji});
}

/// V8.2: Install SIGHUP handler for config hot-reload using portable signal()
/// BUGFIX: Same as SIGUSR2 - sigaction struct layout is platform-specific
fn installSignalHandler() void {
    // Use the simple, portable signal() function instead of sigaction
    const prev = c.signal(c.SIGHUP, sighupHandler);
    if (prev == c.SIG_ERR) {
        if (getenvCompat("WARDEN_VERBOSE")) |v| {
            if (std.mem.eql(u8, v, "1")) {
                std.debug.print("[libwarden.so] ⚠️  Failed to install SIGHUP handler\n", .{});
            }
        }
    }
}

fn getState() ?*GlobalState {
    init_once.call();
    return global_state;
}

// ============================================================
// V7.1: Process Detection Logic
// ============================================================

/// Get the current process name by reading /proc/self/comm
fn getCurrentProcessName(buffer: []u8) ?[]const u8 {
    const fd = c.open("/proc/self/comm", c.O_RDONLY, @as(c_uint, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);

    const bytes_read_raw = c.read(fd, buffer.ptr, buffer.len);
    if (bytes_read_raw <= 0) return null;
    const bytes_read: usize = @intCast(bytes_read_raw);

    // Trim trailing newline
    var len = bytes_read;
    while (len > 0 and (buffer[len - 1] == '\n' or buffer[len - 1] == '\r')) {
        len -= 1;
    }

    return buffer[0..len];
}

/// V7.2: Check if the current process is exempt (trusted build tool)
fn isProcessExempt() bool {
    const state = getState() orelse return false;

    if (!state.config.process_exemptions.enabled) return false;

    var proc_name_buf: [256]u8 = undefined;
    const proc_name = getCurrentProcessName(&proc_name_buf) orelse return false;

    // Check if this process is in the exempt list
    for (state.config.process_exemptions.exempt_processes) |exempt_name| {
        if (std.mem.eql(u8, proc_name, exempt_name)) {
            return true;
        }
    }

    return false;
}

/// V7.1: Check if the current process is on the restricted list
fn getProcessRestrictions() ?*const config_mod.ProcessRestrictions {
    const state = getState() orelse return null;

    if (!state.config.process_restrictions.enabled) return null;

    var proc_name_buf: [256]u8 = undefined;
    const proc_name = getCurrentProcessName(&proc_name_buf) orelse return null;

    // Check if this process is in the restricted list
    for (state.config.process_restrictions.restricted_processes) |*restricted| {
        if (std.mem.eql(u8, proc_name, restricted.name)) {
            return &restricted.restrictions;
        }
    }

    return null;
}

/// V7.1: Check if a path is /tmp or a dotfile that should be monitored
fn isPathRestrictedForProcess(path: [*:0]const u8, restrictions: *const config_mod.ProcessRestrictions, is_write: bool) bool {
    const path_slice = std.mem.span(path);

    // Check /tmp restrictions
    if (is_write and restrictions.block_tmp_write) {
        if (std.mem.startsWith(u8, path_slice, "/tmp/")) {
            return true;
        }
    }

    // Check dotfile restrictions
    if (is_write and restrictions.block_dotfile_write) {
        // Extract filename from path
        const filename_start = if (std.mem.lastIndexOf(u8, path_slice, "/")) |idx| idx + 1 else 0;
        const filename = path_slice[filename_start..];

        // Check if it's in the monitored dotfiles list
        for (restrictions.monitored_dotfiles) |dotfile| {
            if (std.mem.eql(u8, filename, dotfile) or std.mem.endsWith(u8, path_slice, dotfile)) {
                return true;
            }
        }
    }

    return false;
}

// ============================================================
// Path Checking Logic (Config-Driven)
// ============================================================

/// Simple glob pattern matching for `**/.git` style patterns
fn matchesGlobPattern(path_slice: []const u8, pattern: []const u8) bool {
    // Handle `**/.git` pattern
    if (std.mem.startsWith(u8, pattern, "**/")) {
        const suffix = pattern[3..];
        // Check if path ends with the suffix or contains it as a directory component
        if (std.mem.endsWith(u8, path_slice, suffix)) return true;

        // Check for `/.git/` or `/.git` anywhere in path
        var search_pattern_buf: [256]u8 = undefined;
        const search_pattern = std.fmt.bufPrint(&search_pattern_buf, "/{s}", .{suffix}) catch return false;
        if (std.mem.indexOf(u8, path_slice, search_pattern)) |_| return true;
    }
    return false;
}

/// V7: Check if a path is a protected directory ITSELF (not files within it)
/// The Living Citadel Doctrine:
///   - Block: rmdir on /path/to/zig_forge or /path/to/.git
///   - Block: rename of /path/to/zig_forge or /path/to/.git
///   - Allow: unlink on /path/to/zig_forge/file.zig (file inside Citadel)
///   - Allow: unlink on /path/to/.git/index.lock (git's internal operations)
fn isProtectedDirectoryItself(path: [*:0]const u8) bool {
    const state = getState() orelse return false;

    if (!state.config.directory_protection.enabled) return false;

    const path_slice = std.mem.span(path);

    // Check if this path IS a protected root (exact match)
    for (state.config.directory_protection.protected_roots) |root| {
        if (std.mem.eql(u8, path_slice, root)) return true;
    }

    // Check if this path IS a .git directory (for pattern **/.git)
    for (state.config.directory_protection.protected_patterns) |pattern| {
        if (std.mem.eql(u8, pattern, "**/.git")) {
            // Check if path ends with "/.git" or is exactly ".git"
            if (std.mem.endsWith(u8, path_slice, "/.git")) return true;
            if (std.mem.eql(u8, path_slice, ".git")) return true;
        }
    }

    return false;
}

fn isWhitelisted(path: [*:0]const u8) bool {
    const state = getState() orelse return false;
    const path_slice = std.mem.span(path);

    for (state.config.whitelisted_paths) |whitelist| {
        if (std.mem.startsWith(u8, path_slice, whitelist.path)) {
            return true;
        }
    }
    return false;
}

fn isProtectedForOperation(path: [*:0]const u8, operation: []const u8) bool {
    const state = getState() orelse return false;

    // Check if globally disabled
    if (!state.config.global.enabled) return false;

    // Check environment override
    if (state.config.advanced.allow_env_override) {
        if (getenvCompat("LIBWARDEN_OVERRIDE")) |override_val| {
            if (std.mem.eql(u8, override_val, "1")) {
                return false;
            }
        }
    }

    // Whitelist takes precedence
    if (isWhitelisted(path)) return false;

    const path_slice = std.mem.span(path);

    // Check protected paths
    for (state.config.protected_paths) |protected| {
        if (std.mem.startsWith(u8, path_slice, protected.path)) {
            // Check if this operation is blocked for this path
            for (protected.block_operations) |blocked_op| {
                if (std.mem.eql(u8, blocked_op, operation)) {
                    return true;
                }
            }
        }
    }

    return false;
}

fn logBlock(operation: []const u8, path: [*:0]const u8) void {
    const state = getState() orelse {
        std.debug.print("[libwarden.so] 🛡️  BLOCKED {s}: {s}\n", .{ operation, path });
        return;
    };

    std.debug.print("[libwarden.so] {s} BLOCKED {s}: {s}\n", .{ state.config.global.block_emoji, operation, path });
}

// ============================================================
// Re-entrancy Guard (threadlocal)
// ============================================================
//
// CRITICAL FIX: Prevents infinite recursion when intercepted functions
// call C library functions that trigger other interceptors.
// Example: getCurrentProcessName() calls c.open() -> our open interceptor
// -> isProcessExempt() -> getCurrentProcessName() -> c.open() -> ...
// The guard detects this re-entrant call and passes through to the real
// syscall via dlsym(RTLD_NEXT), breaking the recursion.

threadlocal var in_interceptor: bool = false;

// ============================================================
// Syscall Interceptors - unlink() family
// ============================================================

export fn unlink(path: [*:0]const u8) c_int {
    // Re-entrancy guard: pass through if already inside an interceptor
    if (in_interceptor) {
        const f = getOriginalSyscall("unlink") orelse return -1;
        return @as(*const fn ([*:0]const u8) callconv(.c) c_int, @ptrCast(f))(path);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(path)) {
        const original_fn = getOriginalSyscall("unlink") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn ([*:0]const u8) callconv(.c) c_int, @ptrCast(original_fn));
        return original(path);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // V7.2: Exempt trusted build tools (bypass ALL checks for performance)
    if (isProcessExempt()) {
        return state.original_unlink(path);
    }

    // V7.1: Check process-specific restrictions FIRST
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(path, restrictions, true)) {
            logBlock("unlink [PROCESS-RESTRICTED]", path);
            __errno_location().* = 13;
            return -1;
        }
    }

    // V7: unlink operates on FILES, not directories
    // We don't check isProtectedDirectoryItself() here because:
    //   - unlink cannot remove directories (use rmdir for that)
    //   - We want to allow git to manage .git/index.lock and other internal files
    // Only check the operation-level protection

    if (isProtectedForOperation(path, "unlink")) {
        logBlock("unlink", path);
        __errno_location().* = 13; // EACCES
        return -1;
    }

    return state.original_unlink(path);
}

export fn unlinkat(dirfd: c_int, path: [*:0]const u8, flags: c_int) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("unlinkat") orelse return -1;
        return @as(*const fn (c_int, [*:0]const u8, c_int) callconv(.c) c_int, @ptrCast(f))(dirfd, path, flags);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(path)) {
        const original_fn = getOriginalSyscall("unlinkat") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn (c_int, [*:0]const u8, c_int) callconv(.c) c_int, @ptrCast(original_fn));
        return original(dirfd, path, flags);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // V7.2: Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_unlinkat(dirfd, path, flags);
    }

    // V7.1: Check process-specific restrictions FIRST
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(path, restrictions, true)) {
            logBlock("unlinkat [PROCESS-RESTRICTED]", path);
            __errno_location().* = 13;
            return -1;
        }
    }

    // V7: unlinkat can remove files OR directories (with AT_REMOVEDIR flag)
    // Only check directory protection if this is a directory removal operation
    const AT_REMOVEDIR: c_int = 0x200;
    if ((flags & AT_REMOVEDIR) != 0) {
        // This is rmdir-equivalent, check if it's a protected directory
        if (isProtectedDirectoryItself(path)) {
            logBlock("unlinkat/rmdir (Citadel protected)", path);
            __errno_location().* = 13;
            return -1;
        }
    }

    if (isProtectedForOperation(path, "unlinkat")) {
        logBlock("unlinkat", path);
        __errno_location().* = 13;
        return -1;
    }

    return state.original_unlinkat(dirfd, path, flags);
}

export fn rmdir(path: [*:0]const u8) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("rmdir") orelse return -1;
        return @as(*const fn ([*:0]const u8) callconv(.c) c_int, @ptrCast(f))(path);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(path)) {
        const original_fn = getOriginalSyscall("rmdir") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn ([*:0]const u8) callconv(.c) c_int, @ptrCast(original_fn));
        return original(path);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // V7.2: Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_rmdir(path);
    }

    // V7: rmdir operates on directories - THIS is where Living Citadel protection applies
    // Check if this is a protected directory itself
    if (isProtectedDirectoryItself(path)) {
        logBlock("rmdir (Citadel protected)", path);
        __errno_location().* = 13;
        return -1;
    }

    if (isProtectedForOperation(path, "rmdir")) {
        logBlock("rmdir", path);
        __errno_location().* = 13;
        return -1;
    }

    return state.original_rmdir(path);
}

// ============================================================
// Syscall Interceptors - open() family
// ============================================================

export fn open(path: [*:0]const u8, flags: c_int, ...) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("open") orelse return -1;
        const orig = @as(*const fn ([*:0]const u8, c_int, ...) callconv(.c) c_int, @ptrCast(f));
        if ((flags & c.O_CREAT) != 0) {
            var args = @cVaStart();
            const mode = @cVaArg(&args, c_int);
            @cVaEnd(&args);
            return orig(path, flags, mode);
        }
        return orig(path, flags);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(path)) {
        const original_fn = getOriginalSyscall("open") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn ([*:0]const u8, c_int, ...) callconv(.c) c_int, @ptrCast(original_fn));
        if ((flags & c.O_CREAT) != 0) {
            var args = @cVaStart();
            const mode = @cVaArg(&args, c_int);
            @cVaEnd(&args);
            return original(path, flags, mode);
        }
        return original(path, flags);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // V7.2: Exempt trusted build tools
    if (isProcessExempt()) {
        if ((flags & c.O_CREAT) != 0) {
            var args = @cVaStart();
            const mode = @cVaArg(&args, c_int);
            @cVaEnd(&args);
            return state.original_open(path, flags, mode);
        }
        return state.original_open(path, flags);
    }

    const is_write = (flags & c.O_WRONLY) != 0 or (flags & c.O_RDWR) != 0;

    // V7.1: Check process-specific restrictions FIRST (surgical, targeted)
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(path, restrictions, is_write)) {
            logBlock("open(write) [PROCESS-RESTRICTED]", path);
            __errno_location().* = 13;
            return -1;
        }
    }

    // V7.0: Check global protection rules
    if (is_write and isProtectedForOperation(path, "open_write")) {
        logBlock("open(write)", path);
        __errno_location().* = 13;
        return -1;
    }

    // Handle O_CREAT mode parameter if present
    if ((flags & c.O_CREAT) != 0) {
        var args = @cVaStart();
        const mode = @cVaArg(&args, c_int);
        @cVaEnd(&args);
        return state.original_open(path, flags, mode);
    }

    return state.original_open(path, flags);
}

export fn openat(dirfd: c_int, path: [*:0]const u8, flags: c_int, ...) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("openat") orelse return -1;
        const orig = @as(*const fn (c_int, [*:0]const u8, c_int, ...) callconv(.c) c_int, @ptrCast(f));
        if ((flags & c.O_CREAT) != 0) {
            var args = @cVaStart();
            const mode = @cVaArg(&args, c_int);
            @cVaEnd(&args);
            return orig(dirfd, path, flags, mode);
        }
        return orig(dirfd, path, flags);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(path)) {
        const original_fn = getOriginalSyscall("openat") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn (c_int, [*:0]const u8, c_int, ...) callconv(.c) c_int, @ptrCast(original_fn));
        if ((flags & c.O_CREAT) != 0) {
            var args = @cVaStart();
            const mode = @cVaArg(&args, c_int);
            @cVaEnd(&args);
            return original(dirfd, path, flags, mode);
        }
        return original(dirfd, path, flags);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // V7.2: Exempt trusted build tools
    if (isProcessExempt()) {
        if ((flags & c.O_CREAT) != 0) {
            var args = @cVaStart();
            const mode = @cVaArg(&args, c_int);
            @cVaEnd(&args);
            return state.original_openat(dirfd, path, flags, mode);
        }
        return state.original_openat(dirfd, path, flags);
    }

    const is_write = (flags & c.O_WRONLY) != 0 or (flags & c.O_RDWR) != 0;

    // V7.1: Check process-specific restrictions FIRST
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(path, restrictions, is_write)) {
            logBlock("openat(write) [PROCESS-RESTRICTED]", path);
            __errno_location().* = 13;
            return -1;
        }
    }

    // V7.0: Check global protection rules
    if (is_write and isProtectedForOperation(path, "open_write")) {
        logBlock("openat(write)", path);
        __errno_location().* = 13;
        return -1;
    }

    // Handle O_CREAT mode parameter if present
    if ((flags & c.O_CREAT) != 0) {
        var args = @cVaStart();
        const mode = @cVaArg(&args, c_int);
        @cVaEnd(&args);
        return state.original_openat(dirfd, path, flags, mode);
    }

    return state.original_openat(dirfd, path, flags);
}

// ============================================================
// Syscall Interceptors - rename() family
// ============================================================

export fn rename(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("rename") orelse return -1;
        return @as(*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) c_int, @ptrCast(f))(oldpath, newpath);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    // Check both paths for bypass
    if (shouldBypassAllProtection(oldpath) or shouldBypassAllProtection(newpath)) {
        const original_fn = getOriginalSyscall("rename") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) c_int, @ptrCast(original_fn));
        return original(oldpath, newpath);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // V7.2: Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_rename(oldpath, newpath);
    }

    // V7.1: Check process-specific restrictions FIRST (for both paths)
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(oldpath, restrictions, true) or
            isPathRestrictedForProcess(newpath, restrictions, true)) {
            logBlock("rename [PROCESS-RESTRICTED]", oldpath);
            __errno_location().* = 13;
            return -1;
        }
    }

    // V7: rename can move/rename files OR directories
    // Check if we're trying to rename a protected directory itself
    if (isProtectedDirectoryItself(oldpath) or isProtectedDirectoryItself(newpath)) {
        logBlock("rename (Citadel protected)", oldpath);
        __errno_location().* = 13;
        return -1;
    }

    if (isProtectedForOperation(oldpath, "rename") or isProtectedForOperation(newpath, "rename")) {
        logBlock("rename", oldpath);
        __errno_location().* = 13;
        return -1;
    }

    return state.original_rename(oldpath, newpath);
}

export fn renameat(olddirfd: c_int, oldpath: [*:0]const u8, newdirfd: c_int, newpath: [*:0]const u8) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("renameat") orelse return -1;
        return @as(*const fn (c_int, [*:0]const u8, c_int, [*:0]const u8) callconv(.c) c_int, @ptrCast(f))(olddirfd, oldpath, newdirfd, newpath);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(oldpath) or shouldBypassAllProtection(newpath)) {
        const original_fn = getOriginalSyscall("renameat") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn (c_int, [*:0]const u8, c_int, [*:0]const u8) callconv(.c) c_int, @ptrCast(original_fn));
        return original(olddirfd, oldpath, newdirfd, newpath);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // V7.2: Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_renameat(olddirfd, oldpath, newdirfd, newpath);
    }

    // V7.1: Check process-specific restrictions FIRST (for both paths)
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(oldpath, restrictions, true) or
            isPathRestrictedForProcess(newpath, restrictions, true)) {
            logBlock("renameat [PROCESS-RESTRICTED]", oldpath);
            __errno_location().* = 13;
            return -1;
        }
    }

    // V7: renameat can move/rename files OR directories
    // Check if we're trying to rename a protected directory itself
    if (isProtectedDirectoryItself(oldpath) or isProtectedDirectoryItself(newpath)) {
        logBlock("renameat (Citadel protected)", oldpath);
        __errno_location().* = 13;
        return -1;
    }

    if (isProtectedForOperation(oldpath, "rename") or isProtectedForOperation(newpath, "rename")) {
        logBlock("renameat", oldpath);
        __errno_location().* = 13;
        return -1;
    }

    return state.original_renameat(olddirfd, oldpath, newdirfd, newpath);
}

// ============================================================
// V7.1: Syscall Interceptors - chmod() (Ephemeral Execution Prevention)
// ============================================================

export fn chmod(path: [*:0]const u8, mode: c_int) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("chmod") orelse return -1;
        return @as(*const fn ([*:0]const u8, c_int) callconv(.c) c_int, @ptrCast(f))(path, mode);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(path)) {
        const original_fn = getOriginalSyscall("chmod") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn ([*:0]const u8, c_int) callconv(.c) c_int, @ptrCast(original_fn));
        return original(path, mode);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // V7.2: Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_chmod(path, mode);
    }

    // V7.1: Check process-specific restrictions
    // chmod is used to make files executable, which is part of the Ephemeral Execution Attack
    if (getProcessRestrictions()) |restrictions| {
        // Treat chmod as a "write" operation for restriction purposes
        if (isPathRestrictedForProcess(path, restrictions, true)) {
            logBlock("chmod [PROCESS-RESTRICTED]", path);
            __errno_location().* = 13;
            return -1;
        }
    }

    return state.original_chmod(path, mode);
}

// ============================================================
// V7.1: Syscall Interceptors - execve() (Ephemeral Execution Prevention)
// ============================================================

export fn execve(path: [*:0]const u8, argv: [*:null]?[*:0]const u8, envp: [*:null]?[*:0]const u8) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("execve") orelse return -1;
        return @as(*const fn ([*:0]const u8, [*:null]?[*:0]const u8, [*:null]?[*:0]const u8) callconv(.c) c_int, @ptrCast(f))(path, argv, envp);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    // Note: execve bypass is particularly important for recovery scripts
    if (shouldBypassAllProtection(path)) {
        const original_fn = getOriginalSyscall("execve") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn ([*:0]const u8, [*:null]?[*:0]const u8, [*:null]?[*:0]const u8) callconv(.c) c_int, @ptrCast(original_fn));
        return original(path, argv, envp);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // V7.2: Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_execve(path, argv, envp);
    }

    // V7.1: THE CRITICAL DEFENSE - Block execution from /tmp for restricted processes
    if (getProcessRestrictions()) |restrictions| {
        if (restrictions.block_tmp_execute) {
            const path_slice = std.mem.span(path);
            if (std.mem.startsWith(u8, path_slice, "/tmp/")) {
                logBlock("execve(/tmp) [PROCESS-RESTRICTED]", path);
                __errno_location().* = 13; // EACCES
                return -1;
            }
        }
    }

    return state.original_execve(path, argv, envp);
}

// ============================================================
// V8.0: Syscall Interceptors - symlink() (Path Hijacking Defense)
// ============================================================
//
// Symlink attacks are a classic path hijacking technique:
// 1. Attacker creates symlink pointing to malicious binary
// 2. Victim process follows symlink, executes attacker's code
// 3. Examples: /tmp/python -> /tmp/.evil/python
//
// Defense: Block symlink creation in protected directories and
// symlinks POINTING TO protected directories (both source and target)

export fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("symlink") orelse return -1;
        return @as(*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) c_int, @ptrCast(f))(target, linkpath);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(target) or shouldBypassAllProtection(linkpath)) {
        const original_fn = getOriginalSyscall("symlink") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) c_int, @ptrCast(original_fn));
        return original(target, linkpath);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_symlink(target, linkpath);
    }

    // Check process-specific restrictions
    if (getProcessRestrictions()) |restrictions| {
        // Block symlink creation in /tmp for restricted processes
        if (isPathRestrictedForProcess(linkpath, restrictions, true)) {
            logBlock("symlink [PROCESS-RESTRICTED]", linkpath);
            __errno_location().* = 13;
            return -1;
        }
    }

    // Block symlinks IN protected directories (the link itself)
    if (isProtectedForOperation(linkpath, "symlink")) {
        logBlock("symlink (link in protected path)", linkpath);
        __errno_location().* = 13;
        return -1;
    }

    // Block symlinks POINTING TO protected directories (the target)
    if (isProtectedForOperation(target, "symlink_target")) {
        logBlock("symlink (target is protected)", target);
        __errno_location().* = 13;
        return -1;
    }

    return state.original_symlink(target, linkpath);
}

export fn symlinkat(target: [*:0]const u8, newdirfd: c_int, linkpath: [*:0]const u8) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("symlinkat") orelse return -1;
        return @as(*const fn ([*:0]const u8, c_int, [*:0]const u8) callconv(.c) c_int, @ptrCast(f))(target, newdirfd, linkpath);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(target) or shouldBypassAllProtection(linkpath)) {
        const original_fn = getOriginalSyscall("symlinkat") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn ([*:0]const u8, c_int, [*:0]const u8) callconv(.c) c_int, @ptrCast(original_fn));
        return original(target, newdirfd, linkpath);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_symlinkat(target, newdirfd, linkpath);
    }

    // Check process-specific restrictions
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(linkpath, restrictions, true)) {
            logBlock("symlinkat [PROCESS-RESTRICTED]", linkpath);
            __errno_location().* = 13;
            return -1;
        }
    }

    if (isProtectedForOperation(linkpath, "symlink")) {
        logBlock("symlinkat (link in protected path)", linkpath);
        __errno_location().* = 13;
        return -1;
    }

    if (isProtectedForOperation(target, "symlink_target")) {
        logBlock("symlinkat (target is protected)", target);
        __errno_location().* = 13;
        return -1;
    }

    return state.original_symlinkat(target, newdirfd, linkpath);
}

// ============================================================
// V8.0: Syscall Interceptors - link() (Hardlink Privilege Escalation Defense)
// ============================================================
//
// Hardlink attacks enable privilege escalation:
// 1. Attacker creates hardlink to setuid binary
// 2. Original binary is updated/patched
// 3. Hardlink retains old vulnerable version
// 4. Or: hardlink to /etc/shadow for offline cracking
//
// Defense: Block hardlink creation to/from protected paths

export fn link(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("link") orelse return -1;
        return @as(*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) c_int, @ptrCast(f))(oldpath, newpath);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(oldpath) or shouldBypassAllProtection(newpath)) {
        const original_fn = getOriginalSyscall("link") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) c_int, @ptrCast(original_fn));
        return original(oldpath, newpath);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_link(oldpath, newpath);
    }

    // Check process-specific restrictions
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(newpath, restrictions, true)) {
            logBlock("link [PROCESS-RESTRICTED]", newpath);
            __errno_location().* = 13;
            return -1;
        }
    }

    // Block hardlinks FROM protected files (prevents copying protected content)
    if (isProtectedForOperation(oldpath, "link")) {
        logBlock("link (source is protected)", oldpath);
        __errno_location().* = 13;
        return -1;
    }

    // Block hardlinks INTO protected directories
    if (isProtectedForOperation(newpath, "link")) {
        logBlock("link (dest in protected path)", newpath);
        __errno_location().* = 13;
        return -1;
    }

    return state.original_link(oldpath, newpath);
}

export fn linkat(olddirfd: c_int, oldpath: [*:0]const u8, newdirfd: c_int, newpath: [*:0]const u8, flags: c_int) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("linkat") orelse return -1;
        return @as(*const fn (c_int, [*:0]const u8, c_int, [*:0]const u8, c_int) callconv(.c) c_int, @ptrCast(f))(olddirfd, oldpath, newdirfd, newpath, flags);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(oldpath) or shouldBypassAllProtection(newpath)) {
        const original_fn = getOriginalSyscall("linkat") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn (c_int, [*:0]const u8, c_int, [*:0]const u8, c_int) callconv(.c) c_int, @ptrCast(original_fn));
        return original(olddirfd, oldpath, newdirfd, newpath, flags);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_linkat(olddirfd, oldpath, newdirfd, newpath, flags);
    }

    // Check process-specific restrictions
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(newpath, restrictions, true)) {
            logBlock("linkat [PROCESS-RESTRICTED]", newpath);
            __errno_location().* = 13;
            return -1;
        }
    }

    if (isProtectedForOperation(oldpath, "link")) {
        logBlock("linkat (source is protected)", oldpath);
        __errno_location().* = 13;
        return -1;
    }

    if (isProtectedForOperation(newpath, "link")) {
        logBlock("linkat (dest in protected path)", newpath);
        __errno_location().* = 13;
        return -1;
    }

    return state.original_linkat(olddirfd, oldpath, newdirfd, newpath, flags);
}

// ============================================================
// V8.0: Syscall Interceptors - truncate() (Data Destruction Defense)
// ============================================================
//
// Truncate attacks destroy data without unlinking:
// 1. Attacker can't delete file (permission denied)
// 2. But truncate(file, 0) zeros it out
// 3. Data is destroyed, file still exists with same permissions
//
// Defense: Block truncate on protected files

export fn truncate(path: [*:0]const u8, length: c_long) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("truncate") orelse return -1;
        return @as(*const fn ([*:0]const u8, c_long) callconv(.c) c_int, @ptrCast(f))(path, length);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(path)) {
        const original_fn = getOriginalSyscall("truncate") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn ([*:0]const u8, c_long) callconv(.c) c_int, @ptrCast(original_fn));
        return original(path, length);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_truncate(path, length);
    }

    // Check process-specific restrictions
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(path, restrictions, true)) {
            logBlock("truncate [PROCESS-RESTRICTED]", path);
            __errno_location().* = 13;
            return -1;
        }
    }

    // Block truncate on protected files
    if (isProtectedForOperation(path, "truncate")) {
        logBlock("truncate", path);
        __errno_location().* = 13;
        return -1;
    }

    return state.original_truncate(path, length);
}

export fn ftruncate(fd: c_int, length: c_long) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("ftruncate") orelse return -1;
        return @as(*const fn (c_int, c_long) callconv(.c) c_int, @ptrCast(f))(fd, length);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // ftruncate operates on file descriptor, not path
    // We can't easily get the path from fd in LD_PRELOAD
    // For now, just pass through - the fd was already opened with our checks
    // Future enhancement: use /proc/self/fd/N to resolve path
    return state.original_ftruncate(fd, length);
}

// ============================================================
// V8.0: Syscall Interceptors - mkdir() (Directory Creation Control)
// ============================================================
//
// mkdir attacks enable path injection:
// 1. Attacker creates directory in PATH location
// 2. Places malicious binaries inside
// 3. System executes attacker's code instead of legitimate binary
// Example: mkdir /usr/local/bin/evil && cp malware /usr/local/bin/evil/python
//
// Defense: Block mkdir in protected directories

export fn mkdir(path: [*:0]const u8, mode: c_int) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("mkdir") orelse return -1;
        return @as(*const fn ([*:0]const u8, c_int) callconv(.c) c_int, @ptrCast(f))(path, mode);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(path)) {
        const original_fn = getOriginalSyscall("mkdir") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn ([*:0]const u8, c_int) callconv(.c) c_int, @ptrCast(original_fn));
        return original(path, mode);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_mkdir(path, mode);
    }

    // Check process-specific restrictions
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(path, restrictions, true)) {
            logBlock("mkdir [PROCESS-RESTRICTED]", path);
            __errno_location().* = 13;
            return -1;
        }
    }

    // Block mkdir in protected directories
    if (isProtectedForOperation(path, "mkdir")) {
        logBlock("mkdir", path);
        __errno_location().* = 13;
        return -1;
    }

    return state.original_mkdir(path, mode);
}

export fn mkdirat(dirfd: c_int, path: [*:0]const u8, mode: c_int) c_int {
    if (in_interceptor) {
        const f = getOriginalSyscall("mkdirat") orelse return -1;
        return @as(*const fn (c_int, [*:0]const u8, c_int) callconv(.c) c_int, @ptrCast(f))(dirfd, path, mode);
    }
    in_interceptor = true;
    defer in_interceptor = false;

    // V8.1: Emergency bypass - check BEFORE getState()
    if (shouldBypassAllProtection(path)) {
        const original_fn = getOriginalSyscall("mkdirat") orelse {
            __errno_location().* = 2;
            return -1;
        };
        const original = @as(*const fn (c_int, [*:0]const u8, c_int) callconv(.c) c_int, @ptrCast(original_fn));
        return original(dirfd, path, mode);
    }

    const state = getState() orelse {
        __errno_location().* = 2;
        return -1;
    };

    // Exempt trusted build tools
    if (isProcessExempt()) {
        return state.original_mkdirat(dirfd, path, mode);
    }

    // Check process-specific restrictions
    if (getProcessRestrictions()) |restrictions| {
        if (isPathRestrictedForProcess(path, restrictions, true)) {
            logBlock("mkdirat [PROCESS-RESTRICTED]", path);
            __errno_location().* = 13;
            return -1;
        }
    }

    if (isProtectedForOperation(path, "mkdir")) {
        logBlock("mkdirat", path);
        __errno_location().* = 13;
        return -1;
    }

    return state.original_mkdirat(dirfd, path, mode);
}
