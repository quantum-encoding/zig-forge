//! zusers - Print the usernames of users currently logged in
//!
//! High-performance `users` (GNU coreutils) implementation in Zig.
//!
//! Reads the utmpx database through the platform libc (`getutxent` family),
//! exactly as GNU `users` does, so it works on macOS/BSD (/var/run/utmpx) and
//! glibc Linux (/var/run/utmp) without hard-coding a struct layout. An optional
//! FILE operand selects a different database via `utmpxname`, matching GNU.
//! Usernames of USER_PROCESS records are collected, sorted (strcmp order, like
//! GNU), and printed space-separated followed by a newline.

const std = @import("std");
const libc = std.c;
const c = @cImport({
    @cInclude("utmpx.h");
});

const VERSION = "0.16.0";

// POSIX ut_type value for an active login session (identical on Linux and
// macOS/BSD). GNU `users` counts only these records.
const USER_PROCESS: c_short = 7;

/// EINTR-safe, partial-write-safe write of an entire slice to a raw fd.
/// The pre-fix code discarded libc.write's return value, silently dropping
/// bytes on a short write or EINTR to a pipe/slow sink.
fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = libc.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (libc._errno().* == @intFromEnum(libc.E.INTR)) continue;
            return; // unrecoverable write error
        }
        if (n == 0) return;
        // n is a positive isize here; write() never reports more than requested,
        // but clamp to the remaining length so the narrowing cast is bounded.
        off += @min(@as(usize, @intCast(n)), bytes.len - off);
    }
}

fn writeStdout(data: []const u8) void {
    writeAll(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeAll(libc.STDERR_FILENO, data);
}

const USAGE =
    \\Usage: zusers [OPTION]... [FILE]
    \\Print the user names of users currently logged in to the current host.
    \\If FILE is not specified, use the system utmp/utmpx database.
    \\/var/log/wtmp as FILE is common.
    \\
    \\      --help     display this help and exit
    \\      --version  output version information and exit
    \\
;

fn printUsage() void {
    // GNU writes --help to STDOUT (exit 0) so `zusers --help > file` is non-empty.
    writeStdout(USAGE);
}

fn printVersion() void {
    writeStdout("zusers (zig coreutils) " ++ VERSION ++ "\n");
}

pub fn nullTerminated(buf: []const u8) []const u8 {
    for (buf, 0..) |ch, i| {
        if (ch == 0) return buf[0..i];
    }
    return buf;
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Collect the usernames of all USER_PROCESS entries in the currently-selected
/// utmpx database into `names` (each entry duped from the fixed-size field).
fn collectUsers(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8)) void {
    c.setutxent();
    defer c.endutxent();

    while (c.getutxent()) |entry| {
        if (entry[0].ut_type != USER_PROCESS) continue;
        const user = nullTerminated(entry[0].ut_user[0..]);
        if (user.len == 0) continue;
        const owned = allocator.dupe(u8, user) catch return; // best-effort on OOM
        names.append(allocator, owned) catch {
            allocator.free(owned);
            return;
        };
    }
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    var file: ?[]const u8 = null; // FILE operand (utmpx database to read)
    var end_of_options = false;

    while (args.next()) |arg| {
        if (!end_of_options and std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
        } else if (!end_of_options and std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (!end_of_options and std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (!end_of_options and arg.len > 1 and arg[0] == '-') {
            // Unknown option: GNU emits a diagnostic and exits 1 rather than
            // silently ignoring it (pre-fix behavior returned 0).
            writeStderr("zusers: unrecognized option '");
            writeStderr(arg);
            writeStderr("'\nTry 'zusers --help' for more information.\n");
            std.process.exit(1);
        } else {
            // Positional FILE operand. GNU accepts exactly one; a second is an
            // "extra operand" error (exit 1).
            if (file != null) {
                writeStderr("zusers: extra operand '");
                writeStderr(arg);
                writeStderr("'\nTry 'zusers --help' for more information.\n");
                std.process.exit(1);
            }
            file = arg;
        }
    }

    // Point the utmpx reader at FILE if given. GNU produces empty output (exit 0)
    // for a missing/unreadable database rather than erroring, so a failed
    // utmpxname just yields no users.
    if (file) |path| {
        const z = allocator.dupeZ(u8, path) catch {
            std.process.exit(1);
        };
        defer allocator.free(z);
        _ = c.utmpxname(z.ptr);
    }

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    collectUsers(allocator, &names);

    if (names.items.len == 0) return; // GNU prints nothing (not even a newline)

    // GNU sorts usernames (strcmp order) before printing.
    std.mem.sort([]const u8, names.items, {}, lessThanName);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (names.items, 0..) |name, i| {
        if (i != 0) out.append(allocator, ' ') catch return;
        out.appendSlice(allocator, name) catch return;
    }
    out.append(allocator, '\n') catch return;

    writeStdout(out.items);
}
