//! zln - Make links between files
//!
//! Compatible with GNU ln:
//! - Create hard links (default)
//! - -s, --symbolic: create symbolic links
//! - -f, --force: remove existing destination files (link first; never destroys
//!   the destination when the link cannot succeed — matches GNU coreutils)
//! - -i, --interactive: prompt whether to remove destinations (last of -f/-i wins)
//! - -n, --no-dereference: treat LINK_NAME as a normal file if it is a symbolic
//!   link to a directory
//! - -r, --relative: with -s, create symlinks relative to link location
//! - -v, --verbose: print name of each linked file
//! - -t, --target-directory=DIR: specify the DIRECTORY in which to create the links
//! - -T, --no-target-directory: treat LINK_NAME as a normal file always
//! - One-operand form `zln TARGET` creates ./TARGET_BASENAME like GNU ln.

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;
const Io = std.Io;

const Config = struct {
    symbolic: bool = false,
    force: bool = false,
    interactive: bool = false,
    no_dereference: bool = false,
    no_target_directory: bool = false,
    relative: bool = false,
    verbose: bool = false,
    target_directory: ?[]const u8 = null,
    sources: std.ArrayListUnmanaged([]const u8) = .empty,
    destination: ?[]const u8 = null,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.sources.items) |item| {
            allocator.free(item);
        }
        self.sources.deinit(allocator);
        if (self.destination) |d| allocator.free(d);
        if (self.target_directory) |t| allocator.free(t);
    }
};

/// stat() following symlinks; null if the path cannot be resolved.
fn statPath(path: [:0]const u8) ?libc.Stat {
    var st: libc.Stat = undefined;
    if (libc.fstatat(libc.AT.FDCWD, path.ptr, &st, 0) != 0) return null;
    return st;
}

/// lstat(): stat of the path itself, never following a trailing symlink.
fn lstatPath(path: [:0]const u8) ?libc.Stat {
    var st: libc.Stat = undefined;
    if (libc.fstatat(libc.AT.FDCWD, path.ptr, &st, libc.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return st;
}

fn isDirStat(st: libc.Stat) bool {
    return std.posix.S.ISDIR(st.mode);
}

/// Is the destination a directory for link-placement purposes?
/// With -n/--no-dereference (or -T upstream), a symlink to a directory must
/// NOT count as a directory — GNU semantics for `ln -sfn new cur`.
fn destIsDirectory(path: [:0]const u8, config: *const Config) bool {
    const st = (if (config.no_dereference) lstatPath(path) else statPath(path)) orelse return false;
    return isDirStat(st);
}

extern "c" fn strerror(errnum: c_int) ?[*:0]const u8;

fn errString(err: c_int) []const u8 {
    const s = strerror(err) orelse return "Unknown error";
    return std.mem.span(s);
}

fn errnoNow() c_int {
    return libc._errno().*;
}

const E_EEXIST: c_int = @intFromEnum(libc.E.EXIST);

/// GNU-style basename: ignores trailing slashes ("a/b/" -> "b", "/" -> "/").
fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const trimmed = path[0..end];
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |idx| {
        if (idx + 1 < trimmed.len) return trimmed[idx + 1 ..];
    }
    return trimmed;
}

fn dirnameOf(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

/// GNU same_name(): do the two paths refer to the same directory entry?
/// True iff the basenames match and the containing directories are the same
/// inode. This is the guard that prevents `ln -f x x` from destroying x.
fn sameName(allocator: std.mem.Allocator, a: []const u8, b: []const u8) bool {
    if (!std.mem.eql(u8, basename(a), basename(b))) return false;

    const da = allocator.dupeZ(u8, dirnameOf(a)) catch return false;
    defer allocator.free(da);
    const db = allocator.dupeZ(u8, dirnameOf(b)) catch return false;
    defer allocator.free(db);

    const sa = statPath(da) orelse return false;
    const sb = statPath(db) orelse return false;
    return sa.dev == sb.dev and sa.ino == sb.ino;
}

fn attemptLink(target_z: [:0]const u8, link_z: [:0]const u8, symbolic: bool) bool {
    if (symbolic) {
        return libc.symlink(target_z.ptr, link_z.ptr) == 0;
    }
    return libc.link(target_z.ptr, link_z.ptr) == 0;
}

fn printLinkError(link_name: []const u8, effective_target: []const u8, symbolic: bool, err: c_int) void {
    if (symbolic) {
        printErrorFmt("failed to create symbolic link '{s}': {s}", .{ link_name, errString(err) });
    } else if (err == E_EEXIST) {
        // GNU omits the "=> target" part for the File-exists diagnostic.
        printErrorFmt("failed to create hard link '{s}': {s}", .{ link_name, errString(err) });
    } else {
        printErrorFmt("failed to create hard link '{s}' => '{s}': {s}", .{ link_name, effective_target, errString(err) });
    }
}

fn makeLink(allocator: std.mem.Allocator, target: []const u8, link_name: []const u8, config: *const Config) !void {
    // Compute the actual target for the symlink (may be relative)
    var effective_target = target;
    var relative_buf: ?[]const u8 = null;
    defer if (relative_buf) |buf| allocator.free(buf);

    if (config.relative and config.symbolic) {
        relative_buf = computeRelativePath(allocator, target, link_name) catch {
            printErrorFmt("failed to compute relative path for '{s}'", .{target});
            return error.RelativePathFailed;
        };
        effective_target = relative_buf.?;
    }

    const target_z = try allocator.dupeZ(u8, effective_target);
    defer allocator.free(target_z);

    const link_z = try allocator.dupeZ(u8, link_name);
    defer allocator.free(link_z);

    if (!config.symbolic) {
        // GNU checks that a hard-link target is accessible (dereferencing
        // symlinks) before anything else: "failed to access 'X': ...".
        const raw_target_z = try allocator.dupeZ(u8, target);
        defer allocator.free(raw_target_z);
        const tst = statPath(raw_target_z) orelse {
            printErrorFmt("failed to access '{s}': {s}", .{ target, errString(errnoNow()) });
            return error.TargetInaccessible;
        };
        if (isDirStat(tst)) {
            printErrorFmt("{s}: hard link not allowed for directory", .{target});
            return error.HardLinkToDirectory;
        }
    }

    // Attempt the link FIRST. Only if it fails with EEXIST and replacement was
    // requested (-f / -i) do we consider removing the destination. This is the
    // GNU-compatible order: a failing link never destroys the destination.
    if (attemptLink(target_z, link_z, config.symbolic)) {
        if (config.verbose) printVerbose(link_name, effective_target, config.symbolic);
        return;
    }
    const first_err = errnoNow();
    if (first_err != E_EEXIST or (!config.force and !config.interactive)) {
        printLinkError(link_name, effective_target, config.symbolic, first_err);
        return error.LinkFailed;
    }

    // Destination exists and replacement was requested.
    if (lstatPath(link_z)) |dst| {
        if (isDirStat(dst)) {
            // GNU: "ln: realdir: cannot overwrite directory" (before any prompt)
            printErrorFmt("{s}: cannot overwrite directory", .{link_name});
            return error.IsDirectory;
        }
    }

    if (config.force) {
        // Refuse to unlink the destination when it IS the source entry —
        // otherwise `ln -f x x` would delete x (GNU same_name guard).
        if (sameName(allocator, target, link_name)) {
            printErrorFmt("'{s}' and '{s}' are the same file", .{ target, link_name });
            return error.SameFile;
        }
    } else {
        // interactive
        if (!promptUser(link_name)) {
            // GNU exits 1 on a declined prompt, with no extra message.
            return error.Declined;
        }
    }

    if (!config.symbolic) {
        // Same inode already? Unlink+relink would recreate the identical
        // state; GNU replaces atomically. Treat as success without touching
        // the destination so no failure mode can destroy it.
        const raw_target_z = try allocator.dupeZ(u8, target);
        defer allocator.free(raw_target_z);
        if (statPath(raw_target_z)) |tst| {
            if (lstatPath(link_z)) |dst| {
                if (tst.dev == dst.dev and tst.ino == dst.ino) {
                    if (config.verbose) printVerbose(link_name, effective_target, config.symbolic);
                    return;
                }
            }
        }
    }

    if (libc.unlink(link_z.ptr) != 0) {
        printErrorFmt("cannot remove '{s}': {s}", .{ link_name, errString(errnoNow()) });
        return error.UnlinkFailed;
    }

    if (!attemptLink(target_z, link_z, config.symbolic)) {
        printLinkError(link_name, effective_target, config.symbolic, errnoNow());
        return error.LinkFailed;
    }

    if (config.verbose) printVerbose(link_name, effective_target, config.symbolic);
}

extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*]u8;

fn resolveAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // If path is already absolute, return a dupe
    if (path.len > 0 and path[0] == '/') {
        return try allocator.dupe(u8, path);
    }
    // Otherwise, prepend cwd
    var cwd_buf: [4096]u8 = undefined;
    const cwd_ptr = getcwd(&cwd_buf, cwd_buf.len);
    if (cwd_ptr == null) return error.GetCwdFailed;
    const cwd = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(cwd_ptr.?)), 0);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, path });
}

/// Split an absolute path into components, canonicalizing "." and ".."
/// lexically (GNU ln -r emits 'a/b/f' for 'a/./b/../b/f').
fn appendCanonicalParts(
    allocator: std.mem.Allocator,
    parts: *std.ArrayListUnmanaged([]const u8),
    abs_path: []const u8,
) !void {
    var iter = std.mem.splitScalar(u8, abs_path, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            _ = parts.pop(); // at root, ".." is a no-op
            continue;
        }
        try parts.append(allocator, part);
    }
}

fn computeRelativePath(allocator: std.mem.Allocator, target: []const u8, link_name: []const u8) ![]const u8 {
    // Resolve both paths to absolute
    const abs_target = try resolveAbsolute(allocator, target);
    defer allocator.free(abs_target);
    const abs_link = try resolveAbsolute(allocator, link_name);
    defer allocator.free(abs_link);

    // Get directory of the link
    const link_dir = if (std.mem.lastIndexOfScalar(u8, abs_link, '/')) |idx|
        abs_link[0..idx]
    else
        ".";

    // Split both paths into canonicalized components
    var target_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer target_parts.deinit(allocator);
    var link_dir_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer link_dir_parts.deinit(allocator);

    try appendCanonicalParts(allocator, &target_parts, abs_target);
    try appendCanonicalParts(allocator, &link_dir_parts, link_dir);

    // Find common prefix length
    var common: usize = 0;
    while (common < target_parts.items.len and common < link_dir_parts.items.len) {
        if (!std.mem.eql(u8, target_parts.items[common], link_dir_parts.items[common])) break;
        common += 1;
    }

    // Build relative path: go up from link_dir to common ancestor, then down to target
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    // Number of ".." needed
    const ups = link_dir_parts.items.len - common;
    for (0..ups) |idx| {
        if (idx > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, "..");
    }

    // Append remaining target path
    for (common..target_parts.items.len) |idx| {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, target_parts.items[idx]);
    }

    if (result.items.len == 0) {
        try result.append(allocator, '.');
    }

    return try allocator.dupe(u8, result.items);
}

fn promptUser(link_name: []const u8) bool {
    std.debug.print("zln: replace '{s}'? ", .{link_name});
    // Read one full line from stdin so consecutive prompts don't misconsume input.
    const stdin_fd: c_int = 0;
    var first: u8 = 0;
    var have_first = false;
    while (true) {
        var ch: [1]u8 = undefined;
        const n = libc.read(stdin_fd, &ch, 1);
        if (n <= 0) break; // EOF/error: treat as decline
        if (!have_first) {
            first = ch[0];
            have_first = true;
        }
        if (ch[0] == '\n') break;
    }
    if (!have_first) return false;
    return first == 'y' or first == 'Y';
}

fn printVerbose(link_name: []const u8, target: []const u8, symbolic: bool) void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [512]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    if (symbolic) {
        writer.interface.print("'{s}' -> '{s}'\n", .{ link_name, target }) catch {};
    } else {
        writer.interface.print("'{s}' => '{s}'\n", .{ link_name, target }) catch {};
    }
    writer.interface.flush() catch {};
}

fn printError(msg: []const u8) void {
    std.debug.print("zln: {s}\n", .{msg});
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zln: " ++ fmt ++ "\n", args);
}

fn printTryHelp() void {
    std.debug.print("Try 'zln --help' for more information.\n", .{});
}

fn setTargetDirectory(allocator: std.mem.Allocator, config: *Config, value: []const u8) !void {
    if (config.target_directory != null) {
        printError("multiple target directories specified");
        std.process.exit(1);
    }
    config.target_directory = try allocator.dupe(u8, value);
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--symbolic")) {
                    config.symbolic = true;
                } else if (std.mem.eql(u8, arg, "--force")) {
                    // GNU: the last of -f/-i wins
                    config.force = true;
                    config.interactive = false;
                } else if (std.mem.eql(u8, arg, "--no-dereference")) {
                    config.no_dereference = true;
                } else if (std.mem.eql(u8, arg, "--interactive")) {
                    config.interactive = true;
                    config.force = false;
                } else if (std.mem.eql(u8, arg, "--relative")) {
                    config.relative = true;
                } else if (std.mem.eql(u8, arg, "--no-target-directory")) {
                    config.no_target_directory = true;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
                } else if (std.mem.startsWith(u8, arg, "--target-directory=")) {
                    try setTargetDirectory(allocator, &config, arg[19..]);
                } else if (std.mem.eql(u8, arg, "--target-directory")) {
                    i += 1;
                    if (i >= args.len) {
                        printError("option '--target-directory' requires an argument");
                        printTryHelp();
                        std.process.exit(1);
                    }
                    try setTargetDirectory(allocator, &config, args[i]);
                } else if (std.mem.eql(u8, arg, "--")) {
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        try config.sources.append(allocator, try allocator.dupe(u8, args[i]));
                    }
                    break;
                } else {
                    printErrorFmt("unrecognized option '{s}'", .{arg});
                    printTryHelp();
                    std.process.exit(1);
                }
            } else {
                const cluster = arg[1..];
                var j: usize = 0;
                while (j < cluster.len) : (j += 1) {
                    const ch = cluster[j];
                    switch (ch) {
                        's' => config.symbolic = true,
                        'f' => {
                            config.force = true;
                            config.interactive = false;
                        },
                        'i' => {
                            config.interactive = true;
                            config.force = false;
                        },
                        'n' => config.no_dereference = true,
                        'r' => config.relative = true,
                        'T' => config.no_target_directory = true,
                        'v' => config.verbose = true,
                        't' => {
                            if (j + 1 < cluster.len) {
                                // attached value: -tDIR
                                try setTargetDirectory(allocator, &config, cluster[j + 1 ..]);
                                j = cluster.len;
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    printError("option requires an argument -- 't'");
                                    printTryHelp();
                                    std.process.exit(1);
                                }
                                try setTargetDirectory(allocator, &config, args[i]);
                            }
                        },
                        else => {
                            printErrorFmt("invalid option -- '{c}'", .{ch});
                            printTryHelp();
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.sources.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // GNU: "ln: cannot do --relative without --symbolic"
    if (config.relative and !config.symbolic) {
        printError("cannot do --relative without --symbolic");
        std.process.exit(1);
    }

    // GNU: "ln: cannot combine --target-directory and --no-target-directory"
    if (config.target_directory != null and config.no_target_directory) {
        printError("cannot combine --target-directory and --no-target-directory");
        std.process.exit(1);
    }

    if (config.sources.items.len == 0) {
        printError("missing file operand");
        printTryHelp();
        std.process.exit(1);
    }

    if (config.target_directory == null) {
        if (config.no_target_directory) {
            // -T requires exactly TARGET LINK_NAME
            if (config.sources.items.len < 2) {
                printErrorFmt("missing destination file operand after '{s}'", .{config.sources.items[0]});
                printTryHelp();
                std.process.exit(1);
            }
            if (config.sources.items.len > 2) {
                printErrorFmt("extra operand '{s}'", .{config.sources.items[2]});
                printTryHelp();
                std.process.exit(1);
            }
            config.destination = config.sources.pop();
        } else if (config.sources.items.len == 1) {
            // One-operand form: `ln TARGET` == `ln -t . TARGET` (GNU coreutils)
            config.target_directory = try allocator.dupe(u8, ".");
        } else {
            config.destination = config.sources.pop();
        }
    }

    return config;
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [2048]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zln [OPTION]... [-T] TARGET LINK_NAME
        \\   or: zln [OPTION]... TARGET
        \\   or: zln [OPTION]... TARGET... DIRECTORY
        \\   or: zln [OPTION]... -t DIRECTORY TARGET...
        \\Create a link to TARGET with the name LINK_NAME.
        \\
        \\  -s, --symbolic          make symbolic links instead of hard links
        \\  -f, --force             remove existing destination files
        \\  -i, --interactive       prompt whether to remove destinations
        \\  -n, --no-dereference    treat LINK_NAME as a normal file if
        \\                            it is a symbolic link to a directory
        \\  -r, --relative          with -s, create links relative to link location
        \\  -t, --target-directory=DIR  specify the DIRECTORY in which to create the links
        \\  -T, --no-target-directory   treat LINK_NAME as a normal file always
        \\  -v, --verbose           print name of each linked file
        \\      --help              display this help and exit
        \\      --version           output version information and exit
        \\
        \\zln - High-performance link creation utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zln 0.2.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        printError("failed to parse arguments");
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    var error_occurred = false;

    if (config.target_directory) |target_dir| {
        const target_z = allocator.dupeZ(u8, target_dir) catch {
            printError("memory allocation failed");
            std.process.exit(1);
        };
        defer allocator.free(target_z);

        const tdst = statPath(target_z);
        if (tdst == null or !isDirStat(tdst.?)) {
            printErrorFmt("target '{s}' is not a directory", .{target_dir});
            std.process.exit(1);
        }

        for (config.sources.items) |target| {
            const link_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ target_dir, basename(target) }) catch {
                printError("memory allocation failed");
                error_occurred = true;
                continue;
            };
            defer allocator.free(link_name);

            makeLink(allocator, target, link_name, &config) catch {
                error_occurred = true;
            };
        }
    } else if (config.destination) |dest| {
        const dest_z = allocator.dupeZ(u8, dest) catch {
            printError("memory allocation failed");
            std.process.exit(1);
        };
        defer allocator.free(dest_z);

        if (config.sources.items.len == 1) {
            const target = config.sources.items[0];
            if (!config.no_target_directory and destIsDirectory(dest_z, &config)) {
                const link_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename(target) }) catch {
                    printError("memory allocation failed");
                    std.process.exit(1);
                };
                defer allocator.free(link_name);
                makeLink(allocator, target, link_name, &config) catch {
                    error_occurred = true;
                };
            } else {
                makeLink(allocator, target, dest, &config) catch {
                    error_occurred = true;
                };
            }
        } else {
            if (!destIsDirectory(dest_z, &config)) {
                // GNU: "ln: target 'X': Not a directory"
                printErrorFmt("target '{s}': Not a directory", .{dest});
                std.process.exit(1);
            }

            for (config.sources.items) |target| {
                const link_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename(target) }) catch {
                    printError("memory allocation failed");
                    error_occurred = true;
                    continue;
                };
                defer allocator.free(link_name);

                makeLink(allocator, target, link_name, &config) catch {
                    error_occurred = true;
                };
            }
        }
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
