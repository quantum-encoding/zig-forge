//! libmacwarden.dylib - Guardian Shield for macOS
//!
//! macOS port of The Warden using DYLD interposition
//! Provides runtime syscall interception for file protection
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! Config file: /etc/warden/macwarden.conf (or MACWARDEN_CONFIG env var)
//!
//! Config format (line-based):
//!   # Comment
//!   enabled=true
//!   verbose=false
//!   protected=/path/to/protect
//!   whitelist=/path/to/allow
//!   self_preserve=substring

const std = @import("std");

// =============================================================================
// Raw Syscall Implementation (ARM64 macOS)
// =============================================================================
//
// CRITICAL: We must use raw syscalls for any I/O in the interposition hooks
// to avoid infinite recursion. DYLD interposition replaces ALL calls to the
// intercepted functions, including calls from libc itself.

inline fn raw_write(fd: c_int, buf: [*]const u8, count: usize) isize {
    return asm volatile (
        \\ movz x16, #0x0004
        \\ movk x16, #0x0200, lsl #16
        \\ svc #0x80
        : [ret] "={x0}" (-> isize),
        : [fd] "{x0}" (@as(usize, @intCast(fd))),
          [buf] "{x1}" (@intFromPtr(buf)),
          [count] "{x2}" (count),
    );
}

inline fn raw_open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int {
    const result = asm volatile (
        \\ movz x16, #0x0005
        \\ movk x16, #0x0200, lsl #16
        \\ svc #0x80
        : [ret] "={x0}" (-> isize),
        : [path] "{x0}" (@intFromPtr(path)),
          [flags] "{x1}" (@as(usize, @intCast(flags))),
          [mode] "{x2}" (@as(usize, @intCast(mode))),
    );
    return @intCast(result);
}

inline fn raw_close(fd: c_int) c_int {
    const result = asm volatile (
        \\ movz x16, #0x0006
        \\ movk x16, #0x0200, lsl #16
        \\ svc #0x80
        : [ret] "={x0}" (-> isize),
        : [fd] "{x0}" (@as(usize, @intCast(fd))),
    );
    return @intCast(result);
}

inline fn raw_read(fd: c_int, buf: [*]u8, count: usize) isize {
    return asm volatile (
        \\ movz x16, #0x0003
        \\ movk x16, #0x0200, lsl #16
        \\ svc #0x80
        : [ret] "={x0}" (-> isize),
        : [fd] "{x0}" (@as(usize, @intCast(fd))),
          [buf] "{x1}" (@intFromPtr(buf)),
          [count] "{x2}" (count),
    );
}

inline fn raw_access(path: [*:0]const u8, mode: c_int) c_int {
    const result = asm volatile (
        \\ movz x16, #0x0021
        \\ movk x16, #0x0200, lsl #16
        \\ svc #0x80
        : [ret] "={x0}" (-> isize),
        : [path] "{x0}" (@intFromPtr(path)),
          [mode] "{x1}" (@as(usize, @intCast(mode))),
    );
    return @intCast(result);
}

// =============================================================================
// Safe Debug Output (uses raw syscall)
// =============================================================================

fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = raw_write(2, msg.ptr, msg.len);
}

// =============================================================================
// Configuration - Static Storage
// =============================================================================

const MAX_PATHS = 64;
const MAX_PATH_LEN = 256;

const CONFIG_PATH_DEFAULT = "/etc/warden/macwarden.conf";
const EMERGENCY_KILL_SWITCH = "/tmp/.warden_emergency_disable";

// Static path storage (no allocator needed)
var protected_paths_storage: [MAX_PATHS][MAX_PATH_LEN]u8 = undefined;
var protected_paths_lens: [MAX_PATHS]usize = [_]usize{0} ** MAX_PATHS;
var protected_paths_count: usize = 0;

var whitelist_storage: [MAX_PATHS][MAX_PATH_LEN]u8 = undefined;
var whitelist_lens: [MAX_PATHS]usize = [_]usize{0} ** MAX_PATHS;
var whitelist_count: usize = 0;

var self_preserve_storage: [MAX_PATHS][MAX_PATH_LEN]u8 = undefined;
var self_preserve_lens: [MAX_PATHS]usize = [_]usize{0} ** MAX_PATHS;
var self_preserve_count: usize = 0;

var config_enabled: bool = true;
var config_verbose: bool = false;
var config_loaded: bool = false;
var emergency_disabled: bool = false;

const block_emoji = "\xf0\x9f\x9b\xa1\xef\xb8\x8f"; // Shield emoji

// =============================================================================
// Default Configuration
// =============================================================================

fn loadDefaultConfig() void {
    // Default protected paths
    const default_protected = [_][]const u8{
        "/etc/",
        "/System/",
        "/Library/",
    };

    for (default_protected) |path| {
        addProtectedPath(path);
    }

    // Default whitelist
    const default_whitelist = [_][]const u8{
        "/usr/local/",
        "/var/folders/",
        "/tmp/",
        "/private/tmp/",
    };

    for (default_whitelist) |path| {
        addWhitelistPath(path);
    }

    // Default self-preservation
    const default_self = [_][]const u8{
        "libmacwarden",
        "macwarden.conf",
        "warden_emergency",
    };

    for (default_self) |path| {
        addSelfPreservePath(path);
    }
}

fn addProtectedPath(path: []const u8) void {
    if (protected_paths_count >= MAX_PATHS) return;
    if (path.len >= MAX_PATH_LEN) return;

    @memcpy(protected_paths_storage[protected_paths_count][0..path.len], path);
    protected_paths_lens[protected_paths_count] = path.len;
    protected_paths_count += 1;
}

fn addWhitelistPath(path: []const u8) void {
    if (whitelist_count >= MAX_PATHS) return;
    if (path.len >= MAX_PATH_LEN) return;

    @memcpy(whitelist_storage[whitelist_count][0..path.len], path);
    whitelist_lens[whitelist_count] = path.len;
    whitelist_count += 1;
}

fn addSelfPreservePath(path: []const u8) void {
    if (self_preserve_count >= MAX_PATHS) return;
    if (path.len >= MAX_PATH_LEN) return;

    @memcpy(self_preserve_storage[self_preserve_count][0..path.len], path);
    self_preserve_lens[self_preserve_count] = path.len;
    self_preserve_count += 1;
}

// =============================================================================
// Config File Parser (uses raw syscalls)
// =============================================================================

fn loadConfigFile() void {
    if (config_loaded) return;
    config_loaded = true;

    // Get config path from env or use default
    var config_path_buf: [MAX_PATH_LEN]u8 = undefined;
    var config_path: [*:0]const u8 = undefined;

    if (std.c.getenv("MACWARDEN_CONFIG")) |env_path| {
        config_path = env_path;
    } else {
        @memcpy(config_path_buf[0..CONFIG_PATH_DEFAULT.len], CONFIG_PATH_DEFAULT);
        config_path_buf[CONFIG_PATH_DEFAULT.len] = 0;
        config_path = @ptrCast(&config_path_buf);
    }

    // Try to open config file
    const fd = raw_open(config_path, 0, 0); // O_RDONLY = 0
    if (fd < 0) {
        // Config file not found, use defaults
        loadDefaultConfig();
        return;
    }
    defer _ = raw_close(fd);

    // Read config file
    var file_buf: [8192]u8 = undefined;
    const bytes_read = raw_read(fd, &file_buf, file_buf.len - 1);
    if (bytes_read <= 0) {
        loadDefaultConfig();
        return;
    }

    file_buf[@intCast(bytes_read)] = 0;
    const content = file_buf[0..@intCast(bytes_read)];

    // Parse line by line
    var line_start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n' or i == content.len - 1) {
            var line_end = i;
            if (c == '\n' and i > 0) line_end = i;
            if (i == content.len - 1 and c != '\n') line_end = i + 1;

            if (line_end > line_start) {
                const line = content[line_start..line_end];
                parseLine(line);
            }
            line_start = i + 1;
        }
    }

    // If no protected paths were loaded, add defaults
    if (protected_paths_count == 0) {
        loadDefaultConfig();
    }
}

fn parseLine(line: []const u8) void {
    // Skip empty lines and comments
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return;

    // Parse key=value
    if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
        const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

        if (std.mem.eql(u8, key, "enabled")) {
            config_enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "verbose")) {
            config_verbose = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "protected")) {
            addProtectedPath(value);
        } else if (std.mem.eql(u8, key, "whitelist")) {
            addWhitelistPath(value);
        } else if (std.mem.eql(u8, key, "self_preserve")) {
            addSelfPreservePath(value);
        }
    }
}

// =============================================================================
// Emergency Bypass Mechanisms
// =============================================================================

fn checkEmergencyBypass() bool {
    // Already disabled
    if (emergency_disabled) return true;

    // Check environment variable
    if (std.c.getenv("WARDEN_DISABLE")) |val| {
        const v = std.mem.sliceTo(val, 0);
        if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) {
            return true;
        }
    }

    // Check magic kill switch file (using raw syscall)
    var kill_path: [64]u8 = undefined;
    @memcpy(kill_path[0..EMERGENCY_KILL_SWITCH.len], EMERGENCY_KILL_SWITCH);
    kill_path[EMERGENCY_KILL_SWITCH.len] = 0;
    if (raw_access(@ptrCast(&kill_path), 0) == 0) {
        emergency_disabled = true;
        return true;
    }

    return false;
}

// Self-preservation - BLOCK deletion of warden components
fn isSelfPreserved(path: [*:0]const u8) bool {
    const path_slice = std.mem.span(path);
    var i: usize = 0;
    while (i < self_preserve_count) : (i += 1) {
        const pattern = self_preserve_storage[i][0..self_preserve_lens[i]];
        if (std.mem.indexOf(u8, path_slice, pattern)) |_| {
            return true;
        }
    }
    return false;
}

// =============================================================================
// Path Protection Logic
// =============================================================================

fn isWhitelisted(path: [*:0]const u8) bool {
    const path_slice = std.mem.span(path);

    var i: usize = 0;
    while (i < whitelist_count) : (i += 1) {
        const white = whitelist_storage[i][0..whitelist_lens[i]];
        if (std.mem.startsWith(u8, path_slice, white)) {
            return true;
        }
    }
    return false;
}

fn isProtected(path: [*:0]const u8) bool {
    if (!config_enabled) return false;

    // Whitelist takes precedence
    if (isWhitelisted(path)) return false;

    const path_slice = std.mem.span(path);

    var i: usize = 0;
    while (i < protected_paths_count) : (i += 1) {
        const protected = protected_paths_storage[i][0..protected_paths_lens[i]];
        if (std.mem.startsWith(u8, path_slice, protected)) {
            return true;
        }
    }

    return false;
}

fn logBlock(operation: []const u8, path: [*:0]const u8) void {
    // Always log blocks - this is important security info
    debugPrint("[libmacwarden] {s} BLOCKED {s}: {s}\n", .{
        block_emoji,
        operation,
        std.mem.span(path),
    });
}

// =============================================================================
// DYLD Interposition Structure
// =============================================================================

const InterposeTuple = extern struct {
    replacement: *const anyopaque,
    replacee: *const anyopaque,
};

// =============================================================================
// Original Function Declarations
// =============================================================================

extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
extern "c" fn link(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int;
extern "c" fn truncate(path: [*:0]const u8, length: i64) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;

// =============================================================================
// Interposed Functions
// =============================================================================

fn warden_unlink(path: [*:0]const u8) callconv(.c) c_int {
    if (checkEmergencyBypass()) {
        return unlink(path);
    }

    // Self-preservation: block deletion of warden components
    if (isSelfPreserved(path)) {
        logBlock("unlink(self-protect)", path);
        std.c._errno().* = 13; // EACCES
        return -1;
    }

    if (isProtected(path)) {
        logBlock("unlink", path);
        std.c._errno().* = 13; // EACCES
        return -1;
    }

    return unlink(path);
}

fn warden_rmdir(path: [*:0]const u8) callconv(.c) c_int {
    if (checkEmergencyBypass()) {
        return rmdir(path);
    }

    if (isSelfPreserved(path)) {
        logBlock("rmdir(self-protect)", path);
        std.c._errno().* = 13;
        return -1;
    }

    if (isProtected(path)) {
        logBlock("rmdir", path);
        std.c._errno().* = 13;
        return -1;
    }

    return rmdir(path);
}

fn warden_rename(oldpath: [*:0]const u8, newpath: [*:0]const u8) callconv(.c) c_int {
    if (checkEmergencyBypass()) {
        return rename(oldpath, newpath);
    }

    if (isSelfPreserved(oldpath) or isSelfPreserved(newpath)) {
        logBlock("rename(self-protect)", oldpath);
        std.c._errno().* = 13;
        return -1;
    }

    if (isProtected(oldpath) or isProtected(newpath)) {
        logBlock("rename", oldpath);
        std.c._errno().* = 13;
        return -1;
    }

    return rename(oldpath, newpath);
}

fn warden_symlink(target: [*:0]const u8, linkpath: [*:0]const u8) callconv(.c) c_int {
    if (checkEmergencyBypass()) {
        return symlink(target, linkpath);
    }

    if (isProtected(linkpath)) {
        logBlock("symlink", linkpath);
        std.c._errno().* = 13;
        return -1;
    }

    if (isProtected(target)) {
        logBlock("symlink(target)", target);
        std.c._errno().* = 13;
        return -1;
    }

    return symlink(target, linkpath);
}

fn warden_link(oldpath: [*:0]const u8, newpath: [*:0]const u8) callconv(.c) c_int {
    if (checkEmergencyBypass()) {
        return link(oldpath, newpath);
    }

    if (isProtected(oldpath) or isProtected(newpath)) {
        logBlock("link", oldpath);
        std.c._errno().* = 13;
        return -1;
    }

    return link(oldpath, newpath);
}

fn warden_truncate(path: [*:0]const u8, length: i64) callconv(.c) c_int {
    if (checkEmergencyBypass()) {
        return truncate(path, length);
    }

    if (isSelfPreserved(path)) {
        logBlock("truncate(self-protect)", path);
        std.c._errno().* = 13;
        return -1;
    }

    if (isProtected(path)) {
        logBlock("truncate", path);
        std.c._errno().* = 13;
        return -1;
    }

    return truncate(path, length);
}

fn warden_mkdir(path: [*:0]const u8, mode: c_uint) callconv(.c) c_int {
    if (checkEmergencyBypass()) {
        return mkdir(path, mode);
    }

    if (isProtected(path)) {
        logBlock("mkdir", path);
        std.c._errno().* = 13;
        return -1;
    }

    return mkdir(path, mode);
}

fn warden_chmod(path: [*:0]const u8, mode: c_uint) callconv(.c) c_int {
    if (checkEmergencyBypass()) {
        return chmod(path, mode);
    }

    if (isSelfPreserved(path)) {
        logBlock("chmod(self-protect)", path);
        std.c._errno().* = 13;
        return -1;
    }

    if (isProtected(path)) {
        logBlock("chmod", path);
        std.c._errno().* = 13;
        return -1;
    }

    return chmod(path, mode);
}

fn warden_open(path: [*:0]const u8, flags: c_int, mode: c_uint) callconv(.c) c_int {
    if (checkEmergencyBypass()) {
        return open(path, flags, mode);
    }

    // Only block if writing
    const O_WRONLY = 0x0001;
    const O_RDWR = 0x0002;
    const O_CREAT = 0x0200;
    const O_TRUNC = 0x0400;

    const is_write = (flags & O_WRONLY) != 0 or
        (flags & O_RDWR) != 0 or
        (flags & O_CREAT) != 0 or
        (flags & O_TRUNC) != 0;

    if (is_write and isSelfPreserved(path)) {
        logBlock("open(self-protect)", path);
        std.c._errno().* = 13;
        return -1;
    }

    if (is_write and isProtected(path)) {
        logBlock("open(write)", path);
        std.c._errno().* = 13;
        return -1;
    }

    return open(path, flags, mode);
}

// =============================================================================
// DYLD Interposition Table
// =============================================================================

export const warden_unlink_interpose linksection("__DATA,__interpose") = InterposeTuple{
    .replacement = @ptrCast(&warden_unlink),
    .replacee = @ptrCast(&unlink),
};

export const warden_rmdir_interpose linksection("__DATA,__interpose") = InterposeTuple{
    .replacement = @ptrCast(&warden_rmdir),
    .replacee = @ptrCast(&rmdir),
};

export const warden_rename_interpose linksection("__DATA,__interpose") = InterposeTuple{
    .replacement = @ptrCast(&warden_rename),
    .replacee = @ptrCast(&rename),
};

export const warden_symlink_interpose linksection("__DATA,__interpose") = InterposeTuple{
    .replacement = @ptrCast(&warden_symlink),
    .replacee = @ptrCast(&symlink),
};

export const warden_link_interpose linksection("__DATA,__interpose") = InterposeTuple{
    .replacement = @ptrCast(&warden_link),
    .replacee = @ptrCast(&link),
};

export const warden_truncate_interpose linksection("__DATA,__interpose") = InterposeTuple{
    .replacement = @ptrCast(&warden_truncate),
    .replacee = @ptrCast(&truncate),
};

export const warden_mkdir_interpose linksection("__DATA,__interpose") = InterposeTuple{
    .replacement = @ptrCast(&warden_mkdir),
    .replacee = @ptrCast(&mkdir),
};

export const warden_chmod_interpose linksection("__DATA,__interpose") = InterposeTuple{
    .replacement = @ptrCast(&warden_chmod),
    .replacee = @ptrCast(&chmod),
};

export const warden_open_interpose linksection("__DATA,__interpose") = InterposeTuple{
    .replacement = @ptrCast(&warden_open),
    .replacee = @ptrCast(&open),
};

// =============================================================================
// Library Initialization
// =============================================================================

fn init() callconv(.c) void {
    // Load configuration file
    loadConfigFile();

    // Check for verbose mode (env var overrides config)
    if (std.c.getenv("WARDEN_VERBOSE")) |val| {
        const v = std.mem.sliceTo(val, 0);
        if (std.mem.eql(u8, v, "1")) {
            config_verbose = true;
        }
    }

    // Print startup message if verbose
    if (config_verbose) {
        debugPrint("[libmacwarden] Guardian Shield Active - macOS Edition\n", .{});
        debugPrint("[libmacwarden] Config: {d} protected, {d} whitelisted\n", .{
            protected_paths_count,
            whitelist_count,
        });
        debugPrint("[libmacwarden] Recovery: touch {s} | WARDEN_DISABLE=1\n", .{EMERGENCY_KILL_SWITCH});
    }
}

// Constructor attribute to run on library load
export const _init_ptr linksection("__DATA,__mod_init_func") = &init;
