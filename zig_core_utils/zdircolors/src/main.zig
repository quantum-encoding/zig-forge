//! zdircolors - Color setup for ls
//!
//! A Zig implementation of dircolors.
//! Output shell commands to set LS_COLORS environment variable.
//!
//! Usage: zdircolors [OPTION]... [FILE]

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

const O_RDONLY: c_int = 0;

const Shell = enum {
    sh,
    csh,
};

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, msg.ptr, msg.len);
}

fn writeStdoutRaw(data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const result = write(1, data.ptr + written, data.len - written);
        if (result <= 0) break;
        written += @intCast(result);
    }
}

// Default color database
const default_database =
    \\# Configuration file for zdircolors
    \\# Below are TERM entries for common terminals
    \\TERM Eterm
    \\TERM ansi
    \\TERM *color*
    \\TERM con[0-9]*x[0-9]*
    \\TERM cons25
    \\TERM console
    \\TERM cygwin
    \\TERM dtterm
    \\TERM gnome
    \\TERM hurd
    \\TERM jfbterm
    \\TERM konsole
    \\TERM kterm
    \\TERM linux
    \\TERM linux-c
    \\TERM mlterm
    \\TERM putty
    \\TERM rxvt*
    \\TERM screen*
    \\TERM st
    \\TERM terminator
    \\TERM tmux*
    \\TERM vt100
    \\TERM xterm*
    \\
    \\# Below are the color init strings for basic file types
    \\NORMAL 0
    \\FILE 0
    \\RESET 0
    \\DIR 01;34
    \\LINK 01;36
    \\MULTIHARDLINK 00
    \\FIFO 40;33
    \\SOCK 01;35
    \\DOOR 01;35
    \\BLK 40;33;01
    \\CHR 40;33;01
    \\ORPHAN 40;31;01
    \\MISSING 00
    \\SETUID 37;41
    \\SETGID 30;43
    \\CAPABILITY 30;41
    \\STICKY_OTHER_WRITABLE 30;42
    \\OTHER_WRITABLE 34;42
    \\STICKY 37;44
    \\EXEC 01;32
    \\
    \\# Archives or compressed
    \\.tar 01;31
    \\.tgz 01;31
    \\.arc 01;31
    \\.arj 01;31
    \\.taz 01;31
    \\.lha 01;31
    \\.lz4 01;31
    \\.lzh 01;31
    \\.lzma 01;31
    \\.tlz 01;31
    \\.txz 01;31
    \\.tzo 01;31
    \\.t7z 01;31
    \\.zip 01;31
    \\.z 01;31
    \\.dz 01;31
    \\.gz 01;31
    \\.lrz 01;31
    \\.lz 01;31
    \\.lzo 01;31
    \\.xz 01;31
    \\.zst 01;31
    \\.tzst 01;31
    \\.bz2 01;31
    \\.bz 01;31
    \\.tbz 01;31
    \\.tbz2 01;31
    \\.tz 01;31
    \\.deb 01;31
    \\.rpm 01;31
    \\.jar 01;31
    \\.war 01;31
    \\.ear 01;31
    \\.sar 01;31
    \\.rar 01;31
    \\.alz 01;31
    \\.ace 01;31
    \\.zoo 01;31
    \\.cpio 01;31
    \\.7z 01;31
    \\.rz 01;31
    \\.cab 01;31
    \\.wim 01;31
    \\.swm 01;31
    \\.dwm 01;31
    \\.esd 01;31
    \\
    \\# Image formats
    \\.jpg 01;35
    \\.jpeg 01;35
    \\.mjpg 01;35
    \\.mjpeg 01;35
    \\.gif 01;35
    \\.bmp 01;35
    \\.pbm 01;35
    \\.pgm 01;35
    \\.ppm 01;35
    \\.tga 01;35
    \\.xbm 01;35
    \\.xpm 01;35
    \\.tif 01;35
    \\.tiff 01;35
    \\.png 01;35
    \\.svg 01;35
    \\.svgz 01;35
    \\.mng 01;35
    \\.pcx 01;35
    \\.mov 01;35
    \\.mpg 01;35
    \\.mpeg 01;35
    \\.m2v 01;35
    \\.mkv 01;35
    \\.webm 01;35
    \\.webp 01;35
    \\.ogm 01;35
    \\.mp4 01;35
    \\.m4v 01;35
    \\.mp4v 01;35
    \\.vob 01;35
    \\.qt 01;35
    \\.nuv 01;35
    \\.wmv 01;35
    \\.asf 01;35
    \\.rm 01;35
    \\.rmvb 01;35
    \\.flc 01;35
    \\.avi 01;35
    \\.fli 01;35
    \\.flv 01;35
    \\.gl 01;35
    \\.dl 01;35
    \\.xcf 01;35
    \\.xwd 01;35
    \\.yuv 01;35
    \\.cgm 01;35
    \\.emf 01;35
    \\.ogv 01;35
    \\.ogx 01;35
    \\
    \\# Audio formats
    \\.aac 00;36
    \\.au 00;36
    \\.flac 00;36
    \\.m4a 00;36
    \\.mid 00;36
    \\.midi 00;36
    \\.mka 00;36
    \\.mp3 00;36
    \\.mpc 00;36
    \\.ogg 00;36
    \\.ra 00;36
    \\.wav 00;36
    \\.oga 00;36
    \\.opus 00;36
    \\.spx 00;36
    \\.xspf 00;36
    \\
;

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

    // Options
    var shell: Shell = .sh;
    var print_database = false;
    var input_file: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zdircolors {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--sh") or std.mem.eql(u8, arg, "--bourne-shell")) {
            shell = .sh;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--csh") or std.mem.eql(u8, arg, "--c-shell")) {
            shell = .csh;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print-database")) {
            print_database = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            writeStderr("zdircolors: invalid option '{s}'\n", .{arg});
            std.process.exit(1);
        } else {
            input_file = arg;
        }
    }

    // Print database mode
    if (print_database) {
        writeStdoutRaw(default_database);
        return;
    }

    // Read database
    var database: []const u8 = default_database;
    var owned_database: ?[]u8 = null;
    defer if (owned_database) |d| allocator.free(d);

    if (input_file) |file| {
        if (std.mem.eql(u8, file, "-")) {
            // Read from stdin
            var buf: [65536]u8 = undefined;
            var content: std.ArrayListUnmanaged(u8) = .empty;
            defer content.deinit(allocator);

            while (true) {
                const n = c_read(0, &buf, buf.len);
                if (n <= 0) break;
                try content.appendSlice(allocator, buf[0..@intCast(n)]);
            }

            owned_database = try allocator.dupe(u8, content.items);
            database = owned_database.?;
        } else {
            // Read from file
            var file_z: [4097]u8 = undefined;
            if (file.len >= file_z.len) {
                writeStderr("zdircolors: path too long\n", .{});
                std.process.exit(1);
            }
            @memcpy(file_z[0..file.len], file);
            file_z[file.len] = 0;

            const fd = open(@ptrCast(&file_z), O_RDONLY, 0);
            if (fd < 0) {
                writeStderr("zdircolors: cannot open '{s}'\n", .{file});
                std.process.exit(1);
            }
            defer _ = close(fd);

            var buf: [65536]u8 = undefined;
            var content: std.ArrayListUnmanaged(u8) = .empty;
            defer content.deinit(allocator);

            while (true) {
                const n = c_read(fd, &buf, buf.len);
                if (n <= 0) break;
                try content.appendSlice(allocator, buf[0..@intCast(n)]);
            }

            owned_database = try allocator.dupe(u8, content.items);
            database = owned_database.?;
        }
    }

    // Check if terminal supports colors
    const term_env = getenv("TERM");
    if (term_env == null) {
        // No TERM, output empty
        outputEmpty(shell);
        return;
    }

    const term = std.mem.span(term_env.?);
    if (!termSupportsColor(database, term)) {
        outputEmpty(shell);
        return;
    }

    // Parse database and generate LS_COLORS
    var ls_colors: std.ArrayListUnmanaged(u8) = .empty;
    defer ls_colors.deinit(allocator);

    try parseDatabase(allocator, database, &ls_colors);

    // Output
    switch (shell) {
        .sh => {
            writeStdout("LS_COLORS='", .{});
            writeStdoutRaw(ls_colors.items);
            writeStdout("';\nexport LS_COLORS\n", .{});
        },
        .csh => {
            writeStdout("setenv LS_COLORS '", .{});
            writeStdoutRaw(ls_colors.items);
            writeStdout("'\n", .{});
        },
    }
}

fn outputEmpty(shell: Shell) void {
    switch (shell) {
        .sh => writeStdout("LS_COLORS='';\nexport LS_COLORS\n", .{}),
        .csh => writeStdout("setenv LS_COLORS ''\n", .{}),
    }
}

fn termSupportsColor(database: []const u8, term: []const u8) bool {
    var lines = std.mem.splitScalar(u8, database, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "TERM ")) {
            const pattern = std.mem.trim(u8, trimmed[5..], " \t");
            if (matchPattern(pattern, term)) return true;
        }
    }
    return false;
}

fn matchPattern(pattern: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;

    while (pi < pattern.len and si < str.len) {
        if (pattern[pi] == '*') {
            // Wildcard - match anything
            pi += 1;
            if (pi >= pattern.len) return true;

            // Find next non-wildcard character
            while (si < str.len) {
                if (matchPattern(pattern[pi..], str[si..])) return true;
                si += 1;
            }
            return pi >= pattern.len;
        } else if (pattern[pi] == str[si]) {
            pi += 1;
            si += 1;
        } else {
            return false;
        }
    }

    // Skip trailing wildcards
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;

    return pi >= pattern.len and si >= str.len;
}

fn parseDatabase(allocator: std.mem.Allocator, database: []const u8, ls_colors: *std.ArrayListUnmanaged(u8)) !void {
    var lines = std.mem.splitScalar(u8, database, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, "TERM ")) continue;

        // Find key and value
        var parts = std.mem.splitAny(u8, trimmed, " \t");
        const key = parts.next() orelse continue;
        const value = std.mem.trim(u8, parts.rest(), " \t");
        if (value.len == 0) continue;

        // Map key to LS_COLORS code
        const code = mapKeyToCode(key);

        if (ls_colors.items.len > 0) {
            try ls_colors.append(allocator, ':');
        }

        try ls_colors.appendSlice(allocator, code);
        try ls_colors.append(allocator, '=');
        try ls_colors.appendSlice(allocator, value);
    }
}

fn mapKeyToCode(key: []const u8) []const u8 {
    // File type codes
    if (std.mem.eql(u8, key, "NORMAL") or std.mem.eql(u8, key, "NORM")) return "no";
    if (std.mem.eql(u8, key, "FILE")) return "fi";
    if (std.mem.eql(u8, key, "RESET") or std.mem.eql(u8, key, "RS")) return "rs";
    if (std.mem.eql(u8, key, "DIR")) return "di";
    if (std.mem.eql(u8, key, "LINK") or std.mem.eql(u8, key, "LNK") or std.mem.eql(u8, key, "SYMLINK")) return "ln";
    if (std.mem.eql(u8, key, "MULTIHARDLINK") or std.mem.eql(u8, key, "MH")) return "mh";
    if (std.mem.eql(u8, key, "FIFO") or std.mem.eql(u8, key, "PIPE")) return "pi";
    if (std.mem.eql(u8, key, "SOCK")) return "so";
    if (std.mem.eql(u8, key, "DOOR")) return "do";
    if (std.mem.eql(u8, key, "BLK") or std.mem.eql(u8, key, "BLOCK")) return "bd";
    if (std.mem.eql(u8, key, "CHR") or std.mem.eql(u8, key, "CHAR")) return "cd";
    if (std.mem.eql(u8, key, "ORPHAN")) return "or";
    if (std.mem.eql(u8, key, "MISSING")) return "mi";
    if (std.mem.eql(u8, key, "SETUID")) return "su";
    if (std.mem.eql(u8, key, "SETGID")) return "sg";
    if (std.mem.eql(u8, key, "CAPABILITY")) return "ca";
    if (std.mem.eql(u8, key, "STICKY_OTHER_WRITABLE")) return "tw";
    if (std.mem.eql(u8, key, "OTHER_WRITABLE")) return "ow";
    if (std.mem.eql(u8, key, "STICKY")) return "st";
    if (std.mem.eql(u8, key, "EXEC")) return "ex";

    // Extension - pass through as-is
    return key;
}

fn printHelp() void {
    writeStdout(
        \\Usage: zdircolors [OPTION]... [FILE]
        \\Output shell commands to set LS_COLORS environment variable.
        \\
        \\Determine format of output:
        \\  -b, --sh, --bourne-shell    output Bourne shell code to set LS_COLORS
        \\  -c, --csh, --c-shell        output C shell code to set LS_COLORS
        \\  -p, --print-database        output defaults
        \\      --help                  display this help and exit
        \\      --version               output version information and exit
        \\
        \\If FILE is specified, read it to determine which colors to use.
        \\Otherwise, a precompiled database is used.
        \\For details on the format of these files, run 'zdircolors --print-database'.
        \\
        \\Examples:
        \\  zdircolors                  Output LS_COLORS for Bourne shell
        \\  zdircolors -c               Output for C shell
        \\  zdircolors -p               Print default database
        \\  zdircolors ~/.dircolors     Use custom color file
        \\  eval $(zdircolors)          Set colors in current shell
        \\
    , .{});
}
