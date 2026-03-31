//! ztree - High-performance directory tree visualization
//!
//! Displays directory structure in a tree format with color support,
//! file sizes, and various filtering options.
//!
//! Usage: ztree [OPTIONS] [DIRECTORY...]

const std = @import("std");
const posix = std.posix;
const libc = std.c;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const VERSION = "1.0.0";

// Extern C for isatty
extern "c" fn isatty(fd: c_int) c_int;

// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const blue = "\x1b[34m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const magenta = "\x1b[35m";
};

// Tree drawing characters (Unicode)
const TreeChars = struct {
    const branch = "├── ";
    const last_branch = "└── ";
    const vertical = "│   ";
    const space = "    ";
};

// ASCII fallback characters
const TreeCharsAscii = struct {
    const branch = "|-- ";
    const last_branch = "`-- ";
    const vertical = "|   ";
    const space = "    ";
};

const Config = struct {
    show_hidden: bool = false,
    dirs_only: bool = false,
    files_only: bool = false,
    max_depth: ?usize = null,
    show_size: bool = false,
    human_readable: bool = false,
    use_color: bool = true,
    ascii_only: bool = false,
    follow_symlinks: bool = false,
    sort_reverse: bool = false,
    dirs_first: bool = false,
    show_full_path: bool = false,
    pattern: ?[]const u8 = null,
    directories: std.ArrayListUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator = undefined,

    fn deinit(self: *Config) void {
        self.directories.deinit(self.allocator);
    }
};

const Stats = struct {
    dirs: usize = 0,
    files: usize = 0,

    fn add(self: *Stats, other: Stats) void {
        self.dirs += other.dirs;
        self.files += other.files;
    }
};

// Output buffer for efficient writing
const OutputBuffer = struct {
    buffer: [65536]u8 = undefined,
    pos: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        const remaining = self.buffer.len - self.pos;
        if (data.len > remaining) {
            self.flush();
        }
        if (data.len > self.buffer.len) {
            _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
            return;
        }
        @memcpy(self.buffer[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    fn flush(self: *OutputBuffer) void {
        if (self.pos > 0) {
            _ = libc.write(libc.STDOUT_FILENO, &self.buffer, self.pos);
            self.pos = 0;
        }
    }

    fn print(self: *OutputBuffer, comptime fmt: []const u8, args: anytype) void {
        var local_buf: [4096]u8 = undefined;
        const formatted = std.fmt.bufPrint(&local_buf, fmt, args) catch return;
        self.write(formatted);
    }
};

fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn printUsage() void {
    const usage =
        \\Usage: ztree [OPTIONS] [DIRECTORY...]
        \\
        \\Display directory tree structure.
        \\
        \\Options:
        \\  -a              Show hidden files (starting with .)
        \\  -d              List directories only
        \\  -f              List files only
        \\  -L LEVEL        Descend only LEVEL directories deep
        \\  -s              Print size of each file
        \\  -h              Print size in human readable format (with -s)
        \\  -C              Turn colorization on (default if tty)
        \\  -n              Turn colorization off
        \\  -A              Use ASCII line drawing characters
        \\  -l              Follow symbolic links
        \\  -r              Sort in reverse order
        \\  --dirsfirst     List directories before files
        \\  -F              Show full path prefix for each file
        \\  -P PATTERN      Only show files matching pattern
        \\  --help          Display this help message
        \\  --version       Display version information
        \\
        \\Examples:
        \\  ztree                    # Tree of current directory
        \\  ztree /path/to/dir       # Tree of specific directory
        \\  ztree -L 2               # Limit depth to 2 levels
        \\  ztree -a -s -h           # Show hidden files with human sizes
        \\  ztree -d                 # Show directories only
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("ztree " ++ VERSION ++ " - High-performance directory tree\n");
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    var config = Config{
        .allocator = allocator,
    };

    // Check if stdout is a tty for default color behavior
    config.use_color = isatty(1) != 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-a")) {
                config.show_hidden = true;
            } else if (std.mem.eql(u8, arg, "-d")) {
                config.dirs_only = true;
            } else if (std.mem.eql(u8, arg, "-f")) {
                config.files_only = true;
            } else if (std.mem.eql(u8, arg, "-L")) {
                i += 1;
                if (i >= args.len) {
                    writeStderr("ztree: option '-L' requires an argument\n");
                    return error.MissingArgument;
                }
                config.max_depth = std.fmt.parseInt(usize, args[i], 10) catch {
                    writeStderr("ztree: invalid depth value\n");
                    return error.InvalidArgument;
                };
            } else if (std.mem.eql(u8, arg, "-s")) {
                config.show_size = true;
            } else if (std.mem.eql(u8, arg, "-h")) {
                config.human_readable = true;
            } else if (std.mem.eql(u8, arg, "-C")) {
                config.use_color = true;
            } else if (std.mem.eql(u8, arg, "-n")) {
                config.use_color = false;
            } else if (std.mem.eql(u8, arg, "-A")) {
                config.ascii_only = true;
            } else if (std.mem.eql(u8, arg, "-l")) {
                config.follow_symlinks = true;
            } else if (std.mem.eql(u8, arg, "-r")) {
                config.sort_reverse = true;
            } else if (std.mem.eql(u8, arg, "--dirsfirst")) {
                config.dirs_first = true;
            } else if (std.mem.eql(u8, arg, "-F")) {
                config.show_full_path = true;
            } else if (std.mem.eql(u8, arg, "-P")) {
                i += 1;
                if (i >= args.len) {
                    writeStderr("ztree: option '-P' requires an argument\n");
                    return error.MissingArgument;
                }
                config.pattern = args[i];
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--")) {
                i += 1;
                while (i < args.len) : (i += 1) {
                    try config.directories.append(allocator, args[i]);
                }
                break;
            } else {
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "ztree: unrecognized option '{s}'\n", .{arg}) catch "ztree: unrecognized option\n";
                writeStderr(err_msg);
                return error.InvalidOption;
            }
        } else {
            try config.directories.append(allocator, arg);
        }
    }

    if (config.directories.items.len == 0) {
        try config.directories.append(allocator, ".");
    }

    return config;
}

fn formatSize(size: u64, human_readable: bool, buf: []u8) []const u8 {
    if (!human_readable) {
        return std.fmt.bufPrint(buf, "{d}", .{size}) catch "";
    }

    const units = [_][]const u8{ "B", "K", "M", "G", "T", "P" };
    var s: f64 = @floatFromInt(size);
    var unit_idx: usize = 0;

    while (s >= 1024 and unit_idx < units.len - 1) {
        s /= 1024;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d}{s}", .{ size, units[0] }) catch "";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ s, units[unit_idx] }) catch "";
    }
}

fn getFileColor(kind: File.Kind, config: *const Config) []const u8 {
    if (!config.use_color) return "";

    return switch (kind) {
        .directory => Color.blue ++ Color.bold,
        .sym_link => Color.cyan,
        .block_device, .character_device => Color.yellow ++ Color.bold,
        .named_pipe => Color.yellow,
        .unix_domain_socket => Color.magenta ++ Color.bold,
        else => "",
    };
}

fn matchPattern(name: []const u8, pattern: []const u8) bool {
    var ni: usize = 0;
    var pi: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == name[ni])) {
            ni += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_idx = pi;
            match_idx = ni;
            pi += 1;
        } else if (star_idx) |si| {
            pi = si + 1;
            match_idx += 1;
            ni = match_idx;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') {
        pi += 1;
    }

    return pi == pattern.len;
}

const EntryInfo = struct {
    name: []const u8,
    kind: File.Kind,
    size: u64,
    is_last: bool,
};

fn processDirectory(
    allocator: std.mem.Allocator,
    io: Io,
    out: *OutputBuffer,
    dir: Dir,
    dir_path: []const u8,
    prefix: []const u8,
    depth: usize,
    config: *const Config,
) Stats {
    var stats = Stats{};

    // Check depth limit
    if (config.max_depth) |max| {
        if (depth > max) return stats;
    }

    // Collect entries
    var entries = std.ArrayListUnmanaged(EntryInfo).empty;
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }
        entries.deinit(allocator);
    }

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        // Skip hidden files unless -a
        if (!config.show_hidden and entry.name.len > 0 and entry.name[0] == '.') {
            continue;
        }

        // Skip based on -d or -f options
        if (config.dirs_only and entry.kind != .directory) {
            continue;
        }
        if (config.files_only and entry.kind == .directory) {
            continue;
        }

        // Pattern matching
        if (config.pattern) |pattern| {
            if (entry.kind != .directory and !matchPattern(entry.name, pattern)) {
                continue;
            }
        }

        // Get file size if needed
        var size: u64 = 0;
        if (config.show_size and entry.kind != .directory) {
            if (dir.statFile(io, entry.name, .{})) |stat| {
                size = stat.size;
            } else |_| {}
        }

        const name_copy = allocator.dupe(u8, entry.name) catch continue;
        entries.append(allocator, .{
            .name = name_copy,
            .kind = entry.kind,
            .size = size,
            .is_last = false,
        }) catch {
            allocator.free(name_copy);
            continue;
        };
    }

    // Sort entries
    if (config.dirs_first) {
        std.mem.sort(EntryInfo, entries.items, config, struct {
            fn lessThan(cfg: *const Config, a: EntryInfo, b: EntryInfo) bool {
                const a_is_dir = a.kind == .directory;
                const b_is_dir = b.kind == .directory;
                if (a_is_dir != b_is_dir) {
                    return if (cfg.sort_reverse) b_is_dir else a_is_dir;
                }
                const cmp = std.mem.order(u8, a.name, b.name);
                return if (cfg.sort_reverse) cmp == .gt else cmp == .lt;
            }
        }.lessThan);
    } else {
        std.mem.sort(EntryInfo, entries.items, config, struct {
            fn lessThan(cfg: *const Config, a: EntryInfo, b: EntryInfo) bool {
                const cmp = std.mem.order(u8, a.name, b.name);
                return if (cfg.sort_reverse) cmp == .gt else cmp == .lt;
            }
        }.lessThan);
    }

    // Mark last entry
    if (entries.items.len > 0) {
        entries.items[entries.items.len - 1].is_last = true;
    }

    // Tree characters
    const branch = if (config.ascii_only) TreeCharsAscii.branch else TreeChars.branch;
    const last_branch = if (config.ascii_only) TreeCharsAscii.last_branch else TreeChars.last_branch;
    const vertical = if (config.ascii_only) TreeCharsAscii.vertical else TreeChars.vertical;
    const space = if (config.ascii_only) TreeCharsAscii.space else TreeChars.space;

    // Process entries
    for (entries.items) |entry| {
        const connector = if (entry.is_last) last_branch else branch;

        // Print prefix
        out.write(prefix);
        out.write(connector);

        // Print size if requested
        if (config.show_size and entry.kind != .directory) {
            var size_buf: [32]u8 = undefined;
            const size_str = formatSize(entry.size, config.human_readable, &size_buf);
            out.print("[{s: >7}]  ", .{size_str});
        }

        // Print with color
        const color = getFileColor(entry.kind, config);
        if (color.len > 0) {
            out.write(color);
        }

        // Print name
        if (config.show_full_path) {
            out.write(dir_path);
            if (!std.mem.endsWith(u8, dir_path, "/")) {
                out.write("/");
            }
        }
        out.write(entry.name);

        // Reset color
        if (color.len > 0) {
            out.write(Color.reset);
        }

        // Directory indicator
        if (entry.kind == .directory) {
            out.write("/");
        } else if (entry.kind == .sym_link) {
            out.write(" -> ...");
        }

        out.write("\n");

        // Update stats
        if (entry.kind == .directory) {
            stats.dirs += 1;

            // Recurse into directory
            var child_path_buf: [4096]u8 = undefined;
            const child_path = std.fmt.bufPrint(&child_path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

            // Build new prefix
            var new_prefix_buf: [4096]u8 = undefined;
            const extension = if (entry.is_last) space else vertical;
            const new_prefix = std.fmt.bufPrint(&new_prefix_buf, "{s}{s}", .{ prefix, extension }) catch continue;

            // Create null-terminated path for openDir
            var path_z_buf: [4096]u8 = undefined;
            const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{entry.name}) catch continue;

            if (dir.openDir(io, path_z, .{ .iterate = true })) |child_dir| {
                defer child_dir.close(io);
                const child_stats = processDirectory(allocator, io, out, child_dir, child_path, new_prefix, depth + 1, config);
                stats.add(child_stats);
            } else |_| {}
        } else {
            stats.files += 1;
        }
    }

    return stats;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Get the Io interface
    const io = Io.Threaded.global_single_threaded.io();

    // Get command line arguments
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Parse arguments (skip program name)
    var config = parseArgs(allocator, args[1..]) catch |err| {
        switch (err) {
            error.MissingArgument, error.InvalidArgument, error.InvalidOption => std.process.exit(1),
            else => {
                writeStderr("ztree: error parsing arguments\n");
                std.process.exit(1);
            },
        }
    };
    defer config.deinit();

    var out = OutputBuffer{};
    var total_stats = Stats{};

    // Process each directory
    for (config.directories.items, 0..) |dir_path, idx| {
        // Print directory name
        if (config.use_color) {
            out.write(Color.blue);
            out.write(Color.bold);
        }
        out.write(dir_path);
        if (config.use_color) {
            out.write(Color.reset);
        }
        out.write("\n");

        // Open the directory
        var path_z_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{dir_path}) catch {
            writeStderr("ztree: path too long\n");
            continue;
        };

        const cwd = Dir.cwd();
        if (cwd.openDir(io, path_z, .{ .iterate = true })) |dir| {
            defer dir.close(io);
            const stats = processDirectory(allocator, io, &out, dir, dir_path, "", 0, &config);
            total_stats.add(stats);
        } else |err| {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "ztree: cannot open '{s}': {}\n", .{ dir_path, err }) catch "ztree: cannot open directory\n";
            writeStderr(err_msg);
        }

        // Add blank line between multiple directories
        if (idx < config.directories.items.len - 1) {
            out.write("\n");
        }
    }

    // Print summary
    out.write("\n");
    var summary_buf: [128]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "{d} directories, {d} files\n", .{ total_stats.dirs, total_stats.files }) catch "";
    out.write(summary);

    // Flush output
    out.flush();
}
