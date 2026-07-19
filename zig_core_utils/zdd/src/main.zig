//! zdd - Convert and copy a file
//!
//! High-performance dd implementation in Zig.
//! Supports block-level I/O with conversion options.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

extern "c" fn time(t: ?*i64) i64;
extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

const SEEK_SET: c_int = 0;
const SEEK_CUR: c_int = 1;

const VERSION = "1.0.0";

// Global state for signal handler
var g_stats: *Stats = undefined;
var g_show_progress: bool = false;

const Stats = struct {
    records_in_full: u64 = 0,
    records_in_partial: u64 = 0,
    records_out_full: u64 = 0,
    records_out_partial: u64 = 0,
    bytes_copied: u64 = 0,
    start_time: i64 = 0,
};

const ConvFlags = struct {
    lcase: bool = false,
    ucase: bool = false,
    swab: bool = false,
    notrunc: bool = false,
    noerror: bool = false,
    sync: bool = false,
};

const Config = struct {
    input_file: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    ibs: usize = 512,
    obs: usize = 512,
    bs_set: bool = false,
    count: ?u64 = null,
    skip: u64 = 0,
    seek: u64 = 0,
    conv: ConvFlags = .{},
    status: enum { default, none, noxfer, progress } = .default,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn writeNum(n: u64) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    writeStderr(s);
}

/// Print "zdd: <parts...>\n" to stderr (diagnostics always go to stderr,
/// even under status=none, matching GNU dd).
fn diag(parts: []const []const u8) void {
    writeStderr("zdd: ");
    for (parts) |p| writeStderr(p);
    writeStderr("\n");
}

fn errnoMsg() []const u8 {
    return std.mem.span(strerror(libc._errno().*));
}

fn printUsage() void {
    const usage =
        \\Usage: zdd [OPERAND]...
        \\Copy a file, converting and formatting according to the operands.
        \\
        \\Operands:
        \\  if=FILE        Read from FILE instead of stdin
        \\  of=FILE        Write to FILE instead of stdout
        \\  bs=BYTES       Read and write BYTES bytes at a time
        \\  ibs=BYTES      Read BYTES bytes at a time (default: 512)
        \\  obs=BYTES      Write BYTES bytes at a time (default: 512)
        \\  count=N        Copy only N input blocks
        \\  skip=N         Skip N ibs-sized blocks at start of input
        \\  seek=N         Skip N obs-sized blocks at start of output
        \\  conv=CONVS     Convert as per comma-separated list
        \\  status=LEVEL   Transfer info to stderr (none|noxfer|progress)
        \\
        \\CONVS:
        \\  lcase      Change uppercase to lowercase
        \\  ucase      Change lowercase to uppercase
        \\  swab       Swap every pair of input bytes
        \\  notrunc    Do not truncate the output file
        \\  noerror    Continue after read errors
        \\  sync       Pad input blocks with NULs to ibs-size
        \\
        \\BYTES may be followed by: w=2, b=512, K=1024, M=1024*1024, G=1024^3, T=1024^4
        \\
        \\Send SIGUSR1 to print I/O statistics.
        \\
        \\  --help     Display this help
        \\  --version  Output version
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zdd " ++ VERSION ++ "\n");
}

/// Parse a size with GNU dd suffixes (subset): w=2, b=512, K/k, M/m, G/g, T/t.
/// Overflow-checked; returns null on any invalid input.
fn parseSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;

    var multiplier: u64 = 1;
    var num_end = s.len;

    // Check for suffix
    switch (s[s.len - 1]) {
        'w' => {
            multiplier = 2;
            num_end = s.len - 1;
        },
        'b' => {
            multiplier = 512;
            num_end = s.len - 1;
        },
        'K', 'k' => {
            multiplier = 1024;
            num_end = s.len - 1;
        },
        'M', 'm' => {
            multiplier = 1024 * 1024;
            num_end = s.len - 1;
        },
        'G', 'g' => {
            multiplier = 1024 * 1024 * 1024;
            num_end = s.len - 1;
        },
        'T', 't' => {
            multiplier = 1024 * 1024 * 1024 * 1024;
            num_end = s.len - 1;
        },
        else => {},
    }

    if (num_end == 0) return null;

    const num = std.fmt.parseInt(u64, s[0..num_end], 10) catch return null;
    return std.math.mul(u64, num, multiplier) catch null;
}

/// Block sizes must be > 0 and fit in usize (GNU: "invalid number: '0'").
fn parseBlockSize(s: []const u8) ?usize {
    const v = parseSize(s) orelse return null;
    if (v == 0) return null;
    return std.math.cast(usize, v) orelse null;
}

/// Returns the first invalid conversion token, or null if all were valid.
/// GNU dd rejects unknown conversions with exit 1; silently ignoring e.g. a
/// "notrunk" typo would truncate data the user explicitly asked to keep.
fn parseConv(s: []const u8, conv: *ConvFlags) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, s, ',');
    while (iter.next()) |opt| {
        if (std.mem.eql(u8, opt, "lcase")) {
            conv.lcase = true;
        } else if (std.mem.eql(u8, opt, "ucase")) {
            conv.ucase = true;
        } else if (std.mem.eql(u8, opt, "swab")) {
            conv.swab = true;
        } else if (std.mem.eql(u8, opt, "notrunc")) {
            conv.notrunc = true;
        } else if (std.mem.eql(u8, opt, "noerror")) {
            conv.noerror = true;
        } else if (std.mem.eql(u8, opt, "sync")) {
            conv.sync = true;
        } else {
            return opt;
        }
    }
    return null;
}

fn parseArgs(args: []const []const u8) ?Config {
    var cfg = Config{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "if=")) {
            cfg.input_file = arg[3..];
        } else if (std.mem.startsWith(u8, arg, "of=")) {
            cfg.output_file = arg[3..];
        } else if (std.mem.startsWith(u8, arg, "bs=")) {
            const size = parseBlockSize(arg[3..]) orelse {
                diag(&.{ "invalid number: '", arg[3..], "'" });
                return null;
            };
            cfg.ibs = size;
            cfg.obs = size;
            cfg.bs_set = true;
        } else if (std.mem.startsWith(u8, arg, "ibs=")) {
            cfg.ibs = parseBlockSize(arg[4..]) orelse {
                diag(&.{ "invalid number: '", arg[4..], "'" });
                return null;
            };
        } else if (std.mem.startsWith(u8, arg, "obs=")) {
            cfg.obs = parseBlockSize(arg[4..]) orelse {
                diag(&.{ "invalid number: '", arg[4..], "'" });
                return null;
            };
        } else if (std.mem.startsWith(u8, arg, "count=")) {
            cfg.count = parseSize(arg[6..]) orelse {
                diag(&.{ "invalid number: '", arg[6..], "'" });
                return null;
            };
        } else if (std.mem.startsWith(u8, arg, "skip=")) {
            cfg.skip = parseSize(arg[5..]) orelse {
                diag(&.{ "invalid number: '", arg[5..], "'" });
                return null;
            };
        } else if (std.mem.startsWith(u8, arg, "seek=")) {
            cfg.seek = parseSize(arg[5..]) orelse {
                diag(&.{ "invalid number: '", arg[5..], "'" });
                return null;
            };
        } else if (std.mem.startsWith(u8, arg, "conv=")) {
            if (parseConv(arg[5..], &cfg.conv)) |bad| {
                diag(&.{ "invalid conversion: '", bad, "'" });
                return null;
            }
        } else if (std.mem.startsWith(u8, arg, "status=")) {
            const val = arg[7..];
            if (std.mem.eql(u8, val, "none")) {
                cfg.status = .none;
            } else if (std.mem.eql(u8, val, "noxfer")) {
                cfg.status = .noxfer;
            } else if (std.mem.eql(u8, val, "progress")) {
                cfg.status = .progress;
            } else {
                diag(&.{ "invalid status level: '", val, "'" });
                return null;
            }
        } else {
            // GNU dd rejects unrecognized operands (oflag=, cbs=, typos)
            // with exit 1 instead of silently ignoring them.
            diag(&.{ "unrecognized operand '", arg, "'" });
            return null;
        }
    }

    return cfg;
}

fn applyConversions(buf: []u8, len: usize, conv: ConvFlags) void {
    // Swap bytes
    if (conv.swab) {
        var i: usize = 0;
        while (i + 1 < len) : (i += 2) {
            const tmp = buf[i];
            buf[i] = buf[i + 1];
            buf[i + 1] = tmp;
        }
    }

    // Case conversion
    if (conv.lcase) {
        for (buf[0..len]) |*c| {
            if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
        }
    } else if (conv.ucase) {
        for (buf[0..len]) |*c| {
            if (c.* >= 'a' and c.* <= 'z') c.* -= 32;
        }
    }
}

fn printStats(stats: *Stats, xfer: bool) void {
    const elapsed = time(null) - stats.start_time;

    writeNum(stats.records_in_full);
    writeStderr("+");
    writeNum(stats.records_in_partial);
    writeStderr(" records in\n");

    writeNum(stats.records_out_full);
    writeStderr("+");
    writeNum(stats.records_out_partial);
    writeStderr(" records out\n");

    // status=noxfer suppresses the transfer-rate line (GNU dd).
    if (!xfer) return;

    writeNum(stats.bytes_copied);
    writeStderr(" bytes copied");

    if (elapsed > 0) {
        writeStderr(", ");
        writeNum(@intCast(elapsed));
        writeStderr(" s, ");
        writeNum(stats.bytes_copied / @as(u64, @intCast(elapsed)));
        writeStderr(" B/s");
    }
    writeStderr("\n");
}

fn signalHandler(_: c_int) callconv(.c) void {
    if (g_show_progress) {
        printStats(g_stats, true);
    }
}

/// Copy `path` into a NUL-terminated stack buffer for libc.open.
/// Errors out (exit 1) on over-long paths instead of overflowing the stack.
fn openPath(path: []const u8, flags: libc.O, mode: libc.mode_t) c_int {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) {
        diag(&.{ "failed to open '", path, "': File name too long" });
        std.process.exit(1);
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    const fd = libc.open(path_z, flags, mode);
    if (fd < 0) {
        const em = errnoMsg();
        diag(&.{ "failed to open '", path, "': ", em });
        std.process.exit(1);
    }
    return fd;
}

/// Output side: either writes each input block directly (bs= semantics) or
/// reblocks into obs-sized output blocks (ibs=/obs= semantics), counting
/// records by the size of each actual write, like GNU dd.
const Output = struct {
    fd: c_int,
    name: []const u8,
    obs: usize,
    direct: bool,
    obuf: []u8,
    fill: usize = 0,
    stats: *Stats,

    /// Returns false on write error (diagnostic already printed).
    fn emit(self: *Output, data: []const u8) bool {
        if (self.direct) return self.writeAll(data);
        var d = data;
        while (d.len > 0) {
            const n = @min(self.obs - self.fill, d.len);
            @memcpy(self.obuf[self.fill..][0..n], d[0..n]);
            self.fill += n;
            d = d[n..];
            if (self.fill == self.obs) {
                if (!self.writeAll(self.obuf)) return false;
                self.fill = 0;
            }
        }
        return true;
    }

    fn flush(self: *Output) bool {
        if (!self.direct and self.fill > 0) {
            const ok = self.writeAll(self.obuf[0..self.fill]);
            self.fill = 0;
            return ok;
        }
        return true;
    }

    fn writeAll(self: *Output, data: []const u8) bool {
        var written: usize = 0;
        while (written < data.len) {
            const w = libc.write(self.fd, data[written..].ptr, data.len - written);
            if (w < 0) {
                const em = errnoMsg();
                diag(&.{ "error writing '", self.name, "': ", em });
                return false;
            }
            written += @intCast(w);
        }
        if (data.len == self.obs) {
            self.stats.records_out_full += 1;
        } else {
            self.stats.records_out_partial += 1;
        }
        self.stats.bytes_copied += data.len;
        return true;
    }
};

pub fn main(init: std.process.Init) void {
    // Collect args
    var args_storage: [256][]const u8 = undefined;
    var args_count: usize = 0;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name
    while (args_iter.next()) |arg| {
        if (args_count >= args_storage.len) {
            diag(&.{"too many operands"});
            std.process.exit(1);
        }
        args_storage[args_count] = arg;
        args_count += 1;
    }

    const cfg = parseArgs(args_storage[0..args_count]) orelse {
        std.process.exit(1);
    };

    var stats = Stats{};
    stats.start_time = time(null);

    // Setup signal handler for progress (platform-correct SIGUSR1 —
    // hardcoding 10 installed the handler on SIGBUS on macOS and let a real
    // SIGUSR1 kill the process).
    g_stats = &stats;
    g_show_progress = true;
    _ = signal(@intFromEnum(posix.SIG.USR1), signalHandler);

    const in_name: []const u8 = cfg.input_file orelse "standard input";
    const out_name: []const u8 = cfg.output_file orelse "standard output";

    // Open input
    const in_fd: c_int = if (cfg.input_file) |path|
        openPath(path, .{ .ACCMODE = .RDONLY }, 0)
    else
        libc.STDIN_FILENO;
    defer {
        if (cfg.input_file != null) _ = libc.close(in_fd);
    }

    // Open output. GNU dd only O_TRUNCs up front when there is no seek=;
    // with seek= it preserves the leading bytes and ftruncates at the seek
    // offset instead (unless conv=notrunc). Mode is 0666 & ~umask.
    const out_fd: c_int = if (cfg.output_file) |path| blk: {
        var flags: libc.O = .{ .ACCMODE = .WRONLY, .CREAT = true };
        if (!cfg.conv.notrunc and cfg.seek == 0) flags.TRUNC = true;
        break :blk openPath(path, flags, @as(libc.mode_t, 0o666));
    } else libc.STDOUT_FILENO;
    defer {
        if (cfg.output_file != null) _ = libc.close(out_fd);
    }

    // Skip input blocks (overflow-checked: skip=2^64-1 must not wrap)
    if (cfg.skip > 0) {
        const skip_bytes_u = std.math.mul(u64, cfg.skip, cfg.ibs) catch {
            diag(&.{"skip offset overflow"});
            std.process.exit(1);
        };
        const skip_bytes = std.math.cast(i64, skip_bytes_u) orelse {
            diag(&.{"skip offset overflow"});
            std.process.exit(1);
        };
        const seek_result = lseek(in_fd, skip_bytes, SEEK_SET);
        if (seek_result < 0) {
            // If seek fails, read and discard
            var skip_buf: [4096]u8 = undefined;
            var remaining = skip_bytes_u;
            while (remaining > 0) {
                const to_read = @min(remaining, skip_buf.len);
                const n = libc.read(in_fd, &skip_buf, to_read);
                if (n <= 0) break;
                remaining -= @intCast(n);
            }
        }
    }

    // Seek output (overflow-checked), then truncate at the seek offset like
    // GNU dd so stale bytes past it don't survive (unless conv=notrunc).
    if (cfg.seek > 0) {
        const seek_bytes_u = std.math.mul(u64, cfg.seek, cfg.obs) catch {
            diag(&.{"seek offset overflow"});
            std.process.exit(1);
        };
        const seek_bytes = std.math.cast(i64, seek_bytes_u) orelse {
            diag(&.{"seek offset overflow"});
            std.process.exit(1);
        };
        _ = lseek(out_fd, seek_bytes, SEEK_SET);
        if (!cfg.conv.notrunc and cfg.output_file != null) {
            // Ignore failure: ftruncate is expected to fail on
            // non-regular outputs (devices, pipes), as in GNU dd.
            _ = ftruncate(out_fd, seek_bytes);
        }
    }

    // Allocate I/O buffers at the requested block sizes — never silently cap
    // (a fixed 1 MiB buffer made bs=4M count=2 copy 2 MiB instead of 8 MiB).
    const gpa = std.heap.page_allocator;
    const ibuf = gpa.alloc(u8, cfg.ibs) catch {
        diag(&.{"memory exhausted"});
        std.process.exit(1);
    };
    defer gpa.free(ibuf);

    // bs= means "write input blocks as read" (no reblocking) unless a
    // data-transforming conversion is active; ibs=/obs= means reblock to obs.
    const direct = cfg.bs_set and
        !(cfg.conv.lcase or cfg.conv.ucase or cfg.conv.swab);
    const obuf: []u8 = if (direct) &.{} else gpa.alloc(u8, cfg.obs) catch {
        diag(&.{"memory exhausted"});
        std.process.exit(1);
    };
    defer if (!direct) gpa.free(obuf);

    var out = Output{
        .fd = out_fd,
        .name = out_name,
        .obs = cfg.obs,
        .direct = direct,
        .obuf = obuf,
        .stats = &stats,
    };

    var blocks_read: u64 = 0;
    var failed = false;

    // Main copy loop
    while (true) {
        // Check count limit
        if (cfg.count) |max| {
            if (blocks_read >= max) break;
        }

        // Read
        const read_result = libc.read(in_fd, ibuf.ptr, ibuf.len);
        if (read_result < 0) {
            const err: c_int = libc._errno().*;
            diag(&.{ "error reading '", in_name, "': ", std.mem.span(strerror(err)) });
            if (!cfg.conv.noerror) {
                failed = true;
                break;
            }
            // conv=noerror: persistent errno classes can never succeed at any
            // offset — retrying forever would livelock (verified against the
            // old code with if=<directory>).
            if (err == @intFromEnum(posix.E.ISDIR) or
                err == @intFromEnum(posix.E.BADF) or
                err == @intFromEnum(posix.E.INVAL))
            {
                failed = true;
                break;
            }
            // Advance past the bad block when the input is seekable;
            // a non-seekable input would re-fail at the same data forever.
            const cur = lseek(in_fd, 0, SEEK_CUR);
            if (cur < 0) {
                failed = true;
                break;
            }
            _ = lseek(in_fd, cur + @as(i64, @intCast(cfg.ibs)), SEEK_SET);
            blocks_read += 1;
            if (cfg.conv.sync) {
                @memset(ibuf, 0);
                stats.records_in_partial += 1;
                if (!out.emit(ibuf)) {
                    failed = true;
                    break;
                }
            }
            continue;
        }
        const n: usize = @intCast(read_result);

        if (n == 0) break; // EOF

        blocks_read += 1;

        // Track stats
        if (n == ibuf.len) {
            stats.records_in_full += 1;
        } else {
            stats.records_in_partial += 1;
        }

        var write_len = n;

        // Sync: pad partial blocks with NULs
        if (cfg.conv.sync and n < ibuf.len) {
            @memset(ibuf[n..], 0);
            write_len = ibuf.len;
        }

        // Apply conversions
        applyConversions(ibuf, write_len, cfg.conv);

        // Write
        if (!out.emit(ibuf[0..write_len])) {
            failed = true;
            break;
        }

        // Progress output
        if (cfg.status == .progress) {
            writeStderr("\r");
            writeNum(stats.bytes_copied);
            writeStderr(" bytes copied");
        }
    }

    if (!failed and !out.flush()) failed = true;

    if (cfg.status == .progress) {
        writeStderr("\n");
    }

    // Print final stats
    if (cfg.status != .none) {
        printStats(&stats, cfg.status != .noxfer);
    }

    // GNU dd exits 1 on read/write failure; exit 0 here let scripts treat a
    // truncated copy as success.
    if (failed) std.process.exit(1);
}

// ---------------------------------------------------------------------------
// Unit anchors. Expected values come from the GNU coreutils manual,
// "dd invocation" (§ "Sending a stream through dd" / operand descriptions):
// multiplicative suffixes w=2, b=512, K=1024, M=1024*1024, G=1024^3, and
// "dd: invalid number: '0'" for zero block sizes. The end-to-end behavior is
// additionally diffed against the real GNU dd in tests/gnu_parity.zig.
// ---------------------------------------------------------------------------

test "parseSize: GNU-documented multiplicative suffixes" {
    try std.testing.expectEqual(@as(?u64, 2), parseSize("1w"));
    try std.testing.expectEqual(@as(?u64, 512), parseSize("1b"));
    try std.testing.expectEqual(@as(?u64, 1024), parseSize("1K"));
    try std.testing.expectEqual(@as(?u64, 1024), parseSize("1k"));
    try std.testing.expectEqual(@as(?u64, 4 * 1024 * 1024), parseSize("4M"));
    try std.testing.expectEqual(@as(?u64, 1024 * 1024 * 1024), parseSize("1G"));
    try std.testing.expectEqual(@as(?u64, 1024 * 1024 * 1024 * 1024), parseSize("1T"));
    try std.testing.expectEqual(@as(?u64, 512), parseSize("512"));
}

test "parseSize: invalid and overflowing inputs are rejected, never wrapped" {
    try std.testing.expectEqual(@as(?u64, null), parseSize(""));
    try std.testing.expectEqual(@as(?u64, null), parseSize("K"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("12x"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("-1"));
    // Audit: bs=99999999999999999G used to panic (Debug) / wrap (ReleaseFast).
    try std.testing.expectEqual(@as(?u64, null), parseSize("99999999999999999G"));
}

test "parseBlockSize: zero rejected like GNU (invalid number: '0')" {
    try std.testing.expectEqual(@as(?usize, null), parseBlockSize("0"));
    try std.testing.expectEqual(@as(?usize, null), parseBlockSize("0K"));
    try std.testing.expectEqual(@as(?usize, 1), parseBlockSize("1"));
    // count=/skip=/seek= go through parseSize directly, where 0 is valid
    // (GNU accepts count=0 and copies nothing).
    try std.testing.expectEqual(@as(?u64, 0), parseSize("0"));
}

test "parseConv: unknown conversion tokens are rejected" {
    var conv = ConvFlags{};
    try std.testing.expectEqual(@as(?[]const u8, null), parseConv("lcase,notrunc", &conv));
    try std.testing.expect(conv.lcase and conv.notrunc);
    // GNU: dd conv=notrunk → "invalid conversion: 'notrunk'", exit 1.
    var conv2 = ConvFlags{};
    try std.testing.expectEqualStrings("notrunk", parseConv("notrunk", &conv2).?);
}
