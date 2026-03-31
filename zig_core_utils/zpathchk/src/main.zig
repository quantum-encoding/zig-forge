const std = @import("std");
const posix = std.posix;
const libc = std.c;
const linux = std.os.linux;

// POSIX portable filename character set
fn isPortableChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '_' or c == '-';
}

// POSIX minimum limits
const POSIX_NAME_MAX: usize = 14; // Max filename component length
const POSIX_PATH_MAX: usize = 256; // Max path length

fn writeErr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn checkPath(path: []const u8, check_posix: bool, check_extra: bool) bool {
    // -P: check for empty names
    if (check_extra and path.len == 0) {
        writeErr("zpathchk: empty file name\n");
        return false;
    }

    // -p: check total path length
    if (check_posix and path.len > POSIX_PATH_MAX) {
        writeErr("zpathchk: limit ");
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{POSIX_PATH_MAX}) catch "256";
        writeErr(s);
        writeErr(" exceeded by length ");
        const s2 = std.fmt.bufPrint(&buf, "{d}", .{path.len}) catch "?";
        writeErr(s2);
        writeErr(" of file name '");
        writeErr(path);
        writeErr("'\n");
        return false;
    }

    // Check each component
    var start: usize = 0;
    var i: usize = 0;

    while (i <= path.len) {
        const is_sep = i == path.len or path[i] == '/';

        if (is_sep) {
            const component = path[start..i];

            // Skip empty components (multiple slashes or leading slash)
            if (component.len > 0) {
                // -P: check for leading dash
                if (check_extra and component[0] == '-') {
                    writeErr("zpathchk: leading '-' in a component of file name '");
                    writeErr(path);
                    writeErr("'\n");
                    return false;
                }

                // -p: check component length
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

                // -p: check for non-portable characters
                if (check_posix) {
                    for (component) |c| {
                        if (!isPortableChar(c)) {
                            writeErr("zpathchk: non-portable character '");
                            var char_buf: [1]u8 = .{c};
                            writeErr(&char_buf);
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

        i += 1;
    }

    // Default mode (no -p or -P): just basic validity checks
    if (!check_posix and !check_extra) {
        // Empty path is always invalid
        if (path.len == 0) {
            writeErr("zpathchk: '': No such file or directory\n");
            return false;
        }
        // Check path length against system limits
        if (path.len > 4095) {
            writeErr("zpathchk: '");
            writeErr(path);
            writeErr("': File name too long\n");
            return false;
        }
    }

    return true;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var check_posix = false;
    var check_extra = false;
    var paths_count: usize = 0;
    var paths: [256][]const u8 = undefined;
    var parsing_opts = true;

    while (args.next()) |arg| {
        if (parsing_opts and arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--help")) {
                const help =
                    \\Usage: zpathchk [OPTION]... NAME...
                    \\Diagnose invalid or non-portable file names.
                    \\
                    \\  -p                  check for most POSIX systems
                    \\  -P                  check for empty names and leading "-"
                    \\      --portability   check for all POSIX systems (equivalent to -p -P)
                    \\      --help          display this help and exit
                    \\
                ;
                _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
                return;
            } else if (std.mem.eql(u8, arg, "--portability")) {
                check_posix = true;
                check_extra = true;
            } else if (std.mem.eql(u8, arg, "--")) {
                parsing_opts = false;
            } else {
                // Parse short options
                for (arg[1..]) |c| {
                    switch (c) {
                        'p' => check_posix = true,
                        'P' => check_extra = true,
                        else => {
                            writeErr("zpathchk: invalid option -- '");
                            var buf: [1]u8 = .{c};
                            writeErr(&buf);
                            writeErr("'\n");
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            if (paths_count < paths.len) {
                paths[paths_count] = arg;
                paths_count += 1;
            }
        }
    }

    if (paths_count == 0) {
        writeErr("zpathchk: missing operand\n");
        std.process.exit(1);
    }

    var had_error = false;
    for (paths[0..paths_count]) |path| {
        if (!checkPath(path, check_posix, check_extra)) {
            had_error = true;
        }
    }

    if (had_error) std.process.exit(1);
}
