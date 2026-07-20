//! zcut - Remove sections from each line of files
//!
//! A high-performance Zig implementation of the GNU cut utility.
//! Prints selected parts of lines from each FILE to standard output.
//!
//! Usage: zcut OPTION... [FILE]...

const std = @import("std");

const VERSION = "1.0.0";
const BUFFER_SIZE = 65536;

extern "c" fn close(fd: c_int) c_int;

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
    var delimiter_given = false;
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
                if (args[i].len != 1) {
                    err.print("zcut: the delimiter must be a single character\n", .{});
                    std.process.exit(1);
                }
                delimiter = args[i][0];
                delimiter_given = true;
            } else {
                err.print("zcut: option requires an argument -- 'd'\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-d")) {
            const delim_str = arg[2..];
            if (delim_str.len != 1) {
                err.print("zcut: the delimiter must be a single character\n", .{});
                std.process.exit(1);
            }
            delimiter = delim_str[0];
            delimiter_given = true;
        } else if (std.mem.startsWith(u8, arg, "--delimiter=")) {
            const delim_str = arg["--delimiter=".len..];
            if (delim_str.len != 1) {
                err.print("zcut: the delimiter must be a single character\n", .{});
                std.process.exit(1);
            }
            delimiter = delim_str[0];
            delimiter_given = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--only-delimited")) {
            only_delimited = true;
        } else if (std.mem.eql(u8, arg, "--complement")) {
            complement = true;
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--zero-terminated")) {
            zero_terminated = true;
        } else if (std.mem.eql(u8, arg, "-n")) {
            // Ignored for compatibility
        } else if (std.mem.startsWith(u8, arg, "--output-delimiter=")) {
            // GNU cut uses the output delimiter string verbatim (no escape
            // interpretation). Using it literally matches GNU byte-for-byte.
            output_delimiter = arg["--output-delimiter=".len..];
        } else if (std.mem.eql(u8, arg, "--output-delimiter")) {
            if (i + 1 < args.len) {
                i += 1;
                output_delimiter = args[i];
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

    // -s and -d are only meaningful in field mode (GNU parity).
    if (only_delimited and mode != .fields) {
        err.print("zcut: suppressing non-delimited lines makes sense only when operating on fields\n", .{});
        std.process.exit(1);
    }
    if (delimiter_given and mode != .fields) {
        err.print("zcut: an input delimiter may be specified only when operating on fields\n", .{});
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

    // Nonzero if any input could not be read (GNU cut exits 1 in that case).
    var exit_code: u8 = 0;

    // Process files
    for (files.items) |path| {
        var fd: std.posix.fd_t = std.posix.STDIN_FILENO;
        var close_fd = false;

        if (!std.mem.eql(u8, path, "-")) {
            var path_buf: [4096]u8 = undefined;
            if (path.len >= path_buf.len) {
                err.print("zcut: {s}: File name too long\n", .{path});
                exit_code = 1;
                continue;
            }
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = 0;

            fd = std.posix.openatZ(std.posix.AT.FDCWD, @ptrCast(&path_buf), .{ .ACCMODE = .RDONLY }, 0) catch |e| {
                err.print("zcut: {s}: {s}\n", .{ path, openErrorMessage(e) });
                exit_code = 1;
                continue;
            };
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
        var read_error = false;

        while (true) {
            line_buf.clearRetainingCapacity();

            // Read until line delimiter
            while (true) {
                if (buf_pos >= buf_len) {
                    // std.posix.read retries on EINTR internally and returns a
                    // typed error for real I/O failures (distinct from EOF==0).
                    const bytes = std.posix.read(fd, &read_buf) catch |e| {
                        err.print("zcut: {s}: {s}\n", .{ path, readErrorMessage(e) });
                        exit_code = 1;
                        read_error = true;
                        buf_len = 0;
                        break;
                    };
                    if (bytes == 0) {
                        buf_len = 0;
                        break;
                    }
                    buf_len = bytes;
                    buf_pos = 0;
                }

                if (buf_pos < buf_len) {
                    const byte = read_buf[buf_pos];
                    buf_pos += 1;
                    if (byte == line_delim) break;
                    try line_buf.append(allocator, byte);
                }
            }

            // On a read error, stop this file without emitting the partial line.
            if (read_error) break;

            if (line_buf.items.len == 0 and buf_len == 0) {
                break;
            }

            const line = line_buf.items;

            // Process line based on mode
            var suppressed = false;
            switch (mode) {
                .bytes, .characters => {
                    cutBytesOrChars(&out, line, ranges.items, complement);
                },
                .fields => {
                    const has_delim = std.mem.indexOf(u8, line, &[_]u8{delimiter}) != null;

                    if (!has_delim) {
                        if (only_delimited) {
                            // GNU cut with -s emits nothing at all for a
                            // non-delimited line — not even the line delimiter.
                            suppressed = true;
                        } else {
                            out.print("{s}", .{line});
                        }
                    } else {
                        cutFields(allocator, &out, line, delimiter, output_delimiter, ranges.items, complement);
                    }
                },
                .none => unreachable,
            }

            if (!suppressed) out.print("{c}", .{line_delim});

            if (buf_len == 0) break;
        }
    }

    if (exit_code != 0) std.process.exit(exit_code);
}

/// Map an open(2) failure to GNU cut's error wording.
fn openErrorMessage(e: std.posix.OpenError) []const u8 {
    return switch (e) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.NameTooLong => "File name too long",
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "Too many open files",
        else => "No such file or directory",
    };
}

/// Map a read(2) failure to GNU cut's error wording.
fn readErrorMessage(e: std.posix.ReadError) []const u8 {
    return switch (e) {
        error.IsDir => "Is a directory",
        error.AccessDenied => "Permission denied",
        error.InputOutput => "Input/output error",
        else => "Input/output error",
    };
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
    // GNU cut selects each position at most once, in ascending order,
    // regardless of the order the ranges were given on the command line.
    for (line, 1..) |byte, pos| {
        const selected = isInRanges(pos, ranges, line.len);
        if (selected != complement) {
            writer.print("{c}", .{byte});
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

    // GNU cut emits selected fields in ascending order, each at most once,
    // joined by the output delimiter — independent of the given range order.
    var first = true;
    for (fields.items, 1..) |field, pos| {
        const selected = isInRanges(pos, ranges, fields.items.len);
        if (selected != complement) {
            if (!first) {
                writer.print("{s}", .{out_delim});
            }
            first = false;
            writer.print("{s}", .{field});
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
