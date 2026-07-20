//! zcomm - High-performance file comparison utility
//!
//! Compare two sorted files line by line.
//!
//! Usage: zcomm [OPTION]... FILE1 FILE2
//!
//! Behavior is anchored to GNU coreutils `comm` (v9.10). In particular the
//! default `--check-order` sort-order checking, the `--total` summary line, and
//! the help/version-to-stdout + unknown-option-rejection semantics are ported
//! from src/comm.c so that `zcomm` is a drop-in match for the parts of the
//! contract that scripts depend on.

const std = @import("std");
const libc = std.c;

const VERSION = "1.0.0";

const CheckOrder = enum { default, enabled, disabled };

const Config = struct {
    suppress_col1: bool = false, // Lines only in FILE1
    suppress_col2: bool = false, // Lines only in FILE2
    suppress_col3: bool = false, // Lines in both files
    check_order: CheckOrder = .default,
    total: bool = false,
    output_delimiter: []const u8 = "\t",
    zero_terminated: bool = false,
    file1: ?[]const u8 = null,
    file2: ?[]const u8 = null,
};

fn writeStdout(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn printUsage() void {
    // GNU comm writes --help to stdout and exits 0.
    const usage =
        \\Usage: zcomm [OPTION]... FILE1 FILE2
        \\
        \\Compare two sorted files line by line.
        \\
        \\Output three columns:
        \\  Column 1: lines unique to FILE1
        \\  Column 2: lines unique to FILE2
        \\  Column 3: lines common to both files
        \\
        \\Options:
        \\  -1                     Suppress column 1 (lines unique to FILE1)
        \\  -2                     Suppress column 2 (lines unique to FILE2)
        \\  -3                     Suppress column 3 (lines common to both)
        \\  --check-order          Check that input is sorted (fatal on disorder)
        \\  --nocheck-order        Do not check sort order
        \\  --output-delimiter=STR Separate columns with STR
        \\  --total                Output a summary line of counts
        \\  -z, --zero-terminated  End lines with 0 byte, not newline
        \\      --help             Display this help and exit
        \\      --version          Output version information and exit
        \\
        \\Examples:
        \\  zcomm file1 file2           # Show all three columns
        \\  zcomm -12 file1 file2       # Show only common lines
        \\  zcomm -3 file1 file2        # Show unique lines only
        \\  zcomm -23 file1 file2       # Show lines only in FILE1
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    // GNU comm writes --version to stdout and exits 0.
    writeStdout("zcomm " ++ VERSION ++ " - High-performance file comparison\n");
}

const ParseError = error{ UnknownOption, TooManyOperands };

fn parseArgs(args: []const []const u8) ParseError!Config {
    var config = Config{};
    var positional_idx: usize = 0;
    var no_more_opts = false;

    for (args) |arg| {
        if (!no_more_opts and std.mem.eql(u8, arg, "--")) {
            no_more_opts = true;
            continue;
        }

        if (!no_more_opts and arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Short option cluster (e.g. -12z)
            for (arg[1..]) |c| {
                switch (c) {
                    '1' => config.suppress_col1 = true,
                    '2' => config.suppress_col2 = true,
                    '3' => config.suppress_col3 = true,
                    'z' => config.zero_terminated = true,
                    else => {
                        var buf: [64]u8 = undefined;
                        const m = std.fmt.bufPrint(&buf, "zcomm: invalid option -- '{c}'\n", .{c}) catch "zcomm: invalid option\n";
                        writeStderr(m);
                        return error.UnknownOption;
                    },
                }
            }
        } else if (!no_more_opts and arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
            // Long option
            if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--check-order")) {
                config.check_order = .enabled;
            } else if (std.mem.eql(u8, arg, "--nocheck-order")) {
                config.check_order = .disabled;
            } else if (std.mem.eql(u8, arg, "--zero-terminated")) {
                config.zero_terminated = true;
            } else if (std.mem.eql(u8, arg, "--total")) {
                config.total = true;
            } else if (std.mem.startsWith(u8, arg, "--output-delimiter=")) {
                const d = arg["--output-delimiter=".len..];
                // GNU: an empty delimiter is accepted and emits a single NUL byte
                // (col_sep_len is forced to 1 over the empty string). Match that.
                config.output_delimiter = if (d.len == 0) "\x00" else d;
            } else {
                var buf: [256]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "zcomm: unrecognized option '{s}'\n", .{arg}) catch "zcomm: unrecognized option\n";
                writeStderr(m);
                return error.UnknownOption;
            }
        } else {
            // Operand ("-" means stdin).
            switch (positional_idx) {
                0 => config.file1 = arg,
                1 => config.file2 = arg,
                else => {
                    writeStderr("zcomm: extra operand\n");
                    return error.TooManyOperands;
                },
            }
            positional_idx += 1;
        }
    }

    return config;
}

const LineReader = struct {
    fd: c_int,
    owns_fd: bool,
    buf: [65536]u8 = undefined,
    buf_start: usize = 0,
    buf_end: usize = 0,
    line_buf: std.ArrayListUnmanaged(u8) = .empty,
    eof: bool = false,
    allocator: std.mem.Allocator,
    terminator: u8,

    fn init(path: []const u8, alloc: std.mem.Allocator, term: u8) !LineReader {
        var reader = LineReader{
            .fd = 0, // stdin
            .owns_fd = false,
            .allocator = alloc,
            .terminator = term,
        };

        if (!std.mem.eql(u8, path, "-")) {
            var path_buf: [4096]u8 = undefined;
            const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;
            const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
            if (fd_ret < 0) return error.OpenFailed;
            reader.fd = fd_ret;
            reader.owns_fd = true;
        }

        return reader;
    }

    fn deinit(self: *LineReader) void {
        if (self.owns_fd) _ = libc.close(self.fd);
        self.line_buf.deinit(self.allocator);
    }

    /// Returns the next line without its terminator, or null at clean EOF.
    /// A read() error is surfaced as error.ReadFailed (NOT collapsed to EOF).
    fn readLine(self: *LineReader) !?[]const u8 {
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

            const bytes_ret = libc.read(self.fd, &self.buf, self.buf.len);
            if (bytes_ret < 0) return error.ReadFailed;
            if (bytes_ret == 0) {
                self.eof = true;
                break;
            }
            self.buf_start = 0;
            self.buf_end = @intCast(bytes_ret);
        }

        if (self.line_buf.items.len > 0) {
            return self.line_buf.items;
        }
        return null;
    }
};

/// Per-file merge context. Keeps a small ring of duplicated lines so that the
/// order check can look up to two lines back (mirrors GNU comm's 4-buffer ring).
const FileCtx = struct {
    reader: LineReader,
    slots: [4]?[]u8 = .{ null, null, null, null },
    alt: [3]usize = .{ 0, 0, 0 }, // alt[0]=current, alt[1]=prev, alt[2]=prev2
    this: ?[]const u8 = null,
    which: u8, // 1 or 2
    allocator: std.mem.Allocator,

    fn firstRead(self: *FileCtx) !void {
        const line = try self.reader.readLine();
        if (line) |l| {
            if (self.slots[self.alt[0]]) |old| self.allocator.free(old);
            self.slots[self.alt[0]] = try self.allocator.dupe(u8, l);
            self.this = self.slots[self.alt[0]];
        } else {
            self.this = null;
        }
    }

    /// Rotate the ring, read the next line, and run the order check.
    fn step(self: *FileCtx, cfg: *const Config, state: *MergeState) !void {
        self.alt[2] = self.alt[1];
        self.alt[1] = self.alt[0];
        self.alt[0] = (self.alt[0] + 1) & 0x03;

        const line = try self.reader.readLine();
        if (line) |l| {
            if (self.slots[self.alt[0]]) |old| self.allocator.free(old);
            self.slots[self.alt[0]] = try self.allocator.dupe(u8, l);
            self.this = self.slots[self.alt[0]];
            checkOrder(cfg, state, self.slots[self.alt[1]].?, self.this.?, self.which);
        } else {
            self.this = null;
            // At EOF we may have discovered an unpairable line since the last
            // check, so re-verify the previous two lines (GNU comm.c:377-382).
            if (self.slots[self.alt[2]]) |prev2| {
                checkOrder(cfg, state, prev2, self.slots[self.alt[1]].?, self.which);
            }
        }
    }

    fn deinit(self: *FileCtx) void {
        for (self.slots) |s| if (s) |buf| self.allocator.free(buf);
        self.reader.deinit();
    }
};

const MergeState = struct {
    seen_unpairable: bool = false,
    issued_disorder: [2]bool = .{ false, false },
};

/// Port of GNU comm's check_order (comm.c:220-252).
fn checkOrder(cfg: *const Config, state: *MergeState, prev: []const u8, current: []const u8, whatfile: u8) void {
    if (cfg.check_order == .disabled) return;
    if (cfg.check_order != .enabled and !state.seen_unpairable) return;

    const idx = whatfile - 1;
    if (state.issued_disorder[idx]) return;

    if (std.mem.order(u8, prev, current) == .gt) {
        var buf: [64]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "zcomm: file {d} is not in sorted order\n", .{whatfile}) catch "zcomm: file is not in sorted order\n";
        writeStderr(m);
        // --check-order makes disorder fatal immediately; default is a warning.
        if (cfg.check_order == .enabled) std.process.exit(1);
        state.issued_disorder[idx] = true;
    }
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

    const config = parseArgs(args[1..]) catch {
        std.process.exit(1);
    };

    if (config.file1 == null or config.file2 == null) {
        writeStderr("zcomm: missing operand\n");
        std.process.exit(1);
    }

    const terminator: u8 = if (config.zero_terminated) 0 else '\n';
    const terminator_str: []const u8 = if (config.zero_terminated) "\x00" else "\n";

    var reader1 = LineReader.init(config.file1.?, allocator, terminator) catch {
        writeStderr("zcomm: cannot open FILE1\n");
        std.process.exit(1);
    };
    const reader2 = LineReader.init(config.file2.?, allocator, terminator) catch {
        reader1.deinit();
        writeStderr("zcomm: cannot open FILE2\n");
        std.process.exit(1);
    };

    var f1 = FileCtx{ .reader = reader1, .which = 1, .allocator = allocator };
    var f2 = FileCtx{ .reader = reader2, .which = 2, .allocator = allocator };
    defer f1.deinit();
    defer f2.deinit();

    var state = MergeState{};
    var total: [3]u64 = .{ 0, 0, 0 };

    f1.firstRead() catch {
        writeStderr("zcomm: read error on FILE1\n");
        std.process.exit(1);
    };
    f2.firstRead() catch {
        writeStderr("zcomm: read error on FILE2\n");
        std.process.exit(1);
    };

    while (f1.this != null or f2.this != null) {
        // -1 => file1 only, 0 => both, +1 => file2 only
        var order: i8 = undefined;
        if (f1.this == null) {
            order = 1;
        } else if (f2.this == null) {
            order = -1;
        } else {
            order = switch (std.mem.order(u8, f1.this.?, f2.this.?)) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        }

        if (order == 0) {
            total[2] += 1;
            if (!config.suppress_col3) {
                if (!config.suppress_col1) writeStdout(config.output_delimiter);
                if (!config.suppress_col2) writeStdout(config.output_delimiter);
                writeStdout(f1.this.?);
                writeStdout(terminator_str);
            }
        } else {
            state.seen_unpairable = true;
            if (order < 0) {
                total[0] += 1;
                if (!config.suppress_col1) {
                    writeStdout(f1.this.?);
                    writeStdout(terminator_str);
                }
            } else {
                total[1] += 1;
                if (!config.suppress_col2) {
                    if (!config.suppress_col1) writeStdout(config.output_delimiter);
                    writeStdout(f2.this.?);
                    writeStdout(terminator_str);
                }
            }
        }

        if (order <= 0) {
            f1.step(&config, &state) catch {
                writeStderr("zcomm: read error on FILE1\n");
                std.process.exit(1);
            };
        }
        if (order >= 0) {
            f2.step(&config, &state) catch {
                writeStderr("zcomm: read error on FILE2\n");
                std.process.exit(1);
            };
        }
    }

    if (config.total) {
        var tbuf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&tbuf, "{d}{s}{d}{s}{d}{s}total{s}", .{
            total[0], config.output_delimiter,
            total[1], config.output_delimiter,
            total[2], config.output_delimiter,
            terminator_str,
        }) catch blk: {
            // Extremely long custom delimiter; fall back to a heap allocation.
            const heap = std.fmt.allocPrint(allocator, "{d}{s}{d}{s}{d}{s}total{s}", .{
                total[0], config.output_delimiter,
                total[1], config.output_delimiter,
                total[2], config.output_delimiter,
                terminator_str,
            }) catch return;
            writeStdout(heap);
            allocator.free(heap);
            break :blk "";
        };
        if (line.len > 0) writeStdout(line);
    }

    // Default check-order: a warning was issued during the merge; now it's fatal.
    if (state.issued_disorder[0] or state.issued_disorder[1]) {
        writeStderr("zcomm: input is not in sorted order\n");
        std.process.exit(1);
    }
}
