//! zsha256sum - High-performance SHA-256 checksum utility

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const libc = std.c;

const BUFFER_SIZE = 64 * 1024;
const DIGEST_LENGTH = Sha256.digest_length;
const HEX_LENGTH = DIGEST_LENGTH * 2;

const Config = struct {
    check_mode: bool = false,
    binary_mode: bool = false,
    quiet: bool = false,
    status_only: bool = false,
    bsd_tag: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.files.items) |item| allocator.free(item);
        self.files.deinit(allocator);
    }
};

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

fn errno() c_int {
    return std.c._errno().*;
}

// Write all bytes, retrying on EINTR and short writes. libc.write can return
// fewer bytes than requested (slow/full pipe) or -1/EINTR; ignoring that would
// silently drop part of a checksum line.
fn writeAll(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            if (errno() == @intFromEnum(std.c.E.INTR)) continue;
            return; // unrecoverable write error; nothing more we can do
        }
        if (n == 0) return;
        off += @intCast(n);
    }
}

// Read into buf, retrying on EINTR. Returns <0 on a genuine error (errno set),
// 0 on EOF, >0 bytes read. This is what lets us distinguish a real I/O error
// (e.g. EISDIR when a directory is opened and read) from clean end-of-file.
fn readRetry(fd: c_int, buf: []u8) isize {
    while (true) {
        const n = libc.read(fd, buf.ptr, buf.len);
        if (n < 0 and errno() == @intFromEnum(std.c.E.INTR)) continue;
        return n;
    }
}

fn writeStdout(data: []const u8) void {
    writeAll(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeAll(libc.STDERR_FILENO, data);
}

// Emit "zsha256sum: <name>: <strerror(errno)>\n", matching GNU coreutils'
// per-file diagnostic (GNU uses strerror too, so the message text lines up).
fn reportFileError(name: []const u8, en: c_int) void {
    writeStderr("zsha256sum: ");
    writeStderr(name);
    writeStderr(": ");
    writeStderr(std.mem.span(strerror(en)));
    writeStderr("\n");
}

fn hashFile(allocator: std.mem.Allocator, path: []const u8, is_stdin: bool) ![HEX_LENGTH]u8 {
    var hash = Sha256.init(.{});
    var buffer: [BUFFER_SIZE]u8 = undefined;
    const disp = if (is_stdin) "standard input" else path;

    var fd: c_int = libc.STDIN_FILENO;
    if (!is_stdin) {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            reportFileError(disp, errno());
            return error.OpenError;
        }
    }
    defer if (!is_stdin) {
        _ = libc.close(fd);
    };

    while (true) {
        const n = readRetry(fd, &buffer);
        if (n < 0) {
            // Genuine read error (e.g. EISDIR for a directory, or EIO). GNU
            // reports this and exits non-zero rather than emitting the
            // empty-input hash as if it were a valid checksum.
            reportFileError(disp, errno());
            return error.ReadError;
        }
        if (n == 0) break;
        hash.update(buffer[0..@intCast(n)]);
    }

    const digest = hash.finalResult();
    var hex: [HEX_LENGTH]u8 = undefined;
    for (digest, 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0F];
    }
    return hex;
}

fn printHash(path: []const u8, hex: *const [HEX_LENGTH]u8, config: *const Config) void {
    if (config.bsd_tag) {
        writeStdout("SHA256 (");
        writeStdout(path);
        writeStdout(") = ");
        writeStdout(hex);
        writeStdout("\n");
    } else {
        writeStdout(hex);
        writeStdout(if (config.binary_mode) " *" else "  ");
        writeStdout(path);
        writeStdout("\n");
    }
}

const CheckState = struct {
    all_ok: bool = true,
    saw_valid: bool = false,
    mismatches: usize = 0,
    read_failures: usize = 0,
};

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// Handle one line of a checksum file. Returns without touching `saw_valid`
// for improperly-formatted lines (GNU tracks whether ANY line was valid so it
// can error with "no properly formatted checksum lines found").
fn handleCheckLine(allocator: std.mem.Allocator, line: []const u8, config: *const Config, state: *CheckState) void {
    // Trim a trailing CR so CRLF checksum files parse.
    var l = line;
    if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
    if (l.len < HEX_LENGTH + 2) return;

    const hash_str = l[0..HEX_LENGTH];
    for (hash_str) |c| {
        if (!isHexDigit(c)) return;
    }
    // GNU line format: <hash><space>(<space>|'*')<filename>
    if (l[HEX_LENGTH] != ' ') return;
    if (l[HEX_LENGTH + 1] != ' ' and l[HEX_LENGTH + 1] != '*') return;
    const filename = l[HEX_LENGTH + 2 ..];
    if (filename.len == 0) return;

    // Properly formatted checksum line.
    state.saw_valid = true;

    const computed = hashFile(allocator, filename, false) catch {
        if (!config.status_only) {
            writeStdout(filename);
            writeStdout(": FAILED open or read\n");
        }
        state.read_failures += 1;
        state.all_ok = false;
        return;
    };

    // Case-insensitive hex comparison (GNU compares parsed bytes).
    var match = true;
    for (computed, hash_str) |a, b| {
        if (a != asciiLower(b)) {
            match = false;
            break;
        }
    }

    if (match) {
        if (!config.quiet and !config.status_only) {
            writeStdout(filename);
            writeStdout(": OK\n");
        }
    } else {
        if (!config.status_only) {
            writeStdout(filename);
            writeStdout(": FAILED\n");
        }
        state.mismatches += 1;
        state.all_ok = false;
    }
}

// Emit "zsha256sum: WARNING: N <thing> <verb>\n" with GNU singular/plural.
fn warnCount(count: usize, singular: []const u8, plural: []const u8) void {
    var buf: [128]u8 = undefined;
    const word = if (count == 1) singular else plural;
    const msg = std.fmt.bufPrint(&buf, "zsha256sum: WARNING: {d} {s}\n", .{ count, word }) catch return;
    writeStderr(msg);
}

fn checkFile(allocator: std.mem.Allocator, checksum_file: []const u8, config: *const Config) !bool {
    const path_z = try allocator.dupeZ(u8, checksum_file);
    defer allocator.free(path_z);

    const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        reportFileError(checksum_file, errno());
        return error.OpenError;
    }
    defer _ = libc.close(fd);

    var file_buffer: [8192]u8 = undefined;
    var line_buffer: [4096]u8 = undefined;
    var line_len: usize = 0;
    var line_overflow = false;
    var state = CheckState{};

    while (true) {
        const n = readRetry(fd, &file_buffer);
        if (n < 0) {
            reportFileError(checksum_file, errno());
            return error.ReadError;
        }
        if (n == 0) break;
        const bytes_read: usize = @intCast(n);

        for (file_buffer[0..bytes_read]) |byte| {
            if (byte == '\n') {
                if (!line_overflow) handleCheckLine(allocator, line_buffer[0..line_len], config, &state);
                line_len = 0;
                line_overflow = false;
            } else if (line_len < line_buffer.len) {
                line_buffer[line_len] = byte;
                line_len += 1;
            } else {
                // Line longer than the buffer: don't silently truncate to a
                // wrong filename — discard the whole (malformed) line.
                line_overflow = true;
            }
        }
    }

    // Flush a final line that lacked a trailing newline; GNU verifies it.
    if (line_len > 0 and !line_overflow) {
        handleCheckLine(allocator, line_buffer[0..line_len], config, &state);
    }

    if (!state.saw_valid) {
        writeStderr("zsha256sum: ");
        writeStderr(checksum_file);
        writeStderr(": no properly formatted checksum lines found\n");
        return error.NoValidLines;
    }

    if (!config.status_only) {
        if (state.read_failures > 0)
            warnCount(state.read_failures, "listed file could not be read", "listed files could not be read");
        if (state.mismatches > 0)
            warnCount(state.mismatches, "computed checksum did NOT match", "computed checksums did NOT match");
    }
    return state.all_ok;
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| try args_list.append(allocator, arg);
    const args = args_list.items;

    var config = Config{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len > 0 and arg[0] == '-') {
            if (arg.len > 1 and arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) { printHelp(); std.process.exit(0); }
                else if (std.mem.eql(u8, arg, "--version")) { printVersion(); std.process.exit(0); }
                else if (std.mem.eql(u8, arg, "--check")) config.check_mode = true
                else if (std.mem.eql(u8, arg, "--binary")) config.binary_mode = true
                else if (std.mem.eql(u8, arg, "--text")) config.binary_mode = false
                else if (std.mem.eql(u8, arg, "--quiet")) config.quiet = true
                else if (std.mem.eql(u8, arg, "--status")) config.status_only = true
                else if (std.mem.eql(u8, arg, "--tag")) config.bsd_tag = true
                else {
                    writeStderr("zsha256sum: unrecognized option '");
                    writeStderr(arg);
                    writeStderr("'\nTry 'zsha256sum --help' for more information.\n");
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'c' => config.check_mode = true,
                        'b' => config.binary_mode = true,
                        't' => config.binary_mode = false,
                        'q' => config.quiet = true,
                        else => {
                            const buf = [_]u8{ 'z', 's', 'h', 'a', '2', '5', '6', 's', 'u', 'm', ':', ' ', 'i', 'n', 'v', 'a', 'l', 'i', 'd', ' ', 'o', 'p', 't', 'i', 'o', 'n', ' ', '-', '-', ' ', '\'', ch, '\'', '\n' };
                            writeStderr(&buf);
                            writeStderr("Try 'zsha256sum --help' for more information.\n");
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }
    if (config.files.items.len == 0) try config.files.append(allocator, try allocator.dupe(u8, "-"));
    return config;
}

fn printHelp() void {
    writeStdout(
        \\Usage: zsha256sum [OPTION]... [FILE]...
        \\Print or check SHA256 checksums.
        \\
        \\  -b, --binary   read in binary mode (default)
        \\  -c, --check    read checksums from FILEs and check them
        \\  -t, --text     read in text mode
        \\      --tag      create BSD-style checksums
        \\      --quiet    don't print OK for each verified file
        \\      --status   don't output anything, status code shows success
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
    );
}

fn printVersion() void {
    writeStdout("zsha256sum 0.1.0\n");
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    var config = parseArgs(allocator, init.minimal.args) catch { std.process.exit(1); };
    defer config.deinit(allocator);

    var exit_code: u8 = 0;
    if (config.check_mode) {
        for (config.files.items) |file| {
            const all_ok = checkFile(allocator, file, &config) catch { exit_code = 1; continue; };
            if (!all_ok) exit_code = 1;
        }
    } else {
        for (config.files.items) |file| {
            const is_stdin = std.mem.eql(u8, file, "-");
            const hex = hashFile(allocator, file, is_stdin) catch { exit_code = 1; continue; };
            printHash(if (is_stdin) "-" else file, &hex, &config);
        }
    }
    std.process.exit(exit_code);
}
