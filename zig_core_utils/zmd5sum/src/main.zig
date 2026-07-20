//! zmd5sum - High-performance MD5 checksum utility
//!
//! Compatible with GNU md5sum:
//! - FILE: compute MD5 hash of files
//! - -c, --check: verify checksums from file
//! - -b, --binary: read in binary mode (default on non-Unix)
//! - -t, --text: read in text mode
//! - --quiet: don't print OK for each verified file
//! - --status: don't output anything, exit code shows success
//! - --tag: create BSD-style checksums
//! - -z, --zero: end each output line with NUL, disable escaping
//! - --ignore-missing: don't fail for missing files (check mode)
//! - --strict: exit non-zero for improperly formatted lines (check mode)
//! - -w, --warn: warn about improperly formatted lines (check mode)
//!
//! Note: MD5 is cryptographically broken and should not be used for security.
//! Use SHA-256 or BLAKE2 for security-sensitive applications.

const std = @import("std");
const Md5 = std.crypto.hash.Md5;
const libc = std.c;

const BUFFER_SIZE = 64 * 1024; // 64KB buffer for efficient I/O
const DIGEST_LENGTH = Md5.digest_length;
const HEX_LENGTH = DIGEST_LENGTH * 2;

const Config = struct {
    check_mode: bool = false,
    binary_mode: bool = false,
    quiet: bool = false,
    status_only: bool = false,
    bsd_tag: bool = false,
    zero: bool = false,
    ignore_missing: bool = false,
    strict: bool = false,
    warn: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// True if the filename must be escaped on output (GNU escapes '\', '\n', '\r').
fn needsEscape(s: []const u8) bool {
    for (s) |c| {
        if (c == '\\' or c == '\n' or c == '\r') return true;
    }
    return false;
}

/// Write a filename to stdout with GNU escaping: '\'->"\\", '\n'->"\n", '\r'->"\r".
fn writeEscapedName(s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        var j = i;
        while (j < s.len and s[j] != '\\' and s[j] != '\n' and s[j] != '\r') : (j += 1) {}
        if (j > i) writeStdout(s[i..j]);
        if (j < s.len) {
            switch (s[j]) {
                '\\' => writeStdout("\\\\"),
                '\n' => writeStdout("\\n"),
                '\r' => writeStdout("\\r"),
                else => unreachable,
            }
            j += 1;
        }
        i = j;
    }
}

/// Reverse of writeEscapedName: decode a '\'-escaped checksum-file filename.
/// Caller owns the returned slice.
fn unescapeName(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                '\\' => try out.append(allocator, '\\'),
                'n' => try out.append(allocator, '\n'),
                'r' => try out.append(allocator, '\r'),
                else => {
                    // Unknown escape: keep both bytes verbatim.
                    try out.append(allocator, '\\');
                    try out.append(allocator, s[i]);
                },
            }
        } else {
            try out.append(allocator, s[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Read an entire file descriptor into an owned slice. Handles short reads
/// (pipes, slow filesystems) by looping until a genuine EOF (read == 0).
fn readAllFd(allocator: std.mem.Allocator, fd: i32) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [BUFFER_SIZE]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadError;
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return list.toOwnedSlice(allocator);
}

fn hashFile(allocator: std.mem.Allocator, path: []const u8, is_stdin: bool) ![HEX_LENGTH]u8 {
    var hash = Md5.init(.{});
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
            writeStderr("zmd5sum: ");
            writeStderr(path);
            writeStderr(": No such file or directory\n");
            return error.OpenError;
        }
        defer _ = libc.close(fd);

        while (true) {
            const n = libc.read(fd, &buffer, buffer.len);
            if (n < 0) return error.ReadError;
            if (n == 0) break;
            hash.update(buffer[0..@intCast(n)]);
        }
    }

    var digest: [DIGEST_LENGTH]u8 = undefined;
    hash.final(&digest);

    var hex: [HEX_LENGTH]u8 = undefined;
    for (digest, 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    return hex;
}

fn printHash(path: []const u8, hex: *const [HEX_LENGTH]u8, config: *const Config) void {
    // GNU: -z (NUL-terminated) output is not escaped at all.
    const escape = !config.zero and needsEscape(path);
    const terminator: []const u8 = if (config.zero) &[_]u8{0} else "\n";

    if (config.bsd_tag) {
        if (escape) writeStdout("\\");
        writeStdout("MD5 (");
        if (escape) writeEscapedName(path) else writeStdout(path);
        writeStdout(") = ");
        writeStdout(hex);
        writeStdout(terminator);
    } else {
        if (escape) writeStdout("\\");
        writeStdout(hex);
        if (config.binary_mode) {
            writeStdout(" *");
        } else {
            writeStdout("  ");
        }
        if (escape) writeEscapedName(path) else writeStdout(path);
        writeStdout(terminator);
    }
}

const ParsedLine = struct {
    hash: []const u8, // lowercase-comparable hex, exactly HEX_LENGTH
    filename: []const u8, // borrows from `line`, still escaped if `escaped`
    escaped: bool,
};

/// Parse a single checksum line. Returns null if the line is not a properly
/// formatted checksum line (caller counts it as improper). Blank lines are
/// the caller's responsibility (they are skipped, not improper).
fn parseChecksumLine(line: []const u8) ?ParsedLine {
    var s = line;
    var escaped = false;
    if (s.len > 0 and s[0] == '\\') {
        escaped = true;
        s = s[1..];
    }

    // BSD reversed / --tag format:  MD5 (<name>) = <hash>
    if (std.mem.startsWith(u8, s, "MD5 (")) {
        const rest = s[5..];
        if (std.mem.lastIndexOf(u8, rest, ") = ")) |pos| {
            const name = rest[0..pos];
            const hash = rest[pos + 4 ..];
            if (hash.len == HEX_LENGTH and allHex(hash) and name.len > 0) {
                return .{ .hash = hash, .filename = name, .escaped = escaped };
            }
        }
        return null;
    }

    // Standard format: <hash><sep><name>
    // Need at least HEX_LENGTH hex + one separator + one filename char.
    if (s.len < HEX_LENGTH + 2) return null;
    const hash = s[0..HEX_LENGTH];
    if (!allHex(hash)) return null;

    // GNU split_3 separator rule: index HEX_LENGTH must be ' ' or '\t'
    // (always consumed). Then at HEX_LENGTH+1: '*' => binary marker consumed,
    // ' ' => second space consumed; any other char => filename starts there.
    const sep = s[HEX_LENGTH];
    if (sep != ' ' and sep != '\t') return null;
    var start: usize = HEX_LENGTH + 1;
    if (s[start] == '*' or s[start] == ' ') {
        start += 1;
    }
    if (start >= s.len) return null;
    const name = s[start..];
    return .{ .hash = hash, .filename = name, .escaped = escaped };
}

fn allHex(s: []const u8) bool {
    for (s) |c| {
        if (!isHexDigit(c)) return false;
    }
    return true;
}

/// Write a checksum-file entry's filename for the OK/FAILED display line.
/// GNU reproduces the name exactly as it appeared in the checksum file:
/// for an escaped line that is the leading '\' marker plus the (already
/// escaped) substring, verbatim — never re-escaped.
fn writeParsedName(parsed: ParsedLine) void {
    if (parsed.escaped) writeStdout("\\");
    writeStdout(parsed.filename);
}

fn writeNum(n: usize) void {
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    writeStderr(str);
}

fn checkFile(allocator: std.mem.Allocator, checksum_file: []const u8, config: *const Config) !bool {
    const is_stdin = std.mem.eql(u8, checksum_file, "-");

    const content = blk: {
        if (is_stdin) {
            break :blk try readAllFd(allocator, libc.STDIN_FILENO);
        } else {
            const path_z = try allocator.dupeZ(u8, checksum_file);
            defer allocator.free(path_z);
            const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
            if (fd < 0) {
                writeStderr("zmd5sum: ");
                writeStderr(checksum_file);
                writeStderr(": No such file or directory\n");
                return error.OpenError;
            }
            defer _ = libc.close(fd);
            break :blk try readAllFd(allocator, fd);
        }
    };
    defer allocator.free(content);

    var properly_formatted: usize = 0;
    var improper: usize = 0;
    var mismatch: usize = 0;
    var read_failed: usize = 0;
    var verified: usize = 0;

    const sep: u8 = if (config.zero) 0 else '\n';
    var it = std.mem.splitScalar(u8, content, sep);
    var lineno: usize = 0;
    while (it.next()) |raw_line| {
        // The final split segment after a trailing separator is empty; also a
        // genuinely blank line. Blank lines are skipped and never counted.
        if (raw_line.len == 0) continue;
        lineno += 1;

        const parsed = parseChecksumLine(raw_line) orelse {
            improper += 1;
            if (config.warn and !config.status_only) {
                writeStderr("zmd5sum: ");
                writeStderr(checksum_file);
                writeStderr(": ");
                writeNum(lineno);
                writeStderr(": improperly formatted MD5 checksum line\n");
            }
            continue;
        };
        properly_formatted += 1;

        // Resolve the (possibly escaped) filename to a real path.
        var owned_name: ?[]u8 = null;
        defer if (owned_name) |n| allocator.free(n);
        const filename: []const u8 = if (parsed.escaped) blk: {
            owned_name = try unescapeName(allocator, parsed.filename);
            break :blk owned_name.?;
        } else parsed.filename;

        // --ignore-missing: silently skip files that do not exist.
        if (config.ignore_missing) {
            const fz = try allocator.dupeZ(u8, filename);
            defer allocator.free(fz);
            if (libc.access(fz.ptr, libc.F_OK) != 0) continue;
        }

        const computed = hashFile(allocator, filename, false) catch {
            if (!config.status_only) {
                // GNU displays the filename in escaped form here.
                writeParsedName(parsed);
                writeStdout(": FAILED open or read\n");
            }
            read_failed += 1;
            continue;
        };
        verified += 1;

        if (std.ascii.eqlIgnoreCase(&computed, parsed.hash)) {
            if (!config.quiet and !config.status_only) {
                writeParsedName(parsed);
                writeStdout(": OK\n");
            }
        } else {
            if (!config.status_only) {
                writeParsedName(parsed);
                writeStdout(": FAILED\n");
            }
            mismatch += 1;
        }
    }

    // No parseable lines at all: GNU errors and exits 1.
    if (properly_formatted == 0) {
        writeStderr("zmd5sum: ");
        writeStderr(checksum_file);
        writeStderr(": no properly formatted checksum lines found\n");
        return error.NoFormattedLines;
    }

    // --ignore-missing where nothing was actually verified.
    if (config.ignore_missing and verified == 0) {
        writeStderr("zmd5sum: ");
        writeStderr(checksum_file);
        writeStderr(": no file was verified\n");
        return error.NoFileVerified;
    }

    if (!config.status_only) {
        if (improper > 0) {
            writeStderr("zmd5sum: WARNING: ");
            writeNum(improper);
            if (improper == 1) {
                writeStderr(" line is improperly formatted\n");
            } else {
                writeStderr(" lines are improperly formatted\n");
            }
        }
        if (read_failed > 0) {
            writeStderr("zmd5sum: WARNING: ");
            writeNum(read_failed);
            if (read_failed == 1) {
                writeStderr(" listed file could not be read\n");
            } else {
                writeStderr(" listed files could not be read\n");
            }
        }
        if (mismatch > 0) {
            writeStderr("zmd5sum: WARNING: ");
            writeNum(mismatch);
            if (mismatch == 1) {
                writeStderr(" computed checksum did NOT match\n");
            } else {
                writeStderr(" computed checksums did NOT match\n");
            }
        }
    }

    if (mismatch > 0 or read_failed > 0) return false;
    if (config.strict and improper > 0) return false;
    return true;
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
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
                } else if (std.mem.eql(u8, arg, "--zero")) {
                    config.zero = true;
                } else if (std.mem.eql(u8, arg, "--ignore-missing")) {
                    config.ignore_missing = true;
                } else if (std.mem.eql(u8, arg, "--strict")) {
                    config.strict = true;
                } else if (std.mem.eql(u8, arg, "--warn")) {
                    config.warn = true;
                } else {
                    writeStderr("zmd5sum: unrecognized option '");
                    writeStderr(arg);
                    writeStderr("'\n");
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'c' => config.check_mode = true,
                        'b' => config.binary_mode = true,
                        't' => config.binary_mode = false,
                        'q' => config.quiet = true,
                        'z' => config.zero = true,
                        'w' => config.warn = true,
                        else => {
                            writeStderr("zmd5sum: invalid option -- '");
                            var char_buf: [1]u8 = .{ch};
                            writeStderr(&char_buf);
                            writeStderr("'\n");
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.files.items.len == 0) {
        try config.files.append(allocator, try allocator.dupe(u8, "-"));
    }

    return config;
}

fn printHelp() void {
    const usage =
        \\Usage: zmd5sum [OPTION]... [FILE]...
        \\Print or check MD5 checksums.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -b, --binary          read in binary mode (default)
        \\  -c, --check           read checksums from FILEs and check them
        \\  -t, --text            read in text mode
        \\      --tag             create BSD-style checksums
        \\  -z, --zero            end each output line with NUL, not newline,
        \\                          and disable file name escaping
        \\
        \\The following five options are useful only when verifying checksums:
        \\      --ignore-missing  don't fail or report status for missing files
        \\      --quiet           don't print OK for each successfully verified file
        \\      --status          don't output anything, status code shows success
        \\      --strict          exit non-zero for improperly formatted checksum lines
        \\  -w, --warn            warn about improperly formatted checksum lines
        \\
        \\      --help            display this help and exit
        \\      --version         output version information and exit
        \\
        \\WARNING: MD5 is cryptographically broken. Use SHA-256 for security.
        \\
        \\zmd5sum - High-performance MD5 checksum utility in Zig
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zmd5sum 0.1.0\n");
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
            const hex = hashFile(allocator, file, is_stdin) catch {
                exit_code = 1;
                continue;
            };
            printHash(if (is_stdin) "-" else file, &hex, &config);
        }
    }

    std.process.exit(exit_code);
}
