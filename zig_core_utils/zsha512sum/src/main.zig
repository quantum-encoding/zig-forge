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
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.files.items) |item| allocator.free(item);
        self.files.deinit(allocator);
    }
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn hashFile(allocator: std.mem.Allocator, path: []const u8, is_stdin: bool) ![HEX_LENGTH]u8 {
    var hash = Sha512.init(.{});
    var buffer: [BUFFER_SIZE]u8 = undefined;

    if (is_stdin) {
        while (true) {
            const n = libc.read(libc.STDIN_FILENO, &buffer, buffer.len);
            if (n <= 0) break;
            hash.update(buffer[0..@intCast(n)]);
        }
    } else {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            writeStderr("zsha512sum: ");
            writeStderr(path);
            writeStderr(": No such file or directory\n");
            return error.OpenError;
        }
        defer _ = libc.close(fd);

        while (true) {
            const n = libc.read(fd, &buffer, buffer.len);
            if (n <= 0) break;
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
    if (config.bsd_tag) {
        writeStdout("SHA512 (");
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

    var file_buffer: [8192]u8 = undefined;
    var line_buffer: [1024]u8 = undefined;
    var line_len: usize = 0;
    var all_ok = true;
    var failed: usize = 0;

    outer: while (true) {
        const n = libc.read(fd, &file_buffer, file_buffer.len);
        if (n <= 0) break;
        const bytes_read: usize = @intCast(n);

        for (file_buffer[0..bytes_read]) |byte| {
            if (byte == '\n') {
                const line = line_buffer[0..line_len];
                line_len = 0;
                if (line.len < HEX_LENGTH + 2) continue;

                const hash_str = line[0..HEX_LENGTH];
                var filename_start: usize = HEX_LENGTH;
                if (line[HEX_LENGTH] == ' ' and line.len > HEX_LENGTH + 1) {
                    if (line[HEX_LENGTH + 1] == ' ' or line[HEX_LENGTH + 1] == '*') {
                        filename_start = HEX_LENGTH + 2;
                    }
                }

                const filename = line[filename_start..];
                if (filename.len == 0) continue;

                const computed = hashFile(allocator, filename, false) catch {
                    if (!config.status_only) {
                        writeStdout(filename);
                        writeStdout(": FAILED open or read\n");
                    }
                    failed += 1;
                    all_ok = false;
                    continue;
                };

                if (std.mem.eql(u8, &computed, hash_str)) {
                    if (!config.quiet and !config.status_only) {
                        writeStdout(filename);
                        writeStdout(": OK\n");
                    }
                } else {
                    if (!config.status_only) {
                        writeStdout(filename);
                        writeStdout(": FAILED\n");
                    }
                    failed += 1;
                    all_ok = false;
                }
            } else if (line_len < line_buffer.len) {
                line_buffer[line_len] = byte;
                line_len += 1;
            }
        }
        if (bytes_read < file_buffer.len) break :outer;
    }

    if (!config.status_only and failed > 0) {
        writeStderr("zsha512sum: WARNING: checksum mismatch\n");
    }
    return all_ok;
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
                else if (std.mem.eql(u8, arg, "--tag")) config.bsd_tag = true;
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'c' => config.check_mode = true,
                        'b' => config.binary_mode = true,
                        't' => config.binary_mode = false,
                        'q' => config.quiet = true,
                        else => {},
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
    writeStdout("zsha512sum 0.1.0\n");
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
