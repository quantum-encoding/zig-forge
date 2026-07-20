//! zsha512sum - High-performance SHA-512 checksum utility

const std = @import("std");
const Sha512 = std.crypto.hash.sha2.Sha512;
const libc = std.c;

const BUFFER_SIZE = 64 * 1024;
const DIGEST_LENGTH = Sha512.digest_length;
const HEX_LENGTH = DIGEST_LENGTH * 2;

const Config = struct {
    check_mode: bool = false,
    binary_mode: bool = false,
    quiet: bool = false,
    status_only: bool = false,
    bsd_tag: bool = false,
    warn: bool = false,
    strict: bool = false,
    ignore_missing: bool = false,
    zero: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.files.items) |item| allocator.free(item);
        self.files.deinit(allocator);
    }
};

fn writeAll(fd: libc.fd_t, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) break; // EPIPE / hard error: nothing more we can do
        off += @intCast(n);
    }
}

fn writeStdout(data: []const u8) void {
    writeAll(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeAll(libc.STDERR_FILENO, data);
}

/// Hash a file (or stdin). `print_errors` controls whether open/read failures
/// emit a diagnostic to stderr (suppressed for --ignore-missing).
fn hashFile(allocator: std.mem.Allocator, path: []const u8, is_stdin: bool, print_errors: bool) ![HEX_LENGTH]u8 {
    var hash = Sha512.init(.{});
    var buffer: [BUFFER_SIZE]u8 = undefined;

    if (is_stdin) {
        while (true) {
            const n = libc.read(libc.STDIN_FILENO, &buffer, buffer.len);
            if (n < 0) return error.ReadError;
            if (n == 0) break;
            hash.update(buffer[0..@intCast(n)]);
        }
    } else {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            if (print_errors) {
                writeStderr("zsha512sum: ");
                writeStderr(path);
                writeStderr(": No such file or directory\n");
            }
            return error.OpenError;
        }
        defer _ = libc.close(fd);

        // A directory opens fine but read() returns EISDIR; GNU reports
        // "Is a directory" and fails rather than hashing empty input.
        var st: libc.Stat = undefined;
        if (libc.fstat(fd, &st) == 0 and libc.S.ISDIR(@as(u32, st.mode))) {
            if (print_errors) {
                writeStderr("zsha512sum: ");
                writeStderr(path);
                writeStderr(": Is a directory\n");
            }
            return error.IsDir;
        }

        while (true) {
            const n = libc.read(fd, &buffer, buffer.len);
            if (n < 0) {
                if (print_errors) {
                    writeStderr("zsha512sum: ");
                    writeStderr(path);
                    writeStderr(": Read error\n");
                }
                return error.ReadError;
            }
            if (n == 0) break;
            hash.update(buffer[0..@intCast(n)]);
        }
    }

    var digest: [DIGEST_LENGTH]u8 = undefined;
    hash.final(&digest);
    var hex: [HEX_LENGTH]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0F];
    }
    return hex;
}

fn printHash(path: []const u8, hex: *const [HEX_LENGTH]u8, config: *const Config) void {
    if (config.bsd_tag) {
        writeStdout("SHA512 (");
        writeStdout(path);
        writeStdout(") = ");
        writeStdout(hex);
    } else {
        writeStdout(hex);
        writeStdout(if (config.binary_mode) " *" else "  ");
        writeStdout(path);
    }
    writeStdout(if (config.zero) "\x00" else "\n");
}

/// A parsed checksum line: the 128-hex-char digest (lowercased) and the filename.
const ParsedLine = struct {
    hash: [HEX_LENGTH]u8,
    filename: []const u8,
};

/// Validate `s` is exactly HEX_LENGTH hex digits; write its lowercase form to
/// `out`. Case-insensitive so an uppercase manifest verifies like GNU accepts.
fn parseHexHash(s: []const u8, out: *[HEX_LENGTH]u8) bool {
    if (s.len != HEX_LENGTH) return false;
    for (s, 0..) |c, i| {
        if (!std.ascii.isHex(c)) return false;
        out[i] = std.ascii.toLower(c);
    }
    return true;
}

/// Parse one checksum line into hash+filename, or null if not a properly
/// formatted line. Accepts both the GNU `<hash>  <name>` / `<hash> *<name>`
/// layout and the BSD `SHA512 (<name>) = <hash>` (--tag) layout.
fn parseLine(line: []const u8) ?ParsedLine {
    const tag_prefix = "SHA512 (";
    if (std.mem.startsWith(u8, line, tag_prefix)) {
        const rest = line[tag_prefix.len..];
        const sep = std.mem.lastIndexOf(u8, rest, ") = ") orelse return null;
        const filename = rest[0..sep];
        const hashpart = rest[sep + 4 ..];
        if (filename.len == 0) return null;
        var parsed: ParsedLine = .{ .hash = undefined, .filename = filename };
        if (!parseHexHash(hashpart, &parsed.hash)) return null;
        return parsed;
    }

    // GNU layout: 128 hex chars, a space, then ' ' (text) or '*' (binary), then name.
    if (line.len < HEX_LENGTH + 3) return null;
    var parsed: ParsedLine = .{ .hash = undefined, .filename = undefined };
    if (!parseHexHash(line[0..HEX_LENGTH], &parsed.hash)) return null;
    if (line[HEX_LENGTH] != ' ') return null;
    const marker = line[HEX_LENGTH + 1];
    if (marker != ' ' and marker != '*') return null;
    parsed.filename = line[HEX_LENGTH + 2 ..];
    if (parsed.filename.len == 0) return null;
    return parsed;
}

const CheckState = struct {
    n_parsed: usize = 0, // properly formatted lines
    n_malformed: usize = 0, // improperly formatted (non-blank) lines
    n_verified: usize = 0, // properly formatted AND readable
    n_mismatch: usize = 0, // computed digest did not match
    n_unreadable: usize = 0, // listed file could not be read
    all_ok: bool = true,
};

fn processLine(
    allocator: std.mem.Allocator,
    checksum_file: []const u8,
    line: []const u8,
    lineno: usize,
    config: *const Config,
    st: *CheckState,
) void {
    if (line.len == 0) return; // GNU silently skips blank lines

    const parsed = parseLine(line) orelse {
        st.n_malformed += 1;
        if (config.warn) {
            var buf: [64]u8 = undefined;
            const num = std.fmt.bufPrint(&buf, "{d}", .{lineno}) catch "?";
            writeStderr("zsha512sum: ");
            writeStderr(checksum_file);
            writeStderr(": ");
            writeStderr(num);
            writeStderr(": improperly formatted SHA512 checksum line\n");
        }
        return;
    };
    st.n_parsed += 1;

    const computed = hashFile(allocator, parsed.filename, false, !config.ignore_missing) catch {
        if (config.ignore_missing) return; // missing files are silently skipped
        if (!config.status_only) {
            writeStdout(parsed.filename);
            writeStdout(": FAILED open or read\n");
        }
        st.n_unreadable += 1;
        st.all_ok = false;
        return;
    };
    st.n_verified += 1;

    if (std.mem.eql(u8, &computed, &parsed.hash)) {
        if (!config.quiet and !config.status_only) {
            writeStdout(parsed.filename);
            writeStdout(": OK\n");
        }
    } else {
        if (!config.status_only) {
            writeStdout(parsed.filename);
            writeStdout(": FAILED\n");
        }
        st.n_mismatch += 1;
        st.all_ok = false;
    }
}

fn checkFile(allocator: std.mem.Allocator, checksum_file: []const u8, config: *const Config) !bool {
    const path_z = try allocator.dupeZ(u8, checksum_file);
    defer allocator.free(path_z);

    const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        writeStderr("zsha512sum: ");
        writeStderr(checksum_file);
        writeStderr(": No such file or directory\n");
        return error.OpenError;
    }
    defer _ = libc.close(fd);

    var st: CheckState = .{};
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(allocator);
    var lineno: usize = 0;
    const delim: u8 = if (config.zero) 0 else '\n';

    var file_buffer: [8192]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &file_buffer, file_buffer.len);
        if (n < 0) return error.ReadError;
        if (n == 0) break;
        for (file_buffer[0..@intCast(n)]) |byte| {
            if (byte == delim) {
                lineno += 1;
                processLine(allocator, checksum_file, line.items, lineno, config, &st);
                line.clearRetainingCapacity();
            } else {
                try line.append(allocator, byte);
            }
        }
    }
    // Flush the final line when the file lacks a trailing delimiter — GNU still
    // verifies it; dropping it silently passes an unverified manifest.
    if (line.items.len > 0) {
        lineno += 1;
        processLine(allocator, checksum_file, line.items, lineno, config, &st);
    }

    // No properly formatted line at all is a hard error, not a silent success.
    if (st.n_parsed == 0) {
        writeStderr("zsha512sum: ");
        writeStderr(checksum_file);
        writeStderr(": no properly formatted checksum lines found\n");
        return false;
    }
    // --ignore-missing where every listed file was absent.
    if (config.ignore_missing and st.n_verified == 0) {
        writeStderr("zsha512sum: ");
        writeStderr(checksum_file);
        writeStderr(": no file was verified\n");
        return false;
    }

    if (!config.status_only) {
        if ((config.warn or config.strict) and st.n_malformed > 0) {
            warnCount(st.n_malformed, " line is improperly formatted\n", " lines are improperly formatted\n");
        }
        if (st.n_unreadable > 0) {
            warnCount(st.n_unreadable, " listed file could not be read\n", " listed files could not be read\n");
        }
        if (st.n_mismatch > 0) {
            warnCount(st.n_mismatch, " computed checksum did NOT match\n", " computed checksums did NOT match\n");
        }
    }

    var ok = st.all_ok;
    if (config.strict and st.n_malformed > 0) ok = false;
    return ok;
}

fn warnCount(count: usize, singular: []const u8, plural: []const u8) void {
    var buf: [32]u8 = undefined;
    const num = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "?";
    writeStderr("zsha512sum: WARNING: ");
    writeStderr(num);
    writeStderr(if (count == 1) singular else plural);
}

fn unrecognizedLong(arg: []const u8) noreturn {
    writeStderr("zsha512sum: unrecognized option '");
    writeStderr(arg);
    writeStderr("'\nTry 'zsha512sum --help' for more information.\n");
    std.process.exit(1);
}

fn invalidShort(ch: u8) noreturn {
    const buf = [_]u8{ch};
    writeStderr("zsha512sum: invalid option -- '");
    writeStderr(&buf);
    writeStderr("'\nTry 'zsha512sum --help' for more information.\n");
    std.process.exit(1);
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
        if (arg.len > 1 and arg[0] == '-') {
            if (arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--check")) {
                    config.check_mode = true;
                } else if (std.mem.eql(u8, arg, "--binary")) {
                    config.binary_mode = true;
                } else if (std.mem.eql(u8, arg, "--text")) {
                    config.binary_mode = false;
                } else if (std.mem.eql(u8, arg, "--quiet")) {
                    config.quiet = true;
                } else if (std.mem.eql(u8, arg, "--status")) {
                    config.status_only = true;
                } else if (std.mem.eql(u8, arg, "--tag")) {
                    config.bsd_tag = true;
                } else if (std.mem.eql(u8, arg, "--warn")) {
                    config.warn = true;
                } else if (std.mem.eql(u8, arg, "--strict")) {
                    config.strict = true;
                } else if (std.mem.eql(u8, arg, "--ignore-missing")) {
                    config.ignore_missing = true;
                } else if (std.mem.eql(u8, arg, "--zero")) {
                    config.zero = true;
                } else {
                    unrecognizedLong(arg);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'c' => config.check_mode = true,
                        'b' => config.binary_mode = true,
                        't' => config.binary_mode = false,
                        'q' => config.quiet = true,
                        'w' => config.warn = true,
                        'z' => config.zero = true,
                        else => invalidShort(ch),
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
        \\Usage: zsha512sum [OPTION]... [FILE]...
        \\Print or check SHA512 checksums.
        \\
        \\  -b, --binary         read in binary mode (default)
        \\  -c, --check          read checksums from FILEs and check them
        \\  -t, --text           read in text mode
        \\      --tag            create BSD-style checksums
        \\  -z, --zero           end each output line with NUL, not newline
        \\
        \\The following options are useful only when verifying checksums:
        \\      --ignore-missing  don't fail or report status for missing files
        \\      --quiet          don't print OK for each verified file
        \\      --status         don't output anything, status code shows success
        \\      --strict         exit non-zero for improperly formatted lines
        \\  -w, --warn           warn about improperly formatted lines
        \\
        \\      --help           display this help and exit
        \\      --version        output version information and exit
        \\
    );
}

fn printVersion() void {
    writeStdout("zsha512sum 0.1.0\n");
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    var config = parseArgs(allocator, init.minimal.args) catch {
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    var exit_code: u8 = 0;
    if (config.check_mode) {
        for (config.files.items) |file| {
            const all_ok = checkFile(allocator, file, &config) catch {
                exit_code = 1;
                continue;
            };
            if (!all_ok) exit_code = 1;
        }
    } else {
        for (config.files.items) |file| {
            const is_stdin = std.mem.eql(u8, file, "-");
            const hex = hashFile(allocator, file, is_stdin, true) catch {
                exit_code = 1;
                continue;
            };
            printHash(if (is_stdin) "-" else file, &hex, &config);
        }
    }
    std.process.exit(exit_code);
}
