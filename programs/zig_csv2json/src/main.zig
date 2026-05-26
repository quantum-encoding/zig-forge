// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! zig-json: Text-to-JSON structured formatter
//!
//! Reads unstructured text from file or stdin and outputs structured JSON.
//! Auto-detects format: CSV/TSV → array of objects, key-value → object,
//! plain lines → array of strings.

const std = @import("std");
const parser = @import("parser.zig");
const JsonWriter = @import("json_writer.zig").JsonWriter;

extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*std.c.FILE;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse command line args
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    const opts = parseArgs(args_list.items) orelse return;

    // Read input
    const input_data = if (opts.file_path) |path|
        readFile(allocator, path)
    else
        readStdin(allocator);

    if (input_data == null) {
        std.debug.print("Error: Failed to read input\n", .{});
        return;
    }
    const data = input_data.?;
    defer allocator.free(data);

    if (data.len == 0) {
        std.debug.print("Error: Empty input\n", .{});
        return;
    }

    // Split into lines
    const lines = parser.splitIntoLines(allocator, data) catch {
        std.debug.print("Error: Failed to parse input\n", .{});
        return;
    };
    defer allocator.free(lines);

    if (lines.len == 0) {
        std.debug.print("Error: No non-empty lines in input\n", .{});
        return;
    }

    // Detect or use forced format
    const format = opts.format orelse parser.detect(lines);

    // Get output destination
    const out_file: ?*std.c.FILE = if (opts.output_path) |path| blk: {
        const path_z = allocator.allocSentinel(u8, path.len, 0) catch return;
        defer allocator.free(path_z);
        @memcpy(path_z, path);
        break :blk std.c.fopen(path_z.ptr, "wb");
    } else null;
    defer if (out_file) |f| {
        _ = std.c.fclose(f);
    };

    const output: *std.c.FILE = out_file orelse (fdopen(1, "wb") orelse {
        std.debug.print("Error: cannot open stdout\n", .{});
        return;
    });

    var writer = JsonWriter.init(output, opts.pretty);

    // Show detected format on stderr if auto-detected
    if (opts.format == null) {
        std.debug.print("[auto-detected: {s}]\n", .{format.name()});
    }

    // Parse and output
    switch (format) {
        .lines => {
            const items = parser.parseLines(allocator, lines) catch {
                std.debug.print("Error: Failed to parse lines\n", .{});
                return;
            };
            defer allocator.free(items);

            writer.beginArray();
            for (items) |item| {
                if (opts.numbers and parser.isNumeric(item)) {
                    writer.number(item);
                } else {
                    writer.string(item);
                }
            }
            writer.endArray();
        },
        .csv, .tsv => {
            const delimiter: u8 = if (format == .tsv) '\t' else ',';
            const table = parser.parseCsv(allocator, lines, delimiter, !opts.no_headers) catch {
                std.debug.print("Error: Failed to parse CSV/TSV\n", .{});
                return;
            };
            defer {
                if (opts.no_headers) {
                    for (table.headers) |h| allocator.free(h);
                }
                // Free each row's field array (allocated by splitCsvLine)
                for (table.rows) |row| allocator.free(row);
                if (table._backing) |backing| {
                    // headers fields array is owned[0], also from splitCsvLine
                    allocator.free(table.headers);
                    // Free the outer backing array
                    allocator.free(backing);
                } else {
                    allocator.free(table.headers);
                    allocator.free(table.rows);
                }
            }

            writer.beginArray();
            for (table.rows) |row| {
                writer.beginObject();
                for (row, 0..) |value, col| {
                    const col_name = if (col < table.headers.len)
                        table.headers[col]
                    else
                        "?";
                    writer.key(col_name);
                    if (opts.numbers and parser.isNumeric(value)) {
                        writer.number(value);
                    } else {
                        writer.string(value);
                    }
                }
                writer.endObject();
            }
            writer.endArray();
        },
        .kv => {
            const kv = parser.parseKv(allocator, lines) catch {
                std.debug.print("Error: Failed to parse key-value pairs\n", .{});
                return;
            };
            defer {
                allocator.free(kv.keys);
                allocator.free(kv.values);
            }

            writer.beginObject();
            for (kv.keys, kv.values) |k, v| {
                writer.key(k);
                if (opts.numbers and parser.isNumeric(v)) {
                    writer.number(v);
                } else {
                    writer.string(v);
                }
            }
            writer.endObject();
        },
    }

    writer.newline();
}

const Opts = struct {
    file_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    format: ?parser.Format = null,
    pretty: bool = false,
    no_headers: bool = false,
    numbers: bool = false,
};

fn parseArgs(args: []const []const u8) ?Opts {
    var result = Opts{};

    var i: usize = 1; // skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return null;
        } else if (std.mem.eql(u8, arg, "--pretty") or std.mem.eql(u8, arg, "-p")) {
            result.pretty = true;
        } else if (std.mem.eql(u8, arg, "--numbers") or std.mem.eql(u8, arg, "-n")) {
            result.numbers = true;
        } else if (std.mem.eql(u8, arg, "--no-headers")) {
            result.no_headers = true;
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --format requires a value (csv/tsv/kv/lines)\n", .{});
                return null;
            }
            result.format = parser.parseFormat(args[i]) orelse {
                std.debug.print("Error: Unknown format '{s}'. Use: csv, tsv, kv, lines\n", .{args[i]});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: -o requires a file path\n", .{});
                return null;
            }
            result.output_path = args[i];
        } else if (std.mem.eql(u8, arg, "-")) {
            // Explicit stdin
            result.file_path = null;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            result.file_path = arg;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return null;
        }
    }

    return result;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const path_z = allocator.allocSentinel(u8, path.len, 0) catch return null;
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    const file = std.c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    _ = fseek(file, 0, 2); // SEEK_END
    const size_long = ftell(file);
    if (size_long <= 0) return null;
    const size: usize = @intCast(size_long);
    _ = fseek(file, 0, 0); // SEEK_SET

    const buf = allocator.alloc(u8, size) catch return null;
    const read = std.c.fread(buf.ptr, 1, size, file);
    if (read != size) {
        allocator.free(buf);
        return null;
    }
    return buf;
}

fn readStdin(allocator: std.mem.Allocator) ?[]u8 {
    const stdin_file = fdopen(0, "rb") orelse return null;

    // Read in chunks
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, stdin_file);
        if (n == 0) break;
        buf.appendSlice(allocator, chunk[0..n]) catch return null;
    }

    if (buf.items.len == 0) return null;
    return buf.toOwnedSlice(allocator) catch null;
}

fn printHelp() void {
    const help =
        \\zig-json - Text to JSON structured formatter
        \\
        \\Usage:
        \\  zig-json [file] [options]
        \\  cat data.txt | zig-json [options]
        \\
        \\Options:
        \\  -f, --format <fmt>    Force format: csv, tsv, kv, lines
        \\  -o, --output <path>   Write JSON to file (default: stdout)
        \\  -p, --pretty          Pretty-print JSON output
        \\  -n, --numbers         Detect numeric values (output as JSON numbers)
        \\  --no-headers          CSV/TSV: treat first row as data, not headers
        \\  -h, --help            Show this help
        \\
        \\Auto-detection priority:
        \\  1. CSV  - lines with consistent comma count
        \\  2. TSV  - lines with consistent tab count
        \\  3. KV   - lines matching "key: value" or "key = value"
        \\  4. Lines - each line becomes a string in a JSON array
        \\
        \\Examples:
        \\  zig-json names.txt                       # Auto-detect
        \\  zig-json data.csv --pretty --numbers     # CSV with numbers
        \\  echo -e "name: Alice\nage: 30" | zig-json
        \\  cat items.txt | zig-json -f lines -p
        \\
    ;
    std.debug.print("{s}", .{help});
}
