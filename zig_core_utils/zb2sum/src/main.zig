//! zb2sum - High-performance BLAKE2b checksum utility
//!
//! Compatible with b2sum:
//! - FILE: compute BLAKE2b-512 hash of files
//! - -c, --check: verify checksums from file
//! - -l, --length=BITS: digest length in bits (8-512, multiple of 8)
//! - -b, --binary: read in binary mode (default on non-Unix)
//! - -t, --text: read in text mode
//! - --quiet: don't print OK for each verified file
//! - --status: don't output anything, exit code shows success
//! - --tag: create BSD-style checksums
//!
//! BLAKE2b is a secure, high-speed hash function (faster than MD5/SHA-1).
//! Uses Zig's SIMD-optimized BLAKE2 implementation.

const std = @import("std");
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const posix = std.posix;
const Io = std.Io;
const Dir = Io.Dir;

const BUFFER_SIZE = 64 * 1024;
const DEFAULT_DIGEST_LENGTH = Blake2b512.digest_length; // 64 bytes = 512 bits
const DEFAULT_HEX_LENGTH = DEFAULT_DIGEST_LENGTH * 2;

const Config = struct {
    check_mode: bool = false,
    binary_mode: bool = false,
    quiet: bool = false,
    status_only: bool = false,
    bsd_tag: bool = false,
    digest_bits: u16 = 512, // Default BLAKE2b-512
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }

    fn digestLength(self: *const Config) usize {
        return self.digest_bits / 8;
    }

    fn hexLength(self: *const Config) usize {
        return self.digestLength() * 2;
    }
};

fn hashFile(allocator: std.mem.Allocator, path: []const u8, is_stdin: bool, config: *const Config) ![]u8 {
    const io = Io.Threaded.global_single_threaded.io();
    // BLAKE2b parameterizes the output length in its IV/param block: BLAKE2b-256
    // is a genuinely different hash from a truncated BLAKE2b-512. expected_out_bits
    // makes the state match GNU b2sum for every length; final() emits the full
    // 64-byte state and we take the first digest_len bytes (the real BLAKE2b-N digest).
    var hash = Blake2b512.init(.{ .expected_out_bits = config.digest_bits });
    var buffer: [BUFFER_SIZE]u8 = undefined;

    if (is_stdin) {
        const stdin = Io.File.stdin();
        while (true) {
            const bytes_read = stdin.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    std.debug.print("zb2sum: stdin: {s}\n", .{@errorName(err)});
                    return error.ReadError;
                },
            };
            if (bytes_read == 0) break;
            hash.update(buffer[0..bytes_read]);
        }
    } else {
        const file = Dir.openFile(Dir.cwd(), io, path, .{}) catch |err| {
            std.debug.print("zb2sum: {s}: {s}\n", .{ path, @errorName(err) });
            return error.OpenError;
        };
        defer file.close(io);

        while (true) {
            const bytes_read = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    std.debug.print("zb2sum: {s}: {s}\n", .{ path, @errorName(err) });
                    return error.ReadError;
                },
            };
            if (bytes_read == 0) break;
            hash.update(buffer[0..bytes_read]);
        }
    }

    var full_digest: [DEFAULT_DIGEST_LENGTH]u8 = undefined;
    hash.final(&full_digest);
    const digest_len = config.digestLength();

    // Convert to hex (only the requested length)
    var hex = try allocator.alloc(u8, digest_len * 2);
    for (full_digest[0..digest_len], 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    return hex;
}

fn printHash(allocator: std.mem.Allocator, path: []const u8, hex: []const u8, config: *const Config) void {
    _ = allocator;
    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [384]u8 = undefined;
    var writer = stdout.writer(io_ctx, &buf);

    if (config.bsd_tag) {
        if (config.digest_bits != 512) {
            writer.interface.print("BLAKE2b-{d} ({s}) = {s}\n", .{ config.digest_bits, path, hex }) catch {};
        } else {
            writer.interface.print("BLAKE2b ({s}) = {s}\n", .{ path, hex }) catch {};
        }
    } else {
        const mode_char: u8 = if (config.binary_mode) '*' else ' ';
        writer.interface.print("{s} {c}{s}\n", .{ hex, mode_char, path }) catch {};
    }
    writer.interface.flush() catch {};
}

const ParsedLine = struct {
    hash: []const u8, // hex digest as written in the checksum file
    filename: []const u8,
    digest_bits: u16,
};

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Parse one checksum line into (hash, filename, digest_bits), inferring the
/// digest length from the hash's hex length so any BLAKE2b-N line verifies.
/// Handles both the standard `HASH  FILE` / `HASH *FILE` form and GNU's
/// `--tag` BSD form `BLAKE2b[-N] (FILE) = HASH`. Returns null for lines that
/// are not a properly formatted checksum line.
fn parseCheckLine(raw: []const u8) ?ParsedLine {
    // Strip a trailing CR so Windows-authored (CRLF) files verify.
    var line = raw;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    if (line.len == 0) return null;

    // BSD --tag form: "BLAKE2b (FILE) = HASH" or "BLAKE2b-256 (FILE) = HASH"
    if (std.mem.startsWith(u8, line, "BLAKE2b")) {
        const open = std.mem.indexOf(u8, line, " (") orelse return null;
        // Everything between " (" and ") = " is the filename.
        const sep = std.mem.indexOf(u8, line, ") = ") orelse return null;
        if (sep <= open + 2) return null;
        const filename = line[open + 2 .. sep];
        const hash = line[sep + 4 ..];
        if (filename.len == 0 or hash.len == 0) return null;
        for (hash) |c| if (!isHexDigit(c)) return null;
        const bits = hexBitsFromLen(hash.len) orelse return null;
        return .{ .hash = hash, .filename = filename, .digest_bits = bits };
    }

    // Standard form: leading run of hex, then a 2-char separator, then filename.
    var hlen: usize = 0;
    while (hlen < line.len and isHexDigit(line[hlen])) : (hlen += 1) {}
    if (hlen == 0) return null;
    const bits = hexBitsFromLen(hlen) orelse return null;
    // GNU emits "  " (text) or " *" (binary). Require a separator + a filename.
    if (line.len < hlen + 2) return null;
    if (line[hlen] != ' ') return null;
    if (line[hlen + 1] != ' ' and line[hlen + 1] != '*') return null;
    const filename = line[hlen + 2 ..];
    if (filename.len == 0) return null;
    return .{ .hash = line[0..hlen], .filename = filename, .digest_bits = bits };
}

/// Map a hex-string length to BLAKE2b digest bits, rejecting anything that is
/// not a valid BLAKE2b length (8..512 bits, multiple of 8).
fn hexBitsFromLen(hex_len: usize) ?u16 {
    if (hex_len == 0 or hex_len % 2 != 0) return null;
    const bytes = hex_len / 2;
    if (bytes < 1 or bytes > 64) return null;
    return @intCast(bytes * 8);
}

fn checkFile(allocator: std.mem.Allocator, checksum_file: []const u8, config: *const Config) !bool {
    const io_ctx = Io.Threaded.global_single_threaded.io();

    const file = Dir.openFile(Dir.cwd(), io_ctx, checksum_file, .{}) catch |err| {
        std.debug.print("zb2sum: {s}: {s}\n", .{ checksum_file, @errorName(err) });
        return error.OpenError;
    };
    defer file.close(io_ctx);

    var file_buffer: [8192]u8 = undefined;
    // Dynamically-grown line buffer so long paths are never silently truncated.
    var line_buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buffer.deinit(allocator);
    var all_ok = true;
    var failed: usize = 0;
    var valid_lines: usize = 0;

    const stdout_file = Io.File.stdout();
    var stdout_buf: [384]u8 = undefined;
    var stdout_writer = stdout_file.writer(io_ctx, &stdout_buf);

    const processLine = struct {
        fn run(
            alloc: std.mem.Allocator,
            cfg: *const Config,
            writer: *@TypeOf(stdout_writer),
            raw: []const u8,
            valid: *usize,
            failed_ptr: *usize,
            ok_ptr: *bool,
        ) void {
            const parsed = parseCheckLine(raw) orelse return;
            valid.* += 1;

            var line_cfg = cfg.*;
            line_cfg.digest_bits = parsed.digest_bits;

            const computed = hashFile(alloc, parsed.filename, false, &line_cfg) catch {
                if (!cfg.status_only) {
                    writer.interface.print("{s}: FAILED open or read\n", .{parsed.filename}) catch {};
                    writer.interface.flush() catch {};
                }
                failed_ptr.* += 1;
                ok_ptr.* = false;
                return;
            };
            defer alloc.free(computed);

            if (hexEqlIgnoreCase(computed, parsed.hash)) {
                if (!cfg.quiet and !cfg.status_only) {
                    writer.interface.print("{s}: OK\n", .{parsed.filename}) catch {};
                    writer.interface.flush() catch {};
                }
            } else {
                if (!cfg.status_only) {
                    writer.interface.print("{s}: FAILED\n", .{parsed.filename}) catch {};
                    writer.interface.flush() catch {};
                }
                failed_ptr.* += 1;
                ok_ptr.* = false;
            }
        }
    }.run;

    while (true) {
        const bytes_read = file.readStreaming(io_ctx, &.{&file_buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => break,
        };
        if (bytes_read == 0) break;

        for (file_buffer[0..bytes_read]) |byte| {
            if (byte == '\n') {
                processLine(allocator, config, &stdout_writer, line_buffer.items, &valid_lines, &failed, &all_ok);
                line_buffer.clearRetainingCapacity();
            } else {
                try line_buffer.append(allocator, byte);
            }
        }
    }

    // Process a final line that lacked a trailing newline (GNU processes it).
    if (line_buffer.items.len > 0) {
        processLine(allocator, config, &stdout_writer, line_buffer.items, &valid_lines, &failed, &all_ok);
    }

    if (valid_lines == 0) {
        std.debug.print("zb2sum: {s}: no properly formatted checksum lines found\n", .{checksum_file});
        return error.NoValidLines;
    }

    if (!config.status_only and failed > 0) {
        std.debug.print("zb2sum: WARNING: {d} computed checksum did NOT match\n", .{failed});
    }

    return all_ok;
}

fn parseNumber(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    // Accumulate in u32 with an overflow guard so oversized args (e.g. `-l 99999`)
    // return null -> "invalid length" instead of panicking on u16 overflow.
    var val: u32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        val = val * 10 + @as(u32, ch - '0');
        if (val > 0xFFFF) return null;
    }
    return @intCast(val);
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

        if (arg.len > 0 and arg[0] == '-') {
            if (arg.len > 1 and arg[1] == '-') {
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
                } else if (std.mem.startsWith(u8, arg, "--length=")) {
                    const bits = parseNumber(arg[9..]) orelse {
                        std.debug.print("zb2sum: invalid length '{s}'\n", .{arg[9..]});
                        std.process.exit(1);
                    };
                    if (bits < 8 or bits > 512 or bits % 8 != 0) {
                        std.debug.print("zb2sum: length must be 8-512 and multiple of 8\n", .{});
                        std.process.exit(1);
                    }
                    config.digest_bits = bits;
                } else if (std.mem.eql(u8, arg, "--length")) {
                    i += 1;
                    if (i >= args.len) {
                        std.debug.print("zb2sum: option '--length' requires an argument\n", .{});
                        std.process.exit(1);
                    }
                    const bits = parseNumber(args[i]) orelse {
                        std.debug.print("zb2sum: invalid length '{s}'\n", .{args[i]});
                        std.process.exit(1);
                    };
                    if (bits < 8 or bits > 512 or bits % 8 != 0) {
                        std.debug.print("zb2sum: length must be 8-512 and multiple of 8\n", .{});
                        std.process.exit(1);
                    }
                    config.digest_bits = bits;
                } else {
                    std.debug.print("zb2sum: unrecognized option '{s}'\n", .{arg});
                    std.process.exit(1);
                }
            } else {
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    switch (arg[j]) {
                        'c' => config.check_mode = true,
                        'b' => config.binary_mode = true,
                        't' => config.binary_mode = false,
                        'q' => config.quiet = true,
                        'l' => {
                            if (j + 1 < arg.len) {
                                const bits = parseNumber(arg[j + 1 ..]) orelse {
                                    std.debug.print("zb2sum: invalid length\n", .{});
                                    std.process.exit(1);
                                };
                                if (bits < 8 or bits > 512 or bits % 8 != 0) {
                                    std.debug.print("zb2sum: length must be 8-512 and multiple of 8\n", .{});
                                    std.process.exit(1);
                                }
                                config.digest_bits = bits;
                                break;
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    std.debug.print("zb2sum: option '-l' requires an argument\n", .{});
                                    std.process.exit(1);
                                }
                                const bits = parseNumber(args[i]) orelse {
                                    std.debug.print("zb2sum: invalid length '{s}'\n", .{args[i]});
                                    std.process.exit(1);
                                };
                                if (bits < 8 or bits > 512 or bits % 8 != 0) {
                                    std.debug.print("zb2sum: length must be 8-512 and multiple of 8\n", .{});
                                    std.process.exit(1);
                                }
                                config.digest_bits = bits;
                            }
                        },
                        else => {
                            std.debug.print("zb2sum: invalid option -- '{c}'\n", .{arg[j]});
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
    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [1536]u8 = undefined;
    var writer = stdout.writer(io_ctx, &buf);
    writer.interface.writeAll(
        \\Usage: zb2sum [OPTION]... [FILE]...
        \\Print or check BLAKE2b checksums.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -b, --binary       read in binary mode (default)
        \\  -c, --check        read checksums from FILEs and check them
        \\  -l, --length=BITS  digest length in bits (8-512, default 512)
        \\  -t, --text         read in text mode
        \\      --tag          create BSD-style checksums
        \\      --quiet        don't print OK for each verified file
        \\      --status       don't output anything, status code shows success
        \\      --help         display this help and exit
        \\      --version      output version information and exit
        \\
        \\BLAKE2b is faster than MD5/SHA-1/SHA-256 while being secure.
        \\
        \\zb2sum - High-performance BLAKE2b checksum utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [64]u8 = undefined;
    var writer = stdout.writer(io_ctx, &buf);
    writer.interface.writeAll("zb2sum 0.1.0\n") catch {};
    writer.interface.flush() catch {};
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
            const hex = hashFile(allocator, file, is_stdin, &config) catch {
                exit_code = 1;
                continue;
            };
            defer allocator.free(hex);
            printHash(allocator, if (is_stdin) "-" else file, hex, &config);
        }
    }

    std.process.exit(exit_code);
}
