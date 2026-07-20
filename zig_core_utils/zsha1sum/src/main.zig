//! zsha1sum - High-performance SHA-1 checksum utility

const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const libc = std.c;

const BUFFER_SIZE = 64 * 1024;
const DIGEST_LENGTH = Sha1.digest_length;
const HEX_LENGTH = DIGEST_LENGTH * 2;

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

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

fn writeFd(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) break; // EOF / unrecoverable write error
        off += @intCast(n);
    }
}

fn writeStdout(data: []const u8) void {
    writeFd(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeFd(libc.STDERR_FILENO, data);
}

/// "zsha1sum: <path>: <strerror(errno)>\n"
fn reportErrno(path: []const u8) void {
    const e = libc._errno().*;
    writeStderr("zsha1sum: ");
    writeStderr(path);
    writeStderr(": ");
    writeStderr(std.mem.span(strerror(e)));
    writeStderr("\n");
}

/// "zsha1sum: <path>: <msg>\n"
fn reportMsg(path: []const u8, msg: []const u8) void {
    writeStderr("zsha1sum: ");
    writeStderr(path);
    writeStderr(": ");
    writeStderr(msg);
    writeStderr("\n");
}

fn hashFile(allocator: std.mem.Allocator, path: []const u8, is_stdin: bool) ![HEX_LENGTH]u8 {
    var hash = Sha1.init(.{});
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
            reportErrno(path);
            return error.OpenError;
        }
        defer _ = libc.close(fd);

        // A directory opens O_RDONLY successfully; read() then fails (EISDIR on
        // Darwin) or returns 0 on Linux — either way the empty-string digest
        // would be emitted. Detect it up front and error like GNU.
        var st: libc.Stat = undefined;
        if (libc.fstat(fd, &st) == 0 and libc.S.ISDIR(st.mode)) {
            reportMsg(path, "Is a directory");
            return error.IsDirectory;
        }

        while (true) {
            const n = libc.read(fd, &buffer, buffer.len);
            if (n < 0) {
                reportErrno(path);
                return error.ReadError;
            }
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

fn nameNeedsEscape(path: []const u8) bool {
    for (path) |c| {
        if (c == '\\' or c == '\n') return true;
    }
    return false;
}

/// GNU escapes output filenames containing '\' or '\n': the line is prefixed
/// with a literal '\', backslashes are doubled, and newlines become "\n".
fn writeEscapedName(path: []const u8) void {
    for (path) |c| {
        switch (c) {
            '\\' => writeStdout("\\\\"),
            '\n' => writeStdout("\\n"),
            else => writeStdout(&[1]u8{c}),
        }
    }
}

fn printHash(path: []const u8, hex: *const [HEX_LENGTH]u8, config: *const Config) void {
    const term: []const u8 = if (config.zero) "\x00" else "\n";
    if (config.bsd_tag) {
        writeStdout("SHA1 (");
        writeStdout(path);
        writeStdout(") = ");
        writeStdout(hex);
        writeStdout(term);
        return;
    }
    // GNU only escapes when NOT in --zero (NUL-terminated) mode.
    const escape = !config.zero and nameNeedsEscape(path);
    if (escape) writeStdout("\\");
    writeStdout(hex);
    writeStdout(if (config.binary_mode) " *" else "  ");
    if (escape) writeEscapedName(path) else writeStdout(path);
    writeStdout(term);
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn allHex(s: []const u8) bool {
    for (s) |c| {
        if (!isHexDigit(c)) return false;
    }
    return true;
}

/// Reverse GNU's check-file escaping ("\\" -> "\", "\n" -> newline). Only
/// applied to lines GNU flagged with a leading '\'. Caller owns the result.
fn unescapeName(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const nxt = raw[i + 1];
            switch (nxt) {
                '\\' => {
                    try out.append(allocator, '\\');
                    i += 1;
                    continue;
                },
                'n' => {
                    try out.append(allocator, '\n');
                    i += 1;
                    continue;
                },
                'r' => {
                    try out.append(allocator, '\r');
                    i += 1;
                    continue;
                },
                else => {},
            }
        }
        try out.append(allocator, raw[i]);
    }
    return out.toOwnedSlice(allocator);
}

const ParsedLine = struct {
    hash: [HEX_LENGTH]u8,
    /// Filename as it should be OPENED (un-escaped).
    open_name: []u8,
    /// Filename as it should be DISPLAYED in OK/FAILED lines (GNU echoes the
    /// escaped form, including the leading '\').
    display: []u8,

    fn deinit(self: *ParsedLine, allocator: std.mem.Allocator) void {
        allocator.free(self.open_name);
        allocator.free(self.display);
    }
};

/// Parse one line of a checksum file. Returns null if the line is not a
/// properly-formatted checksum line (blank lines included).
fn parseCheckLine(allocator: std.mem.Allocator, line_in: []const u8) !?ParsedLine {
    var line = line_in;
    // Strip a trailing CR so CRLF checksum files verify.
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    if (line.len == 0) return null;

    var escaped = false;
    if (line[0] == '\\') {
        escaped = true;
        line = line[1..];
    }

    // BSD/--tag form: "SHA1 (NAME) = HASH"
    if (std.mem.startsWith(u8, line, "SHA1 (")) {
        const body = line[6..];
        const sep = std.mem.indexOf(u8, body, ") = ") orelse return null;
        const raw_name = body[0..sep];
        const hash_str = body[sep + 4 ..];
        if (hash_str.len != HEX_LENGTH or !allHex(hash_str)) return null;

        var parsed: ParsedLine = undefined;
        @memcpy(&parsed.hash, hash_str);
        parsed.open_name = if (escaped) try unescapeName(allocator, raw_name) else try allocator.dupe(u8, raw_name);
        errdefer allocator.free(parsed.open_name);
        parsed.display = try allocator.dupe(u8, raw_name);
        return parsed;
    }

    // GNU form: "<40 hex><SP><SP|*><filename>"
    if (line.len < HEX_LENGTH + 2) return null;
    const hash_str = line[0..HEX_LENGTH];
    if (!allHex(hash_str)) return null;
    if (line[HEX_LENGTH] != ' ') return null;
    const flag = line[HEX_LENGTH + 1];
    if (flag != ' ' and flag != '*') return null;
    const raw_name = line[HEX_LENGTH + 2 ..];
    if (raw_name.len == 0) return null;

    var parsed: ParsedLine = undefined;
    @memcpy(&parsed.hash, hash_str);
    parsed.open_name = if (escaped) try unescapeName(allocator, raw_name) else try allocator.dupe(u8, raw_name);
    errdefer allocator.free(parsed.open_name);
    // Reproduce GNU's displayed (escaped) form, including the leading '\'.
    if (escaped) {
        var disp: std.ArrayListUnmanaged(u8) = .empty;
        errdefer disp.deinit(allocator);
        try disp.append(allocator, '\\');
        try disp.appendSlice(allocator, raw_name);
        parsed.display = try disp.toOwnedSlice(allocator);
    } else {
        parsed.display = try allocator.dupe(u8, raw_name);
    }
    return parsed;
}

fn writeCount(n: usize) void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    writeStderr(s);
}

fn checkFile(allocator: std.mem.Allocator, checksum_file: []const u8, config: *const Config) !bool {
    const path_z = try allocator.dupeZ(u8, checksum_file);
    defer allocator.free(path_z);

    const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        reportErrno(checksum_file);
        return error.OpenError;
    }
    defer _ = libc.close(fd);

    // A directory checksum-file argument must error, not hash-as-empty.
    var st: libc.Stat = undefined;
    if (libc.fstat(fd, &st) == 0 and libc.S.ISDIR(st.mode)) {
        reportMsg(checksum_file, "Is a directory");
        return error.IsDirectory;
    }

    // Read the whole checksum file. Handles arbitrary line lengths and short
    // reads (the previous fixed 1024-byte line buffer truncated long lines and
    // the "short read == EOF" heuristic silently dropped trailing lines).
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);
    var rbuf: [BUFFER_SIZE]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &rbuf, rbuf.len);
        if (n < 0) {
            reportErrno(checksum_file);
            return error.ReadError;
        }
        if (n == 0) break;
        try content.appendSlice(allocator, rbuf[0..@intCast(n)]);
    }

    const terminator: u8 = if (config.zero) 0 else '\n';
    var properly_formatted: usize = 0;
    var improperly_formatted: usize = 0;
    var mismatch: usize = 0;
    var read_failed: usize = 0;
    var all_ok = true;
    var line_no: usize = 0;

    var it = std.mem.splitScalar(u8, content.items, terminator);
    while (it.next()) |line| {
        // The final segment after a trailing terminator is empty — skip it, but
        // a genuine last line lacking a terminator is still processed here
        // (this is the "no trailing newline" fix).
        if (line.len == 0) continue;
        line_no += 1;

        var parsed = (try parseCheckLine(allocator, line)) orelse {
            improperly_formatted += 1;
            if (config.warn) {
                writeStderr("zsha1sum: ");
                writeStderr(checksum_file);
                writeStderr(": ");
                writeCount(line_no);
                writeStderr(": improperly formatted SHA1 checksum line\n");
            }
            continue;
        };
        defer parsed.deinit(allocator);
        properly_formatted += 1;

        const computed = hashFile(allocator, parsed.open_name, false) catch |e| {
            if (config.ignore_missing and e == error.OpenError) {
                // Not counted against verification under --ignore-missing.
                properly_formatted -= 1;
                continue;
            }
            if (!config.status_only) {
                writeStdout(parsed.display);
                writeStdout(": FAILED open or read\n");
            }
            read_failed += 1;
            all_ok = false;
            continue;
        };

        // Case-insensitive digest compare (GNU accepts upper/lower hex).
        var matches = true;
        for (computed, parsed.hash) |a, b| {
            const lb = std.ascii.toLower(b);
            if (a != lb) {
                matches = false;
                break;
            }
        }

        if (matches) {
            if (!config.quiet and !config.status_only) {
                writeStdout(parsed.display);
                writeStdout(": OK\n");
            }
        } else {
            if (!config.status_only) {
                writeStdout(parsed.display);
                writeStdout(": FAILED\n");
            }
            mismatch += 1;
            all_ok = false;
        }
    }

    if (properly_formatted == 0) {
        reportMsg(checksum_file, "no properly formatted checksum lines found");
        return error.NoValidLines;
    }

    if (!config.status_only) {
        if (config.warn and improperly_formatted > 0) {
            writeStderr("zsha1sum: WARNING: ");
            writeCount(improperly_formatted);
            writeStderr(if (improperly_formatted == 1) " line is improperly formatted\n" else " lines are improperly formatted\n");
        }
        if (read_failed > 0) {
            writeStderr("zsha1sum: WARNING: ");
            writeCount(read_failed);
            writeStderr(if (read_failed == 1) " listed file could not be read\n" else " listed files could not be read\n");
        }
        if (mismatch > 0) {
            writeStderr("zsha1sum: WARNING: ");
            writeCount(mismatch);
            writeStderr(if (mismatch == 1) " computed checksum did NOT match\n" else " computed checksums did NOT match\n");
        }
    }

    if (config.strict and improperly_formatted > 0) all_ok = false;
    return all_ok;
}

fn invalidShortOption(ch: u8) noreturn {
    writeStderr("zsha1sum: invalid option -- '");
    writeStderr(&[1]u8{ch});
    writeStderr("'\nTry 'zsha1sum --help' for more information.\n");
    std.process.exit(1);
}

fn unrecognizedLongOption(arg: []const u8) noreturn {
    writeStderr("zsha1sum: unrecognized option '");
    writeStderr(arg);
    writeStderr("'\nTry 'zsha1sum --help' for more information.\n");
    std.process.exit(1);
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| try args_list.append(allocator, arg);
    const args = args_list.items;

    var config = Config{};
    var no_more_opts = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!no_more_opts and std.mem.eql(u8, arg, "--")) {
            no_more_opts = true;
        } else if (!no_more_opts and arg.len > 1 and arg[0] == '-' and arg[1] == '-') {
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
                unrecognizedLongOption(arg);
            }
        } else if (!no_more_opts and arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |ch| {
                switch (ch) {
                    'c' => config.check_mode = true,
                    'b' => config.binary_mode = true,
                    't' => config.binary_mode = false,
                    'q' => config.quiet = true,
                    'w' => config.warn = true,
                    'z' => config.zero = true,
                    else => invalidShortOption(ch),
                }
            }
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.bsd_tag and config.check_mode) {
        writeStderr("zsha1sum: the --tag option is meaningless when verifying checksums\nTry 'zsha1sum --help' for more information.\n");
        std.process.exit(1);
    }

    if (config.files.items.len == 0) try config.files.append(allocator, try allocator.dupe(u8, "-"));
    return config;
}

fn printHelp() void {
    writeStdout(
        \\Usage: zsha1sum [OPTION]... [FILE]...
        \\Print or check SHA1 checksums.
        \\
        \\WARNING: SHA-1 is cryptographically broken. Use SHA-256 for security.
        \\
        \\  -b, --binary          read in binary mode (default)
        \\  -c, --check           read checksums from FILEs and check them
        \\  -t, --text            read in text mode
        \\      --tag             create BSD-style checksums
        \\  -z, --zero            end each output line with NUL, not newline
        \\
        \\The following five options are useful only when verifying checksums:
        \\      --ignore-missing  don't fail or report status for missing files
        \\      --quiet           don't print OK for each verified file
        \\      --status          don't output anything, status code shows success
        \\      --strict          exit non-zero for improperly formatted lines
        \\  -w, --warn            warn about improperly formatted checksum lines
        \\
        \\      --help            display this help and exit
        \\      --version         output version information and exit
        \\
    );
}

fn printVersion() void {
    writeStdout("zsha1sum 0.1.0\n");
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
