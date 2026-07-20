//! zpaste - High-performance line merging utility
//!
//! Merge lines of files.
//!
//! Usage: zpaste [OPTION]... [FILE]...

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

/// A delimiter element. `null` represents GNU's `\0` / empty-string delimiter
/// (emit nothing between columns for this cycle position). An empty delimiter
/// *list* (len == 0) means "no separator at all" (`-d ''`), distinct from the
/// default single-TAB list.
const Delim = ?u8;

const DEFAULT_DELIMS = [_]Delim{'\t'};

const Config = struct {
    serial: bool = false,
    delims: []const Delim = &DEFAULT_DELIMS,
    delims_owned: bool = false,
    zero_terminated: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
};

fn writeFd(fd: c_int, msg: []const u8) void {
    var off: usize = 0;
    while (off < msg.len) {
        const ret = libc.write(fd, msg[off..].ptr, msg.len - off);
        if (ret <= 0) return;
        off += @intCast(ret);
    }
}

fn writeStdout(msg: []const u8) void {
    writeFd(libc.STDOUT_FILENO, msg);
}

fn writeStderr(msg: []const u8) void {
    writeFd(libc.STDERR_FILENO, msg);
}

/// Buffered stdout. Checks every write() result so a closed downstream pipe
/// (EPIPE) or short write surfaces as error.WriteFailed instead of being
/// silently dropped, and coalesces the per-field/per-delimiter writes into
/// large syscalls.
const BufOut = struct {
    fd: c_int,
    buf: [64 * 1024]u8 = undefined,
    len: usize = 0,

    fn writeAll(self: *BufOut, data: []const u8) !void {
        var rest = data;
        while (rest.len > 0) {
            if (self.len == self.buf.len) try self.flush();
            const n = @min(self.buf.len - self.len, rest.len);
            @memcpy(self.buf[self.len..][0..n], rest[0..n]);
            self.len += n;
            rest = rest[n..];
        }
    }

    fn writeByte(self: *BufOut, b: u8) !void {
        if (self.len == self.buf.len) try self.flush();
        self.buf[self.len] = b;
        self.len += 1;
    }

    fn flush(self: *BufOut) !void {
        var off: usize = 0;
        while (off < self.len) {
            const ret = libc.write(self.fd, self.buf[off..].ptr, self.len - off);
            if (ret <= 0) return error.WriteFailed;
            off += @intCast(ret);
        }
        self.len = 0;
    }
};

fn printUsage(fd: c_int) void {
    const usage =
        \\Usage: zpaste [OPTION]... [FILE]...
        \\
        \\Write lines consisting of the sequentially corresponding lines from
        \\each FILE, separated by TABs, to standard output.
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Options:
        \\  -d, --delimiters=LIST  Use characters from LIST instead of TABs
        \\                         Cycle through LIST characters between columns
        \\                         Escapes: \n \t \r \b \f \v \\ \0
        \\  -s, --serial           Paste one file at a time instead of in parallel
        \\  -z, --zero-terminated  End lines with 0 byte, not newline
        \\      --help             Display this help and exit
        \\      --version          Output version information and exit
        \\
        \\Examples:
        \\  zpaste file1 file2           # Merge files side by side
        \\  zpaste -d, file1 file2       # Use comma as delimiter
        \\  zpaste -d',;:' f1 f2 f3 f4   # Cycle: comma, semicolon, colon
        \\  zpaste -s file1 file2        # Concatenate lines of each file
        \\  ls | zpaste - -              # Two columns from stdin
        \\
    ;
    writeFd(fd, usage);
}

fn printVersion(fd: c_int) void {
    writeFd(fd, "zpaste " ++ VERSION ++ " - High-performance line merging\n");
}

fn invalidOptionShort(c: u8) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zpaste: invalid option -- '{c}'\nTry 'zpaste --help' for more information.\n", .{c}) catch "zpaste: invalid option\n";
    writeStderr(msg);
}

fn unrecognizedOptionLong(arg: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zpaste: unrecognized option '{s}'\nTry 'zpaste --help' for more information.\n", .{arg}) catch "zpaste: unrecognized option\n";
    writeStderr(msg);
}

fn optionRequiresArg(name: []const u8) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zpaste: option requires an argument -- '{s}'\nTry 'zpaste --help' for more information.\n", .{name}) catch "zpaste: option requires an argument\n";
    writeStderr(msg);
}

/// Expand a raw `-d` delimiter list into a slice of Delim, resolving GNU
/// backslash escapes. `\0` maps to `null` (empty-string delimiter, NOT a NUL
/// byte). A list ending in an unescaped backslash is an error (GNU parity).
/// Returns an owned slice (caller frees).
fn parseDelims(raw: []const u8, allocator: std.mem.Allocator) ![]Delim {
    var list: std.ArrayListUnmanaged(Delim) = .empty;
    errdefer list.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\') {
            if (i + 1 >= raw.len) return error.TrailingBackslash;
            const d: Delim = switch (raw[i + 1]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => 0x08, // backspace
                'f' => 0x0C, // form feed
                'v' => 0x0B, // vertical tab
                '\\' => '\\',
                '0' => null, // GNU: empty string, not a NUL byte
                else => raw[i + 1],
            };
            try list.append(allocator, d);
            i += 2;
        } else {
            try list.append(allocator, raw[i]);
            i += 1;
        }
    }

    return list.toOwnedSlice(allocator);
}

fn parseArgs(args: []const []const u8, allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var i: usize = 0;
    var no_more_opts = false;
    var delim_raw: ?[]const u8 = null;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (!no_more_opts and arg.len > 1 and arg[0] == '-') {
            if (arg[1] != '-') {
                // Short options (may be bundled, e.g. -sd,)
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    switch (arg[j]) {
                        's' => config.serial = true,
                        'z' => config.zero_terminated = true,
                        'd' => {
                            if (j + 1 < arg.len) {
                                delim_raw = arg[j + 1 ..];
                                break;
                            } else if (i + 1 < args.len) {
                                i += 1;
                                delim_raw = args[i];
                            } else {
                                optionRequiresArg("d");
                                std.process.exit(1);
                            }
                        },
                        else => {
                            invalidOptionShort(arg[j]);
                            std.process.exit(1);
                        },
                    }
                }
            } else if (arg.len == 2) {
                // "--" : end of options; everything after is an operand
                no_more_opts = true;
            } else {
                // Long options
                if (std.mem.eql(u8, arg, "--help")) {
                    printUsage(libc.STDOUT_FILENO);
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion(libc.STDOUT_FILENO);
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--serial")) {
                    config.serial = true;
                } else if (std.mem.eql(u8, arg, "--zero-terminated")) {
                    config.zero_terminated = true;
                } else if (std.mem.startsWith(u8, arg, "--delimiters=")) {
                    delim_raw = arg[13..];
                } else if (std.mem.eql(u8, arg, "--delimiters")) {
                    if (i + 1 < args.len) {
                        i += 1;
                        delim_raw = args[i];
                    } else {
                        optionRequiresArg("delimiters");
                        std.process.exit(1);
                    }
                } else {
                    unrecognizedOptionLong(arg);
                    std.process.exit(1);
                }
            }
        } else {
            try config.files.append(allocator, arg);
        }
    }

    if (delim_raw) |raw| {
        config.delims = parseDelims(raw, allocator) catch |err| {
            if (err == error.TrailingBackslash) {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "zpaste: delimiter list ends with an unescaped backslash: {s}\n", .{raw}) catch "zpaste: delimiter list ends with an unescaped backslash\n";
                writeStderr(msg);
                std.process.exit(1);
            }
            return err;
        };
        config.delims_owned = true;
    }

    if (config.files.items.len == 0) {
        try config.files.append(allocator, "-");
    }

    return config;
}

const FileReader = struct {
    fd: c_int,
    buf: [8192]u8 = undefined,
    buf_start: usize = 0,
    buf_end: usize = 0,
    line_buf: std.ArrayListUnmanaged(u8) = .empty,
    eof: bool = false,
    is_stdin: bool,
    allocator: std.mem.Allocator,
    terminator: u8,

    fn init(path: []const u8, alloc: std.mem.Allocator, term: u8) !FileReader {
        var reader = FileReader{
            .fd = 0,
            .is_stdin = std.mem.eql(u8, path, "-"),
            .allocator = alloc,
            .terminator = term,
        };

        if (!reader.is_stdin) {
            var path_buf: [4096]u8 = undefined;
            const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;
            const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
            if (fd_ret < 0) return error.OpenFailed;
            reader.fd = fd_ret;
        }

        return reader;
    }

    fn deinit(self: *FileReader) void {
        if (!self.is_stdin and self.fd != 0) _ = libc.close(self.fd);
        self.line_buf.deinit(self.allocator);
    }

    fn readLine(self: *FileReader) !?[]const u8 {
        if (self.eof) return null;

        self.line_buf.clearRetainingCapacity();

        while (true) {
            while (self.buf_start < self.buf_end) {
                const c = self.buf[self.buf_start];
                self.buf_start += 1;

                if (c == self.terminator) {
                    return self.line_buf.items;
                }
                try self.line_buf.append(self.allocator, c);
            }

            // Refill buffer
            const bytes_ret = libc.read(self.fd, &self.buf, self.buf.len);
            if (bytes_ret <= 0) {
                self.eof = true;
                break;
            }
            const bytes_read: usize = @intCast(bytes_ret);
            self.buf_start = 0;
            self.buf_end = bytes_read;
        }

        if (self.line_buf.items.len > 0) {
            return self.line_buf.items;
        }

        return null;
    }
};

/// Write the delimiter for column `idx` (0-based, the separator *before*
/// column idx+1). Empty delimiter list => emit nothing. `null` element =>
/// empty-string delimiter (GNU `\0`).
fn writeDelim(out: *BufOut, delims: []const Delim, idx: usize) !void {
    if (delims.len == 0) return; // -d '' : no separator
    if (delims[idx % delims.len]) |byte| {
        try out.writeByte(byte);
    }
}

fn pasteParallel(config: *const Config, allocator: std.mem.Allocator, out: *BufOut) !void {
    const terminator: u8 = if (config.zero_terminated) 0 else '\n';
    const n = config.files.items.len;

    // All '-' operands must share ONE stdin reader so their lines interleave
    // round-robin across the columns (GNU behaviour) rather than each getting
    // its own view of fd 0. `readers` holds one *FileReader per column; the
    // pointer is shared for every '-'.
    var owned: std.ArrayListUnmanaged(*FileReader) = .empty;
    defer {
        for (owned.items) |r| {
            r.deinit();
            allocator.destroy(r);
        }
        owned.deinit(allocator);
    }

    var readers = try allocator.alloc(*FileReader, n);
    defer allocator.free(readers);

    var stdin_reader: ?*FileReader = null;
    for (config.files.items, 0..) |path, idx| {
        const is_stdin = std.mem.eql(u8, path, "-");
        if (is_stdin and stdin_reader != null) {
            readers[idx] = stdin_reader.?;
            continue;
        }
        const r = try allocator.create(FileReader);
        r.* = FileReader.init(path, allocator, terminator) catch {
            allocator.destroy(r);
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zpaste: cannot open '{s}'\n", .{path}) catch "zpaste: cannot open file\n";
            writeStderr(err_msg);
            std.process.exit(1);
        };
        try owned.append(allocator, r);
        readers[idx] = r;
        if (is_stdin) stdin_reader = r;
    }

    // Read and paste lines. Buffer each column's line so we don't emit trailing
    // delimiters once all readers have hit EOF.
    var line_parts = try allocator.alloc(?[]const u8, n);
    defer allocator.free(line_parts);
    var line_copies = try allocator.alloc([]u8, n);
    defer allocator.free(line_copies);

    while (true) {
        var any_data = false;

        for (readers, 0..) |reader, idx| {
            if (try reader.readLine()) |line| {
                line_copies[idx] = try allocator.dupe(u8, line);
                line_parts[idx] = line_copies[idx];
                any_data = true;
            } else {
                line_parts[idx] = null;
            }
        }

        if (!any_data) break;

        for (line_parts, 0..) |part, idx| {
            if (idx > 0) try writeDelim(out, config.delims, idx - 1);
            if (part) |line| try out.writeAll(line);
        }
        try out.writeByte(terminator);

        for (line_parts, 0..) |part, idx| {
            if (part != null) {
                allocator.free(line_copies[idx]);
                line_parts[idx] = null;
            }
        }
    }
}

/// Returns true if any operand could not be opened (caller exits 1).
fn pasteSerial(config: *const Config, allocator: std.mem.Allocator, out: *BufOut) !bool {
    const terminator: u8 = if (config.zero_terminated) 0 else '\n';
    var had_error = false;

    for (config.files.items) |path| {
        var reader = FileReader.init(path, allocator, terminator) catch {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zpaste: cannot open '{s}'\n", .{path}) catch "zpaste: cannot open file\n";
            writeStderr(err_msg);
            had_error = true;
            continue;
        };
        defer reader.deinit();

        var first = true;
        var delim_idx: usize = 0;

        while (try reader.readLine()) |line| {
            if (!first) {
                try writeDelim(out, config.delims, delim_idx);
                delim_idx += 1;
            }
            try out.writeAll(line);
            first = false;
        }

        if (!first) {
            try out.writeByte(terminator);
        }
    }

    return had_error;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = parseArgs(args[1..], allocator) catch {
        std.process.exit(1);
    };
    defer {
        if (config.delims_owned) allocator.free(config.delims);
        config.files.deinit(allocator);
    }

    var out = BufOut{ .fd = libc.STDOUT_FILENO };

    var had_error = false;
    if (config.serial) {
        had_error = pasteSerial(&config, allocator, &out) catch |err| {
            if (err == error.WriteFailed) writeStderr("zpaste: write error\n");
            std.process.exit(1);
        };
    } else {
        pasteParallel(&config, allocator, &out) catch |err| {
            if (err == error.WriteFailed) writeStderr("zpaste: write error\n");
            std.process.exit(1);
        };
    }

    out.flush() catch {
        writeStderr("zpaste: write error\n");
        std.process.exit(1);
    };

    if (had_error) std.process.exit(1);
}
