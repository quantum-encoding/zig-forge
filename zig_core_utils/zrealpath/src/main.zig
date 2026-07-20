//! zrealpath - Print the resolved path
//!
//! Compatible with GNU realpath (coreutils 9.x):
//! - Print the resolved absolute file name
//! - -E, --canonicalize:          all but the last component must exist (DEFAULT)
//! - -e, --canonicalize-existing: all components of the path must exist
//! - -m, --canonicalize-missing:  no path components need exist or be a directory
//! - -L, --logical:               resolve '..' components before symlinks
//! - -P, --physical:              resolve symlinks as encountered (default)
//! - -q, --quiet:                 suppress most error messages
//! - -s, --strip, --no-symlinks:  don't expand symlinks
//! - -z, --zero:                  end each output line with NUL, not newline
//! - --relative-to=DIR:           print the resolved path relative to DIR
//! - --relative-base=DIR:         print absolute paths unless paths below DIR
//!
//! Canonicalization is implemented natively (not via libc realpath()) so that
//! -m / -E / -s all behave like GNU, which libc realpath() cannot express.

const std = @import("std");
const libc = std.c;

// Direct libc bindings. std.posix in this Zig has no getcwd/lstat/readlink,
// and the new Io-based std.Io.Dir API would require threading an Io through
// every helper; these three raw calls are simpler and fully portable.
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern "c" fn lstat(path: [*:0]const u8, buf: *libc.Stat) c_int;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsize: usize) isize;

// Universal Unix file-type bits (identical on Linux, macOS and the BSDs).
const S_IFMT: u16 = 0o170000;
const S_IFLNK: u16 = 0o120000;
const S_IFDIR: u16 = 0o040000;

const MAX_PATH = 4096; // PATH_MAX on Linux; macOS is 1024, so this is a safe cap.

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

const Mode = enum { existing, all_but_last, missing };

const Config = struct {
    mode: Mode = .all_but_last, // GNU default is -E
    no_symlinks: bool = false,
    logical: bool = false,
    quiet: bool = false,
    zero: bool = false,
    relative_to: ?[]const u8 = null,
    relative_base: ?[]const u8 = null,
    paths: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.paths.items) |item| {
            allocator.free(item);
        }
        self.paths.deinit(allocator);
        if (self.relative_to) |r| allocator.free(r);
        if (self.relative_base) |r| allocator.free(r);
    }
};

// ---------------------------------------------------------------------------
// Canonicalization
// ---------------------------------------------------------------------------

const CanonError = error{
    NoEnt, // ENOENT  -> "No such file or directory"
    NotDir, // ENOTDIR -> "Not a directory"
    Loop, // ELOOP   -> "Too many levels of symbolic links"
    Acces, // EACCES  -> "Permission denied"
    NameTooLong, // ENAMETOOLONG -> "File name too long"
    Other,
    OutOfMemory,
};

fn errMsg(e: CanonError) []const u8 {
    return switch (e) {
        error.NoEnt => "No such file or directory",
        error.NotDir => "Not a directory",
        error.Loop => "Too many levels of symbolic links",
        error.Acces => "Permission denied",
        error.NameTooLong => "File name too long",
        error.Other => "Invalid argument",
        error.OutOfMemory => "Cannot allocate memory",
    };
}

const MAX_SYMLINKS = 40;

/// Remove the last path component from `rname` (an absolute path buffer),
/// including its leading '/'. The root "/" is preserved.
fn popComponent(rname: *std.ArrayListUnmanaged(u8)) void {
    const idx = std.mem.lastIndexOfScalar(u8, rname.items, '/') orelse 0;
    if (idx == 0) {
        rname.items.len = 1; // keep leading "/"
    } else {
        rname.items.len = idx;
    }
}

fn appendComponent(allocator: std.mem.Allocator, rname: *std.ArrayListUnmanaged(u8), comp: []const u8) !void {
    if (rname.items.len == 0 or rname.items[rname.items.len - 1] != '/') {
        try rname.append(allocator, '/');
    }
    try rname.appendSlice(allocator, comp);
}

/// True if everything from `pos` onward in `rem` is empty or only slashes,
/// i.e. the current component is the final real component of the path.
fn isLast(rem: []const u8, pos: usize) bool {
    var k = pos;
    while (k < rem.len) : (k += 1) {
        if (rem[k] != '/') return false;
    }
    return true;
}

fn currentErrno() CanonError {
    const e: libc.E = @enumFromInt(libc._errno().*);
    return switch (e) {
        .NOENT => error.NoEnt,
        .NOTDIR => error.NotDir,
        .ACCES => error.Acces,
        .LOOP => error.Loop,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Other,
    };
}

/// Produce an absolute path with '.', '..' and duplicate slashes resolved
/// purely textually (no filesystem access). Used for GNU -L, which resolves
/// '..' components lexically BEFORE any symlink is followed.
fn lexicalAbs(allocator: std.mem.Allocator, name: []const u8) CanonError![]u8 {
    var rname: std.ArrayListUnmanaged(u8) = .empty;
    errdefer rname.deinit(allocator);

    if (name.len > 0 and name[0] == '/') {
        try rname.append(allocator, '/');
    } else {
        var cwd_buf: [MAX_PATH]u8 = undefined;
        const cwd_ptr = getcwd(&cwd_buf, cwd_buf.len) orelse return currentErrno();
        try rname.appendSlice(allocator, std.mem.span(cwd_ptr));
    }

    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            popComponent(&rname);
            continue;
        }
        try appendComponent(allocator, &rname, comp);
    }
    return rname.toOwnedSlice(allocator);
}

/// Canonicalize `name` under `mode`. When `no_symlinks` is set, symlinks are
/// not dereferenced (GNU -s): resolution is purely lexical, but existence is
/// still checked per `mode`. When `logical` is set (GNU -L), '..' components
/// are collapsed lexically before symlinks are resolved.
///
/// Mirrors coreutils canonicalize_filename_mode():
///  - existing:      every component must exist (lstat every component)
///  - all_but_last:  every component except the final one must exist
///  - missing:       nothing needs to exist; a non-directory mid-path is not
///                   an error, remaining components are appended literally
fn canonicalize(
    allocator: std.mem.Allocator,
    name_in: []const u8,
    mode: Mode,
    no_symlinks: bool,
    logical: bool,
) CanonError![]u8 {
    if (name_in.len == 0) return error.NoEnt;

    // GNU -L: pre-collapse '..' lexically, then resolve symlinks on the result.
    // (-s takes precedence and stays fully lexical in the main loop.)
    var lex: ?[]u8 = null;
    defer if (lex) |l| allocator.free(l);
    const name = if (logical and !no_symlinks) blk: {
        lex = try lexicalAbs(allocator, name_in);
        break :blk lex.?;
    } else name_in;

    var rname: std.ArrayListUnmanaged(u8) = .empty;
    errdefer rname.deinit(allocator);

    // `remaining` holds the yet-to-process portion of the path (relative to
    // rname). It is mutated when a symlink target is spliced in.
    var remaining: std.ArrayListUnmanaged(u8) = .empty;
    defer remaining.deinit(allocator);

    if (name[0] == '/') {
        try rname.append(allocator, '/');
    } else {
        var cwd_buf: [MAX_PATH]u8 = undefined;
        const cwd_ptr = getcwd(&cwd_buf, cwd_buf.len) orelse return currentErrno();
        const cwd = std.mem.span(cwd_ptr);
        try rname.appendSlice(allocator, cwd);
    }
    try remaining.appendSlice(allocator, name);

    var num_links: usize = 0;
    var pos: usize = 0;
    var stopped_resolving = false; // once a component is missing/non-dir under -m

    while (pos < remaining.items.len) {
        const rem = remaining.items;
        // skip slashes
        while (pos < rem.len and rem[pos] == '/') pos += 1;
        if (pos >= rem.len) break;
        const comp_start = pos;
        while (pos < rem.len and rem[pos] != '/') pos += 1;
        const comp = rem[comp_start..pos];

        if (comp.len == 0) break;
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            popComponent(&rname);
            continue;
        }

        try appendComponent(allocator, &rname, comp);
        const last = isLast(remaining.items, pos);

        if (stopped_resolving) continue;

        // Null-terminate rname for the syscall (sentinel not counted in len).
        try rname.append(allocator, 0);
        const path_z: [*:0]const u8 = @ptrCast(rname.items.ptr);
        rname.items.len -= 1;

        var st: libc.Stat = undefined;
        if (lstat(path_z, &st) != 0) {
            const ce = currentErrno();
            switch (mode) {
                .existing => return ce,
                .all_but_last => if (!last) return ce,
                .missing => {},
            }
            // Component does not exist: keep it literally, stop resolving.
            stopped_resolving = true;
            continue;
        }

        const fmt = st.mode & S_IFMT;
        if (fmt == S_IFLNK and !no_symlinks) {
            num_links += 1;
            if (num_links > MAX_SYMLINKS) return error.Loop;

            var link_buf: [MAX_PATH]u8 = undefined;
            try rname.append(allocator, 0);
            const rz: [*:0]const u8 = @ptrCast(rname.items.ptr);
            rname.items.len -= 1;
            const n = readlink(rz, &link_buf, link_buf.len);
            if (n < 0) return currentErrno();
            const target = link_buf[0..@intCast(n)];

            // Remove the component we just appended.
            popComponent(&rname);

            // Splice: new remaining = target [+ "/" + old-tail]
            var spliced: std.ArrayListUnmanaged(u8) = .empty;
            errdefer spliced.deinit(allocator);
            try spliced.appendSlice(allocator, target);
            if (pos < remaining.items.len) {
                try spliced.append(allocator, '/');
                try spliced.appendSlice(allocator, remaining.items[pos..]);
            }
            remaining.deinit(allocator);
            remaining = spliced;
            pos = 0;

            if (target.len > 0 and target[0] == '/') {
                rname.items.len = 1; // reset to root "/"
            }
            continue;
        }

        // Not a symlink (or -s). Reject a non-directory in a non-final
        // position, except under -m which tolerates it.
        if (fmt != S_IFDIR and !last) {
            if (mode == .missing) {
                stopped_resolving = true;
                continue;
            }
            return error.NotDir;
        }
    }

    return rname.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Relative path computation (matches coreutils relpath.c)
// ---------------------------------------------------------------------------

fn splitComponents(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| {
        if (c.len == 0) continue;
        try list.append(allocator, c);
    }
    return list.toOwnedSlice(allocator);
}

/// True if canonical `base` is at or above canonical `path` (path == base or
/// path is under base).
fn pathPrefix(allocator: std.mem.Allocator, base: []const u8, path: []const u8) !bool {
    const bparts = try splitComponents(allocator, base);
    defer allocator.free(bparts);
    const pparts = try splitComponents(allocator, path);
    defer allocator.free(pparts);
    if (bparts.len > pparts.len) return false;
    for (bparts, 0..) |b, i| {
        if (!std.mem.eql(u8, b, pparts[i])) return false;
    }
    return true;
}

/// Compute `path` expressed relative to `base` (both absolute & canonical).
fn relpath(allocator: std.mem.Allocator, path: []const u8, base: []const u8) ![]u8 {
    const pparts = try splitComponents(allocator, path);
    defer allocator.free(pparts);
    const bparts = try splitComponents(allocator, base);
    defer allocator.free(bparts);

    var k: usize = 0;
    const min = @min(pparts.len, bparts.len);
    while (k < min and std.mem.eql(u8, pparts[k], bparts[k])) : (k += 1) {}

    const ups = bparts.len - k;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var first = true;
    var u: usize = 0;
    while (u < ups) : (u += 1) {
        if (!first) try out.append(allocator, '/');
        try out.appendSlice(allocator, "..");
        first = false;
    }
    var j = k;
    while (j < pparts.len) : (j += 1) {
        if (!first) try out.append(allocator, '/');
        try out.appendSlice(allocator, pparts[j]);
        first = false;
    }
    if (out.items.len == 0) {
        try out.append(allocator, '.');
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

fn usageHint() void {
    writeStderr("Try 'zrealpath --help' for more information.\n");
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
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

        if (arg.len > 1 and arg[0] == '-') {
            if (arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--canonicalize")) {
                    config.mode = .all_but_last;
                } else if (std.mem.eql(u8, arg, "--canonicalize-existing")) {
                    config.mode = .existing;
                } else if (std.mem.eql(u8, arg, "--canonicalize-missing")) {
                    config.mode = .missing;
                } else if (std.mem.eql(u8, arg, "--logical")) {
                    config.logical = true;
                } else if (std.mem.eql(u8, arg, "--physical")) {
                    config.logical = false;
                } else if (std.mem.eql(u8, arg, "--quiet")) {
                    config.quiet = true;
                } else if (std.mem.eql(u8, arg, "--no-symlinks") or std.mem.eql(u8, arg, "--strip")) {
                    config.no_symlinks = true;
                } else if (std.mem.eql(u8, arg, "--zero")) {
                    config.zero = true;
                } else if (std.mem.startsWith(u8, arg, "--relative-to=")) {
                    config.relative_to = try allocator.dupe(u8, arg[14..]);
                } else if (std.mem.eql(u8, arg, "--relative-to")) {
                    i += 1;
                    if (i >= args.len) {
                        writeStderr("zrealpath: option '--relative-to' requires an argument\n");
                        usageHint();
                        std.process.exit(1);
                    }
                    config.relative_to = try allocator.dupe(u8, args[i]);
                } else if (std.mem.startsWith(u8, arg, "--relative-base=")) {
                    config.relative_base = try allocator.dupe(u8, arg[16..]);
                } else if (std.mem.eql(u8, arg, "--relative-base")) {
                    i += 1;
                    if (i >= args.len) {
                        writeStderr("zrealpath: option '--relative-base' requires an argument\n");
                        usageHint();
                        std.process.exit(1);
                    }
                    config.relative_base = try allocator.dupe(u8, args[i]);
                } else {
                    writeStderr("zrealpath: unrecognized option '");
                    writeStderr(arg);
                    writeStderr("'\n");
                    usageHint();
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'E' => config.mode = .all_but_last,
                        'e' => config.mode = .existing,
                        'm' => config.mode = .missing,
                        'L' => config.logical = true,
                        'P' => config.logical = false,
                        'q' => config.quiet = true,
                        's' => config.no_symlinks = true,
                        'z' => config.zero = true,
                        else => {
                            writeStderr("zrealpath: invalid option -- '");
                            var char_buf: [1]u8 = .{ch};
                            writeStderr(&char_buf);
                            writeStderr("'\n");
                            usageHint();
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.paths.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.paths.items.len == 0) {
        writeStderr("zrealpath: missing operand\n");
        usageHint();
        std.process.exit(1);
    }

    return config;
}

fn printHelp() void {
    const usage =
        \\Usage: zrealpath [OPTION]... FILE...
        \\Print the resolved absolute file name.
        \\
        \\  -E, --canonicalize           all but the last component must exist (default)
        \\  -e, --canonicalize-existing  all components of the path must exist
        \\  -m, --canonicalize-missing   no path components need exist or be a directory
        \\  -L, --logical                resolve '..' components before symlinks
        \\  -P, --physical               resolve symlinks as encountered (default)
        \\  -q, --quiet                  suppress most error messages
        \\      --relative-to=DIR        print the resolved path relative to DIR
        \\      --relative-base=DIR      print absolute paths unless paths below DIR
        \\  -s, --strip, --no-symlinks   don't expand symlinks
        \\  -z, --zero                   end each output line with NUL, not newline
        \\      --help                   display this help and exit
        \\      --version                output version information and exit
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zrealpath 0.2.0\n");
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

fn reportError(quiet: bool, path: []const u8, e: CanonError) void {
    if (quiet) return;
    writeStderr("zrealpath: ");
    if (path.len == 0) {
        writeStderr("''");
    } else {
        writeStderr(path);
    }
    writeStderr(": ");
    writeStderr(errMsg(e));
    writeStderr("\n");
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        writeStderr("zrealpath: failed to parse arguments\n");
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    const terminator: []const u8 = if (config.zero) "\x00" else "\n";
    var error_occurred = false;

    // --relative-base implies an anchor; when --relative-to is absent it
    // defaults to the base (GNU behavior).
    var can_relative_to: ?[]u8 = null;
    var can_relative_base: ?[]u8 = null;
    defer {
        if (can_relative_to) |r| allocator.free(r);
        if (can_relative_base) |r| allocator.free(r);
    }

    if (config.relative_base) |rb| {
        can_relative_base = canonicalize(allocator, rb, config.mode, config.no_symlinks, config.logical) catch |e| {
            reportError(config.quiet, rb, e);
            std.process.exit(1);
        };
    }
    if (config.relative_to) |rt| {
        can_relative_to = canonicalize(allocator, rt, config.mode, config.no_symlinks, config.logical) catch |e| {
            reportError(config.quiet, rt, e);
            std.process.exit(1);
        };
    } else if (can_relative_base) |rb| {
        can_relative_to = allocator.dupe(u8, rb) catch std.process.exit(1);
    }

    for (config.paths.items) |path| {
        const resolved = canonicalize(allocator, path, config.mode, config.no_symlinks, config.logical) catch |e| {
            reportError(config.quiet, path, e);
            error_occurred = true;
            continue;
        };
        defer allocator.free(resolved);

        // Decide relative vs absolute output.
        if (can_relative_to) |anchor| {
            const below = if (can_relative_base) |base|
                pathPrefix(allocator, base, resolved) catch true
            else
                true;
            if (below) {
                const rel = relpath(allocator, resolved, anchor) catch {
                    writeStdout(resolved);
                    writeStdout(terminator);
                    continue;
                };
                defer allocator.free(rel);
                writeStdout(rel);
                writeStdout(terminator);
                continue;
            }
        }

        writeStdout(resolved);
        writeStdout(terminator);
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
