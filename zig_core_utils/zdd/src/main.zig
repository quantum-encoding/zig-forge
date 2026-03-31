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

const SIGUSR1: c_int = 10;
const SEEK_SET: c_int = 0;

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
        \\BYTES may be followed by: K=1024, M=1024*1024, G=1024^3
        \\
        \\Send SIGUSR1 to print I/O statistics.
        \\
        \\  --help     Display this help
        \\  --version  Output version
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zdd " ++ VERSION ++ "\n");
}

fn parseSize(s: []const u8) ?usize {
    if (s.len == 0) return null;
    
    var multiplier: usize = 1;
    var num_end = s.len;
    
    // Check for suffix
    const last = s[s.len - 1];
    if (last == 'K' or last == 'k') {
        multiplier = 1024;
        num_end = s.len - 1;
    } else if (last == 'M' or last == 'm') {
        multiplier = 1024 * 1024;
        num_end = s.len - 1;
    } else if (last == 'G' or last == 'g') {
        multiplier = 1024 * 1024 * 1024;
        num_end = s.len - 1;
    }
    
    if (num_end == 0) return null;
    
    const num = std.fmt.parseInt(usize, s[0..num_end], 10) catch return null;
    return num * multiplier;
}

fn parseConv(s: []const u8, conv: *ConvFlags) void {
    var iter = std.mem.splitScalar(u8, s, ',');
    while (iter.next()) |opt| {
        if (std.mem.eql(u8, opt, "lcase")) conv.lcase = true
        else if (std.mem.eql(u8, opt, "ucase")) conv.ucase = true
        else if (std.mem.eql(u8, opt, "swab")) conv.swab = true
        else if (std.mem.eql(u8, opt, "notrunc")) conv.notrunc = true
        else if (std.mem.eql(u8, opt, "noerror")) conv.noerror = true
        else if (std.mem.eql(u8, opt, "sync")) conv.sync = true;
    }
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
            const size = parseSize(arg[3..]) orelse {
                writeStderr("zdd: invalid block size\n");
                return null;
            };
            cfg.ibs = size;
            cfg.obs = size;
        } else if (std.mem.startsWith(u8, arg, "ibs=")) {
            cfg.ibs = parseSize(arg[4..]) orelse {
                writeStderr("zdd: invalid input block size\n");
                return null;
            };
        } else if (std.mem.startsWith(u8, arg, "obs=")) {
            cfg.obs = parseSize(arg[4..]) orelse {
                writeStderr("zdd: invalid output block size\n");
                return null;
            };
        } else if (std.mem.startsWith(u8, arg, "count=")) {
            cfg.count = std.fmt.parseInt(u64, arg[6..], 10) catch {
                writeStderr("zdd: invalid count\n");
                return null;
            };
        } else if (std.mem.startsWith(u8, arg, "skip=")) {
            cfg.skip = std.fmt.parseInt(u64, arg[5..], 10) catch {
                writeStderr("zdd: invalid skip\n");
                return null;
            };
        } else if (std.mem.startsWith(u8, arg, "seek=")) {
            cfg.seek = std.fmt.parseInt(u64, arg[5..], 10) catch {
                writeStderr("zdd: invalid seek\n");
                return null;
            };
        } else if (std.mem.startsWith(u8, arg, "conv=")) {
            parseConv(arg[5..], &cfg.conv);
        } else if (std.mem.startsWith(u8, arg, "status=")) {
            const val = arg[7..];
            if (std.mem.eql(u8, val, "none")) cfg.status = .none
            else if (std.mem.eql(u8, val, "noxfer")) cfg.status = .noxfer
            else if (std.mem.eql(u8, val, "progress")) cfg.status = .progress;
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

fn printStats(stats: *Stats) void {
    const elapsed = time(null) - stats.start_time;
    
    writeNum(stats.records_in_full);
    writeStderr("+");
    writeNum(stats.records_in_partial);
    writeStderr(" records in\n");
    
    writeNum(stats.records_out_full);
    writeStderr("+");
    writeNum(stats.records_out_partial);
    writeStderr(" records out\n");
    
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
        printStats(g_stats);
    }
}

pub fn main(init: std.process.Init) void {
    // Collect args
    var args_storage: [256][]const u8 = undefined;
    var args_count: usize = 0;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name
    while (args_iter.next()) |arg| {
        if (args_count < args_storage.len) {
            args_storage[args_count] = arg;
            args_count += 1;
        }
    }

    const cfg = parseArgs(args_storage[0..args_count]) orelse {
        std.process.exit(1);
    };
    
    var stats = Stats{};
    stats.start_time = time(null);
    
    // Setup signal handler for progress
    g_stats = &stats;
    g_show_progress = true;
    _ = signal(SIGUSR1, signalHandler);
    
    // Open input
    const in_fd: c_int = if (cfg.input_file) |path| blk: {
        var path_buf: [4096]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);
        const fd = libc.open(path_z, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            writeStderr("zdd: cannot open input file\n");
            std.process.exit(1);
        }
        break :blk fd;
    } else libc.STDIN_FILENO;
    defer {
        if (cfg.input_file != null) _ = libc.close(in_fd);
    }
    
    // Open output
    const out_fd: c_int = if (cfg.output_file) |path| blk: {
        var path_buf: [4096]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);
        var flags: libc.O = .{ .ACCMODE = .WRONLY, .CREAT = true };
        if (!cfg.conv.notrunc) flags.TRUNC = true;
        const fd = libc.open(path_z, flags, @as(libc.mode_t, 0o644));
        if (fd < 0) {
            writeStderr("zdd: cannot open output file\n");
            std.process.exit(1);
        }
        break :blk fd;
    } else libc.STDOUT_FILENO;
    defer {
        if (cfg.output_file != null) _ = libc.close(out_fd);
    }
    
    // Skip input blocks
    if (cfg.skip > 0) {
        const skip_bytes: i64 = @intCast(cfg.skip * cfg.ibs);
        const seek_result = lseek(in_fd, skip_bytes, SEEK_SET);
        if (seek_result < 0) {
            // If seek fails, read and discard
            var skip_buf: [4096]u8 = undefined;
            var remaining = cfg.skip * cfg.ibs;
            while (remaining > 0) {
                const to_read = @min(remaining, skip_buf.len);
                const n = libc.read(in_fd, &skip_buf, to_read);
                if (n <= 0) break;
                remaining -= @intCast(n);
            }
        }
    }

    // Seek output
    if (cfg.seek > 0) {
        const seek_bytes: i64 = @intCast(cfg.seek * cfg.obs);
        _ = lseek(out_fd, seek_bytes, SEEK_SET);
    }
    
    // Allocate buffer
    var buf: [1024 * 1024]u8 = undefined; // 1MB max
    const buf_size = @min(cfg.ibs, buf.len);
    
    var blocks_read: u64 = 0;
    
    // Main copy loop
    while (true) {
        // Check count limit
        if (cfg.count) |max| {
            if (blocks_read >= max) break;
        }

        // Read
        const read_result = libc.read(in_fd, &buf, buf_size);
        if (read_result < 0) {
            if (cfg.conv.noerror) {
                blocks_read += 1;
                continue;
            }
            writeStderr("zdd: read error\n");
            break;
        }
        const n: usize = @intCast(read_result);

        if (n == 0) break; // EOF

        blocks_read += 1;

        // Track stats
        if (n == buf_size) {
            stats.records_in_full += 1;
        } else {
            stats.records_in_partial += 1;
        }

        var write_len = n;

        // Sync: pad partial blocks with NULs
        if (cfg.conv.sync and n < buf_size) {
            @memset(buf[n..buf_size], 0);
            write_len = buf_size;
        }

        // Apply conversions
        applyConversions(&buf, write_len, cfg.conv);

        // Write
        var written: usize = 0;
        while (written < write_len) {
            const w = libc.write(out_fd, buf[written..write_len].ptr, write_len - written);
            if (w < 0) {
                writeStderr("zdd: write error\n");
                std.process.exit(1);
            }
            written += @intCast(w);
        }

        if (written == cfg.obs) {
            stats.records_out_full += 1;
        } else {
            stats.records_out_partial += 1;
        }

        stats.bytes_copied += written;

        // Progress output
        if (cfg.status == .progress) {
            writeStderr("\r");
            writeNum(stats.bytes_copied);
            writeStderr(" bytes copied");
        }
    }
    
    if (cfg.status == .progress) {
        writeStderr("\n");
    }
    
    // Print final stats
    if (cfg.status != .none) {
        printStats(&stats);
    }
}
