//! zchcon - Change SELinux security context
//!
//! Change the SELinux security context of files.
//! Uses extended attributes (security.selinux) directly.

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

const VERSION = "1.0.0";

// macOS xattr API has extra (position, options) params; Linux has separate l* variants.
// We declare platform-specific externs and wrap in helper functions.
const is_macos = builtin.os.tag == .macos;

const XATTR_NOFOLLOW: u32 = 0x0001; // macOS: don't follow symlinks

extern "c" fn getxattr(path: [*:0]const u8, name: [*:0]const u8, value: ?[*]u8, size: usize, ...) isize;
extern "c" fn setxattr(path: [*:0]const u8, name: [*:0]const u8, value: [*]const u8, size: usize, ...) c_int;

fn xgetattr(path: [*:0]const u8, name: [*:0]const u8, value: ?[*]u8, size: usize, nofollow: bool) isize {
    if (is_macos) {
        // macOS: getxattr(path, name, value, size, position, options)
        const opts: u32 = if (nofollow) XATTR_NOFOLLOW else 0;
        return @call(.auto, getxattr, .{ path, name, value, size, @as(u32, 0), opts });
    } else {
        if (nofollow) {
            const lgetxattr = @extern(*const fn ([*:0]const u8, [*:0]const u8, ?[*]u8, usize) callconv(.c) isize, .{ .name = "lgetxattr" });
            return lgetxattr(path, name, value, size);
        }
        return getxattr(path, name, value, size);
    }
}

fn xsetattr(path: [*:0]const u8, name: [*:0]const u8, value: [*]const u8, size: usize, nofollow: bool) c_int {
    if (is_macos) {
        // macOS: setxattr(path, name, value, size, position, options)
        const opts: u32 = if (nofollow) XATTR_NOFOLLOW else 0;
        return @call(.auto, setxattr, .{ path, name, value, size, @as(u32, 0), opts });
    } else {
        if (nofollow) {
            const lsetxattr = @extern(*const fn ([*:0]const u8, [*:0]const u8, [*]const u8, usize, c_int) callconv(.c) c_int, .{ .name = "lsetxattr" });
            return lsetxattr(path, name, value, size, 0);
        }
        return setxattr(path, name, value, size, @as(c_int, 0));
    }
}

const SELINUX_XATTR = "security.selinux";

const Config = struct {
    user: ?[]const u8 = null,
    role: ?[]const u8 = null,
    type_: ?[]const u8 = null,
    range: ?[]const u8 = null,
    context: ?[]const u8 = null,
    reference: ?[]const u8 = null,
    recursive: bool = false,
    verbose: bool = false,
    no_dereference: bool = false,
    files: [64][]const u8 = undefined,
    file_count: usize = 0,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zchcon [OPTION]... CONTEXT FILE...
        \\   or: zchcon [OPTION]... [-u USER] [-r ROLE] [-t TYPE] [-l RANGE] FILE...
        \\   or: zchcon [OPTION]... --reference=RFILE FILE...
        \\Change the SELinux security context of each FILE to CONTEXT.
        \\
        \\Options:
        \\      --dereference      Affect the referent of symlinks (default)
        \\  -h, --no-dereference   Affect symbolic links instead of referents
        \\  -u, --user=USER        Set user in the target security context
        \\  -r, --role=ROLE        Set role in the target security context
        \\  -t, --type=TYPE        Set type in the target security context
        \\  -l, --range=RANGE      Set range in the target security context
        \\      --reference=RFILE  Use RFILE's security context
        \\  -R, --recursive        Operate on files and directories recursively
        \\  -v, --verbose          Output a diagnostic for every file processed
        \\      --help             Display this help and exit
        \\      --version          Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zchcon " ++ VERSION ++ "\n");
}

var g_context_buf: [1024]u8 = undefined;

fn getContext(path: []const u8, no_deref: bool) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;

    const result = xgetattr(path_z, SELINUX_XATTR, &g_context_buf, g_context_buf.len, no_deref);

    if (result < 0) return null;

    // Remove trailing null if present
    var len: usize = @intCast(result);
    if (len > 0 and g_context_buf[len - 1] == 0) len -= 1;

    return g_context_buf[0..len];
}

fn setContext(path: []const u8, context: []const u8, no_deref: bool) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;

    const result = xsetattr(path_z, SELINUX_XATTR, context.ptr, context.len, no_deref);

    return result == 0;
}

fn buildContext(current: ?[]const u8, cfg: *const Config, buf: []u8) ?[]const u8 {
    // SELinux context format: user:role:type:range
    // If we have specific components to change, modify them

    if (cfg.context) |ctx| {
        return ctx;
    }

    const base = current orelse "system_u:object_r:unlabeled_t:s0";

    // Parse current context
    var user: []const u8 = "";
    var role: []const u8 = "";
    var type_: []const u8 = "";
    var range: []const u8 = "";

    var parts: [4][]const u8 = undefined;
    var part_count: usize = 0;
    var start: usize = 0;

    for (base, 0..) |c, i| {
        if (c == ':') {
            if (part_count < 4) {
                parts[part_count] = base[start..i];
                part_count += 1;
            }
            start = i + 1;
        }
    }
    if (part_count < 4 and start < base.len) {
        parts[part_count] = base[start..];
        part_count += 1;
    }

    if (part_count >= 1) user = parts[0];
    if (part_count >= 2) role = parts[1];
    if (part_count >= 3) type_ = parts[2];
    if (part_count >= 4) range = parts[3];

    // Apply overrides
    if (cfg.user) |u| user = u;
    if (cfg.role) |r| role = r;
    if (cfg.type_) |t| type_ = t;
    if (cfg.range) |l| range = l;

    // Build new context
    if (range.len > 0) {
        return std.fmt.bufPrint(buf, "{s}:{s}:{s}:{s}", .{ user, role, type_, range }) catch null;
    } else {
        return std.fmt.bufPrint(buf, "{s}:{s}:{s}", .{ user, role, type_ }) catch null;
    }
}

fn processFile(path: []const u8, new_context: []const u8, cfg: *const Config) bool {
    if (cfg.verbose) {
        writeStderr("changing security context of '");
        writeStderr(path);
        writeStderr("'\n");
    }

    if (!setContext(path, new_context, cfg.no_dereference)) {
        writeStderr("zchcon: failed to change context of '");
        writeStderr(path);
        writeStderr("'\n");
        return false;
    }

    return true;
}

pub fn main(init: std.process.Init) !void {
    var cfg = Config{};
    var positional_idx: usize = 0;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var next_opt: enum { none, user, role, type_, range } = .none;
    while (args_iter.next()) |arg| {
        // Handle arguments that follow option flags
        switch (next_opt) {
            .user => {
                cfg.user = arg;
                next_opt = .none;
                continue;
            },
            .role => {
                cfg.role = arg;
                next_opt = .none;
                continue;
            },
            .type_ => {
                cfg.type_ = arg;
                next_opt = .none;
                continue;
            },
            .range => {
                cfg.range = arg;
                next_opt = .none;
                continue;
            },
            .none => {},
        }

        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "--recursive")) {
            cfg.recursive = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--no-dereference")) {
            cfg.no_dereference = true;
        } else if (std.mem.eql(u8, arg, "--dereference")) {
            cfg.no_dereference = false;
        } else if (std.mem.eql(u8, arg, "-u")) {
            next_opt = .user;
        } else if (std.mem.startsWith(u8, arg, "--user=")) {
            cfg.user = arg[7..];
        } else if (std.mem.eql(u8, arg, "-r")) {
            next_opt = .role;
        } else if (std.mem.startsWith(u8, arg, "--role=")) {
            cfg.role = arg[7..];
        } else if (std.mem.eql(u8, arg, "-t")) {
            next_opt = .type_;
        } else if (std.mem.startsWith(u8, arg, "--type=")) {
            cfg.type_ = arg[7..];
        } else if (std.mem.eql(u8, arg, "-l")) {
            next_opt = .range;
        } else if (std.mem.startsWith(u8, arg, "--range=")) {
            cfg.range = arg[8..];
        } else if (std.mem.startsWith(u8, arg, "--reference=")) {
            cfg.reference = arg[12..];
        } else if (arg.len > 0 and arg[0] != '-') {
            // First positional could be context if no -u/-r/-t/-l/--reference
            if (positional_idx == 0 and cfg.user == null and cfg.role == null and
                cfg.type_ == null and cfg.range == null and cfg.reference == null)
            {
                cfg.context = arg;
            } else {
                if (cfg.file_count < cfg.files.len) {
                    cfg.files[cfg.file_count] = arg;
                    cfg.file_count += 1;
                }
            }
            positional_idx += 1;
        }
    }

    if (cfg.file_count == 0) {
        writeStderr("zchcon: missing operand\n");
        writeStderr("Try 'zchcon --help' for more information.\n");
        std.process.exit(1);
    }

    // Get reference context if specified
    var ref_context: ?[]const u8 = null;
    if (cfg.reference) |ref| {
        ref_context = getContext(ref, cfg.no_dereference);
        if (ref_context == null) {
            writeStderr("zchcon: failed to get security context of '");
            writeStderr(ref);
            writeStderr("'\n");
            std.process.exit(1);
        }
    }

    var exit_code: u8 = 0;
    var ctx_buf: [1024]u8 = undefined;

    for (cfg.files[0..cfg.file_count]) |path| {
        var current_context: ?[]const u8 = null;

        // If we need to modify specific fields, get current context
        if (cfg.context == null and ref_context == null) {
            current_context = getContext(path, cfg.no_dereference);
        }

        const base = ref_context orelse current_context;
        const new_context = buildContext(base, &cfg, &ctx_buf) orelse {
            writeStderr("zchcon: failed to build context for '");
            writeStderr(path);
            writeStderr("'\n");
            exit_code = 1;
            continue;
        };

        if (!processFile(path, new_context, &cfg)) {
            exit_code = 1;
        }
    }

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
