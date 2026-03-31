// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! zig-xlsx: General-purpose XLSX to JSON converter

const std = @import("std");
const xlsx = @import("xlsx");

extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*FILE;
const FILE = std.c.FILE;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse command line args
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    const parsed = parseArgs(args_list.items) orelse return;

    // Open XLSX file
    var file = xlsx.XlsxFile.open(allocator, parsed.file_path) catch |err| {
        std.debug.print("Error opening '{s}': {}\n", .{ parsed.file_path, err });
        return;
    };
    defer file.close();

    // Get output destination
    const out_file: ?*FILE = if (parsed.output_path) |path| blk: {
        const path_z = allocator.allocSentinel(u8, path.len, 0) catch {
            std.debug.print("Error: out of memory\n", .{});
            return;
        };
        defer allocator.free(path_z);
        @memcpy(path_z, path);
        break :blk std.c.fopen(path_z.ptr, "wb");
    } else null;
    defer if (out_file) |f| {
        _ = std.c.fclose(f);
    };

    // stdout via fdopen(1)
    const output: *FILE = out_file orelse (fdopen(1, "wb") orelse {
        std.debug.print("Error: cannot open stdout\n", .{});
        return;
    });

    var writer = xlsx.JsonWriter.init(output, parsed.pretty);

    if (parsed.list_only) {
        // --list: output sheet names as JSON array
        writer.beginArray();
        var i: usize = 0;
        while (i < file.sheetCount()) : (i += 1) {
            if (file.getSheetNameByIndex(i)) |name| {
                writer.string(name);
            }
        }
        writer.endArray();
        writer.newline();
        return;
    }

    // Output sheets
    writer.beginObject();
    writer.key("sheets");
    writer.beginArray();

    var i: usize = 0;
    while (i < file.sheetCount()) : (i += 1) {
        const name = file.getSheetNameByIndex(i) orelse continue;

        // If -s specified, skip non-matching sheets
        if (parsed.sheet_name) |requested| {
            if (!std.mem.eql(u8, name, requested)) continue;
        }

        var sheet = file.readSheet(allocator, name) catch |err| {
            std.debug.print("Error reading sheet '{s}': {}\n", .{ name, err });
            continue;
        };
        defer sheet.deinit(allocator);

        writer.beginObject();
        writer.key("name");
        writer.string(name);
        writer.key("rows");
        writer.beginArray();

        if (parsed.headers and sheet.rows.len > 0) {
            // First row is headers, subsequent rows become objects
            const header_row = sheet.rows[0];
            for (sheet.rows[1..]) |row| {
                writer.beginObject();
                for (row, 0..) |cell, col_idx| {
                    // Use header value or fallback to column letter
                    const col_name = if (col_idx < header_row.len)
                        (header_row[col_idx] orelse "")
                    else
                        "";
                    if (col_name.len > 0) {
                        writer.key(col_name);
                    } else {
                        // Fallback: use column letter
                        var col_buf: [4]u8 = undefined;
                        const col_label = columnLabel(col_idx, &col_buf);
                        writer.key(col_label);
                    }
                    if (cell) |v| {
                        writer.string(v);
                    } else {
                        writer.writeNull();
                    }
                }
                writer.endObject();
            }
        } else {
            // Default: array of arrays
            for (sheet.rows) |row| {
                writer.beginArray();
                for (row) |cell| {
                    if (cell) |v| {
                        writer.string(v);
                    } else {
                        writer.writeNull();
                    }
                }
                writer.endArray();
            }
        }

        writer.endArray();
        writer.endObject();
    }

    writer.endArray();
    writer.endObject();
    writer.newline();
}

const Args = struct {
    file_path: []const u8,
    sheet_name: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    headers: bool = false,
    list_only: bool = false,
    pretty: bool = false,
};

fn parseArgs(args: []const []const u8) ?Args {
    var result = Args{ .file_path = "" };
    var got_file = false;

    var i: usize = 1; // skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return null;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            result.list_only = true;
        } else if (std.mem.eql(u8, arg, "--headers") or std.mem.eql(u8, arg, "-H")) {
            result.headers = true;
        } else if (std.mem.eql(u8, arg, "--pretty") or std.mem.eql(u8, arg, "-p")) {
            result.pretty = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sheet")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: -s requires a sheet name\n", .{});
                return null;
            }
            result.sheet_name = args[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: -o requires a file path\n", .{});
                return null;
            }
            result.output_path = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            result.file_path = arg;
            got_file = true;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return null;
        }
    }

    if (!got_file) {
        std.debug.print("Error: No input file specified\n\n", .{});
        printHelp();
        return null;
    }

    return result;
}

fn columnLabel(col: usize, buf: []u8) []const u8 {
    var c = col;
    var len: usize = 0;
    while (true) {
        buf[len] = @intCast('A' + @as(u8, @intCast(c % 26)));
        len += 1;
        if (c < 26) break;
        c = c / 26 - 1;
    }
    // Reverse
    var lo: usize = 0;
    var hi: usize = len - 1;
    while (lo < hi) {
        const tmp = buf[lo];
        buf[lo] = buf[hi];
        buf[hi] = tmp;
        lo += 1;
        hi -= 1;
    }
    return buf[0..len];
}

fn printHelp() void {
    const help =
        \\zig-xlsx - XLSX to JSON converter
        \\
        \\Usage:
        \\  zig-xlsx <file.xlsx> [options]
        \\
        \\Options:
        \\  -s, --sheet <name>    Output only the named sheet
        \\  -o, --output <path>   Write JSON to file (default: stdout)
        \\  -H, --headers         Use first row as object keys
        \\  -l, --list            List sheet names only
        \\  -p, --pretty          Pretty-print JSON output
        \\  -h, --help            Show this help
        \\
        \\Examples:
        \\  zig-xlsx data.xlsx
        \\  zig-xlsx data.xlsx --list
        \\  zig-xlsx data.xlsx -s "Sheet1" --headers --pretty
        \\  zig-xlsx data.xlsx -o output.json
        \\
    ;
    std.debug.print("{s}", .{help});
}
