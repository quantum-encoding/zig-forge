//! Command-line argument parsing for zdu
//! Compatible with GNU du options

const std = @import("std");
const main = @import("main.zig");
const Options = main.Options;

pub const ParseResult = struct {
    options: Options,
    paths: []const []const u8,
    allocator: std.mem.Allocator,
    paths_buf: std.ArrayList([]const u8),

    pub fn deinit(self: *const ParseResult) void {
        var buf = self.paths_buf;
        buf.deinit(self.allocator);
    }
};

pub const ParseError = error{
    InvalidOption,
    InvalidBlockSize,
    InvalidMaxDepth,
    HelpRequested,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, minimal_args: anytype) ParseError!ParseResult {
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    _ = args_iter.next(); // Skip program name

    var options = Options{};
    var paths = std.ArrayList([]const u8).initCapacity(allocator, 8) catch return ParseError.OutOfMemory;

    while (args_iter.next()) |arg| {
        if (arg.len == 0) continue;

        if (arg[0] == '-' and arg.len > 1) {
            if (arg[1] == '-') {
                // Long option
                try parseLongOption(arg[2..], &options, &args_iter);
            } else {
                // Short options (can be combined like -sh)
                for (arg[1..]) |c| {
                    try parseShortOption(c, &options, &args_iter);
                }
            }
        } else {
            // Path argument
            paths.append(allocator, arg) catch return ParseError.OutOfMemory;
        }
    }

    return ParseResult{
        .options = options,
        .paths = paths.items,
        .allocator = allocator,
        .paths_buf = paths,
    };
}

fn parseShortOption(c: u8, options: *Options, args_iter: anytype) ParseError!void {
    switch (c) {
        'a' => options.all = true,
        'b' => {
            options.apparent_size = true;
            options.bytes = true;
            options.block_size = 1;
        },
        'c' => options.total = true,
        'd' => {
            if (args_iter.next()) |depth_str| {
                options.max_depth = std.fmt.parseInt(usize, depth_str, 10) catch
                    return ParseError.InvalidMaxDepth;
            } else {
                return ParseError.InvalidMaxDepth;
            }
        },
        'h' => options.human_readable = true,
        'k' => options.block_size = 1024,
        'l' => options.count_links = true,
        'L' => options.dereference = true,
        'm' => options.block_size = 1024 * 1024,
        's' => options.summarize = true,
        'S' => {}, // separate-dirs (not yet implemented)
        'x' => options.one_file_system = true,
        '0' => options.null_terminator = true,
        else => return ParseError.InvalidOption,
    }
}

fn parseLongOption(opt: []const u8, options: *Options, args_iter: anytype) ParseError!void {
    // Handle --option=value format
    var name: []const u8 = opt;
    var value: ?[]const u8 = null;

    if (std.mem.indexOf(u8, opt, "=")) |idx| {
        name = opt[0..idx];
        value = opt[idx + 1 ..];
    }

    if (std.mem.eql(u8, name, "help")) {
        printHelp();
        return ParseError.HelpRequested;
    } else if (std.mem.eql(u8, name, "version")) {
        printVersion();
        return ParseError.HelpRequested;
    } else if (std.mem.eql(u8, name, "all")) {
        options.all = true;
    } else if (std.mem.eql(u8, name, "apparent-size")) {
        options.apparent_size = true;
    } else if (std.mem.eql(u8, name, "block-size") or std.mem.eql(u8, name, "B")) {
        const size_str = value orelse args_iter.next() orelse return ParseError.InvalidBlockSize;
        options.block_size = parseBlockSize(size_str) catch return ParseError.InvalidBlockSize;
    } else if (std.mem.eql(u8, name, "bytes")) {
        options.apparent_size = true;
        options.bytes = true;
        options.block_size = 1;
    } else if (std.mem.eql(u8, name, "total")) {
        options.total = true;
    } else if (std.mem.eql(u8, name, "max-depth")) {
        const depth_str = value orelse args_iter.next() orelse return ParseError.InvalidMaxDepth;
        options.max_depth = std.fmt.parseInt(usize, depth_str, 10) catch
            return ParseError.InvalidMaxDepth;
    } else if (std.mem.eql(u8, name, "human-readable")) {
        options.human_readable = true;
    } else if (std.mem.eql(u8, name, "si")) {
        options.si = true;
    } else if (std.mem.eql(u8, name, "summarize")) {
        options.summarize = true;
    } else if (std.mem.eql(u8, name, "one-file-system")) {
        options.one_file_system = true;
    } else if (std.mem.eql(u8, name, "dereference")) {
        options.dereference = true;
    } else if (std.mem.eql(u8, name, "count-links")) {
        options.count_links = true;
    } else if (std.mem.eql(u8, name, "null")) {
        options.null_terminator = true;
    } else if (std.mem.eql(u8, name, "threads")) {
        const t_str = value orelse args_iter.next() orelse return ParseError.InvalidOption;
        options.threads = std.fmt.parseInt(usize, t_str, 10) catch return ParseError.InvalidOption;
    } else if (std.mem.eql(u8, name, "json-stats")) {
        options.json_stats = true;
    } else {
        return ParseError.InvalidOption;
    }
}

fn parseBlockSize(s: []const u8) !u64 {
    if (s.len == 0) return error.InvalidBlockSize;

    var num_end: usize = 0;
    for (s, 0..) |c, i| {
        if (c >= '0' and c <= '9') {
            num_end = i + 1;
        } else {
            break;
        }
    }

    const num_part = s[0..num_end];
    const suffix = s[num_end..];

    var base: u64 = if (num_part.len > 0)
        std.fmt.parseInt(u64, num_part, 10) catch return error.InvalidBlockSize
    else
        1;

    // Handle suffixes (K, M, G, T, P, E, KB, MB, etc.)
    if (suffix.len > 0) {
        const multiplier: u64 = switch (suffix[0]) {
            'K', 'k' => 1024,
            'M', 'm' => 1024 * 1024,
            'G', 'g' => 1024 * 1024 * 1024,
            'T', 't' => 1024 * 1024 * 1024 * 1024,
            'P', 'p' => 1024 * 1024 * 1024 * 1024 * 1024,
            'E', 'e' => 1024 * 1024 * 1024 * 1024 * 1024 * 1024,
            else => return error.InvalidBlockSize,
        };
        base = if (base == 0) multiplier else base * multiplier;
    }

    return base;
}

fn printHelp() void {
    const help =
        \\Usage: zdu [OPTION]... [FILE]...
        \\  or:  zdu [OPTION]... --files0-from=F
        \\Summarize device usage of the set of FILEs, recursively for directories.
        \\
        \\  -a, --all             write counts for all files, not just directories
        \\  -b, --bytes           equivalent to '--apparent-size --block-size=1'
        \\  -c, --total           produce a grand total
        \\  -d, --max-depth=N     print total for a directory only if it is N or fewer
        \\                          levels below the command line argument
        \\  -h, --human-readable  print sizes in human readable format (e.g., 1K 234M 2G)
        \\  -k                    like --block-size=1K
        \\  -l, --count-links     count sizes many times if hard linked
        \\  -L, --dereference     dereference all symbolic links
        \\  -m                    like --block-size=1M
        \\  -s, --summarize       display only a total for each argument
        \\      --si              like -h, but use powers of 1000 not 1024
        \\  -x, --one-file-system skip directories on different file systems
        \\  -0, --null            end each output line with NUL, not newline
        \\  -B, --block-size=SIZE scale sizes by SIZE before printing
        \\      --threads=N       use N threads for parallel traversal (default: auto)
        \\      --help            display this help and exit
        \\      --version         output version information and exit
        \\
        \\zdu - Zig Disk Usage - A high-performance du implementation in Zig.
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn printVersion() void {
    std.debug.print("zdu 0.1.0 (Zig Disk Usage)\n", .{});
    std.debug.print("Built with Zig {s}\n", .{@import("builtin").zig_version_string});
}

test "parse block size" {
    try std.testing.expectEqual(@as(u64, 1024), try parseBlockSize("1K"));
    try std.testing.expectEqual(@as(u64, 1024), try parseBlockSize("K"));
    try std.testing.expectEqual(@as(u64, 1048576), try parseBlockSize("1M"));
    try std.testing.expectEqual(@as(u64, 2048), try parseBlockSize("2K"));
    try std.testing.expectEqual(@as(u64, 512), try parseBlockSize("512"));
}
