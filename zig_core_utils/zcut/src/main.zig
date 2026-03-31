//! zcut - Remove sections from each line of files
//!
//! A high-performance Zig implementation of the GNU cut utility.
//! Prints selected parts of lines from each FILE to standard output.
//!
//! Usage: zcut OPTION... [FILE]...

const std = @import("std");

const VERSION = "1.0.0";
const BUFFER_SIZE = 65536;

// C functions
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;

const O_RDONLY = 0;

/// Parse escape sequences in a string, returning the processed result
/// Supports: \n, \t, \r, \b, \f, \v, \\, \0, and octal \NNN
fn parseEscapeSequences(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => {
                    try result.append(allocator, '\n');
                    i += 2;
                },
                't' => {
                    try result.append(allocator, '\t');
                    i += 2;
                },
                'r' => {
                    try result.append(allocator, '\r');
                    i += 2;
                },
                'b' => {
                    try result.append(allocator, 0x08); // backspace
                    i += 2;
                },
                'f' => {
                    try result.append(allocator, 0x0C); // form feed
                    i += 2;
                },
                'v' => {
                    try result.append(allocator, 0x0B); // vertical tab
                    i += 2;
                },
                '\\' => {
                    try result.append(allocator, '\\');
                    i += 2;
                },
                '0' => {
                    // Octal escape \0, \0N, \0NN, \0NNN
                    var val: u8 = 0;
                    var j: usize = i + 1;
                    var digits: usize = 0;
                    while (j < input.len and digits < 4) : (j += 1) {
                        const c = input[j];
                        if (c >= '0' and c <= '7') {
                            val = val * 8 + (c - '0');
                            digits += 1;
                        } else break;
                    }
                    try result.append(allocator, val);
                    i = j;
                },
                else => {
                    // Unknown escape, keep as-is
                    try result.append(allocator, input[i]);
                    i += 1;
                },
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

const CutMode = enum {
    none,
    bytes,
    characters,
    fields,
};

const Range = struct {
    start: usize, // 1-indexed, 0 means "from beginning"
    end: usize, // 1-indexed, 0 means "to end"
};

// Zig 0.16 Writer abstraction
const Writer = struct {
    io: std.Io,
    buffer: *[8192]u8,
    file: std.Io.File,

    pub fn stdout() Writer {
        const io_instance = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [8192]u8 = undefined;
        };
        return Writer{
            .io = io_instance,
            .buffer = &static.buffer,
            .file = std.Io.File.stdout(),
        };
    }

    pub fn stderr() Writer {
        const io_instance = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [8192]u8 = undefined;
        };
        return Writer{
            .io = io_instance,
            .buffer = &static.buffer,
            .file = std.Io.File.stderr(),
        };
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        var writer = self.file.writer(self.io, self.buffer);
        writer.interface.print(fmt, args) catch {};
        writer.interface.flush() catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var out = Writer.stdout();
    var err = Writer.stderr();

    // Parse options
    var mode: CutMode = .none;
    var list_str: ?[]const u8 = null;
    var delimiter: u8 = '\t';
    var only_delimited = false;
    var complement = false;
    var output_delimiter: ?[]const u8 = null;
    var output_delimiter_alloc: ?[]u8 = null; // Allocated version with escapes parsed
    defer if (output_delimiter_alloc) |od| allocator.free(od);
    var zero_terminated = false;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp(&err);
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            err.print("zcut {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bytes")) {
            if (mode != .none) {
                err.print("zcut: only one type of list may be specified\n", .{});
                std.process.exit(1);
            }
            mode = .bytes;
            if (i + 1 < args.len) {
                i += 1;
                list_str = args[i];
            } else {
                err.print("zcut: option requires an argument -- 'b'\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-b")) {
            if (mode != .none) {
                err.print("zcut: only one type of list may be specified\n", .{});
                std.process.exit(1);
            }
            mode = .bytes;
            list_str = arg[2..];
        } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
            if (mode != .none) {
                err.print("zcut: only one type of list may be specified\n", .{});
                std.process.exit(1);
            }
            mode = .bytes;
            list_str = arg["--bytes=".len..];
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--characters")) {
            if (mode != .none) {
                err.print("zcut: only one type of list may be specified\n", .{});
                std.process.exit(1);
            }
            mode = .characters;
            if (i + 1 < args.len) {
                i += 1;
                list_str = args[i];
            } else {
                err.print("zcut: option requires an argument -- 'c'\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-c")) {
            if (mode != .none) {
                err.print("zcut: only one type of list may be specified\n", .{});
                std.process.exit(1);
            }
            mode = .characters;
            list_str = arg[2..];
        } else if (std.mem.startsWith(u8, arg, "--characters=")) {
            if (mode != .none) {
                err.print("zcut: only one type of list may be specified\n", .{});
                std.process.exit(1);
            }
            mode = .characters;
            list_str = arg["--characters=".len..];
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--fields")) {
            if (mode != .none) {
                err.print("zcut: only one type of list may be specified\n", .{});
                std.process.exit(1);
            }
            mode = .fields;
            if (i + 1 < args.len) {
                i += 1;
                list_str = args[i];
            } else {
                err.print("zcut: option requires an argument -- 'f'\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-f")) {
            if (mode != .none) {
                err.print("zcut: only one type of list may be specified\n", .{});
                std.process.exit(1);
            }
            mode = .fields;
            list_str = arg[2..];
        } else if (std.mem.startsWith(u8, arg, "--fields=")) {
            if (mode != .none) {
                err.print("zcut: only one type of list may be specified\n", .{});
                std.process.exit(1);
            }
            mode = .fields;
            list_str = arg["--fields=".len..];
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delimiter")) {
            if (i + 1 < args.len) {
                i += 1;
                if (args[i].len == 0) {
                    err.print("zcut: delimiter must be a single character\n", .{});
                    std.process.exit(1);
                }
                delimiter = args[i][0];
            } else {
                err.print("zcut: option requires an argument -- 'd'\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-d")) {
            if (arg.len < 3) {
                err.print("zcut: delimiter must be a single character\n", .{});
                std.process.exit(1);
            }
            delimiter = arg[2];
        } else if (std.mem.startsWith(u8, arg, "--delimiter=")) {
            const delim_str = arg["--delimiter=".len..];
            if (delim_str.len == 0) {
                err.print("zcut: delimiter must be a single character\n", .{});
                std.process.exit(1);
            }
            delimiter = delim_str[0];
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--only-delimited")) {
            only_delimited = true;
        } else if (std.mem.eql(u8, arg, "--complement")) {
            complement = true;
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--zero-terminated")) {
            zero_terminated = true;
        } else if (std.mem.eql(u8, arg, "-n")) {
            // Ignored for compatibility
        } else if (std.mem.startsWith(u8, arg, "--output-delimiter=")) {
            const raw = arg["--output-delimiter=".len..];
            if (output_delimiter_alloc) |od| allocator.free(od);
            output_delimiter_alloc = parseEscapeSequences(allocator, raw) catch null;
            output_delimiter = output_delimiter_alloc;
        } else if (std.mem.eql(u8, arg, "--output-delimiter")) {
            if (i + 1 < args.len) {
                i += 1;
                if (output_delimiter_alloc) |od| allocator.free(od);
                output_delimiter_alloc = parseEscapeSequences(allocator, args[i]) catch null;
                output_delimiter = output_delimiter_alloc;
            } else {
                err.print("zcut: option requires an argument -- 'output-delimiter'\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try files.append(allocator, args[i]);
            }
            break;
        } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            err.print("zcut: invalid option -- '{s}'\n", .{arg[1..]});
            err.print("Try 'zcut --help' for more information.\n", .{});
            std.process.exit(1);
        } else {
            try files.append(allocator, arg);
        }
    }

    // Validate
    if (mode == .none) {
        err.print("zcut: you must specify a list of bytes, characters, or fields\n", .{});
        err.print("Try 'zcut --help' for more information.\n", .{});
        std.process.exit(1);
    }

    if (list_str == null or list_str.?.len == 0) {
        err.print("zcut: missing list specification\n", .{});
        std.process.exit(1);
    }

    // Parse ranges
    var ranges: std.ArrayListUnmanaged(Range) = .empty;
    defer ranges.deinit(allocator);
    parseRanges(allocator, list_str.?, &ranges, &err);

    if (ranges.items.len == 0) {
        err.print("zcut: invalid list specification\n", .{});
        std.process.exit(1);
    }

    // Use stdin if no files specified
    if (files.items.len == 0) {
        try files.append(allocator, "-");
    }

    const line_delim: u8 = if (zero_terminated) 0 else '\n';

    // Process files
    for (files.items) |path| {
        var fd: c_int = 0; // stdin
        var close_fd = false;

        if (!std.mem.eql(u8, path, "-")) {
            var path_buf: [4096]u8 = undefined;
            if (path.len >= path_buf.len) {
                err.print("zcut: {s}: File name too long\n", .{path});
                continue;
            }
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = 0;

            fd = open(@ptrCast(&path_buf), O_RDONLY);
            if (fd < 0) {
                err.print("zcut: {s}: No such file or directory\n", .{path});
                continue;
            }
            close_fd = true;
        }
        defer if (close_fd) {
            _ = close(fd);
        };

        // Read and process line by line
        var line_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer line_buf.deinit(allocator);

        var read_buf: [BUFFER_SIZE]u8 = undefined;
        var buf_pos: usize = 0;
        var buf_len: usize = 0;

        while (true) {
            line_buf.clearRetainingCapacity();

            // Read until line delimiter
            while (true) {
                if (buf_pos >= buf_len) {
                    const bytes = read(fd, &read_buf, BUFFER_SIZE);
                    if (bytes <= 0) {
                        buf_len = 0;
                        break;
                    }
                    buf_len = @intCast(bytes);
                    buf_pos = 0;
                }

                if (buf_pos < buf_len) {
                    const byte = read_buf[buf_pos];
                    buf_pos += 1;
                    if (byte == line_delim) break;
                    try line_buf.append(allocator, byte);
                }
            }

            if (line_buf.items.len == 0 and buf_len == 0) {
                break;
            }

            const line = line_buf.items;

            // Process line based on mode
            switch (mode) {
                .bytes, .characters => {
                    cutBytesOrChars(&out, line, ranges.items, complement);
                },
                .fields => {
                    const has_delim = std.mem.indexOf(u8, line, &[_]u8{delimiter}) != null;

                    if (!has_delim) {
                        if (!only_delimited) {
                            out.print("{s}", .{line});
                        }
                    } else {
                        cutFields(allocator, &out, line, delimiter, output_delimiter, ranges.items, complement);
                    }
                },
                .none => unreachable,
            }

            out.print("{c}", .{line_delim});

            if (buf_len == 0) break;
        }
    }
}

fn parseRanges(
    allocator: std.mem.Allocator,
    list: []const u8,
    ranges: *std.ArrayListUnmanaged(Range),
    err_writer: *Writer,
) void {
    var iter = std.mem.splitScalar(u8, list, ',');

    while (iter.next()) |part| {
        if (part.len == 0) continue;

        if (std.mem.indexOf(u8, part, "-")) |dash_pos| {
            const left = part[0..dash_pos];
            const right = part[dash_pos + 1 ..];

            var start: usize = 1;
            var end: usize = 0;

            if (left.len > 0) {
                start = std.fmt.parseInt(usize, left, 10) catch {
                    err_writer.print("zcut: invalid range: '{s}'\n", .{part});
                    std.process.exit(1);
                };
            }

            if (right.len > 0) {
                end = std.fmt.parseInt(usize, right, 10) catch {
                    err_writer.print("zcut: invalid range: '{s}'\n", .{part});
                    std.process.exit(1);
                };
            }

            if (start == 0 and left.len > 0) {
                err_writer.print("zcut: fields and positions are numbered from 1\n", .{});
                std.process.exit(1);
            }

            if (end != 0 and start > end) {
                err_writer.print("zcut: invalid decreasing range: '{s}'\n", .{part});
                std.process.exit(1);
            }

            ranges.append(allocator, .{ .start = start, .end = end }) catch {};
        } else {
            const num = std.fmt.parseInt(usize, part, 10) catch {
                err_writer.print("zcut: invalid field value: '{s}'\n", .{part});
                std.process.exit(1);
            };

            if (num == 0) {
                err_writer.print("zcut: fields and positions are numbered from 1\n", .{});
                std.process.exit(1);
            }

            ranges.append(allocator, .{ .start = num, .end = num }) catch {};
        }
    }
}

fn cutBytesOrChars(
    writer: *Writer,
    line: []const u8,
    ranges: []const Range,
    complement: bool,
) void {
    if (complement) {
        for (line, 1..) |byte, pos| {
            if (!isInRanges(pos, ranges, line.len)) {
                writer.print("{c}", .{byte});
            }
        }
    } else {
        for (ranges) |range| {
            const start = if (range.start == 0) 1 else range.start;
            const end = if (range.end == 0) line.len else @min(range.end, line.len);

            if (start > line.len) continue;

            for (start..end + 1) |pos| {
                writer.print("{c}", .{line[pos - 1]});
            }
        }
    }
}

fn cutFields(
    allocator: std.mem.Allocator,
    writer: *Writer,
    line: []const u8,
    delimiter: u8,
    output_delimiter: ?[]const u8,
    ranges: []const Range,
    complement: bool,
) void {
    var fields: std.ArrayListUnmanaged([]const u8) = .empty;
    defer fields.deinit(allocator);

    var iter = std.mem.splitScalar(u8, line, delimiter);
    while (iter.next()) |field| {
        fields.append(allocator, field) catch {};
    }

    const out_delim = output_delimiter orelse &[_]u8{delimiter};

    var first = true;

    if (complement) {
        for (fields.items, 1..) |field, pos| {
            if (!isInRanges(pos, ranges, fields.items.len)) {
                if (!first) {
                    writer.print("{s}", .{out_delim});
                }
                first = false;
                writer.print("{s}", .{field});
            }
        }
    } else {
        for (ranges) |range| {
            const start = if (range.start == 0) 1 else range.start;
            const end = if (range.end == 0) fields.items.len else @min(range.end, fields.items.len);

            if (start > fields.items.len) continue;

            for (start..end + 1) |pos| {
                if (!first) {
                    writer.print("{s}", .{out_delim});
                }
                first = false;
                writer.print("{s}", .{fields.items[pos - 1]});
            }
        }
    }
}

fn isInRanges(pos: usize, ranges: []const Range, max_len: usize) bool {
    for (ranges) |range| {
        const start = if (range.start == 0) 1 else range.start;
        const end = if (range.end == 0) max_len else range.end;
        if (pos >= start and pos <= end) {
            return true;
        }
    }
    return false;
}

fn printHelp(writer: *Writer) void {
    writer.print(
        \\Usage: zcut OPTION... [FILE]...
        \\
        \\Print selected parts of lines from each FILE to standard output.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Options:
        \\  -b, --bytes=LIST        select only these bytes
        \\  -c, --characters=LIST   select only these characters
        \\  -d, --delimiter=DELIM   use DELIM instead of TAB for field delimiter
        \\  -f, --fields=LIST       select only these fields
        \\  -n                      (ignored)
        \\  -s, --only-delimited    do not print lines not containing delimiters
        \\      --complement        complement the set of selected bytes/chars/fields
        \\      --output-delimiter=STRING  use STRING as the output delimiter
        \\                          STRING may contain escapes: \n \t \r \b \f \v \\ \0NNN
        \\  -z, --zero-terminated   line delimiter is NUL, not newline
        \\  -h, --help              display this help and exit
        \\  -V, --version           output version information and exit
        \\
        \\Each LIST is one or more ranges separated by commas:
        \\  N       N'th byte, character or field, counted from 1
        \\  N-      from N'th byte, character or field, to end of line
        \\  N-M     from N'th to M'th (included) byte, character or field
        \\  -M      from first to M'th (included) byte, character or field
        \\
        \\Examples:
        \\  zcut -d: -f1 /etc/passwd     Print first field (username) from passwd
        \\  zcut -c1-10 file.txt         Print first 10 characters of each line
        \\  zcut -f2,4 data.tsv          Print 2nd and 4th tab-separated fields
        \\  echo "a:b:c" | zcut -d: -f2  Print "b"
        \\
    , .{});
}
