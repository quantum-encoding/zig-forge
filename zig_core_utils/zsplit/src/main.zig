//! zsplit - Split a file into pieces
//!
//! A Zig implementation of split.
//! Output pieces of FILE to PREFIXaa, PREFIXab, ...
//!
//! Usage: zsplit [OPTIONS] [FILE [PREFIX]]

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;

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

fn writeFd(fd: c_int, data: []const u8) bool {
    var written: usize = 0;
    while (written < data.len) {
        const result = write(fd, data.ptr + written, data.len - written);
        if (result <= 0) return false;
        written += @intCast(result);
    }
    return true;
}

const SplitMode = enum {
    lines,
    bytes,
    chunks,
    line_bytes,
};

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
    var mode: SplitMode = .lines;
    var lines_per_file: usize = 1000;
    var bytes_per_file: usize = 0;
    var num_chunks: usize = 0;
    var line_bytes_per_file: usize = 0;
    var numeric_suffixes = false;
    var suffix_length: usize = 2;
    var additional_suffix: []const u8 = "";
    var elide_empty = false;
    var verbose = false;
    var input_file: []const u8 = "-";
    var prefix: []const u8 = "x";

    var i: usize = 1;
    var positional_count: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zsplit {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--lines")) {
            mode = .lines;
            i += 1;
            if (i >= args.len) {
                writeStderr("zsplit: option requires an argument -- 'l'\n", .{});
                std.process.exit(1);
            }
            lines_per_file = std.fmt.parseInt(usize, args[i], 10) catch {
                writeStderr("zsplit: invalid number of lines: '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--lines=")) {
            mode = .lines;
            const val = arg[8..];
            lines_per_file = std.fmt.parseInt(usize, val, 10) catch {
                writeStderr("zsplit: invalid number of lines: '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bytes")) {
            mode = .bytes;
            i += 1;
            if (i >= args.len) {
                writeStderr("zsplit: option requires an argument -- 'b'\n", .{});
                std.process.exit(1);
            }
            bytes_per_file = parseSize(args[i]) orelse {
                writeStderr("zsplit: invalid number of bytes: '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
            mode = .bytes;
            const val = arg[8..];
            bytes_per_file = parseSize(val) orelse {
                writeStderr("zsplit: invalid number of bytes: '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--line-bytes")) {
            mode = .line_bytes;
            i += 1;
            if (i >= args.len) {
                writeStderr("zsplit: option requires an argument -- 'C'\n", .{});
                std.process.exit(1);
            }
            line_bytes_per_file = parseSize(args[i]) orelse {
                writeStderr("zsplit: invalid number of bytes: '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--line-bytes=")) {
            mode = .line_bytes;
            const val = arg["--line-bytes=".len..];
            line_bytes_per_file = parseSize(val) orelse {
                writeStderr("zsplit: invalid number of bytes: '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--elide-empty-files")) {
            elide_empty = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--number")) {
            mode = .chunks;
            i += 1;
            if (i >= args.len) {
                writeStderr("zsplit: option requires an argument -- 'n'\n", .{});
                std.process.exit(1);
            }
            num_chunks = std.fmt.parseInt(usize, args[i], 10) catch {
                writeStderr("zsplit: invalid number of chunks: '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--number=")) {
            mode = .chunks;
            const val = arg[9..];
            num_chunks = std.fmt.parseInt(usize, val, 10) catch {
                writeStderr("zsplit: invalid number of chunks: '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--numeric-suffixes")) {
            numeric_suffixes = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--suffix-length")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zsplit: option requires an argument -- 'a'\n", .{});
                std.process.exit(1);
            }
            suffix_length = std.fmt.parseInt(usize, args[i], 10) catch {
                writeStderr("zsplit: invalid suffix length: '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--suffix-length=")) {
            const val = arg[16..];
            suffix_length = std.fmt.parseInt(usize, val, 10) catch {
                writeStderr("zsplit: invalid suffix length: '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--additional-suffix=")) {
            additional_suffix = arg["--additional-suffix=".len..];
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Combined short options or -lN, -bN
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const ch = arg[j];
                switch (ch) {
                    'd' => numeric_suffixes = true,
                    'e' => elide_empty = true,
                    'C' => {
                        mode = .line_bytes;
                        if (j + 1 < arg.len) {
                            const val = arg[j + 1 ..];
                            line_bytes_per_file = parseSize(val) orelse {
                                writeStderr("zsplit: invalid number of bytes: '{s}'\n", .{val});
                                std.process.exit(1);
                            };
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("zsplit: option requires an argument -- 'C'\n", .{});
                                std.process.exit(1);
                            }
                            line_bytes_per_file = parseSize(args[i]) orelse {
                                writeStderr("zsplit: invalid number of bytes: '{s}'\n", .{args[i]});
                                std.process.exit(1);
                            };
                            break;
                        }
                    },
                    'l' => {
                        mode = .lines;
                        if (j + 1 < arg.len) {
                            const val = arg[j + 1 ..];
                            lines_per_file = std.fmt.parseInt(usize, val, 10) catch {
                                writeStderr("zsplit: invalid number of lines: '{s}'\n", .{val});
                                std.process.exit(1);
                            };
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("zsplit: option requires an argument -- 'l'\n", .{});
                                std.process.exit(1);
                            }
                            lines_per_file = std.fmt.parseInt(usize, args[i], 10) catch {
                                writeStderr("zsplit: invalid number of lines: '{s}'\n", .{args[i]});
                                std.process.exit(1);
                            };
                            break;
                        }
                    },
                    'b' => {
                        mode = .bytes;
                        if (j + 1 < arg.len) {
                            const val = arg[j + 1 ..];
                            bytes_per_file = parseSize(val) orelse {
                                writeStderr("zsplit: invalid number of bytes: '{s}'\n", .{val});
                                std.process.exit(1);
                            };
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("zsplit: option requires an argument -- 'b'\n", .{});
                                std.process.exit(1);
                            }
                            bytes_per_file = parseSize(args[i]) orelse {
                                writeStderr("zsplit: invalid number of bytes: '{s}'\n", .{args[i]});
                                std.process.exit(1);
                            };
                            break;
                        }
                    },
                    'n' => {
                        mode = .chunks;
                        if (j + 1 < arg.len) {
                            const val = arg[j + 1 ..];
                            num_chunks = std.fmt.parseInt(usize, val, 10) catch {
                                writeStderr("zsplit: invalid number of chunks: '{s}'\n", .{val});
                                std.process.exit(1);
                            };
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("zsplit: option requires an argument -- 'n'\n", .{});
                                std.process.exit(1);
                            }
                            num_chunks = std.fmt.parseInt(usize, args[i], 10) catch {
                                writeStderr("zsplit: invalid number of chunks: '{s}'\n", .{args[i]});
                                std.process.exit(1);
                            };
                            break;
                        }
                    },
                    'a' => {
                        if (j + 1 < arg.len) {
                            const val = arg[j + 1 ..];
                            suffix_length = std.fmt.parseInt(usize, val, 10) catch {
                                writeStderr("zsplit: invalid suffix length: '{s}'\n", .{val});
                                std.process.exit(1);
                            };
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("zsplit: option requires an argument -- 'a'\n", .{});
                                std.process.exit(1);
                            }
                            suffix_length = std.fmt.parseInt(usize, args[i], 10) catch {
                                writeStderr("zsplit: invalid suffix length: '{s}'\n", .{args[i]});
                                std.process.exit(1);
                            };
                            break;
                        }
                    },
                    else => {
                        writeStderr("zsplit: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(1);
                    },
                }
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                if (positional_count == 0) {
                    input_file = args[i];
                } else if (positional_count == 1) {
                    prefix = args[i];
                }
                positional_count += 1;
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            if (positional_count == 0) {
                input_file = arg;
            } else if (positional_count == 1) {
                prefix = arg;
            }
            positional_count += 1;
        } else if (std.mem.eql(u8, arg, "-")) {
            input_file = "-";
            positional_count += 1;
        } else {
            writeStderr("zsplit: unrecognized option '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    // Validate
    if (mode == .chunks and num_chunks == 0) {
        writeStderr("zsplit: number of chunks must be positive\n", .{});
        std.process.exit(1);
    }

    // Open input file
    var in_fd: c_int = 0; // stdin
    var file_size: ?usize = null;

    if (!std.mem.eql(u8, input_file, "-")) {
        var path_z: [4097]u8 = undefined;
        if (input_file.len >= path_z.len) {
            writeStderr("zsplit: path too long\n", .{});
            std.process.exit(1);
        }
        @memcpy(path_z[0..input_file.len], input_file);
        path_z[input_file.len] = 0;

        in_fd = open(@ptrCast(&path_z), O_RDONLY, 0);
        if (in_fd < 0) {
            writeStderr("zsplit: cannot open '{s}' for reading\n", .{input_file});
            std.process.exit(1);
        }

        // Get file size for chunk mode
        if (mode == .chunks) {
            file_size = getFileSize(in_fd);
        }
    }
    defer {
        if (in_fd != 0) _ = close(in_fd);
    }

    // Calculate bytes per file for chunk mode
    if (mode == .chunks) {
        if (file_size) |size| {
            bytes_per_file = (size + num_chunks - 1) / num_chunks;
            mode = .bytes;
        } else {
            writeStderr("zsplit: cannot determine input size for chunk mode from stdin\n", .{});
            std.process.exit(1);
        }
    }

    // Split the file
    switch (mode) {
        .lines => splitByLines(allocator, in_fd, prefix, lines_per_file, suffix_length, numeric_suffixes, additional_suffix, verbose),
        .bytes => splitByBytes(in_fd, prefix, bytes_per_file, suffix_length, numeric_suffixes, additional_suffix, verbose),
        .line_bytes => splitByLineBytes(allocator, in_fd, prefix, line_bytes_per_file, suffix_length, numeric_suffixes, additional_suffix, elide_empty, verbose),
        .chunks => unreachable,
    }
}

fn parseSize(s: []const u8) ?usize {
    if (s.len == 0) return null;

    var multiplier: usize = 1;
    var num_end = s.len;

    const last = s[s.len - 1];
    if (last == 'K' or last == 'k') {
        multiplier = 1024;
        num_end -= 1;
    } else if (last == 'M' or last == 'm') {
        multiplier = 1024 * 1024;
        num_end -= 1;
    } else if (last == 'G' or last == 'g') {
        multiplier = 1024 * 1024 * 1024;
        num_end -= 1;
    }

    const num = std.fmt.parseInt(usize, s[0..num_end], 10) catch return null;
    return num * multiplier;
}

fn getFileSize(fd: c_int) ?usize {
    const stat_t = extern struct {
        st_dev: u64,
        st_ino: u64,
        st_nlink: u64,
        st_mode: u32,
        st_uid: u32,
        st_gid: u32,
        __pad0: u32,
        st_rdev: u64,
        st_size: i64,
        st_blksize: i64,
        st_blocks: i64,
        st_atime: i64,
        st_atime_nsec: i64,
        st_mtime: i64,
        st_mtime_nsec: i64,
        st_ctime: i64,
        st_ctime_nsec: i64,
        __unused: [3]i64,
    };

    const fstat = @extern(*const fn (c_int, *stat_t) callconv(.c) c_int, .{ .name = "fstat" });

    var st: stat_t = undefined;
    if (fstat(fd, &st) == 0) {
        return if (st.st_size >= 0) @intCast(st.st_size) else null;
    }
    return null;
}

fn generateSuffix(buf: []u8, index: usize, length: usize, numeric: bool) []const u8 {
    if (numeric) {
        // Numeric suffix: 00, 01, 02, ...
        var num = index;
        var pos = length;
        while (pos > 0) {
            pos -= 1;
            buf[pos] = '0' + @as(u8, @intCast(num % 10));
            num /= 10;
        }
    } else {
        // Alphabetic suffix: aa, ab, ..., az, ba, ...
        var num = index;
        var pos = length;
        while (pos > 0) {
            pos -= 1;
            buf[pos] = 'a' + @as(u8, @intCast(num % 26));
            num /= 26;
        }
    }
    return buf[0..length];
}

fn openOutputFile(prefix: []const u8, suffix: []const u8, additional_suffix: []const u8) c_int {
    var path_buf: [4097]u8 = undefined;
    const total_len = prefix.len + suffix.len + additional_suffix.len;
    if (total_len >= path_buf.len) return -1;

    @memcpy(path_buf[0..prefix.len], prefix);
    @memcpy(path_buf[prefix.len .. prefix.len + suffix.len], suffix);
    @memcpy(path_buf[prefix.len + suffix.len .. total_len], additional_suffix);
    path_buf[total_len] = 0;

    return open(@ptrCast(&path_buf), O_WRONLY | O_CREAT | O_TRUNC, 0o644);
}

fn splitByLines(allocator: std.mem.Allocator, in_fd: c_int, prefix: []const u8, lines_per_file: usize, suffix_length: usize, numeric: bool, additional_suffix: []const u8, verbose: bool) void {
    var buf: [65536]u8 = undefined;
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    var file_index: usize = 0;
    var lines_in_current: usize = 0;
    var out_fd: c_int = -1;
    var suffix_buf: [16]u8 = undefined;

    while (true) {
        const n = c_read(in_fd, &buf, buf.len);
        if (n <= 0) break;

        const data = buf[0..@intCast(n)];
        for (data) |byte| {
            line_buf.append(allocator, byte) catch continue;

            if (byte == '\n') {
                // Open new file if needed
                if (out_fd < 0) {
                    const suffix = generateSuffix(&suffix_buf, file_index, suffix_length, numeric);
                    out_fd = openOutputFile(prefix, suffix, additional_suffix);
                    if (out_fd < 0) {
                        writeStderr("zsplit: cannot create output file\n", .{});
                        return;
                    }
                    if (verbose) {
                        writeStdout("creating file '{s}{s}{s}'\n", .{ prefix, suffix, additional_suffix });
                    }
                }

                // Write line
                _ = writeFd(out_fd, line_buf.items);
                line_buf.clearRetainingCapacity();
                lines_in_current += 1;

                // Check if we need a new file
                if (lines_in_current >= lines_per_file) {
                    _ = close(out_fd);
                    out_fd = -1;
                    file_index += 1;
                    lines_in_current = 0;
                }
            }
        }
    }

    // Write remaining data
    if (line_buf.items.len > 0) {
        if (out_fd < 0) {
            const suffix = generateSuffix(&suffix_buf, file_index, suffix_length, numeric);
            out_fd = openOutputFile(prefix, suffix, additional_suffix);
            if (verbose and out_fd >= 0) {
                writeStdout("creating file '{s}{s}{s}'\n", .{ prefix, suffix, additional_suffix });
            }
        }
        if (out_fd >= 0) {
            _ = writeFd(out_fd, line_buf.items);
        }
    }

    if (out_fd >= 0) {
        _ = close(out_fd);
    }
}

fn splitByBytes(in_fd: c_int, prefix: []const u8, bytes_per_file: usize, suffix_length: usize, numeric: bool, additional_suffix: []const u8, verbose: bool) void {
    var buf: [65536]u8 = undefined;
    var file_index: usize = 0;
    var bytes_in_current: usize = 0;
    var out_fd: c_int = -1;
    var suffix_buf: [16]u8 = undefined;

    while (true) {
        const n = c_read(in_fd, &buf, buf.len);
        if (n <= 0) break;

        const data = buf[0..@intCast(n)];
        var offset: usize = 0;

        while (offset < data.len) {
            // Open new file if needed
            if (out_fd < 0) {
                const suffix = generateSuffix(&suffix_buf, file_index, suffix_length, numeric);
                out_fd = openOutputFile(prefix, suffix, additional_suffix);
                if (out_fd < 0) {
                    writeStderr("zsplit: cannot create output file\n", .{});
                    return;
                }
                if (verbose) {
                    writeStdout("creating file '{s}{s}{s}'\n", .{ prefix, suffix, additional_suffix });
                }
                bytes_in_current = 0;
            }

            // Calculate how much to write
            const remaining_in_file = bytes_per_file - bytes_in_current;
            const remaining_in_buf = data.len - offset;
            const to_write = @min(remaining_in_file, remaining_in_buf);

            // Write chunk
            _ = writeFd(out_fd, data[offset .. offset + to_write]);
            offset += to_write;
            bytes_in_current += to_write;

            // Check if we need a new file
            if (bytes_in_current >= bytes_per_file) {
                _ = close(out_fd);
                out_fd = -1;
                file_index += 1;
            }
        }
    }

    if (out_fd >= 0) {
        _ = close(out_fd);
    }
}

fn writeLineByteChunk(data: []const u8, out_fd_ptr: *c_int, bytes_in_current_ptr: *usize, file_index_ptr: *usize, max_bytes: usize, prefix: []const u8, suffix_length: usize, numeric: bool, additional_suffix: []const u8, verbose: bool) void {
    var suffix_buf: [16]u8 = undefined;
    var remaining = data;

    while (remaining.len > 0) {
        // Open new file if needed
        if (out_fd_ptr.* < 0) {
            const suffix = generateSuffix(&suffix_buf, file_index_ptr.*, suffix_length, numeric);
            out_fd_ptr.* = openOutputFile(prefix, suffix, additional_suffix);
            if (out_fd_ptr.* < 0) {
                writeStderr("zsplit: cannot create output file\n", .{});
                return;
            }
            if (verbose) {
                writeStdout("creating file '{s}{s}{s}'\n", .{ prefix, suffix, additional_suffix });
            }
            bytes_in_current_ptr.* = 0;
        }

        const space_left = max_bytes - bytes_in_current_ptr.*;
        const to_write = @min(remaining.len, space_left);

        _ = writeFd(out_fd_ptr.*, remaining[0..to_write]);
        bytes_in_current_ptr.* += to_write;
        remaining = remaining[to_write..];

        if (bytes_in_current_ptr.* >= max_bytes) {
            _ = close(out_fd_ptr.*);
            out_fd_ptr.* = -1;
            file_index_ptr.* += 1;
            bytes_in_current_ptr.* = 0;
        }
    }
}

fn splitByLineBytes(allocator: std.mem.Allocator, in_fd: c_int, prefix: []const u8, max_bytes: usize, suffix_length: usize, numeric: bool, additional_suffix: []const u8, elide_empty: bool, verbose: bool) void {
    _ = elide_empty; // line_bytes mode never produces empty files naturally
    var buf: [65536]u8 = undefined;
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    var file_index: usize = 0;
    var bytes_in_current: usize = 0;
    var out_fd: c_int = -1;
    var suffix_buf: [16]u8 = undefined;

    while (true) {
        const n = c_read(in_fd, &buf, buf.len);
        if (n <= 0) break;

        const data = buf[0..@intCast(n)];
        for (data) |byte| {
            line_buf.append(allocator, byte) catch continue;

            if (byte == '\n') {
                const line_data = line_buf.items;
                const line_len = line_data.len;

                if (line_len <= max_bytes) {
                    // Line fits within max_bytes
                    // Check if adding this line would exceed the limit in current file
                    if (out_fd >= 0 and bytes_in_current > 0 and bytes_in_current + line_len > max_bytes) {
                        // Close current file, start new one
                        _ = close(out_fd);
                        out_fd = -1;
                        file_index += 1;
                        bytes_in_current = 0;
                    }

                    // Open new file if needed
                    if (out_fd < 0) {
                        const suffix = generateSuffix(&suffix_buf, file_index, suffix_length, numeric);
                        out_fd = openOutputFile(prefix, suffix, additional_suffix);
                        if (out_fd < 0) {
                            writeStderr("zsplit: cannot create output file\n", .{});
                            return;
                        }
                        if (verbose) {
                            writeStdout("creating file '{s}{s}{s}'\n", .{ prefix, suffix, additional_suffix });
                        }
                        bytes_in_current = 0;
                    }

                    // Write the line
                    _ = writeFd(out_fd, line_data);
                    bytes_in_current += line_len;

                    // If this fills the file exactly, close it
                    if (bytes_in_current >= max_bytes) {
                        _ = close(out_fd);
                        out_fd = -1;
                        file_index += 1;
                        bytes_in_current = 0;
                    }
                } else {
                    // Line exceeds max_bytes - close current file first, then split at byte boundaries
                    if (out_fd >= 0) {
                        _ = close(out_fd);
                        out_fd = -1;
                        file_index += 1;
                        bytes_in_current = 0;
                    }
                    writeLineByteChunk(line_data, &out_fd, &bytes_in_current, &file_index, max_bytes, prefix, suffix_length, numeric, additional_suffix, verbose);
                }

                line_buf.clearRetainingCapacity();
            }
        }
    }

    // Write remaining data (incomplete line)
    if (line_buf.items.len > 0) {
        const line_data = line_buf.items;
        const line_len = line_data.len;

        if (line_len <= max_bytes) {
            if (out_fd >= 0 and bytes_in_current > 0 and bytes_in_current + line_len > max_bytes) {
                _ = close(out_fd);
                out_fd = -1;
                file_index += 1;
                bytes_in_current = 0;
            }

            if (out_fd < 0) {
                const suffix = generateSuffix(&suffix_buf, file_index, suffix_length, numeric);
                out_fd = openOutputFile(prefix, suffix, additional_suffix);
                if (verbose and out_fd >= 0) {
                    writeStdout("creating file '{s}{s}{s}'\n", .{ prefix, suffix, additional_suffix });
                }
            }
            if (out_fd >= 0) {
                _ = writeFd(out_fd, line_data);
            }
        } else {
            writeLineByteChunk(line_data, &out_fd, &bytes_in_current, &file_index, max_bytes, prefix, suffix_length, numeric, additional_suffix, verbose);
        }
    }

    if (out_fd >= 0) {
        _ = close(out_fd);
    }
}

fn printHelp() void {
    writeStdout(
        \\Usage: zsplit [OPTION]... [FILE [PREFIX]]
        \\Output pieces of FILE to PREFIXaa, PREFIXab, ...
        \\Default size is 1000 lines, default PREFIX is 'x'.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Options:
        \\  -a, --suffix-length=N     use suffixes of length N (default 2)
        \\      --additional-suffix=S append S to output file names
        \\  -b, --bytes=SIZE          put SIZE bytes per output file
        \\  -C, --line-bytes=SIZE     put at most SIZE bytes of lines per output file
        \\  -d, --numeric-suffixes    use numeric suffixes instead of alphabetic
        \\  -e, --elide-empty-files   do not generate empty output files with '-n'
        \\  -l, --lines=NUMBER        put NUMBER lines per output file
        \\  -n, --number=CHUNKS       split into CHUNKS output files
        \\      --verbose             print a diagnostic for each output file
        \\      --help                display this help and exit
        \\      --version             output version information and exit
        \\
        \\SIZE may have a suffix: K (1024), M (1024^2), G (1024^3).
        \\
        \\Examples:
        \\  zsplit file.txt                           Split into 1000-line pieces
        \\  zsplit -l 100 file.txt                    Split into 100-line pieces
        \\  zsplit -b 1M file.bin                     Split into 1MB pieces
        \\  zsplit -n 5 file.txt                      Split into 5 equal pieces
        \\  zsplit -d file.txt part_                  Output: part_00, part_01, ...
        \\  zsplit --additional-suffix=.txt file.txt  Output: xaa.txt, xab.txt, ...
        \\
    , .{});
}
