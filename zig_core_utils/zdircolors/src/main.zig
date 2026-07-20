//! zdircolors - Color setup for ls
//!
//! A Zig implementation of GNU dircolors.
//! Output shell commands to set the LS_COLORS environment variable.
//!
//! Usage: zdircolors [OPTION]... [FILE]
//!
//! Behavior is anchored to GNU coreutils 9.10 `dircolors`. In particular the
//! database is parsed by the same single-pass TERM/COLORTERM state machine, so
//! terminal gating, `COLORTERM` support, extension globbing (`*.ext`) and
//! `unrecognized keyword` rejection all match the reference implementation.

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
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        // Message too long for the fixed buffer: emit a truncated marker
        // rather than silently dropping it.
        const trunc = "zdircolors: (message truncated)\n";
        _ = write(2, trunc.ptr, trunc.len);
        return;
    };
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        const trunc = "zdircolors: (output truncated)\n";
        _ = write(1, trunc.ptr, trunc.len);
        return;
    };
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

// Default color database. Entries mirror GNU coreutils 9.10 `dircolors -p`
// so the generated LS_COLORS is byte-identical to the reference tool.
// NORMAL/FILE are intentionally absent (GNU's modern default omits them);
// CAPABILITY defaults to 00.
const default_database =
    \\# Configuration file for zdircolors, a utility to help you set the
    \\# LS_COLORS environment variable used by GNU ls with the --color option.
    \\# The keywords COLOR, OPTIONS, and EIGHTBIT are recognized but ignored.
    \\# Global config options can be specified before TERM or COLORTERM entries.
    \\
    \\# Below, there should be one TERM entry for each termtype that is colorizable
    \\COLORTERM ?*
    \\TERM Eterm
    \\TERM ansi
    \\TERM *color*
    \\TERM con[0-9]*x[0-9]*
    \\TERM cons25
    \\TERM console
    \\TERM cygwin
    \\TERM *direct*
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
    \\TERM vt220
    \\TERM xterm*
    \\
    \\# Below are the color init strings for the basic file types.
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
    \\CAPABILITY 00
    \\STICKY_OTHER_WRITABLE 30;42
    \\OTHER_WRITABLE 34;42
    \\STICKY 37;44
    \\EXEC 01;32
    \\
    \\# List any file extensions like '.gz' or '.tar' that you would like ls
    \\# to color below. Put the extension, a space, and the color init string.
    \\# Archives or compressed (bright red)
    \\.7z 01;31
    \\.ace 01;31
    \\.alz 01;31
    \\.apk 01;31
    \\.arc 01;31
    \\.arj 01;31
    \\.bz 01;31
    \\.bz2 01;31
    \\.cab 01;31
    \\.cpio 01;31
    \\.crate 01;31
    \\.deb 01;31
    \\.drpm 01;31
    \\.dwm 01;31
    \\.dz 01;31
    \\.ear 01;31
    \\.egg 01;31
    \\.esd 01;31
    \\.gz 01;31
    \\.jar 01;31
    \\.lha 01;31
    \\.lrz 01;31
    \\.lz 01;31
    \\.lz4 01;31
    \\.lzh 01;31
    \\.lzma 01;31
    \\.lzo 01;31
    \\.pyz 01;31
    \\.rar 01;31
    \\.rpm 01;31
    \\.rz 01;31
    \\.sar 01;31
    \\.swm 01;31
    \\.t7z 01;31
    \\.tar 01;31
    \\.taz 01;31
    \\.tbz 01;31
    \\.tbz2 01;31
    \\.tgz 01;31
    \\.tlz 01;31
    \\.txz 01;31
    \\.tz 01;31
    \\.tzo 01;31
    \\.tzst 01;31
    \\.udeb 01;31
    \\.war 01;31
    \\.whl 01;31
    \\.wim 01;31
    \\.xz 01;31
    \\.z 01;31
    \\.zip 01;31
    \\.zoo 01;31
    \\.zst 01;31
    \\
    \\# Image formats (bright magenta)
    \\.avif 01;35
    \\.jpg 01;35
    \\.jpeg 01;35
    \\.jxl 01;35
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
    \\# Audio formats (cyan)
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
    \\# Backup and temporary files (bright black / gray)
    \\*~ 00;90
    \\*# 00;90
    \\.bak 00;90
    \\.crdownload 00;90
    \\.dpkg-dist 00;90
    \\.dpkg-new 00;90
    \\.dpkg-old 00;90
    \\.dpkg-tmp 00;90
    \\.old 00;90
    \\.orig 00;90
    \\.part 00;90
    \\.rej 00;90
    \\.rpmnew 00;90
    \\.rpmorig 00;90
    \\.rpmsave 00;90
    \\.swp 00;90
    \\.tmp 00;90
    \\.ucf-dist 00;90
    \\.ucf-new 00;90
    \\.ucf-old 00;90
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
    var shell_explicit = false;
    var print_database = false;
    var input_file: ?[]const u8 = null;
    var seen_operand = false;
    var no_more_options = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (!no_more_options and std.mem.eql(u8, arg, "--")) {
            no_more_options = true;
        } else if (!no_more_options and std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (!no_more_options and std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (!no_more_options and (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--sh") or std.mem.eql(u8, arg, "--bourne-shell"))) {
            shell = .sh;
            shell_explicit = true;
        } else if (!no_more_options and (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--csh") or std.mem.eql(u8, arg, "--c-shell"))) {
            shell = .csh;
            shell_explicit = true;
        } else if (!no_more_options and (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print-database"))) {
            print_database = true;
        } else if (!no_more_options and arg.len > 1 and arg[0] == '-') {
            writeStderr("zdircolors: invalid option '{s}'\n", .{arg});
            writeStderr("Try 'zdircolors --help' for more information.\n", .{});
            std.process.exit(1);
        } else {
            // Operand (FILE). GNU accepts exactly one; a second is an error.
            if (seen_operand) {
                writeStderr("zdircolors: extra operand '{s}'\n", .{arg});
                writeStderr("Try 'zdircolors --help' for more information.\n", .{});
                std.process.exit(1);
            }
            input_file = arg;
            seen_operand = true;
        }
    }

    // Print database mode
    if (print_database) {
        writeStdoutRaw(default_database);
        return;
    }

    // Shell auto-detection when neither -b nor -c was given (matches GNU:
    // guess from $SHELL, error if it is unset).
    if (!shell_explicit) {
        if (getenv("SHELL")) |shell_env| {
            const sh = std.mem.span(shell_env);
            shell = if (shellBasenameIsCsh(sh)) .csh else .sh;
        } else {
            writeStderr("zdircolors: no SHELL environment variable, and no shell type option given\n", .{});
            std.process.exit(1);
        }
    }

    // Read database
    var database: []const u8 = default_database;
    var owned_database: ?[]u8 = null;
    defer if (owned_database) |d| allocator.free(d);
    // Filename used in diagnostics (GNU prints "<internal>" for the built-in DB).
    var db_name: []const u8 = "<internal>";

    if (input_file) |file| {
        if (std.mem.eql(u8, file, "-")) {
            db_name = "<standard input>";
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
            db_name = file;
            var file_z: [4097]u8 = undefined;
            if (file.len >= file_z.len) {
                writeStderr("zdircolors: path too long\n", .{});
                std.process.exit(1);
            }
            @memcpy(file_z[0..file.len], file);
            file_z[file.len] = 0;

            const fd = open(@ptrCast(&file_z), O_RDONLY, 0);
            if (fd < 0) {
                writeStderr("zdircolors: {s}: No such file or directory\n", .{file});
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

    // Read the terminal environment (GNU falls back to "none").
    const term_env = getenv("TERM");
    const term = if (term_env) |t| blk: {
        const s = std.mem.span(t);
        break :blk if (s.len == 0) "none" else s;
    } else "none";

    const colorterm_env = getenv("COLORTERM");
    const colorterm = if (colorterm_env) |c| std.mem.span(c) else "";

    // Parse database and generate LS_COLORS via the GNU state machine.
    var ls_colors: std.ArrayListUnmanaged(u8) = .empty;
    defer ls_colors.deinit(allocator);

    const ok = try generateLsColors(allocator, database, db_name, term, colorterm, &ls_colors);
    if (!ok) {
        // Unrecognized keyword(s): errors already reported; no LS_COLORS emitted.
        std.process.exit(1);
    }

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

fn shellBasenameIsCsh(path: []const u8) bool {
    // Basename after the last '/', matching GNU's "ends with csh" heuristic.
    var base = path;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        base = path[idx + 1 ..];
    }
    return std.mem.endsWith(u8, base, "csh");
}

const ParseState = enum { termno, termyes, termsure, global };

/// Single-pass parse of the dircolors database. Returns true on success, false
/// if any unrecognized keyword was found in an active (TERM-matched) section —
/// in which case diagnostics have been printed and the caller must exit 1.
fn generateLsColors(
    allocator: std.mem.Allocator,
    database: []const u8,
    filename: []const u8,
    term: []const u8,
    colorterm: []const u8,
    ls_colors: *std.ArrayListUnmanaged(u8),
) !bool {
    var state: ParseState = .global;
    var line_number: usize = 0;
    var ok = true;

    var lines = std.mem.splitScalar(u8, database, '\n');
    while (lines.next()) |raw| {
        line_number += 1;

        // Strip a trailing CR (CRLF files) and surrounding whitespace.
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const keyword = it.next() orelse continue;
        const arg = it.next() orelse "";

        if (eqlIgnoreCase(keyword, "TERM")) {
            if (state != .termsure) {
                if (fnmatch(arg, term)) {
                    state = .termyes;
                } else if (state != .termyes) {
                    state = .termno;
                }
            }
            continue;
        }
        if (eqlIgnoreCase(keyword, "COLORTERM")) {
            if (state != .termsure) {
                if (fnmatch(arg, colorterm)) {
                    state = .termsure;
                } else if (state != .termyes) {
                    state = .termno;
                }
            }
            continue;
        }

        // A definition line. Skip entirely if this section is disabled.
        if (state == .termno) continue;

        if (keyword[0] == '.') {
            // Extension: LS_COLORS patterns must be shell globs "*.ext".
            if (arg.len == 0) continue;
            try ls_colors.append(allocator, '*');
            try ls_colors.appendSlice(allocator, keyword);
            try ls_colors.append(allocator, '=');
            try ls_colors.appendSlice(allocator, arg);
            try ls_colors.append(allocator, ':');
        } else if (keyword[0] == '*') {
            // Already a glob (e.g. "*~", "*.tar"): emit verbatim.
            if (arg.len == 0) continue;
            try ls_colors.appendSlice(allocator, keyword);
            try ls_colors.append(allocator, '=');
            try ls_colors.appendSlice(allocator, arg);
            try ls_colors.append(allocator, ':');
        } else if (isObsoleteKeyword(keyword)) {
            // COLOR / OPTIONS / EIGHTBIT: recognized but ignored (Slackware compat).
            continue;
        } else if (mapKeyToCode(keyword)) |code| {
            if (arg.len == 0) continue;
            try ls_colors.appendSlice(allocator, code);
            try ls_colors.append(allocator, '=');
            try ls_colors.appendSlice(allocator, arg);
            try ls_colors.append(allocator, ':');
        } else {
            // Unrecognized keyword. GNU only errors inside a matched section
            // (ST_TERMYES / ST_TERMSURE); in the global preamble it is ignored.
            if (state == .termyes or state == .termsure) {
                writeStderr("zdircolors: {s}:{d}: unrecognized keyword {s}\n", .{ filename, line_number, keyword });
                ok = false;
            }
        }
    }

    return ok;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toUpper(ca) != std.ascii.toUpper(cb)) return false;
    }
    return true;
}

fn isObsoleteKeyword(key: []const u8) bool {
    return eqlIgnoreCase(key, "OPTIONS") or
        eqlIgnoreCase(key, "COLOR") or
        eqlIgnoreCase(key, "EIGHTBIT");
}

/// fnmatch-style glob match supporting '*', '?', '[...]' classes and '\' escapes,
/// matching the semantics GNU dircolors uses for TERM / COLORTERM patterns.
fn fnmatch(pattern: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;

    while (pi < pattern.len) {
        const c = pattern[pi];
        switch (c) {
            '*' => {
                // Collapse consecutive stars.
                pi += 1;
                while (pi < pattern.len and pattern[pi] == '*') pi += 1;
                if (pi >= pattern.len) return true;
                var k = si;
                while (k <= str.len) : (k += 1) {
                    if (fnmatch(pattern[pi..], str[k..])) return true;
                }
                return false;
            },
            '?' => {
                if (si >= str.len) return false;
                pi += 1;
                si += 1;
            },
            '[' => {
                if (si >= str.len) return false;
                if (matchClass(pattern[pi..], str[si])) |res| {
                    if (!res.matched) return false;
                    pi += res.consumed;
                    si += 1;
                } else {
                    // No closing ']': treat '[' as a literal character.
                    if (str[si] != '[') return false;
                    pi += 1;
                    si += 1;
                }
            },
            '\\' => {
                pi += 1;
                const lit = if (pi < pattern.len) pattern[pi] else '\\';
                if (si >= str.len or str[si] != lit) return false;
                pi += 1;
                si += 1;
            },
            else => {
                if (si >= str.len or str[si] != c) return false;
                pi += 1;
                si += 1;
            },
        }
    }

    return si >= str.len;
}

const ClassResult = struct { matched: bool, consumed: usize };

/// Match a single char against a bracket expression beginning at pattern[0]=='['.
/// Returns whether `ch` is in the class and how many pattern bytes it spans
/// (through the closing ']'), or null if the class is unterminated.
fn matchClass(pattern: []const u8, ch: u8) ?ClassResult {
    std.debug.assert(pattern[0] == '[');
    var i: usize = 1;
    var negate = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pattern.len) {
        // A ']' closes the class unless it is the very first class member.
        if (pattern[i] == ']' and !first) {
            i += 1;
            return .{ .matched = matched != negate, .consumed = i };
        }
        first = false;

        // Range: a-z (a trailing '-' before ']' is a literal).
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            const lo = pattern[i];
            const hi = pattern[i + 2];
            if (ch >= lo and ch <= hi) matched = true;
            i += 3;
        } else {
            if (pattern[i] == ch) matched = true;
            i += 1;
        }
    }
    // Unterminated class.
    return null;
}

fn mapKeyToCode(key: []const u8) ?[]const u8 {
    // File type codes (case-insensitive keywords, matching GNU's ls_codes table).
    if (eqlIgnoreCase(key, "NORMAL") or eqlIgnoreCase(key, "NORM")) return "no";
    if (eqlIgnoreCase(key, "FILE")) return "fi";
    if (eqlIgnoreCase(key, "RESET") or eqlIgnoreCase(key, "RS")) return "rs";
    if (eqlIgnoreCase(key, "DIR")) return "di";
    if (eqlIgnoreCase(key, "LINK") or eqlIgnoreCase(key, "LNK") or eqlIgnoreCase(key, "SYMLINK")) return "ln";
    if (eqlIgnoreCase(key, "MULTIHARDLINK")) return "mh";
    if (eqlIgnoreCase(key, "FIFO") or eqlIgnoreCase(key, "PIPE")) return "pi";
    if (eqlIgnoreCase(key, "SOCK")) return "so";
    if (eqlIgnoreCase(key, "DOOR")) return "do";
    if (eqlIgnoreCase(key, "BLK") or eqlIgnoreCase(key, "BLOCK")) return "bd";
    if (eqlIgnoreCase(key, "CHR") or eqlIgnoreCase(key, "CHAR")) return "cd";
    if (eqlIgnoreCase(key, "ORPHAN")) return "or";
    if (eqlIgnoreCase(key, "MISSING")) return "mi";
    if (eqlIgnoreCase(key, "SETUID") or eqlIgnoreCase(key, "SUID")) return "su";
    if (eqlIgnoreCase(key, "SETGID") or eqlIgnoreCase(key, "SGID")) return "sg";
    if (eqlIgnoreCase(key, "CAPABILITY")) return "ca";
    if (eqlIgnoreCase(key, "STICKY_OTHER_WRITABLE") or eqlIgnoreCase(key, "OWT")) return "tw";
    if (eqlIgnoreCase(key, "OTHER_WRITABLE") or eqlIgnoreCase(key, "OWR")) return "ow";
    if (eqlIgnoreCase(key, "STICKY")) return "st";
    if (eqlIgnoreCase(key, "EXEC")) return "ex";
    if (eqlIgnoreCase(key, "LEFT") or eqlIgnoreCase(key, "LEFTCODE")) return "lc";
    if (eqlIgnoreCase(key, "RIGHT") or eqlIgnoreCase(key, "RIGHTCODE")) return "rc";
    if (eqlIgnoreCase(key, "END") or eqlIgnoreCase(key, "ENDCODE")) return "ec";
    if (eqlIgnoreCase(key, "CLRTOEOL")) return "cl";

    // Not a known keyword.
    return null;
}

fn printVersion() void {
    writeStdout(
        \\zdircolors (zig-forge coreutils) {s}
        \\A Zig reimplementation of GNU dircolors, anchored to coreutils 9.10.
        \\License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
        \\This is free software: you are free to change and redistribute it.
        \\There is NO WARRANTY, to the extent permitted by law.
        \\
    , .{VERSION});
}

fn printHelp() void {
    writeStdout(
        \\Usage: zdircolors [OPTION]... [FILE]
        \\Output commands to set the LS_COLORS environment variable.
        \\
        \\Determine format of output:
        \\  -b, --sh, --bourne-shell    output Bourne shell code to set LS_COLORS
        \\  -c, --csh, --c-shell        output C shell code to set LS_COLORS
        \\  -p, --print-database        output defaults
        \\      --help                  display this help and exit
        \\      --version               output version information and exit
        \\
        \\If FILE is specified, read it to determine which colors to use for which
        \\file types and extensions.  Otherwise, a precompiled database is used.
        \\For details on the format of these files, run 'zdircolors --print-database'.
        \\
        \\Examples:
        \\  zdircolors                  Output LS_COLORS for the current shell
        \\  zdircolors -c               Output for C shell
        \\  zdircolors -p               Print default database
        \\  zdircolors ~/.dircolors     Use custom color file
        \\  eval "$(zdircolors)"        Set colors in current shell
        \\
    , .{});
}
