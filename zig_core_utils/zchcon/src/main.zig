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

// IMPORTANT: the platform xattr calls are ORDINARY (non-variadic) C functions.
// They MUST be declared with their exact fixed signatures. Declaring them
// variadic (`...`) breaks the Apple arm64 calling convention — variadic args
// are passed on the stack there, so `position`/`options` arrive as garbage and
// every setxattr/getxattr returns EINVAL. We therefore bind each platform's
// real prototype via @extern with the correct fixed arity.
//
//   macOS:  ssize_t getxattr(path, name, value, size, u_int32_t position, int options)
//           int     setxattr(path, name, value, size, u_int32_t position, int options)
//   Linux:  ssize_t getxattr (path, name, value, size)   /  l* for no-follow
//           int     setxattr (path, name, value, size, int flags) / l* for no-follow

fn xgetattr(path: [*:0]const u8, name: [*:0]const u8, value: ?[*]u8, size: usize, nofollow: bool) isize {
    if (is_macos) {
        const f = @extern(*const fn ([*:0]const u8, [*:0]const u8, ?[*]u8, usize, u32, c_int) callconv(.c) isize, .{ .name = "getxattr" });
        const opts: c_int = if (nofollow) @intCast(XATTR_NOFOLLOW) else 0;
        return f(path, name, value, size, 0, opts);
    } else {
        if (nofollow) {
            const lgetxattr = @extern(*const fn ([*:0]const u8, [*:0]const u8, ?[*]u8, usize) callconv(.c) isize, .{ .name = "lgetxattr" });
            return lgetxattr(path, name, value, size);
        }
        const getxattr = @extern(*const fn ([*:0]const u8, [*:0]const u8, ?[*]u8, usize) callconv(.c) isize, .{ .name = "getxattr" });
        return getxattr(path, name, value, size);
    }
}

fn xsetattr(path: [*:0]const u8, name: [*:0]const u8, value: [*]const u8, size: usize, nofollow: bool) c_int {
    if (is_macos) {
        const f = @extern(*const fn ([*:0]const u8, [*:0]const u8, [*]const u8, usize, u32, c_int) callconv(.c) c_int, .{ .name = "setxattr" });
        const opts: c_int = if (nofollow) @intCast(XATTR_NOFOLLOW) else 0;
        return f(path, name, value, size, 0, opts);
    } else {
        if (nofollow) {
            const lsetxattr = @extern(*const fn ([*:0]const u8, [*:0]const u8, [*]const u8, usize, c_int) callconv(.c) c_int, .{ .name = "lsetxattr" });
            return lsetxattr(path, name, value, size, 0);
        }
        const setxattr = @extern(*const fn ([*:0]const u8, [*:0]const u8, [*]const u8, usize, c_int) callconv(.c) c_int, .{ .name = "setxattr" });
        return setxattr(path, name, value, size, 0);
    }
}

const SELINUX_XATTR = "security.selinux";

// GNU chcon traversal modes for -R (default -P: never follow symlinks).
const Traversal = enum { P, H, L };

const Config = struct {
    user: ?[]const u8 = null,
    role: ?[]const u8 = null,
    type_: ?[]const u8 = null,
    range: ?[]const u8 = null,
    context: ?[]const u8 = null,
    reference: ?[]const u8 = null,
    recursive: bool = false,
    traversal: Traversal = .P,
    verbose: bool = false,
    no_dereference: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
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
        \\  -H                     If a command line argument is a symbolic link
        \\                           to a directory, traverse it
        \\  -L                     Traverse every symbolic link to a directory
        \\                           encountered
        \\  -P                     Do not traverse any symbolic links (default)
        \\  -v, --verbose          Output a diagnostic for every file processed
        \\      --help             Display this help and exit
        \\      --version          Output version information and exit
        \\
    ;
    // GNU coreutils writes --help/--version to STDOUT and exits 0.
    writeStdout(usage);
}

fn printVersion() void {
    // GNU coreutils writes --version to STDOUT and exits 0.
    writeStdout("zchcon " ++ VERSION ++ "\n");
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

    // libselinux/GNU write the context value with a trailing NUL terminator on
    // the `security.selinux` xattr; readers (including getContext above) expect
    // it. Emit context bytes + one NUL.
    var val_buf: [1025]u8 = undefined;
    if (context.len + 1 > val_buf.len) return false;
    @memcpy(val_buf[0..context.len], context);
    val_buf[context.len] = 0;

    const result = xsetattr(path_z, SELINUX_XATTR, &val_buf, context.len + 1, no_deref);

    return result == 0;
}

fn buildContext(current: ?[]const u8, cfg: *const Config, buf: []u8) ?[]const u8 {
    // SELinux context format: user:role:type[:range]
    // If we have specific components to change, modify them.

    if (cfg.context) |ctx| {
        return ctx;
    }

    const base = current orelse "system_u:object_r:unlabeled_t:s0";

    // Split into at most 4 fields on the FIRST THREE colons only. The 4th field
    // (the MLS/MCS range, e.g. `s0-s0:c0.c1023`) may itself contain ':' and must
    // be kept verbatim — SELinux context grammar reserves only the first three
    // colons as field separators (see libselinux context_new / policycoreutils).
    var user: []const u8 = "";
    var role: []const u8 = "";
    var type_: []const u8 = "";
    var range: []const u8 = "";

    var rest = base;
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
        user = rest[0..i];
        rest = rest[i + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, ':')) |j| {
            role = rest[0..j];
            rest = rest[j + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, ':')) |k| {
                type_ = rest[0..k];
                range = rest[k + 1 ..]; // entire remainder, colons included
            } else {
                type_ = rest;
            }
        } else {
            role = rest;
        }
    } else {
        user = rest;
    }

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

/// Relabel a single path. `deref` selects whether the symlink itself (true =
/// no-follow) or its referent is affected. `ref_context` is the pre-fetched
/// --reference context (if any). Returns true on success.
fn relabelOne(path: []const u8, cfg: *const Config, ref_context: ?[]const u8, deref: bool) bool {
    var current_context: ?[]const u8 = null;
    if (cfg.context == null and ref_context == null) {
        current_context = getContext(path, deref);
    }

    var ctx_buf: [1024]u8 = undefined;
    const base = ref_context orelse current_context;
    const new_context = buildContext(base, cfg, &ctx_buf) orelse {
        writeStderr("zchcon: failed to build context for '");
        writeStderr(path);
        writeStderr("'\n");
        return false;
    };

    if (cfg.verbose) {
        writeStderr("changing security context of '");
        writeStderr(path);
        writeStderr("'\n");
    }

    if (!setContext(path, new_context, deref)) {
        writeStderr("zchcon: failed to change context of '");
        writeStderr(path);
        writeStderr("'\n");
        return false;
    }
    return true;
}

/// Process one command-line operand, descending recursively when -R is set.
/// Returns true if every path touched succeeded.
fn processOperand(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    cfg: *const Config,
    ref_context: ?[]const u8,
) bool {
    var ok = relabelOne(path, cfg, ref_context, cfg.no_dereference);

    if (!cfg.recursive) return ok;

    // Default traversal (-P) never follows a symlink, so open the operand
    // WITHOUT following it. A symlink (even one pointing at a directory) then
    // fails to open as a directory and we do not descend — matching GNU chcon's
    // default -P behavior. -H/-L request following; we honour -H/-L on the
    // command-line operand by following it here.
    const follow_top = cfg.traversal != .P;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{
        .iterate = true,
        .follow_symlinks = follow_top,
    }) catch {
        // Not a directory (a plain file, or a symlink under -P): nothing to
        // descend into.
        return ok;
    };
    defer dir.close(io);

    var walker = dir.walk(gpa) catch return false;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        // Build the full path: operand + '/' + entry-relative-path.
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ path, entry.path }) catch {
            ok = false;
            continue;
        };
        defer gpa.free(full);

        // During -P recursion the walker never enters symlinked directories
        // (Walker only descends real directory entries), so any symlink we see
        // is relabelled as the link itself, never dereferenced. For every other
        // entry, honour the operand's --dereference/-h choice.
        const entry_deref = cfg.no_dereference or entry.kind == .sym_link;
        if (!relabelOne(full, cfg, ref_context, entry_deref)) ok = false;
    }

    return ok;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    var cfg = Config{};

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var positional_idx: usize = 0;
    var no_more_opts = false; // set once "--" is seen
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

        if (!no_more_opts and std.mem.eql(u8, arg, "--")) {
            no_more_opts = true;
            continue;
        }

        const is_option = !no_more_opts and arg.len > 1 and arg[0] == '-';

        if (is_option and arg[1] == '-') {
            // Long option
            if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                return;
            } else if (std.mem.eql(u8, arg, "--recursive")) {
                cfg.recursive = true;
            } else if (std.mem.eql(u8, arg, "--verbose")) {
                cfg.verbose = true;
            } else if (std.mem.eql(u8, arg, "--no-dereference")) {
                cfg.no_dereference = true;
            } else if (std.mem.eql(u8, arg, "--dereference")) {
                cfg.no_dereference = false;
            } else if (std.mem.startsWith(u8, arg, "--user=")) {
                cfg.user = arg[7..];
            } else if (std.mem.startsWith(u8, arg, "--role=")) {
                cfg.role = arg[7..];
            } else if (std.mem.startsWith(u8, arg, "--type=")) {
                cfg.type_ = arg[7..];
            } else if (std.mem.startsWith(u8, arg, "--range=")) {
                cfg.range = arg[8..];
            } else if (std.mem.startsWith(u8, arg, "--reference=")) {
                cfg.reference = arg[12..];
            } else {
                writeStderr("zchcon: unrecognized option '");
                writeStderr(arg);
                writeStderr("'\nTry 'zchcon --help' for more information.\n");
                std.process.exit(1);
            }
        } else if (is_option) {
            // Bundled short options: e.g. -Rv, -hR. A cluster member that takes
            // a value (-u/-r/-t/-l) consumes the rest of the cluster as its
            // argument, or the next argv if it is the last char.
            var ci: usize = 1;
            while (ci < arg.len) : (ci += 1) {
                const c = arg[ci];
                switch (c) {
                    'R' => cfg.recursive = true,
                    'v' => cfg.verbose = true,
                    'h' => cfg.no_dereference = true,
                    'H' => cfg.traversal = .H,
                    'L' => cfg.traversal = .L,
                    'P' => cfg.traversal = .P,
                    'u', 'r', 't', 'l' => {
                        const rest = arg[ci + 1 ..];
                        const opt: @TypeOf(next_opt) = switch (c) {
                            'u' => .user,
                            'r' => .role,
                            't' => .type_,
                            'l' => .range,
                            else => unreachable,
                        };
                        if (rest.len > 0) {
                            // Value is the remainder of this cluster.
                            switch (opt) {
                                .user => cfg.user = rest,
                                .role => cfg.role = rest,
                                .type_ => cfg.type_ = rest,
                                .range => cfg.range = rest,
                                .none => {},
                            }
                        } else {
                            next_opt = opt;
                        }
                        break; // rest of cluster consumed (or awaiting next argv)
                    },
                    else => {
                        writeStderr("zchcon: invalid option -- '");
                        writeStderr(arg[ci .. ci + 1]);
                        writeStderr("'\nTry 'zchcon --help' for more information.\n");
                        std.process.exit(1);
                    },
                }
            }
        } else {
            // Positional operand.
            // First positional is CONTEXT if no -u/-r/-t/-l/--reference given.
            if (positional_idx == 0 and cfg.user == null and cfg.role == null and
                cfg.type_ == null and cfg.range == null and cfg.reference == null)
            {
                cfg.context = arg;
            } else {
                cfg.files.append(arena, arg) catch {
                    writeStderr("zchcon: out of memory\n");
                    std.process.exit(1);
                };
            }
            positional_idx += 1;
        }
    }

    if (cfg.files.items.len == 0) {
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
    for (cfg.files.items) |path| {
        if (!processOperand(io, gpa, path, &cfg, ref_context)) {
            exit_code = 1;
        }
    }

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
