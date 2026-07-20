const std = @import("std");
const posix = std.posix;
const libc = std.c;

const prog_name = "ztac";

// ---------------------------------------------------------------------------
// POSIX regex (for -r / --regex). std.c does not expose these, so declare the
// extern surface directly. ABI verified against macOS <regex.h>:
//   sizeof(regex_t)   == 32, contains pointers -> 8-byte aligned
//   sizeof(regmatch_t)== 16, { i64 rm_so; i64 rm_eo; } (rm_so@0, rm_eo@8)
//   REG_EXTENDED == 1, REG_NOTBOL == 1, REG_NOMATCH == 1
// (see cc probe in the audit; regoff_t is 8 bytes / __int64_t on Darwin)
const regex_t = extern struct { _opaque: [4]u64 };
const regmatch_t = extern struct { rm_so: i64, rm_eo: i64 };
const REG_EXTENDED: c_int = 1;
const REG_NOTBOL: c_int = 1;
const REG_NOMATCH: c_int = 1;
extern "c" fn regcomp(preg: *regex_t, pattern: [*:0]const u8, cflags: c_int) c_int;
extern "c" fn regexec(preg: *const regex_t, string: [*:0]const u8, nmatch: usize, pmatch: [*]regmatch_t, eflags: c_int) c_int;
extern "c" fn regfree(preg: *regex_t) void;

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

fn cErrno() c_int {
    return libc._errno().*;
}

const EINTR: c_int = @intFromEnum(posix.E.INTR);

// ---------------------------------------------------------------------------

const OutputBuffer = struct {
    buf: [16384]u8 = undefined,
    pos: usize = 0,
    err: bool = false,

    fn write(self: *OutputBuffer, data: []const u8) void {
        var rem = data;
        while (rem.len > 0) {
            const space = self.buf.len - self.pos;
            const n = @min(space, rem.len);
            @memcpy(self.buf[self.pos .. self.pos + n], rem[0..n]);
            self.pos += n;
            rem = rem[n..];
            if (self.pos == self.buf.len) self.flush();
        }
    }

    fn flush(self: *OutputBuffer) void {
        if (self.pos > 0) {
            if (!fullWrite(libc.STDOUT_FILENO, self.buf[0..self.pos])) self.err = true;
            self.pos = 0;
        }
    }
};

/// Write every byte, retrying partial writes and EINTR. Returns false on a real
/// write error (EPIPE/ENOSPC/...) so the caller can report a nonzero exit.
fn fullWrite(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = libc.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (cErrno() == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn writeStderr(bytes: []const u8) void {
    _ = fullWrite(libc.STDERR_FILENO, bytes);
}

// ---------------------------------------------------------------------------
// Record splitting
// ---------------------------------------------------------------------------

const Range = struct { start: usize, end: usize };

const Config = struct {
    before: bool = false,
    regex: bool = false,
    separator: []const u8 = "\n",
};

fn findLiteral(allocator: std.mem.Allocator, content: []const u8, sep: []const u8, matches: *std.ArrayListUnmanaged(Range)) !void {
    if (sep.len == 0) return; // empty separator -> whole content is one record
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, content, i, sep)) |idx| {
        try matches.append(allocator, .{ .start = idx, .end = idx + sep.len });
        i = idx + sep.len;
    }
}

/// Find regex separator matches. `content` must be NUL-terminated at content.len.
fn findRegex(allocator: std.mem.Allocator, content_z: [:0]const u8, re: *const regex_t, matches: *std.ArrayListUnmanaged(Range)) !void {
    const len = content_z.len;
    var pos: usize = 0;
    var m: regmatch_t = undefined;
    while (pos <= len) {
        const eflags: c_int = if (pos > 0) REG_NOTBOL else 0;
        const start_ptr: [*:0]const u8 = @ptrCast(content_z.ptr + pos);
        const r = regexec(re, start_ptr, 1, @ptrCast(&m), eflags);
        if (r == REG_NOMATCH) break;
        if (r != 0) break; // treat other regexec errors as "no more matches"
        const ms = pos + @as(usize, @intCast(m.rm_so));
        const me = pos + @as(usize, @intCast(m.rm_eo));
        try matches.append(allocator, .{ .start = ms, .end = me });
        if (me == ms) {
            pos = ms + 1; // zero-length match: advance to avoid an infinite loop
        } else {
            pos = me;
        }
    }
}

/// Emit records in reverse. In default (after) mode each record ends with a
/// separator; in --before mode each record begins with one — matching GNU tac.
fn emitReversed(content: []const u8, matches: []const Range, before: bool, out: *OutputBuffer) void {
    // Build the record boundary list on the fly, then walk it backwards.
    // Records are contiguous and cover all of `content`, so we can emit in
    // reverse by walking boundaries from the end.
    if (before) {
        // boundaries at match starts: [0, s0), [s0, s1), ... [s_{k-1}, len)
        var end_idx: usize = content.len;
        var i: usize = matches.len;
        while (i > 0) {
            i -= 1;
            const start = matches[i].start;
            out.write(content[start..end_idx]);
            end_idx = start;
        }
        // leading record [0, first_start)
        out.write(content[0..end_idx]);
    } else {
        // boundaries at match ends: [0, e0), [e0, e1), ... plus trailing [e_last, len)
        // trailing remainder after the last separator
        const last_end: usize = if (matches.len > 0) matches[matches.len - 1].end else 0;
        if (last_end < content.len) {
            out.write(content[last_end..content.len]);
        }
        var start_idx: usize = last_end;
        var i: usize = matches.len;
        while (i > 0) {
            i -= 1;
            const rec_start: usize = if (i == 0) 0 else matches[i - 1].end;
            out.write(content[rec_start..start_idx]);
            start_idx = rec_start;
        }
    }
}

fn reverseLines(allocator: std.mem.Allocator, content: []const u8, cfg: Config, out: *OutputBuffer) !void {
    var matches = std.ArrayListUnmanaged(Range).empty;
    defer matches.deinit(allocator);

    if (cfg.regex) {
        // regexec needs a NUL-terminated string.
        const content_z = try allocator.dupeZ(u8, content);
        defer allocator.free(content_z);
        var re: regex_t = undefined;
        const sep_z = try allocator.dupeZ(u8, cfg.separator);
        defer allocator.free(sep_z);
        if (regcomp(&re, sep_z.ptr, REG_EXTENDED) != 0) return error.BadRegex;
        defer regfree(&re);
        try findRegex(allocator, content_z, &re, &matches);
    } else {
        try findLiteral(allocator, content, cfg.separator, &matches);
    }

    emitReversed(content, matches.items, cfg.before, out);
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

const ReadError = error{ ReadFailed, OutOfMemory };

fn readAll(allocator: std.mem.Allocator, fd: c_int, errno_out: *c_int) ReadError![]u8 {
    var content = std.ArrayListUnmanaged(u8).empty;
    errdefer content.deinit(allocator);
    var buf: [65536]u8 = undefined;

    while (true) {
        const n = libc.read(fd, &buf, buf.len);
        if (n < 0) {
            const e = cErrno();
            if (e == EINTR) continue;
            errno_out.* = e;
            return error.ReadFailed;
        }
        if (n == 0) break; // genuine EOF
        try content.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    return content.toOwnedSlice(allocator);
}

fn reportOpenError(path: []const u8, errno: c_int) void {
    // GNU: "gtac: failed to open 'PATH' for reading: <strerror>"
    writeStderr(prog_name ++ ": failed to open '");
    writeStderr(path);
    writeStderr("' for reading: ");
    writeStderr(std.mem.span(strerror(errno)));
    writeStderr("\n");
}

fn reportReadError(path: []const u8, errno: c_int) void {
    // GNU: "gtac: PATH: read error: <strerror>"
    writeStderr(prog_name ++ ": ");
    writeStderr(path);
    writeStderr(": read error: ");
    writeStderr(std.mem.span(strerror(errno)));
    writeStderr("\n");
}

/// Returns true on success, false if the file could not be opened or read
/// (a nonzero-exit condition, matching GNU tac).
fn processFile(allocator: std.mem.Allocator, path: []const u8, cfg: Config, out: *OutputBuffer) bool {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) {
        reportOpenError(path, @intFromEnum(posix.E.NAMETOOLONG));
        return false;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    const fd = libc.open(path_z, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        reportOpenError(path, cErrno());
        return false;
    }
    defer _ = libc.close(fd);

    var read_errno: c_int = 0;
    const content = readAll(allocator, fd, &read_errno) catch |err| switch (err) {
        error.ReadFailed => {
            reportReadError(path, read_errno);
            return false;
        },
        error.OutOfMemory => {
            writeStderr(prog_name ++ ": out of memory\n");
            return false;
        },
    };
    defer allocator.free(content);

    reverseLines(allocator, content, cfg, out) catch {
        writeStderr(prog_name ++ ": internal error processing input\n");
        return false;
    };
    return true;
}

fn processStdin(allocator: std.mem.Allocator, cfg: Config, out: *OutputBuffer) bool {
    var read_errno: c_int = 0;
    const content = readAll(allocator, posix.STDIN_FILENO, &read_errno) catch |err| switch (err) {
        error.ReadFailed => {
            reportReadError("-", read_errno);
            return false;
        },
        error.OutOfMemory => {
            writeStderr(prog_name ++ ": out of memory\n");
            return false;
        },
    };
    defer allocator.free(content);
    reverseLines(allocator, content, cfg, out) catch {
        writeStderr(prog_name ++ ": internal error processing input\n");
        return false;
    };
    return true;
}

// ---------------------------------------------------------------------------

const help_text =
    \\Usage: ztac [OPTION]... [FILE]...
    \\Write each FILE to standard output, last line first.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -b, --before             attach the separator before instead of after
    \\  -r, --regex              interpret the separator as a regular expression
    \\  -s, --separator=STRING   use STRING as the separator instead of newline
    \\      --help               display this help and exit
    \\      --version            output version information and exit
    \\
;

const version_text = prog_name ++ " (zig_core_utils) tac-compatible\n";

fn optArg(args: *std.process.Args.Iterator, flag: []const u8) ?[]const u8 {
    return args.next() orelse {
        writeStderr(prog_name ++ ": option requires an argument -- '");
        writeStderr(flag);
        writeStderr("'\n");
        return null;
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    var cfg = Config{};
    var files = std.ArrayListUnmanaged([]const u8).empty;
    defer files.deinit(allocator);

    var no_more_opts = false;

    while (args.next()) |arg| {
        if (no_more_opts) {
            try files.append(allocator, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            no_more_opts = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            _ = fullWrite(libc.STDOUT_FILENO, help_text);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            _ = fullWrite(libc.STDOUT_FILENO, version_text);
            return;
        } else if (std.mem.eql(u8, arg, "--before")) {
            cfg.before = true;
        } else if (std.mem.eql(u8, arg, "--regex")) {
            cfg.regex = true;
        } else if (std.mem.eql(u8, arg, "--separator")) {
            cfg.separator = optArg(&args, "separator") orelse std.process.exit(1);
        } else if (std.mem.startsWith(u8, arg, "--separator=")) {
            cfg.separator = arg["--separator=".len..];
        } else if (arg.len > 1 and arg[0] == '-' and !std.mem.eql(u8, arg, "-")) {
            // Short-option cluster, e.g. -b, -rs,, -bs SEP.
            var j: usize = 1;
            var consumed_sep = false;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'b' => cfg.before = true,
                    'r' => cfg.regex = true,
                    's' => {
                        if (j + 1 < arg.len) {
                            cfg.separator = arg[j + 1 ..];
                        } else {
                            cfg.separator = optArg(&args, "s") orelse std.process.exit(1);
                        }
                        consumed_sep = true;
                    },
                    else => {
                        writeStderr(prog_name ++ ": invalid option -- '");
                        writeStderr(arg[j .. j + 1]);
                        writeStderr("'\nTry '" ++ prog_name ++ " --help' for more information.\n");
                        std.process.exit(1);
                    },
                }
                if (consumed_sep) break;
            }
        } else {
            // "-" (stdin) or a plain file path.
            try files.append(allocator, arg);
        }
    }

    var out = OutputBuffer{};
    var had_error = false;

    if (files.items.len == 0) {
        if (!processStdin(allocator, cfg, &out)) had_error = true;
    } else {
        for (files.items) |path| {
            const ok = if (std.mem.eql(u8, path, "-"))
                processStdin(allocator, cfg, &out)
            else
                processFile(allocator, path, cfg, &out);
            if (!ok) had_error = true;
        }
    }

    out.flush();
    if (out.err) had_error = true;

    if (had_error) std.process.exit(1);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test {
    _ = @import("gnu_parity_test.zig");
}
