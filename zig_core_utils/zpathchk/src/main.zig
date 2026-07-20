const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const libc = std.c;
const linux = std.os.linux;

// POSIX portable filename character set: A-Z a-z 0-9 . _ -
fn isPortableChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '_' or c == '-';
}

// POSIX minimum limits used by -p (portability) mode.
// GNU pathchk reports the component limit as _POSIX_NAME_MAX (14) and the
// total-path limit as _POSIX_PATH_MAX - 1 (255), matching coreutils.
const POSIX_NAME_MAX: usize = 14; // _POSIX_NAME_MAX
const POSIX_PATH_MAX: usize = 256; // _POSIX_PATH_MAX (check is `len >= 256`, reported limit is 255)

// pathconf(2) name selectors differ between Darwin and Linux.
const PC_NAME_MAX: c_int = if (builtin.os.tag == .linux) 3 else 4;
const PC_PATH_MAX: c_int = if (builtin.os.tag == .linux) 4 else 5;

extern "c" fn pathconf(path: [*:0]const u8, name: c_int) c_long;

fn writeErr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn writeOut(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

// Render the offending byte the way GNU quotearg does inside the single quotes:
// printable ASCII is emitted raw; everything else as a 3-digit octal escape
// (e.g. byte 0xC3 -> \303), matching `gpathchk` under LC_ALL=C.
fn writeQuotedChar(c: u8) void {
    if (c >= 0x20 and c <= 0x7e) {
        var buf: [1]u8 = .{c};
        writeErr(&buf);
    } else {
        var buf: [4]u8 = undefined;
        buf[0] = '\\';
        buf[1] = '0' + @as(u8, @intCast((c >> 6) & 0x7));
        buf[2] = '0' + @as(u8, @intCast((c >> 3) & 0x7));
        buf[3] = '0' + @as(u8, @intCast(c & 0x7));
        writeErr(&buf);
    }
}

const FsLimits = struct {
    name_max: usize,
    path_max: usize,
};

// Determine the filesystem NAME_MAX / PATH_MAX applicable to `path`, the way GNU
// default mode does: query pathconf() on the longest existing leading directory.
// Falls back to typical values if pathconf is indeterminate so the check never
// silently disappears.
fn fsLimits(path: []const u8) FsLimits {
    var dir_buf: [4096]u8 = undefined;

    // Start from the directory portion of `path` (everything up to the last
    // '/'), then strip trailing components until one exists.
    var end: usize = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| idx else 0;

    while (true) {
        const dir: []const u8 = if (end == 0)
            (if (path.len > 0 and path[0] == '/') "/" else ".")
        else
            path[0..end];

        if (dir.len < dir_buf.len) {
            @memcpy(dir_buf[0..dir.len], dir);
            dir_buf[dir.len] = 0;
            const dir_z: [*:0]const u8 = @ptrCast(&dir_buf);

            const nm = pathconf(dir_z, PC_NAME_MAX);
            const pm = pathconf(dir_z, PC_PATH_MAX);
            if (nm > 0 and pm > 0) {
                return .{ .name_max = @intCast(nm), .path_max = @intCast(pm) };
            }
        }

        if (end == 0) break;
        // Strip one more trailing component and retry with the parent.
        end = if (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |idx| idx else 0;
    }

    // Indeterminate: fall back to common POSIX-ish values rather than skipping.
    return .{ .name_max = 255, .path_max = 1024 };
}

fn checkPath(path: []const u8, check_posix: bool, check_extra: bool) bool {
    // -P: reject empty names.
    if (check_extra and path.len == 0) {
        writeErr("zpathchk: empty file name\n");
        return false;
    }

    // Default mode (no -p / -P): basic validity + filesystem limits.
    if (!check_posix and !check_extra) {
        if (path.len == 0) {
            writeErr("zpathchk: '': No such file or directory\n");
            return false;
        }

        const limits = fsLimits(path);

        // GNU checks total path length first (>= path_max), then components.
        if (path.len >= limits.path_max) {
            writeErr("zpathchk: ");
            writeErr(path);
            writeErr(": File name too long\n");
            return false;
        }

        // Per-component length against the filesystem NAME_MAX.
        var start: usize = 0;
        var i: usize = 0;
        while (i <= path.len) : (i += 1) {
            const is_sep = i == path.len or path[i] == '/';
            if (is_sep) {
                const component = path[start..i];
                if (component.len > limits.name_max) {
                    writeErr("zpathchk: ");
                    writeErr(path);
                    writeErr(": File name too long\n");
                    return false;
                }
                start = i + 1;
            }
        }

        return true;
    }

    // -p: check total path length against the POSIX minimum. GNU triggers when
    // len >= _POSIX_PATH_MAX (256) and reports the limit as 255.
    if (check_posix and path.len >= POSIX_PATH_MAX) {
        writeErr("zpathchk: limit ");
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{POSIX_PATH_MAX - 1}) catch "255";
        writeErr(s);
        writeErr(" exceeded by length ");
        const s2 = std.fmt.bufPrint(&buf, "{d}", .{path.len}) catch "?";
        writeErr(s2);
        writeErr(" of file name '");
        writeErr(path);
        writeErr("'\n");
        return false;
    }

    // Walk each component for -p / -P checks.
    var start: usize = 0;
    var i: usize = 0;

    while (i <= path.len) : (i += 1) {
        const is_sep = i == path.len or path[i] == '/';

        if (is_sep) {
            const component = path[start..i];

            // Skip empty components (multiple slashes or leading slash).
            if (component.len > 0) {
                // -P: reject a leading dash in any component.
                if (check_extra and component[0] == '-') {
                    writeErr("zpathchk: leading '-' in a component of file name '");
                    writeErr(path);
                    writeErr("'\n");
                    return false;
                }

                // -p: component length against the POSIX minimum (14).
                if (check_posix and component.len > POSIX_NAME_MAX) {
                    writeErr("zpathchk: limit ");
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}", .{POSIX_NAME_MAX}) catch "14";
                    writeErr(s);
                    writeErr(" exceeded by length ");
                    const s2 = std.fmt.bufPrint(&buf, "{d}", .{component.len}) catch "?";
                    writeErr(s2);
                    writeErr(" of file name component '");
                    writeErr(component);
                    writeErr("'\n");
                    return false;
                }

                // -p: reject non-portable characters.
                if (check_posix) {
                    for (component) |c| {
                        if (!isPortableChar(c)) {
                            writeErr("zpathchk: non-portable character '");
                            writeQuotedChar(c);
                            writeErr("' in file name '");
                            writeErr(path);
                            writeErr("'\n");
                            return false;
                        }
                    }
                }
            }

            start = i + 1;
        }
    }

    return true;
}

const help_text =
    \\Usage: zpathchk [OPTION]... NAME...
    \\Diagnose invalid or non-portable file names.
    \\
    \\  -p                  check for most POSIX systems
    \\  -P                  check for empty names and leading "-"
    \\      --portability   check for all POSIX systems (equivalent to -p -P)
    \\      --help          display this help and exit
    \\      --version       output version information and exit
    \\
;

const version_text = "zpathchk (zig_core_utils) 1.0\n";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var paths_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths_list.deinit(allocator);

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var check_posix = false;
    var check_extra = false;
    var parsing_opts = true;

    while (args.next()) |arg| {
        if (parsing_opts and arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (std.mem.eql(u8, arg, "--help")) {
                writeOut(help_text);
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                writeOut(version_text);
                return;
            } else if (std.mem.eql(u8, arg, "--portability")) {
                check_posix = true;
                check_extra = true;
            } else if (std.mem.eql(u8, arg, "--")) {
                parsing_opts = false;
            } else if (arg[1] == '-') {
                // Unknown long option.
                writeErr("zpathchk: unrecognized option '");
                writeErr(arg);
                writeErr("'\n");
                writeErr("Try 'zpathchk --help' for more information.\n");
                std.process.exit(1);
            } else {
                // Parse short options.
                for (arg[1..]) |c| {
                    switch (c) {
                        'p' => check_posix = true,
                        'P' => check_extra = true,
                        else => {
                            writeErr("zpathchk: invalid option -- '");
                            var buf: [1]u8 = .{c};
                            writeErr(&buf);
                            writeErr("'\n");
                            writeErr("Try 'zpathchk --help' for more information.\n");
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            // Every operand is validated — no fixed cap.
            try paths_list.append(allocator, arg);
        }
    }

    if (paths_list.items.len == 0) {
        writeErr("zpathchk: missing operand\n");
        writeErr("Try 'zpathchk --help' for more information.\n");
        std.process.exit(1);
    }

    var had_error = false;
    for (paths_list.items) |path| {
        if (!checkPath(path, check_posix, check_extra)) {
            had_error = true;
        }
    }

    if (had_error) std.process.exit(1);
}
