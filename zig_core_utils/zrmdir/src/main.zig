//! zrmdir - Remove empty directories
//!
//! Compatible with GNU rmdir (anchored against GNU coreutils 9.10):
//! - Remove empty directories
//! - -p, --parents: remove directory and ancestors (GNU parent-climb
//!   algorithm: trailing slashes stripped, slash runs collapsed)
//! - -v, --verbose: "removing directory, 'x'" on stdout BEFORE each
//!   attempt, including attempts that then fail
//! - --ignore-fail-on-non-empty: ignore non-empty directory errors
//! - '-' and '--'-terminated operands treated as directory names
//! - diagnostics use strerror-style text on stderr; exit 1 on failure

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;

const Config = struct {
    parents: bool = false,
    verbose: bool = false,
    ignore_non_empty: bool = false,
    dirs: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.dirs.items) |item| {
            allocator.free(item);
        }
        self.dirs.deinit(allocator);
    }
};

const RmdirError = Dir.DeleteDirError || error{InvalidArgument};

/// rmdir(2) fails with EINVAL when the last path component is "." (POSIX),
/// and on Darwin also when it is "..". Zig's `Dir.deleteDir` treats EINVAL
/// as a programmer bug and aborts the process, so detect these paths up
/// front and surface the same "Invalid argument" diagnostic GNU rmdir
/// reports (previously `zrmdir .` died with SIGABRT).
fn isDotFinalComponent(path: []const u8) bool {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    const trimmed = path[0..end];
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |idx| idx + 1 else 0;
    const comp = trimmed[start..];
    if (std.mem.eql(u8, comp, ".")) return true;
    if (comptime builtin.os.tag.isDarwin()) {
        if (std.mem.eql(u8, comp, "..")) return true;
    }
    return false;
}

fn removeDir(io: Io, path: []const u8) RmdirError!void {
    if (isDotFinalComponent(path)) return error.InvalidArgument;
    return Dir.deleteDir(Dir.cwd(), io, path);
}

/// strerror-style text matching what GNU rmdir prints for the same errno
/// on this platform.
fn errorMessage(err: RmdirError) []const u8 {
    return switch (err) {
        error.InvalidArgument => "Invalid argument",
        error.DirNotEmpty => "Directory not empty",
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.PermissionDenied => "Operation not permitted",
        error.NotDir => "Not a directory",
        error.ReadOnlyFileSystem => "Read-only file system",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.NameTooLong => "File name too long",
        error.FileBusy => if (comptime builtin.os.tag.isDarwin())
            "Resource busy"
        else
            "Device or resource busy",
        else => @errorName(err),
    };
}

/// Truncate `dir` to its parent the way GNU rmdir's remove_parents does:
/// cut at the last '/', collapsing any run of consecutive slashes, keeping
/// a leading "/" for absolute paths. Returns null when there is no parent
/// left to climb to.
fn parentOf(dir: []const u8) ?[]const u8 {
    const last_slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
    var end = last_slash;
    while (end > 0 and dir[end - 1] == '/') end -= 1;
    if (end == 0) end = 1; // absolute path climbed all the way to "/"
    // "/" (and slash-runs collapsing to it) is its own last-slash prefix.
    // Returning it would make a `while (parentOf(dir)) |p| dir = p;` climb
    // fixpoint on the root forever; the root has no parent, so stop.
    if (end == dir.len) return null;
    return dir[0..end];
}

fn stripTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

/// Process one operand the way GNU rmdir's main loop does. Returns true on
/// success (including ignored failures), false if a diagnostic was printed.
fn processOperand(io: Io, stdout: *Io.Writer, path: []const u8, config: *const Config) bool {
    // GNU prints the verbose line BEFORE the attempt, operand as given.
    if (config.verbose) printVerbose(stdout, path);

    removeDir(io, path) catch |err| {
        if (err == error.DirNotEmpty and config.ignore_non_empty) {
            return true;
        }
        printErrorFmt("failed to remove '{s}': {s}", .{ path, errorMessage(err) });
        return false;
    };

    if (config.parents) {
        return removeParents(io, stdout, path, config);
    }
    return true;
}

/// GNU remove_parents: strip trailing slashes, then repeatedly truncate to
/// the parent and remove it, stopping (quietly with --ignore-fail-on-non-empty,
/// with a diagnostic otherwise) at the first failure.
fn removeParents(io: Io, stdout: *Io.Writer, path: []const u8, config: *const Config) bool {
    var dir = stripTrailingSlashes(path);
    while (parentOf(dir)) |parent| {
        dir = parent;
        if (config.verbose) printVerbose(stdout, dir);
        removeDir(io, dir) catch |err| {
            if (err == error.DirNotEmpty and config.ignore_non_empty) {
                return true;
            }
            printErrorFmt("failed to remove directory '{s}': {s}", .{ dir, errorMessage(err) });
            return false;
        };
    }
    return true;
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

        // A lone '-' is an ordinary operand in GNU rmdir, not an option.
        if (arg.len > 1 and arg[0] == '-') {
            if (arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--parents")) {
                    config.parents = true;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
                } else if (std.mem.eql(u8, arg, "--ignore-fail-on-non-empty")) {
                    config.ignore_non_empty = true;
                } else if (std.mem.eql(u8, arg, "--")) {
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        try config.dirs.append(allocator, try allocator.dupe(u8, args[i]));
                    }
                    break;
                } else {
                    printErrorFmt("unrecognized option '{s}'", .{arg});
                    printTryHelp();
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'p' => config.parents = true,
                        'v' => config.verbose = true,
                        else => {
                            printErrorFmt("invalid option -- '{c}'", .{ch});
                            printTryHelp();
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.dirs.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.dirs.items.len == 0) {
        printError("missing operand");
        printTryHelp();
        std.process.exit(1);
    }

    return config;
}

fn printVerbose(stdout: *Io.Writer, path: []const u8) void {
    // GNU wording: present tense, comma, printed before the attempt.
    stdout.print("zrmdir: removing directory, '{s}'\n", .{path}) catch {};
    // Flush per line: GNU's error() flushes stdout before writing stderr,
    // so verbose lines must not sit buffered past a subsequent diagnostic.
    stdout.flush() catch {};
}

fn printError(msg: []const u8) void {
    std.debug.print("zrmdir: {s}\n", .{msg});
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zrmdir: " ++ fmt ++ "\n", args);
}

fn printTryHelp() void {
    std.debug.print("Try 'zrmdir --help' for more information.\n", .{});
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [2048]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writerStreaming(io, &buf);
    writer.interface.writeAll(
        \\Usage: zrmdir [OPTION]... DIRECTORY...
        \\Remove the DIRECTORY(ies), if they are empty.
        \\
        \\      --ignore-fail-on-non-empty
        \\                    ignore each failure to remove a non-empty directory
        \\  -p, --parents     remove DIRECTORY and its ancestors;
        \\                    e.g., 'zrmdir -p a/b' is similar to 'zrmdir a/b a'
        \\  -v, --verbose     output a diagnostic for every directory processed
        \\      --help        display this help and exit
        \\      --version     output version information and exit
        \\
        \\zrmdir - High-performance directory removal utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writerStreaming(io, &buf);
    writer.interface.writeAll("zrmdir 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    const io = Io.Threaded.global_single_threaded.io();

    var config = parseArgs(allocator, init.minimal.args) catch {
        printError("failed to parse arguments");
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    // ONE streaming stdout writer for the whole run. The previous code
    // built a fresh positional writer per verbose line, so with stdout
    // redirected to a regular file every line was pwritten at offset 0,
    // overwriting the previous one.
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var error_occurred = false;

    for (config.dirs.items) |dir| {
        if (!processOperand(io, stdout, dir, &config)) {
            error_occurred = true;
        }
    }

    stdout.flush() catch {};

    if (error_occurred) {
        std.process.exit(1);
    }
}

// ---- unit tests (pure helpers) ----
//
// End-to-end GNU parity is covered by src/gnu_parity_test.zig, which runs
// this binary and the real GNU `rmdir` (grmdir) on identical fixtures and
// diffs their stdout/stderr/exit-code. Both files are wired into
// `zig build test`. The parity test skips itself if grmdir is not installed.

test "parentOf follows GNU remove_parents truncation" {
    const t = std.testing;
    try t.expectEqualStrings("a/b", parentOf("a/b/c").?);
    try t.expectEqualStrings("a", parentOf("a/b").?);
    try t.expectEqual(@as(?[]const u8, null), parentOf("a"));
    // slash runs collapse: "a//b" climbs to "a", not "a/"
    try t.expectEqualStrings("a", parentOf("a//b").?);
    // "./a" climbs to "." (GNU then reports EINVAL on it)
    try t.expectEqualStrings(".", parentOf("./a").?);
    // absolute paths keep the leading "/"
    try t.expectEqualStrings("/", parentOf("/a").?);
    try t.expectEqualStrings("/a", parentOf("/a/b").?);
    // "/" is the root: it has no parent. Without this, a parent-climb loop
    // fixpoints on "/"->"/" forever instead of terminating.
    try t.expectEqual(@as(?[]const u8, null), parentOf("/"));
}

test "stripTrailingSlashes" {
    const t = std.testing;
    try t.expectEqualStrings("a/b/c", stripTrailingSlashes("a/b/c/"));
    try t.expectEqualStrings("a/b/c", stripTrailingSlashes("a/b/c//"));
    try t.expectEqualStrings("a", stripTrailingSlashes("a"));
    try t.expectEqualStrings("/", stripTrailingSlashes("/"));
    try t.expectEqualStrings("", stripTrailingSlashes(""));
}

test "isDotFinalComponent detects EINVAL paths" {
    const t = std.testing;
    try t.expect(isDotFinalComponent("."));
    try t.expect(isDotFinalComponent("./"));
    try t.expect(isDotFinalComponent("a/."));
    try t.expect(isDotFinalComponent("a/./"));
    try t.expect(!isDotFinalComponent("a"));
    try t.expect(!isDotFinalComponent("a.b"));
    try t.expect(!isDotFinalComponent(".hidden"));
    try t.expect(!isDotFinalComponent("a/.b"));
    try t.expect(!isDotFinalComponent(""));
    try t.expect(!isDotFinalComponent("/"));
    if (comptime builtin.os.tag.isDarwin()) {
        try t.expect(isDotFinalComponent(".."));
        try t.expect(isDotFinalComponent("a/.."));
        try t.expect(!isDotFinalComponent("..a"));
        try t.expect(!isDotFinalComponent("a..b"));
    }
}
