//! zjq - JSON query and manipulation tool
//!
//! A Zig implementation of jq-like functionality.
//! Parse, query, and transform JSON data.
//!
//! Usage: zjq [OPTIONS] [FILTER] [FILE...]
//!
//! Examples:
//!   zjq .                    # Pretty print JSON
//!   zjq .name                # Extract "name" field
//!   zjq '.users[0]'          # First element of users array
//!   zjq '.users[]'           # Iterate all users
//!   zjq -c .                 # Compact output
//!   zjq -r .name             # Raw string output

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn isatty(fd: c_int) c_int;

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStdoutRaw(msg);
}

// Buffered output for performance
var output_buffer: [65536]u8 = undefined;
var output_pos: usize = 0;

fn flushOutput() void {
    if (output_pos > 0) {
        var offset: usize = 0;
        while (offset < output_pos) {
            const written = write(1, output_buffer[offset..].ptr, output_pos - offset);
            if (written <= 0) break;
            offset += @intCast(written);
        }
        output_pos = 0;
    }
}

fn writeStdoutRaw(data: []const u8) void {
    for (data) |c| {
        if (output_pos >= output_buffer.len) {
            flushOutput();
        }
        output_buffer[output_pos] = c;
        output_pos += 1;
    }
}

// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const null_color = "\x1b[90m"; // gray
    const bool_color = "\x1b[33m"; // yellow
    const number_color = "\x1b[36m"; // cyan
    const string_color = "\x1b[32m"; // green
    const key_color = "\x1b[34m"; // blue (bold would be \x1b[1;34m)
    const bracket_color = "\x1b[37m"; // white
};

const Options = struct {
    compact: bool = false,
    raw_output: bool = false,
    raw_input: bool = false,
    slurp: bool = false,
    tab: bool = false,
    monochrome: bool = false,
    sort_keys: bool = false,
    null_input: bool = false,
    exit_status: bool = false,
    join_output: bool = false,
};

const OutputContext = struct {
    options: Options,
    use_color: bool,
    indent_str: []const u8,
    first_output: bool = true,

    fn init(options: Options) OutputContext {
        const is_tty = isatty(1) != 0;
        return .{
            .options = options,
            .use_color = is_tty and !options.monochrome,
            .indent_str = if (options.tab) "\t" else "  ",
        };
    }
};

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var options = Options{};
    var filter: []const u8 = ".";
    var filter_set = false;
    var files = std.ArrayListUnmanaged([]const u8).empty;
    defer files.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var parsing_options = true;
    while (args_iter.next()) |arg| {
        if (parsing_options and arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--")) {
                parsing_options = false;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printHelp();
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                writeStdout("zjq {s}\n", .{VERSION});
                return;
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--compact-output")) {
                options.compact = true;
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--raw-output")) {
                options.raw_output = true;
            } else if (std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "--raw-input")) {
                options.raw_input = true;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--slurp")) {
                options.slurp = true;
            } else if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--sort-keys")) {
                options.sort_keys = true;
            } else if (std.mem.eql(u8, arg, "-M") or std.mem.eql(u8, arg, "--monochrome-output")) {
                options.monochrome = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--null-input")) {
                options.null_input = true;
            } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exit-status")) {
                options.exit_status = true;
            } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--join-output")) {
                options.join_output = true;
            } else if (std.mem.eql(u8, arg, "--tab")) {
                options.tab = true;
            } else {
                // Check for combined short options
                var valid = true;
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'c' => options.compact = true,
                        'r' => options.raw_output = true,
                        'R' => options.raw_input = true,
                        's' => options.slurp = true,
                        'S' => options.sort_keys = true,
                        'M' => options.monochrome = true,
                        'n' => options.null_input = true,
                        'e' => options.exit_status = true,
                        'j' => options.join_output = true,
                        else => {
                            valid = false;
                            break;
                        },
                    }
                }
                if (!valid) {
                    writeStderr("zjq: unknown option: {s}\n", .{arg});
                    std.process.exit(2);
                }
            }
        } else {
            if (!filter_set) {
                filter = arg;
                filter_set = true;
            } else {
                files.append(allocator, arg) catch {
                    writeStderr("zjq: out of memory\n", .{});
                    std.process.exit(1);
                };
            }
        }
    }

    var ctx = OutputContext.init(options);

    if (options.null_input) {
        // Process filter with null input
        processJsonValue(allocator, .null, filter, &ctx);
        flushOutput();
        return;
    }

    if (files.items.len == 0) {
        // Read from stdin
        const input = readStdin(allocator) catch |err| {
            writeStderr("zjq: error reading stdin: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer allocator.free(input);

        if (options.slurp) {
            processSlurp(allocator, input, filter, &ctx);
        } else {
            processJsonStream(allocator, input, filter, &ctx);
        }
    } else {
        for (files.items) |file| {
            const content = readFile(allocator, file) catch |err| {
                writeStderr("zjq: error reading '{s}': {s}\n", .{ file, @errorName(err) });
                std.process.exit(1);
            };
            defer allocator.free(content);

            if (options.slurp) {
                processSlurp(allocator, content, filter, &ctx);
            } else {
                processJsonStream(allocator, content, filter, &ctx);
            }
        }
    }

    flushOutput();
}

fn readStdin(allocator: std.mem.Allocator) ![]u8 {
    var result = std.ArrayListUnmanaged(u8).empty;
    var buf: [8192]u8 = undefined;

    while (true) {
        const n = read(0, &buf, buf.len);
        if (n <= 0) break;
        try result.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    return result.toOwnedSlice(allocator);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    var result = std.ArrayListUnmanaged(u8).empty;
    var buf: [8192]u8 = undefined;

    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        try result.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    return result.toOwnedSlice(allocator);
}

fn skipWhitespace(input: []const u8, start: usize) usize {
    var pos = start;
    while (pos < input.len and (input[pos] == ' ' or input[pos] == '\n' or input[pos] == '\r' or input[pos] == '\t')) {
        pos += 1;
    }
    return pos;
}

/// Find the end offset of one JSON value starting at input[0..].
/// Returns the byte offset past the end of the value.
fn findJsonValueEnd(allocator: std.mem.Allocator, input: []const u8) ?usize {
    var scanner = std.json.Scanner.initStreaming(allocator);
    defer scanner.deinit();
    scanner.feedInput(input);
    scanner.endInput();

    var depth: usize = 0;
    var found_start = false;

    while (true) {
        const token = scanner.next() catch return null;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                found_start = true;
            },
            .object_end, .array_end => {
                if (depth > 0) depth -= 1;
                if (depth == 0 and found_start) {
                    return scanner.cursor;
                }
            },
            .end_of_document => return null,
            else => {
                if (depth == 0) {
                    // Scalar value at top level
                    return scanner.cursor;
                }
            },
        }
    }
}

/// Parse and process a stream of one or more JSON values (NDJSON support)
fn processJsonStream(allocator: std.mem.Allocator, input: []const u8, filter: []const u8, ctx: *OutputContext) void {
    var offset: usize = 0;
    var parsed_any = false;

    while (true) {
        offset = skipWhitespace(input, offset);
        if (offset >= input.len) break;

        const remaining = input[offset..];

        // Find where this JSON value ends
        const value_end = findJsonValueEnd(allocator, remaining) orelse {
            if (!parsed_any) {
                writeStderr("zjq: parse error: SyntaxError\n", .{});
                std.process.exit(1);
            }
            return;
        };

        // Parse just this one value
        const value_slice = remaining[0..value_end];
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, value_slice, .{}) catch |err| {
            if (parsed_any) return;
            writeStderr("zjq: parse error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer parsed.deinit();

        processJsonValue(allocator, parsed.value, filter, ctx);
        parsed_any = true;
        offset += value_end;
    }
}

fn processSlurp(allocator: std.mem.Allocator, input: []const u8, filter: []const u8, ctx: *OutputContext) void {
    // Collect all JSON values into an array
    var values = std.ArrayListUnmanaged(std.json.Value).empty;
    defer values.deinit(allocator);

    // We need to keep parsed data alive, store parsers
    var parsers = std.ArrayListUnmanaged(std.json.Parsed(std.json.Value)).empty;
    defer {
        for (parsers.items) |*p| p.deinit();
        parsers.deinit(allocator);
    }

    var offset: usize = 0;
    while (true) {
        offset = skipWhitespace(input, offset);
        if (offset >= input.len) break;

        const remaining = input[offset..];
        const value_end = findJsonValueEnd(allocator, remaining) orelse break;
        const value_slice = remaining[0..value_end];

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, value_slice, .{}) catch break;
        parsers.append(allocator, parsed) catch return;
        values.append(allocator, parsed.value) catch return;
        offset += value_end;
    }

    // Build a JSON array value from collected values
    var arr = std.json.Array.init(allocator);
    arr.appendSlice(values.items) catch return;
    const array_value = std.json.Value{ .array = arr };

    processJsonValue(allocator, array_value, filter, ctx);
}

fn processJsonValue(allocator: std.mem.Allocator, value: std.json.Value, filter: []const u8, ctx: *OutputContext) void {
    // Parse and apply filter
    var results = std.ArrayListUnmanaged(std.json.Value).empty;
    defer results.deinit(allocator);

    evaluateFilter(allocator, value, filter, &results) catch |err| {
        writeStderr("zjq: filter error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    for (results.items) |result| {
        outputValue(allocator, result, ctx, 0);
    }
}

const FilterError = error{
    InvalidFilter,
    TypeMismatch,
    IndexOutOfBounds,
    KeyNotFound,
    OutOfMemory,
    BreakError,
};

fn evaluateFilter(allocator: std.mem.Allocator, value: std.json.Value, filter: []const u8, results: *std.ArrayListUnmanaged(std.json.Value)) FilterError!void {
    // Split on top-level pipe '|' first
    if (splitPipe(filter)) |pipe_pos| {
        const left = std.mem.trim(u8, filter[0..pipe_pos], " ");
        const right = std.mem.trim(u8, filter[pipe_pos + 1 ..], " ");

        // Evaluate left side
        var intermediate = std.ArrayListUnmanaged(std.json.Value).empty;
        defer intermediate.deinit(allocator);
        try evaluateFilter(allocator, value, left, &intermediate);

        // For each intermediate result, evaluate right side
        for (intermediate.items) |inter_val| {
            evaluateFilter(allocator, inter_val, right, results) catch |err| {
                if (err == FilterError.BreakError) continue;
                return err;
            };
        }
        return;
    }

    // Split on top-level comma ',' for multiple outputs
    if (splitComma(filter)) |comma_pos| {
        const left = std.mem.trim(u8, filter[0..comma_pos], " ");
        const right = std.mem.trim(u8, filter[comma_pos + 1 ..], " ");

        try evaluateFilter(allocator, value, left, results);
        try evaluateFilter(allocator, value, right, results);
        return;
    }

    var pos: usize = 0;

    // Skip leading whitespace
    while (pos < filter.len and filter[pos] == ' ') pos += 1;

    if (pos >= filter.len or (filter.len == 1 and filter[0] == '.')) {
        // Identity filter
        results.append(allocator, value) catch return FilterError.OutOfMemory;
        return;
    }

    // Check for built-in functions
    const trimmed = std.mem.trim(u8, filter, " ");
    if (tryBuiltinFunction(allocator, value, trimmed, results)) return;

    // Check for object construction { ... }
    if (trimmed.len > 1 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        if (tryObjectConstruction(allocator, value, trimmed, results)) return;
    }

    // Check for array construction [ ... ]
    if (trimmed.len > 1 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " ");
        if (inner.len == 0) {
            // Empty array literal
            const arr = std.json.Array.init(allocator);
            results.append(allocator, .{ .array = arr }) catch return FilterError.OutOfMemory;
            return;
        }
        // Evaluate inner filter, collect results into array
        var inner_results = std.ArrayListUnmanaged(std.json.Value).empty;
        defer inner_results.deinit(allocator);
        try evaluateFilter(allocator, value, inner, &inner_results);
        var arr = std.json.Array.init(allocator);
        arr.appendSlice(inner_results.items) catch return FilterError.OutOfMemory;
        results.append(allocator, .{ .array = arr }) catch return FilterError.OutOfMemory;
        return;
    }

    // Check for string literal
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        results.append(allocator, .{ .string = trimmed[1 .. trimmed.len - 1] }) catch return FilterError.OutOfMemory;
        return;
    }

    // Check for numeric literal
    if (trimmed.len > 0 and (trimmed[0] >= '0' and trimmed[0] <= '9')) {
        if (std.fmt.parseInt(i64, trimmed, 10)) |n| {
            results.append(allocator, .{ .integer = n }) catch return FilterError.OutOfMemory;
            return;
        } else |_| {}
        if (std.fmt.parseFloat(f64, trimmed)) |f| {
            results.append(allocator, .{ .float = f }) catch return FilterError.OutOfMemory;
            return;
        } else |_| {}
    }

    // Check for boolean/null literals
    if (std.mem.eql(u8, trimmed, "true")) {
        results.append(allocator, .{ .bool = true }) catch return FilterError.OutOfMemory;
        return;
    }
    if (std.mem.eql(u8, trimmed, "false")) {
        results.append(allocator, .{ .bool = false }) catch return FilterError.OutOfMemory;
        return;
    }
    if (std.mem.eql(u8, trimmed, "null")) {
        results.append(allocator, .null) catch return FilterError.OutOfMemory;
        return;
    }
    if (std.mem.eql(u8, trimmed, "empty")) {
        return; // produces no output
    }

    var current = value;

    while (pos < filter.len) {
        // Skip whitespace
        while (pos < filter.len and filter[pos] == ' ') pos += 1;
        if (pos >= filter.len) break;

        if (filter[pos] == '.') {
            pos += 1;
            if (pos >= filter.len) {
                // Just "." at end
                break;
            }

            // Check for array iteration .[]
            if (filter[pos] == '[') {
                pos += 1;
                if (pos < filter.len and filter[pos] == ']') {
                    pos += 1;
                    // Iterate array or object
                    switch (current) {
                        .array => |arr| {
                            if (pos >= filter.len) {
                                for (arr.items) |item| {
                                    results.append(allocator, item) catch return FilterError.OutOfMemory;
                                }
                                return;
                            } else {
                                // Continue filtering each element
                                const rest = filter[pos..];
                                for (arr.items) |item| {
                                    try evaluateFilter(allocator, item, rest, results);
                                }
                                return;
                            }
                        },
                        .object => |obj| {
                            if (pos >= filter.len) {
                                var iter = obj.iterator();
                                while (iter.next()) |entry| {
                                    results.append(allocator, entry.value_ptr.*) catch return FilterError.OutOfMemory;
                                }
                                return;
                            } else {
                                const rest = filter[pos..];
                                var iter = obj.iterator();
                                while (iter.next()) |entry| {
                                    try evaluateFilter(allocator, entry.value_ptr.*, rest, results);
                                }
                                return;
                            }
                        },
                        else => return FilterError.TypeMismatch,
                    }
                } else {
                    // Array index .[N] or .[- N]
                    current = try parseArrayIndex(filter, &pos, current);
                }
            } else if (filter[pos] == '"') {
                // Quoted key ."key"
                pos += 1;
                const key_start = pos;
                while (pos < filter.len and filter[pos] != '"') pos += 1;
                if (pos >= filter.len) return FilterError.InvalidFilter;
                const key = filter[key_start..pos];
                pos += 1;

                switch (current) {
                    .object => |obj| {
                        if (obj.get(key)) |val| {
                            current = val;
                        } else {
                            current = .null;
                        }
                    },
                    else => return FilterError.TypeMismatch,
                }
            } else {
                // Unquoted key .key
                const key_start = pos;
                while (pos < filter.len and filter[pos] != '.' and filter[pos] != '[' and filter[pos] != ' ' and filter[pos] != '|' and filter[pos] != ',') {
                    pos += 1;
                }
                const key = filter[key_start..pos];

                if (key.len == 0) return FilterError.InvalidFilter;

                switch (current) {
                    .object => |obj| {
                        if (obj.get(key)) |val| {
                            current = val;
                        } else {
                            current = .null;
                        }
                    },
                    else => return FilterError.TypeMismatch,
                }
            }
        } else if (filter[pos] == '[') {
            pos += 1;
            if (pos < filter.len and filter[pos] == ']') {
                pos += 1;
                // Iterate
                switch (current) {
                    .array => |arr| {
                        if (pos >= filter.len) {
                            for (arr.items) |item| {
                                results.append(allocator, item) catch return FilterError.OutOfMemory;
                            }
                            return;
                        } else {
                            const rest = filter[pos..];
                            for (arr.items) |item| {
                                try evaluateFilter(allocator, item, rest, results);
                            }
                            return;
                        }
                    },
                    .object => |obj| {
                        if (pos >= filter.len) {
                            var iter = obj.iterator();
                            while (iter.next()) |entry| {
                                results.append(allocator, entry.value_ptr.*) catch return FilterError.OutOfMemory;
                            }
                            return;
                        } else {
                            const rest = filter[pos..];
                            var iter = obj.iterator();
                            while (iter.next()) |entry| {
                                try evaluateFilter(allocator, entry.value_ptr.*, rest, results);
                            }
                            return;
                        }
                    },
                    else => return FilterError.TypeMismatch,
                }
            } else {
                // Index (including negative)
                current = try parseArrayIndex(filter, &pos, current);
            }
        } else {
            return FilterError.InvalidFilter;
        }
    }

    results.append(allocator, current) catch return FilterError.OutOfMemory;
}

/// Parse an array index including negative indices, consuming from filter[pos..]
/// Expects pos to be right after the '[' character.
fn parseArrayIndex(filter: []const u8, pos: *usize, current: std.json.Value) FilterError!std.json.Value {
    const p = pos.*;
    var negative = false;
    var idx_start = p;

    if (p < filter.len and filter[p] == '-') {
        negative = true;
        idx_start = p + 1;
        pos.* = p + 1;
    }

    var idx_end = idx_start;
    while (idx_end < filter.len and filter[idx_end] >= '0' and filter[idx_end] <= '9') idx_end += 1;
    if (idx_end == idx_start) return FilterError.InvalidFilter;

    const idx_val = std.fmt.parseInt(usize, filter[idx_start..idx_end], 10) catch return FilterError.InvalidFilter;

    pos.* = idx_end;
    if (pos.* >= filter.len or filter[pos.*] != ']') return FilterError.InvalidFilter;
    pos.* += 1;

    switch (current) {
        .array => |arr| {
            if (negative) {
                if (idx_val > arr.items.len) return FilterError.IndexOutOfBounds;
                return arr.items[arr.items.len - idx_val];
            } else {
                if (idx_val >= arr.items.len) return FilterError.IndexOutOfBounds;
                return arr.items[idx_val];
            }
        },
        else => return FilterError.TypeMismatch,
    }
}

/// Find the position of a top-level '|' (not inside brackets, parens, or strings)
fn splitPipe(filter: []const u8) ?usize {
    var depth: i32 = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < filter.len) : (i += 1) {
        if (in_string) {
            if (filter[i] == '\\') {
                i += 1; // skip escaped char
            } else if (filter[i] == '"') {
                in_string = false;
            }
        } else {
            switch (filter[i]) {
                '"' => in_string = true,
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -= 1,
                '|' => if (depth == 0) return i,
                else => {},
            }
        }
    }
    return null;
}

/// Find the position of a top-level ','
fn splitComma(filter: []const u8) ?usize {
    var depth: i32 = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < filter.len) : (i += 1) {
        if (in_string) {
            if (filter[i] == '\\') {
                i += 1;
            } else if (filter[i] == '"') {
                in_string = false;
            }
        } else {
            switch (filter[i]) {
                '"' => in_string = true,
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -= 1,
                ',' => if (depth == 0) return i,
                else => {},
            }
        }
    }
    return null;
}

/// Try to evaluate a built-in function. Returns true if handled.
fn tryBuiltinFunction(allocator: std.mem.Allocator, value: std.json.Value, filter: []const u8, results: *std.ArrayListUnmanaged(std.json.Value)) bool {
    // length
    if (std.mem.eql(u8, filter, "length")) {
        const len: i64 = switch (value) {
            .array => |arr| @intCast(arr.items.len),
            .object => |obj| @intCast(obj.count()),
            .string => |s| @intCast(s.len),
            .null => 0,
            .integer => |n| if (n < 0) -n else n,
            .float => |f| blk: {
                const abs = @abs(f);
                break :blk @intFromFloat(abs);
            },
            else => 0,
        };
        results.append(allocator, .{ .integer = len }) catch return true;
        return true;
    }

    // keys / keys_unsorted
    if (std.mem.eql(u8, filter, "keys") or std.mem.eql(u8, filter, "keys_unsorted")) {
        switch (value) {
            .object => |obj| {
                var key_arr = std.json.Array.init(allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    key_arr.append(.{ .string = entry.key_ptr.* }) catch return true;
                }
                // Sort if "keys" (not keys_unsorted)
                if (std.mem.eql(u8, filter, "keys")) {
                    std.mem.sort(std.json.Value, key_arr.items, {}, struct {
                        fn lessThan(_: void, a: std.json.Value, b: std.json.Value) bool {
                            return std.mem.lessThan(u8, jsonString(a), jsonString(b));
                        }
                        fn jsonString(v: std.json.Value) []const u8 {
                            return switch (v) {
                                .string => |s| s,
                                else => "",
                            };
                        }
                    }.lessThan);
                }
                results.append(allocator, .{ .array = key_arr }) catch return true;
                return true;
            },
            .array => |arr| {
                var idx_arr = std.json.Array.init(allocator);
                for (0..arr.items.len) |i| {
                    idx_arr.append(.{ .integer = @intCast(i) }) catch return true;
                }
                results.append(allocator, .{ .array = idx_arr }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // values
    if (std.mem.eql(u8, filter, "values")) {
        switch (value) {
            .object => |obj| {
                var val_arr = std.json.Array.init(allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    val_arr.append(entry.value_ptr.*) catch return true;
                }
                results.append(allocator, .{ .array = val_arr }) catch return true;
                return true;
            },
            .array => {
                results.append(allocator, value) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // type
    if (std.mem.eql(u8, filter, "type")) {
        const type_str: []const u8 = switch (value) {
            .null => "null",
            .bool => "boolean",
            .integer, .float, .number_string => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
        results.append(allocator, .{ .string = type_str }) catch return true;
        return true;
    }

    // to_entries
    if (std.mem.eql(u8, filter, "to_entries")) {
        switch (value) {
            .object => |obj| {
                var entries_arr = std.json.Array.init(allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    var entry_obj = std.json.ObjectMap.init(allocator);
                    entry_obj.put("key", .{ .string = entry.key_ptr.* }) catch return true;
                    entry_obj.put("value", entry.value_ptr.*) catch return true;
                    entries_arr.append(.{ .object = entry_obj }) catch return true;
                }
                results.append(allocator, .{ .array = entries_arr }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // from_entries
    if (std.mem.eql(u8, filter, "from_entries")) {
        switch (value) {
            .array => |arr| {
                var obj = std.json.ObjectMap.init(allocator);
                for (arr.items) |item| {
                    switch (item) {
                        .object => |entry_obj| {
                            const key_val = entry_obj.get("key") orelse entry_obj.get("name") orelse continue;
                            const key_str = switch (key_val) {
                                .string => |s| s,
                                else => continue,
                            };
                            const val = entry_obj.get("value") orelse .null;
                            obj.put(key_str, val) catch return true;
                        },
                        else => continue,
                    }
                }
                results.append(allocator, .{ .object = obj }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // with_entries(f) - desugar to to_entries | map(f) | from_entries
    if (std.mem.startsWith(u8, filter, "with_entries(") and filter[filter.len - 1] == ')') {
        const inner_filter = filter["with_entries(".len .. filter.len - 1];
        // to_entries
        var entries_results = std.ArrayListUnmanaged(std.json.Value).empty;
        defer entries_results.deinit(allocator);
        if (!tryBuiltinFunction(allocator, value, "to_entries", &entries_results)) return false;
        if (entries_results.items.len == 0) return false;
        const entries = entries_results.items[0];

        // map(inner_filter)
        switch (entries) {
            .array => |arr| {
                var mapped = std.json.Array.init(allocator);
                for (arr.items) |item| {
                    var sub_results = std.ArrayListUnmanaged(std.json.Value).empty;
                    defer sub_results.deinit(allocator);
                    evaluateFilter(allocator, item, inner_filter, &sub_results) catch return false;
                    for (sub_results.items) |r| {
                        mapped.append(r) catch return true;
                    }
                }
                const mapped_val = std.json.Value{ .array = mapped };

                // from_entries
                _ = tryBuiltinFunction(allocator, mapped_val, "from_entries", results);
                return true;
            },
            else => return false,
        }
    }

    // not
    if (std.mem.eql(u8, filter, "not")) {
        const b = !jsonTruthy(value);
        results.append(allocator, .{ .bool = b }) catch return true;
        return true;
    }

    // tostring
    if (std.mem.eql(u8, filter, "tostring")) {
        switch (value) {
            .string => {
                results.append(allocator, value) catch return true;
                return true;
            },
            .integer => |n| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return true;
                const duped = allocator.dupe(u8, s) catch return true;
                results.append(allocator, .{ .string = duped }) catch return true;
                return true;
            },
            .float => |f| {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return true;
                const duped = allocator.dupe(u8, s) catch return true;
                results.append(allocator, .{ .string = duped }) catch return true;
                return true;
            },
            .bool => |b| {
                results.append(allocator, .{ .string = if (b) "true" else "false" }) catch return true;
                return true;
            },
            .null => {
                results.append(allocator, .{ .string = "null" }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // tonumber
    if (std.mem.eql(u8, filter, "tonumber")) {
        switch (value) {
            .integer => {
                results.append(allocator, value) catch return true;
                return true;
            },
            .float => {
                results.append(allocator, value) catch return true;
                return true;
            },
            .string => |s| {
                if (std.fmt.parseInt(i64, s, 10)) |n| {
                    results.append(allocator, .{ .integer = n }) catch return true;
                    return true;
                } else |_| {}
                if (std.fmt.parseFloat(f64, s)) |f| {
                    results.append(allocator, .{ .float = f }) catch return true;
                    return true;
                } else |_| {}
                return false;
            },
            else => return false,
        }
    }

    // ascii_downcase
    if (std.mem.eql(u8, filter, "ascii_downcase")) {
        switch (value) {
            .string => |s| {
                const lower = allocator.alloc(u8, s.len) catch return true;
                for (s, 0..) |c, i| {
                    lower[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                }
                results.append(allocator, .{ .string = lower }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // ascii_upcase
    if (std.mem.eql(u8, filter, "ascii_upcase")) {
        switch (value) {
            .string => |s| {
                const upper = allocator.alloc(u8, s.len) catch return true;
                for (s, 0..) |c, i| {
                    upper[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
                }
                results.append(allocator, .{ .string = upper }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // reverse
    if (std.mem.eql(u8, filter, "reverse")) {
        switch (value) {
            .array => |arr| {
                var reversed = std.json.Array.init(allocator);
                reversed.appendSlice(arr.items) catch return true;
                std.mem.reverse(std.json.Value, reversed.items);
                results.append(allocator, .{ .array = reversed }) catch return true;
                return true;
            },
            .string => |s| {
                const rev = allocator.alloc(u8, s.len) catch return true;
                for (s, 0..) |_, i| {
                    rev[i] = s[s.len - 1 - i];
                }
                results.append(allocator, .{ .string = rev }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // sort
    if (std.mem.eql(u8, filter, "sort")) {
        switch (value) {
            .array => |arr| {
                var sorted = std.json.Array.init(allocator);
                sorted.appendSlice(arr.items) catch return true;
                std.mem.sort(std.json.Value, sorted.items, {}, jsonLessThan);
                results.append(allocator, .{ .array = sorted }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // sort_by(f)
    if (std.mem.startsWith(u8, filter, "sort_by(") and filter[filter.len - 1] == ')') {
        const inner = filter["sort_by(".len .. filter.len - 1];
        switch (value) {
            .array => |arr| {
                // Create key-value pairs
                const Pair = struct { key: std.json.Value, val: std.json.Value };
                var pairs = allocator.alloc(Pair, arr.items.len) catch return true;
                defer allocator.free(pairs);

                for (arr.items, 0..) |item, i| {
                    var sub = std.ArrayListUnmanaged(std.json.Value).empty;
                    defer sub.deinit(allocator);
                    evaluateFilter(allocator, item, inner, &sub) catch {
                        pairs[i] = .{ .key = .null, .val = item };
                        continue;
                    };
                    pairs[i] = .{ .key = if (sub.items.len > 0) sub.items[0] else .null, .val = item };
                }

                std.mem.sort(Pair, pairs, {}, struct {
                    fn lessThan(_: void, a: Pair, b: Pair) bool {
                        return jsonLessThan({}, a.key, b.key);
                    }
                }.lessThan);

                var sorted = std.json.Array.init(allocator);
                for (pairs) |p| {
                    sorted.append(p.val) catch return true;
                }
                results.append(allocator, .{ .array = sorted }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // group_by(f)
    if (std.mem.startsWith(u8, filter, "group_by(") and filter[filter.len - 1] == ')') {
        const inner = filter["group_by(".len .. filter.len - 1];
        switch (value) {
            .array => |arr| {
                const Pair = struct { key: std.json.Value, val: std.json.Value };
                var pairs = allocator.alloc(Pair, arr.items.len) catch return true;
                defer allocator.free(pairs);

                for (arr.items, 0..) |item, i| {
                    var sub = std.ArrayListUnmanaged(std.json.Value).empty;
                    defer sub.deinit(allocator);
                    evaluateFilter(allocator, item, inner, &sub) catch {
                        pairs[i] = .{ .key = .null, .val = item };
                        continue;
                    };
                    pairs[i] = .{ .key = if (sub.items.len > 0) sub.items[0] else .null, .val = item };
                }

                // Sort by key
                std.mem.sort(Pair, pairs, {}, struct {
                    fn lessThan(_: void, a: Pair, b: Pair) bool {
                        return jsonLessThan({}, a.key, b.key);
                    }
                }.lessThan);

                // Group consecutive equal keys
                var groups = std.json.Array.init(allocator);
                var current_group = std.json.Array.init(allocator);
                var last_key: ?std.json.Value = null;

                for (pairs) |p| {
                    if (last_key) |lk| {
                        if (!jsonEqual(lk, p.key)) {
                            groups.append(.{ .array = current_group }) catch return true;
                            current_group = std.json.Array.init(allocator);
                        }
                    }
                    current_group.append(p.val) catch return true;
                    last_key = p.key;
                }
                if (current_group.items.len > 0) {
                    groups.append(.{ .array = current_group }) catch return true;
                }

                results.append(allocator, .{ .array = groups }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // unique
    if (std.mem.eql(u8, filter, "unique")) {
        switch (value) {
            .array => |arr| {
                var unique_arr = std.json.Array.init(allocator);
                for (arr.items) |item| {
                    var found = false;
                    for (unique_arr.items) |existing| {
                        if (jsonEqual(existing, item)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        unique_arr.append(item) catch return true;
                    }
                }
                results.append(allocator, .{ .array = unique_arr }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // unique_by(f)
    if (std.mem.startsWith(u8, filter, "unique_by(") and filter[filter.len - 1] == ')') {
        const inner = filter["unique_by(".len .. filter.len - 1];
        switch (value) {
            .array => |arr| {
                var unique_arr = std.json.Array.init(allocator);
                var seen_keys = std.ArrayListUnmanaged(std.json.Value).empty;
                defer seen_keys.deinit(allocator);

                for (arr.items) |item| {
                    var sub = std.ArrayListUnmanaged(std.json.Value).empty;
                    defer sub.deinit(allocator);
                    evaluateFilter(allocator, item, inner, &sub) catch continue;
                    const key = if (sub.items.len > 0) sub.items[0] else std.json.Value.null;

                    var found = false;
                    for (seen_keys.items) |sk| {
                        if (jsonEqual(sk, key)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        seen_keys.append(allocator, key) catch return true;
                        unique_arr.append(item) catch return true;
                    }
                }
                results.append(allocator, .{ .array = unique_arr }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // flatten / flatten(depth)
    if (std.mem.eql(u8, filter, "flatten")) {
        switch (value) {
            .array => |arr| {
                var flat = std.json.Array.init(allocator);
                flattenArray(allocator, arr.items, &flat, 1);
                results.append(allocator, .{ .array = flat }) catch return true;
                return true;
            },
            else => return false,
        }
    }
    if (std.mem.startsWith(u8, filter, "flatten(") and filter[filter.len - 1] == ')') {
        const depth_str = filter["flatten(".len .. filter.len - 1];
        const depth = std.fmt.parseInt(usize, depth_str, 10) catch return false;
        switch (value) {
            .array => |arr| {
                var flat = std.json.Array.init(allocator);
                flattenArray(allocator, arr.items, &flat, depth);
                results.append(allocator, .{ .array = flat }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // add
    if (std.mem.eql(u8, filter, "add")) {
        switch (value) {
            .array => |arr| {
                if (arr.items.len == 0) {
                    results.append(allocator, .null) catch return true;
                    return true;
                }
                // Check type of first element
                switch (arr.items[0]) {
                    .integer => {
                        var sum: i64 = 0;
                        for (arr.items) |item| {
                            switch (item) {
                                .integer => |n| sum += n,
                                .float => |f| {
                                    var fsum: f64 = @floatFromInt(sum);
                                    fsum += f;
                                    for (arr.items[1..]) |rest| {
                                        switch (rest) {
                                            .integer => |rn| fsum += @floatFromInt(rn),
                                            .float => |rf| fsum += rf,
                                            else => {},
                                        }
                                    }
                                    results.append(allocator, .{ .float = fsum }) catch return true;
                                    return true;
                                },
                                else => {},
                            }
                        }
                        results.append(allocator, .{ .integer = sum }) catch return true;
                        return true;
                    },
                    .float => {
                        var sum: f64 = 0;
                        for (arr.items) |item| {
                            switch (item) {
                                .integer => |n| sum += @floatFromInt(n),
                                .float => |f| sum += f,
                                else => {},
                            }
                        }
                        results.append(allocator, .{ .float = sum }) catch return true;
                        return true;
                    },
                    .string => {
                        var total_len: usize = 0;
                        for (arr.items) |item| {
                            switch (item) {
                                .string => |s| total_len += s.len,
                                else => {},
                            }
                        }
                        const concat = allocator.alloc(u8, total_len) catch return true;
                        var off: usize = 0;
                        for (arr.items) |item| {
                            switch (item) {
                                .string => |s| {
                                    @memcpy(concat[off..][0..s.len], s);
                                    off += s.len;
                                },
                                else => {},
                            }
                        }
                        results.append(allocator, .{ .string = concat }) catch return true;
                        return true;
                    },
                    .array => {
                        var combined = std.json.Array.init(allocator);
                        for (arr.items) |item| {
                            switch (item) {
                                .array => |sub| combined.appendSlice(sub.items) catch return true,
                                else => {},
                            }
                        }
                        results.append(allocator, .{ .array = combined }) catch return true;
                        return true;
                    },
                    else => {
                        results.append(allocator, .null) catch return true;
                        return true;
                    },
                }
            },
            else => return false,
        }
    }

    // any
    if (std.mem.eql(u8, filter, "any")) {
        switch (value) {
            .array => |arr| {
                for (arr.items) |item| {
                    if (jsonTruthy(item)) {
                        results.append(allocator, .{ .bool = true }) catch return true;
                        return true;
                    }
                }
                results.append(allocator, .{ .bool = false }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // all
    if (std.mem.eql(u8, filter, "all")) {
        switch (value) {
            .array => |arr| {
                for (arr.items) |item| {
                    if (!jsonTruthy(item)) {
                        results.append(allocator, .{ .bool = false }) catch return true;
                        return true;
                    }
                }
                results.append(allocator, .{ .bool = true }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // min
    if (std.mem.eql(u8, filter, "min")) {
        switch (value) {
            .array => |arr| {
                if (arr.items.len == 0) {
                    results.append(allocator, .null) catch return true;
                    return true;
                }
                var min_val = arr.items[0];
                for (arr.items[1..]) |item| {
                    if (jsonLessThan({}, item, min_val)) min_val = item;
                }
                results.append(allocator, min_val) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // max
    if (std.mem.eql(u8, filter, "max")) {
        switch (value) {
            .array => |arr| {
                if (arr.items.len == 0) {
                    results.append(allocator, .null) catch return true;
                    return true;
                }
                var max_val = arr.items[0];
                for (arr.items[1..]) |item| {
                    if (jsonLessThan({}, max_val, item)) max_val = item;
                }
                results.append(allocator, max_val) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // min_by(f) / max_by(f)
    if (std.mem.startsWith(u8, filter, "min_by(") and filter[filter.len - 1] == ')') {
        const inner = filter["min_by(".len .. filter.len - 1];
        return minMaxBy(allocator, value, inner, results, true);
    }
    if (std.mem.startsWith(u8, filter, "max_by(") and filter[filter.len - 1] == ')') {
        const inner = filter["max_by(".len .. filter.len - 1];
        return minMaxBy(allocator, value, inner, results, false);
    }

    // first / last
    if (std.mem.eql(u8, filter, "first")) {
        switch (value) {
            .array => |arr| {
                if (arr.items.len > 0) {
                    results.append(allocator, arr.items[0]) catch return true;
                } else {
                    results.append(allocator, .null) catch return true;
                }
                return true;
            },
            else => return false,
        }
    }
    if (std.mem.eql(u8, filter, "last")) {
        switch (value) {
            .array => |arr| {
                if (arr.items.len > 0) {
                    results.append(allocator, arr.items[arr.items.len - 1]) catch return true;
                } else {
                    results.append(allocator, .null) catch return true;
                }
                return true;
            },
            else => return false,
        }
    }

    // nth(n)
    if (std.mem.startsWith(u8, filter, "nth(") and filter[filter.len - 1] == ')') {
        const n_str = filter["nth(".len .. filter.len - 1];
        const n = std.fmt.parseInt(i64, n_str, 10) catch return false;
        switch (value) {
            .array => |arr| {
                const idx = if (n < 0) @as(i64, @intCast(arr.items.len)) + n else n;
                if (idx >= 0 and idx < @as(i64, @intCast(arr.items.len))) {
                    results.append(allocator, arr.items[@intCast(idx)]) catch return true;
                } else {
                    results.append(allocator, .null) catch return true;
                }
                return true;
            },
            else => return false,
        }
    }

    // map(f)
    if (std.mem.startsWith(u8, filter, "map(") and filter[filter.len - 1] == ')') {
        const inner = filter["map(".len .. filter.len - 1];
        switch (value) {
            .array => |arr| {
                var mapped = std.json.Array.init(allocator);
                for (arr.items) |item| {
                    var sub_results = std.ArrayListUnmanaged(std.json.Value).empty;
                    defer sub_results.deinit(allocator);
                    evaluateFilter(allocator, item, inner, &sub_results) catch continue;
                    for (sub_results.items) |r| {
                        mapped.append(r) catch return true;
                    }
                }
                results.append(allocator, .{ .array = mapped }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // map_values(f)
    if (std.mem.startsWith(u8, filter, "map_values(") and filter[filter.len - 1] == ')') {
        const inner = filter["map_values(".len .. filter.len - 1];
        switch (value) {
            .object => |obj| {
                var new_obj = std.json.ObjectMap.init(allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    var sub_results = std.ArrayListUnmanaged(std.json.Value).empty;
                    defer sub_results.deinit(allocator);
                    evaluateFilter(allocator, entry.value_ptr.*, inner, &sub_results) catch continue;
                    if (sub_results.items.len > 0) {
                        new_obj.put(entry.key_ptr.*, sub_results.items[0]) catch return true;
                    }
                }
                results.append(allocator, .{ .object = new_obj }) catch return true;
                return true;
            },
            .array => |arr| {
                var mapped = std.json.Array.init(allocator);
                for (arr.items) |item| {
                    var sub_results = std.ArrayListUnmanaged(std.json.Value).empty;
                    defer sub_results.deinit(allocator);
                    evaluateFilter(allocator, item, inner, &sub_results) catch continue;
                    if (sub_results.items.len > 0) {
                        mapped.append(sub_results.items[0]) catch return true;
                    }
                }
                results.append(allocator, .{ .array = mapped }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // select(f)
    if (std.mem.startsWith(u8, filter, "select(") and filter[filter.len - 1] == ')') {
        const inner = filter["select(".len .. filter.len - 1];
        var sub_results = std.ArrayListUnmanaged(std.json.Value).empty;
        defer sub_results.deinit(allocator);
        evaluateFilter(allocator, value, inner, &sub_results) catch return true;
        if (sub_results.items.len > 0 and jsonTruthy(sub_results.items[0])) {
            results.append(allocator, value) catch return true;
        }
        return true;
    }

    // has(key)
    if (std.mem.startsWith(u8, filter, "has(") and filter[filter.len - 1] == ')') {
        var inner = std.mem.trim(u8, filter["has(".len .. filter.len - 1], " ");
        // Strip quotes if present
        if (inner.len >= 2 and inner[0] == '"' and inner[inner.len - 1] == '"') {
            inner = inner[1 .. inner.len - 1];
        }
        switch (value) {
            .object => |obj| {
                results.append(allocator, .{ .bool = obj.get(inner) != null }) catch return true;
                return true;
            },
            .array => |arr| {
                // has(n) for arrays
                const idx = std.fmt.parseInt(usize, inner, 10) catch return false;
                results.append(allocator, .{ .bool = idx < arr.items.len }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // contains(value)
    if (std.mem.startsWith(u8, filter, "contains(") and filter[filter.len - 1] == ')') {
        const inner = std.mem.trim(u8, filter["contains(".len .. filter.len - 1], " ");
        // Parse the argument as JSON
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, inner, .{}) catch return false;
        defer parsed.deinit();
        results.append(allocator, .{ .bool = jsonContains(value, parsed.value) }) catch return true;
        return true;
    }

    // inside(value)
    if (std.mem.startsWith(u8, filter, "inside(") and filter[filter.len - 1] == ')') {
        const inner = std.mem.trim(u8, filter["inside(".len .. filter.len - 1], " ");
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, inner, .{}) catch return false;
        defer parsed.deinit();
        results.append(allocator, .{ .bool = jsonContains(parsed.value, value) }) catch return true;
        return true;
    }

    // limit(n; f)
    if (std.mem.startsWith(u8, filter, "limit(") and filter[filter.len - 1] == ')') {
        const inner = filter["limit(".len .. filter.len - 1];
        if (std.mem.indexOf(u8, inner, ";")) |semi| {
            const n_str = std.mem.trim(u8, inner[0..semi], " ");
            const expr = std.mem.trim(u8, inner[semi + 1 ..], " ");
            const n = std.fmt.parseInt(usize, n_str, 10) catch return false;
            var sub = std.ArrayListUnmanaged(std.json.Value).empty;
            defer sub.deinit(allocator);
            evaluateFilter(allocator, value, expr, &sub) catch return true;
            const count = @min(n, sub.items.len);
            for (sub.items[0..count]) |item| {
                results.append(allocator, item) catch return true;
            }
            return true;
        }
    }

    // range(n) / range(a;b)
    if (std.mem.startsWith(u8, filter, "range(") and filter[filter.len - 1] == ')') {
        const inner = filter["range(".len .. filter.len - 1];
        if (std.mem.indexOf(u8, inner, ";")) |semi| {
            const a_str = std.mem.trim(u8, inner[0..semi], " ");
            const b_str = std.mem.trim(u8, inner[semi + 1 ..], " ");
            const a = std.fmt.parseInt(i64, a_str, 10) catch return false;
            const b = std.fmt.parseInt(i64, b_str, 10) catch return false;
            var i = a;
            while (i < b) : (i += 1) {
                results.append(allocator, .{ .integer = i }) catch return true;
            }
            return true;
        } else {
            const n = std.fmt.parseInt(i64, inner, 10) catch return false;
            var i: i64 = 0;
            while (i < n) : (i += 1) {
                results.append(allocator, .{ .integer = i }) catch return true;
            }
            return true;
        }
    }

    // indices(s) / index(s) / rindex(s)
    if (std.mem.startsWith(u8, filter, "split(") and filter[filter.len - 1] == ')') {
        var inner = std.mem.trim(u8, filter["split(".len .. filter.len - 1], " ");
        if (inner.len >= 2 and inner[0] == '"' and inner[inner.len - 1] == '"') {
            inner = inner[1 .. inner.len - 1];
        }
        switch (value) {
            .string => |s| {
                var parts = std.json.Array.init(allocator);
                var start: usize = 0;
                while (start <= s.len) {
                    if (inner.len == 0) {
                        if (start < s.len) {
                            parts.append(.{ .string = s[start .. start + 1] }) catch return true;
                            start += 1;
                        } else break;
                    } else if (std.mem.indexOf(u8, s[start..], inner)) |idx| {
                        parts.append(.{ .string = s[start .. start + idx] }) catch return true;
                        start = start + idx + inner.len;
                    } else {
                        parts.append(.{ .string = s[start..] }) catch return true;
                        break;
                    }
                }
                results.append(allocator, .{ .array = parts }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // join(s)
    if (std.mem.startsWith(u8, filter, "join(") and filter[filter.len - 1] == ')') {
        var sep = std.mem.trim(u8, filter["join(".len .. filter.len - 1], " ");
        if (sep.len >= 2 and sep[0] == '"' and sep[sep.len - 1] == '"') {
            sep = sep[1 .. sep.len - 1];
        }
        switch (value) {
            .array => |arr| {
                var total_len: usize = 0;
                for (arr.items, 0..) |item, i| {
                    if (i > 0) total_len += sep.len;
                    switch (item) {
                        .string => |s| total_len += s.len,
                        .integer => |n| {
                            var buf: [32]u8 = undefined;
                            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch continue;
                            total_len += s.len;
                        },
                        else => {},
                    }
                }
                const joined = allocator.alloc(u8, total_len) catch return true;
                var off: usize = 0;
                for (arr.items, 0..) |item, i| {
                    if (i > 0) {
                        @memcpy(joined[off..][0..sep.len], sep);
                        off += sep.len;
                    }
                    switch (item) {
                        .string => |s| {
                            @memcpy(joined[off..][0..s.len], s);
                            off += s.len;
                        },
                        .integer => |n| {
                            var buf: [32]u8 = undefined;
                            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch continue;
                            @memcpy(joined[off..][0..s.len], s);
                            off += s.len;
                        },
                        else => {},
                    }
                }
                results.append(allocator, .{ .string = joined[0..off] }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // ltrimstr(s) / rtrimstr(s)
    if (std.mem.startsWith(u8, filter, "ltrimstr(") and filter[filter.len - 1] == ')') {
        var prefix = std.mem.trim(u8, filter["ltrimstr(".len .. filter.len - 1], " ");
        if (prefix.len >= 2 and prefix[0] == '"' and prefix[prefix.len - 1] == '"') {
            prefix = prefix[1 .. prefix.len - 1];
        }
        switch (value) {
            .string => |s| {
                if (std.mem.startsWith(u8, s, prefix)) {
                    results.append(allocator, .{ .string = s[prefix.len..] }) catch return true;
                } else {
                    results.append(allocator, value) catch return true;
                }
                return true;
            },
            else => return false,
        }
    }
    if (std.mem.startsWith(u8, filter, "rtrimstr(") and filter[filter.len - 1] == ')') {
        var suffix = std.mem.trim(u8, filter["rtrimstr(".len .. filter.len - 1], " ");
        if (suffix.len >= 2 and suffix[0] == '"' and suffix[suffix.len - 1] == '"') {
            suffix = suffix[1 .. suffix.len - 1];
        }
        switch (value) {
            .string => |s| {
                if (std.mem.endsWith(u8, s, suffix)) {
                    results.append(allocator, .{ .string = s[0 .. s.len - suffix.len] }) catch return true;
                } else {
                    results.append(allocator, value) catch return true;
                }
                return true;
            },
            else => return false,
        }
    }

    // startswith(s) / endswith(s)
    if (std.mem.startsWith(u8, filter, "startswith(") and filter[filter.len - 1] == ')') {
        var prefix = std.mem.trim(u8, filter["startswith(".len .. filter.len - 1], " ");
        if (prefix.len >= 2 and prefix[0] == '"' and prefix[prefix.len - 1] == '"') {
            prefix = prefix[1 .. prefix.len - 1];
        }
        switch (value) {
            .string => |s| {
                results.append(allocator, .{ .bool = std.mem.startsWith(u8, s, prefix) }) catch return true;
                return true;
            },
            else => return false,
        }
    }
    if (std.mem.startsWith(u8, filter, "endswith(") and filter[filter.len - 1] == ')') {
        var suffix = std.mem.trim(u8, filter["endswith(".len .. filter.len - 1], " ");
        if (suffix.len >= 2 and suffix[0] == '"' and suffix[suffix.len - 1] == '"') {
            suffix = suffix[1 .. suffix.len - 1];
        }
        switch (value) {
            .string => |s| {
                results.append(allocator, .{ .bool = std.mem.endsWith(u8, s, suffix) }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // test(regex) - simple substring match
    if (std.mem.startsWith(u8, filter, "test(") and filter[filter.len - 1] == ')') {
        var pattern = std.mem.trim(u8, filter["test(".len .. filter.len - 1], " ");
        if (pattern.len >= 2 and pattern[0] == '"' and pattern[pattern.len - 1] == '"') {
            pattern = pattern[1 .. pattern.len - 1];
        }
        switch (value) {
            .string => |s| {
                results.append(allocator, .{ .bool = std.mem.indexOf(u8, s, pattern) != null }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // ascii
    if (std.mem.eql(u8, filter, "ascii")) {
        switch (value) {
            .integer => |n| {
                if (n >= 0 and n < 128) {
                    var buf: [1]u8 = .{@intCast(n)};
                    const s = allocator.dupe(u8, &buf) catch return true;
                    results.append(allocator, .{ .string = s }) catch return true;
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    // explode / implode
    if (std.mem.eql(u8, filter, "explode")) {
        switch (value) {
            .string => |s| {
                var arr = std.json.Array.init(allocator);
                for (s) |c| {
                    arr.append(.{ .integer = @intCast(c) }) catch return true;
                }
                results.append(allocator, .{ .array = arr }) catch return true;
                return true;
            },
            else => return false,
        }
    }
    if (std.mem.eql(u8, filter, "implode")) {
        switch (value) {
            .array => |arr| {
                const s = allocator.alloc(u8, arr.items.len) catch return true;
                for (arr.items, 0..) |item, i| {
                    switch (item) {
                        .integer => |n| s[i] = if (n >= 0 and n < 256) @intCast(n) else '?',
                        else => s[i] = '?',
                    }
                }
                results.append(allocator, .{ .string = s }) catch return true;
                return true;
            },
            else => return false,
        }
    }

    // env
    if (std.mem.eql(u8, filter, "env")) {
        const env_obj = std.json.ObjectMap.init(allocator);
        // We can't easily enumerate env vars without libc environ, just return empty
        results.append(allocator, .{ .object = env_obj }) catch return true;
        return true;
    }

    // input / inputs / debug / stderr - no-ops or passthrough
    if (std.mem.eql(u8, filter, "debug")) {
        // debug outputs to stderr then passes through
        var buf: [4096]u8 = undefined;
        const dbg = jsonToString(allocator, value, &buf);
        writeStderr("[\"DEBUG:\",{s}]\n", .{dbg});
        results.append(allocator, value) catch return true;
        return true;
    }

    // if-then-else: if COND then EXPR (else EXPR) end
    if (std.mem.startsWith(u8, filter, "if ")) {
        if (parseIfThenElse(allocator, value, filter, results)) return true;
    }

    // Comparison operators: ==, !=, <, >, <=, >=
    if (tryComparisonOp(allocator, value, filter, results)) return true;

    // Arithmetic: +, -, *, /, %
    if (tryArithmeticOp(allocator, value, filter, results)) return true;

    // and / or
    if (tryLogicalOp(allocator, value, filter, results)) return true;

    // Alternative operator: //
    if (tryAlternativeOp(allocator, value, filter, results)) return true;

    // try-catch: f?
    if (filter.len > 1 and filter[filter.len - 1] == '?') {
        const inner = filter[0 .. filter.len - 1];
        var sub = std.ArrayListUnmanaged(std.json.Value).empty;
        defer sub.deinit(allocator);
        evaluateFilter(allocator, value, inner, &sub) catch {
            return true; // suppress error
        };
        results.appendSlice(allocator, sub.items) catch return true;
        return true;
    }

    return false;
}

fn tryObjectConstruction(allocator: std.mem.Allocator, value: std.json.Value, filter: []const u8, results: *std.ArrayListUnmanaged(std.json.Value)) bool {
    const inner = std.mem.trim(u8, filter[1 .. filter.len - 1], " ");
    if (inner.len == 0) {
        const obj = std.json.ObjectMap.init(allocator);
        results.append(allocator, .{ .object = obj }) catch return true;
        return true;
    }

    var obj = std.json.ObjectMap.init(allocator);

    // Split on commas at depth 0
    var start: usize = 0;
    var depth: i32 = 0;
    var in_string = false;
    var i: usize = 0;
    while (i <= inner.len) : (i += 1) {
        if (i == inner.len or (inner[i] == ',' and depth == 0 and !in_string)) {
            const pair = std.mem.trim(u8, inner[start..i], " ");
            if (pair.len > 0) {
                // Find ':' at depth 0
                var colon_pos: ?usize = null;
                var pd: i32 = 0;
                var ps = false;
                for (pair, 0..) |ch, j| {
                    if (ps) {
                        if (ch == '\\') {
                            // skip next in string handled by loop
                        } else if (ch == '"') ps = false;
                    } else {
                        switch (ch) {
                            '"' => ps = true,
                            '(', '[', '{' => pd += 1,
                            ')', ']', '}' => pd -= 1,
                            ':' => if (pd == 0) {
                                colon_pos = j;
                                break;
                            },
                            else => {},
                        }
                    }
                }

                if (colon_pos) |cp| {
                    var key_part = std.mem.trim(u8, pair[0..cp], " ");
                    const val_part = std.mem.trim(u8, pair[cp + 1 ..], " ");

                    // Resolve key
                    var key_str: []const u8 = "";
                    if (key_part.len >= 2 and key_part[0] == '"' and key_part[key_part.len - 1] == '"') {
                        key_str = key_part[1 .. key_part.len - 1];
                    } else {
                        // Evaluate as filter to get key
                        var key_results = std.ArrayListUnmanaged(std.json.Value).empty;
                        defer key_results.deinit(allocator);
                        evaluateFilter(allocator, value, key_part, &key_results) catch return false;
                        if (key_results.items.len > 0) {
                            switch (key_results.items[0]) {
                                .string => |s| key_str = s,
                                else => return false,
                            }
                        }
                    }

                    // Resolve value
                    var val_results = std.ArrayListUnmanaged(std.json.Value).empty;
                    defer val_results.deinit(allocator);
                    evaluateFilter(allocator, value, val_part, &val_results) catch return false;
                    if (val_results.items.len > 0) {
                        obj.put(key_str, val_results.items[0]) catch return true;
                    }
                } else {
                    // Shorthand: just a key name means {key: .key}
                    if (pair.len >= 2 and pair[0] == '"' and pair[pair.len - 1] == '"') {
                        const k = pair[1 .. pair.len - 1];
                        switch (value) {
                            .object => |vobj| {
                                obj.put(k, vobj.get(k) orelse .null) catch return true;
                            },
                            else => obj.put(k, .null) catch return true,
                        }
                    } else {
                        // Bare key shorthand
                        switch (value) {
                            .object => |vobj| {
                                obj.put(pair, vobj.get(pair) orelse .null) catch return true;
                            },
                            else => obj.put(pair, .null) catch return true,
                        }
                    }
                }
            }
            start = i + 1;
        } else if (in_string) {
            if (inner[i] == '\\') {
                i += 1; // skip
            } else if (inner[i] == '"') {
                in_string = false;
            }
        } else {
            switch (inner[i]) {
                '"' => in_string = true,
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -= 1,
                else => {},
            }
        }
    }

    results.append(allocator, .{ .object = obj }) catch return true;
    return true;
}

fn tryComparisonOp(allocator: std.mem.Allocator, value: std.json.Value, filter: []const u8, results: *std.ArrayListUnmanaged(std.json.Value)) bool {
    const ops = [_]struct { op: []const u8, id: u8 }{
        .{ .op = "==", .id = 0 },
        .{ .op = "!=", .id = 1 },
        .{ .op = "<=", .id = 4 },
        .{ .op = ">=", .id = 5 },
        .{ .op = "<", .id = 2 },
        .{ .op = ">", .id = 3 },
    };

    for (ops) |op_info| {
        if (findTopLevelOp(filter, op_info.op)) |op_pos| {
            const left = std.mem.trim(u8, filter[0..op_pos], " ");
            const right = std.mem.trim(u8, filter[op_pos + op_info.op.len ..], " ");

            var left_results = std.ArrayListUnmanaged(std.json.Value).empty;
            defer left_results.deinit(allocator);
            var right_results = std.ArrayListUnmanaged(std.json.Value).empty;
            defer right_results.deinit(allocator);

            evaluateFilter(allocator, value, left, &left_results) catch return false;
            evaluateFilter(allocator, value, right, &right_results) catch return false;

            if (left_results.items.len == 0 or right_results.items.len == 0) return false;

            const l = left_results.items[0];
            const r = right_results.items[0];

            const result: bool = switch (op_info.id) {
                0 => jsonEqual(l, r),
                1 => !jsonEqual(l, r),
                2 => jsonLessThan({}, l, r),
                3 => jsonLessThan({}, r, l),
                4 => jsonEqual(l, r) or jsonLessThan({}, l, r),
                5 => jsonEqual(l, r) or jsonLessThan({}, r, l),
                else => false,
            };

            results.append(allocator, .{ .bool = result }) catch return true;
            return true;
        }
    }
    return false;
}

fn tryArithmeticOp(allocator: std.mem.Allocator, value: std.json.Value, filter: []const u8, results: *std.ArrayListUnmanaged(std.json.Value)) bool {
    // Check +, -, *, /, % at top level (respecting precedence: + and - last)
    const low_ops = [_]struct { op: []const u8, id: u8 }{
        .{ .op = "+", .id = 0 },
        .{ .op = "-", .id = 1 },
    };
    const high_ops = [_]struct { op: []const u8, id: u8 }{
        .{ .op = "*", .id = 2 },
        .{ .op = "/", .id = 3 },
        .{ .op = "%", .id = 4 },
    };

    // Try low precedence first (they bind less tightly)
    for (low_ops) |op_info| {
        if (findTopLevelOp(filter, op_info.op)) |op_pos| {
            // Avoid matching negative numbers at start
            if (op_info.id == 1 and op_pos == 0) continue;
            const left = std.mem.trim(u8, filter[0..op_pos], " ");
            const right = std.mem.trim(u8, filter[op_pos + op_info.op.len ..], " ");
            if (left.len == 0) continue; // unary minus or empty

            return doArithmetic(allocator, value, left, right, op_info.id, results);
        }
    }
    for (high_ops) |op_info| {
        if (findTopLevelOp(filter, op_info.op)) |op_pos| {
            const left = std.mem.trim(u8, filter[0..op_pos], " ");
            const right = std.mem.trim(u8, filter[op_pos + op_info.op.len ..], " ");
            if (left.len == 0) continue;

            return doArithmetic(allocator, value, left, right, op_info.id, results);
        }
    }
    return false;
}

fn doArithmetic(allocator: std.mem.Allocator, value: std.json.Value, left: []const u8, right: []const u8, op: u8, results: *std.ArrayListUnmanaged(std.json.Value)) bool {
    var left_results = std.ArrayListUnmanaged(std.json.Value).empty;
    defer left_results.deinit(allocator);
    var right_results = std.ArrayListUnmanaged(std.json.Value).empty;
    defer right_results.deinit(allocator);

    evaluateFilter(allocator, value, left, &left_results) catch return false;
    evaluateFilter(allocator, value, right, &right_results) catch return false;

    if (left_results.items.len == 0 or right_results.items.len == 0) return false;

    const l = left_results.items[0];
    const r = right_results.items[0];

    // String concatenation with +
    if (op == 0) {
        const l_str = switch (l) {
            .string => true,
            else => false,
        };
        const r_str = switch (r) {
            .string => true,
            else => false,
        };
        if (l_str and r_str) {
            const ls = switch (l) {
                .string => |s| s,
                else => unreachable,
            };
            const rs = switch (r) {
                .string => |s| s,
                else => unreachable,
            };
            const concat = allocator.alloc(u8, ls.len + rs.len) catch return true;
            @memcpy(concat[0..ls.len], ls);
            @memcpy(concat[ls.len..], rs);
            results.append(allocator, .{ .string = concat }) catch return true;
            return true;
        }
    }

    const ln = jsonToNumber(l) orelse return false;
    const rn = jsonToNumber(r) orelse return false;

    // Check if both are integers
    const l_int = switch (l) {
        .integer => true,
        else => false,
    };
    const r_int = switch (r) {
        .integer => true,
        else => false,
    };

    if (l_int and r_int) {
        const li = switch (l) {
            .integer => |n| n,
            else => unreachable,
        };
        const ri = switch (r) {
            .integer => |n| n,
            else => unreachable,
        };
        const result: i64 = switch (op) {
            0 => li + ri,
            1 => li - ri,
            2 => li * ri,
            3 => if (ri != 0) @divTrunc(li, ri) else 0,
            4 => if (ri != 0) @rem(li, ri) else 0,
            else => 0,
        };
        results.append(allocator, .{ .integer = result }) catch return true;
    } else {
        const result: f64 = switch (op) {
            0 => ln + rn,
            1 => ln - rn,
            2 => ln * rn,
            3 => if (rn != 0) ln / rn else 0,
            4 => if (rn != 0) @mod(ln, rn) else 0,
            else => 0,
        };
        results.append(allocator, .{ .float = result }) catch return true;
    }
    return true;
}

fn tryLogicalOp(allocator: std.mem.Allocator, value: std.json.Value, filter: []const u8, results: *std.ArrayListUnmanaged(std.json.Value)) bool {
    // " and " / " or "
    if (findTopLevelKeyword(filter, " and ")) |pos| {
        const left = std.mem.trim(u8, filter[0..pos], " ");
        const right = std.mem.trim(u8, filter[pos + 5 ..], " ");

        var left_results = std.ArrayListUnmanaged(std.json.Value).empty;
        defer left_results.deinit(allocator);
        evaluateFilter(allocator, value, left, &left_results) catch return false;

        if (left_results.items.len == 0) return false;
        if (!jsonTruthy(left_results.items[0])) {
            results.append(allocator, .{ .bool = false }) catch return true;
            return true;
        }

        var right_results = std.ArrayListUnmanaged(std.json.Value).empty;
        defer right_results.deinit(allocator);
        evaluateFilter(allocator, value, right, &right_results) catch return false;

        if (right_results.items.len > 0) {
            results.append(allocator, .{ .bool = jsonTruthy(right_results.items[0]) }) catch return true;
        }
        return true;
    }

    if (findTopLevelKeyword(filter, " or ")) |pos| {
        const left = std.mem.trim(u8, filter[0..pos], " ");
        const right = std.mem.trim(u8, filter[pos + 4 ..], " ");

        var left_results = std.ArrayListUnmanaged(std.json.Value).empty;
        defer left_results.deinit(allocator);
        evaluateFilter(allocator, value, left, &left_results) catch return false;

        if (left_results.items.len > 0 and jsonTruthy(left_results.items[0])) {
            results.append(allocator, .{ .bool = true }) catch return true;
            return true;
        }

        var right_results = std.ArrayListUnmanaged(std.json.Value).empty;
        defer right_results.deinit(allocator);
        evaluateFilter(allocator, value, right, &right_results) catch return false;

        if (right_results.items.len > 0) {
            results.append(allocator, .{ .bool = jsonTruthy(right_results.items[0]) }) catch return true;
        }
        return true;
    }

    return false;
}

fn tryAlternativeOp(allocator: std.mem.Allocator, value: std.json.Value, filter: []const u8, results: *std.ArrayListUnmanaged(std.json.Value)) bool {
    // "//" alternative operator
    if (findTopLevelOp(filter, "//")) |pos| {
        const left = std.mem.trim(u8, filter[0..pos], " ");
        const right = std.mem.trim(u8, filter[pos + 2 ..], " ");

        var left_results = std.ArrayListUnmanaged(std.json.Value).empty;
        defer left_results.deinit(allocator);
        evaluateFilter(allocator, value, left, &left_results) catch {
            // Left failed, use right
            evaluateFilter(allocator, value, right, results) catch return false;
            return true;
        };

        if (left_results.items.len > 0) {
            const lv = left_results.items[0];
            switch (lv) {
                .null => {},
                .bool => |b| if (!b) {} else {
                    results.append(allocator, lv) catch return true;
                    return true;
                },
                else => {
                    results.append(allocator, lv) catch return true;
                    return true;
                },
            }
        }

        // Fall through to right
        evaluateFilter(allocator, value, right, results) catch return false;
        return true;
    }
    return false;
}

fn parseIfThenElse(allocator: std.mem.Allocator, value: std.json.Value, filter: []const u8, results: *std.ArrayListUnmanaged(std.json.Value)) bool {
    // Simple: if COND then EXPR else EXPR end
    // or: if COND then EXPR end
    const after_if = filter[3..];

    const then_pos = findTopLevelKeyword(after_if, " then ") orelse return false;
    const cond = std.mem.trim(u8, after_if[0..then_pos], " ");
    const after_then = after_if[then_pos + 6 ..];

    var cond_results = std.ArrayListUnmanaged(std.json.Value).empty;
    defer cond_results.deinit(allocator);
    evaluateFilter(allocator, value, cond, &cond_results) catch return false;

    const is_truthy = if (cond_results.items.len > 0) jsonTruthy(cond_results.items[0]) else false;

    if (findTopLevelKeyword(after_then, " else ")) |else_pos| {
        const then_expr = std.mem.trim(u8, after_then[0..else_pos], " ");
        var end_expr = std.mem.trim(u8, after_then[else_pos + 6 ..], " ");
        // Strip trailing " end"
        if (std.mem.endsWith(u8, end_expr, " end")) {
            end_expr = end_expr[0 .. end_expr.len - 4];
        } else if (std.mem.eql(u8, end_expr, "end")) {
            end_expr = ".";
        }

        if (is_truthy) {
            evaluateFilter(allocator, value, then_expr, results) catch return false;
        } else {
            evaluateFilter(allocator, value, end_expr, results) catch return false;
        }
    } else {
        // No else
        var then_expr = std.mem.trim(u8, after_then, " ");
        if (std.mem.endsWith(u8, then_expr, " end")) {
            then_expr = then_expr[0 .. then_expr.len - 4];
        } else if (std.mem.eql(u8, then_expr, "end")) {
            then_expr = ".";
        }

        if (is_truthy) {
            evaluateFilter(allocator, value, then_expr, results) catch return false;
        } else {
            results.append(allocator, value) catch return true;
        }
    }
    return true;
}

/// Find a top-level occurrence of an operator (not inside brackets/strings)
fn findTopLevelOp(filter: []const u8, op: []const u8) ?usize {
    if (filter.len < op.len) return null;
    var depth: i32 = 0;
    var in_string = false;
    // Search from right to left for left-associativity
    var i: usize = filter.len;
    while (i >= op.len) {
        i -= 1;
        const ch = filter[i];
        // We're scanning backwards
        if (in_string) {
            if (ch == '"' and (i == 0 or filter[i - 1] != '\\')) {
                in_string = false;
            }
        } else {
            switch (ch) {
                '"' => in_string = true,
                ')', ']', '}' => depth += 1,
                '(', '[', '{' => depth -= 1,
                else => {
                    if (depth == 0 and i + op.len <= filter.len) {
                        if (std.mem.eql(u8, filter[i .. i + op.len], op)) {
                            // For "//", make sure we don't match a longer operator
                            // For single char ops, check it's not part of a longer op
                            if (op.len == 1) {
                                // Don't match '=' inside '==' or '!=' etc
                                if (op[0] == '=' and i > 0 and (filter[i - 1] == '!' or filter[i - 1] == '<' or filter[i - 1] == '>')) continue;
                                if (op[0] == '=' and i + 1 < filter.len and filter[i + 1] == '=') continue;
                                if (op[0] == '<' and i + 1 < filter.len and filter[i + 1] == '=') continue;
                                if (op[0] == '>' and i + 1 < filter.len and filter[i + 1] == '=') continue;
                                // Don't match '-' when it looks like a negative number
                                if (op[0] == '-' and i > 0) {
                                    // Check if preceded by an operator-like char
                                    const prev = filter[i - 1];
                                    if (prev == '(' or prev == '[' or prev == ',' or prev == ':') continue;
                                }
                            }
                            return i;
                        }
                    }
                },
            }
        }
    }
    return null;
}

/// Find a top-level keyword (surrounded by context, not in strings/brackets)
fn findTopLevelKeyword(filter: []const u8, keyword: []const u8) ?usize {
    if (filter.len < keyword.len) return null;
    var depth: i32 = 0;
    var in_string = false;
    var i: usize = 0;
    while (i + keyword.len <= filter.len) : (i += 1) {
        if (in_string) {
            if (filter[i] == '\\') {
                i += 1;
            } else if (filter[i] == '"') {
                in_string = false;
            }
        } else {
            switch (filter[i]) {
                '"' => in_string = true,
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -= 1,
                else => {
                    if (depth == 0 and std.mem.eql(u8, filter[i .. i + keyword.len], keyword)) {
                        return i;
                    }
                },
            }
        }
    }
    return null;
}

// Helper functions

fn jsonTruthy(value: std.json.Value) bool {
    return switch (value) {
        .null => false,
        .bool => |b| b,
        else => true,
    };
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    const tag_a = @intFromEnum(std.meta.activeTag(a));
    const tag_b = @intFromEnum(std.meta.activeTag(b));

    // Handle number comparisons across integer/float
    const a_num = jsonToNumber(a);
    const b_num = jsonToNumber(b);
    if (a_num != null and b_num != null) {
        return a_num.? == b_num.?;
    }

    if (tag_a != tag_b) return false;

    return switch (a) {
        .null => true,
        .bool => |ab| ab == (switch (b) {
            .bool => |bb| bb,
            else => unreachable,
        }),
        .integer => |ai| ai == (switch (b) {
            .integer => |bi| bi,
            else => unreachable,
        }),
        .float => |af| af == (switch (b) {
            .float => |bf| bf,
            else => unreachable,
        }),
        .string => |as_str| std.mem.eql(u8, as_str, switch (b) {
            .string => |bs| bs,
            else => unreachable,
        }),
        else => false, // Arrays/objects: simplified
    };
}

fn jsonLessThan(_: void, a: std.json.Value, b: std.json.Value) bool {
    const a_num = jsonToNumber(a);
    const b_num = jsonToNumber(b);
    if (a_num != null and b_num != null) {
        return a_num.? < b_num.?;
    }

    // String comparison
    const a_str: ?[]const u8 = switch (a) {
        .string => |s| s,
        else => null,
    };
    const b_str: ?[]const u8 = switch (b) {
        .string => |s| s,
        else => null,
    };
    if (a_str != null and b_str != null) {
        return std.mem.lessThan(u8, a_str.?, b_str.?);
    }

    // Type ordering: null < false < true < number < string < array < object
    return jsonTypeOrder(a) < jsonTypeOrder(b);
}

fn jsonTypeOrder(value: std.json.Value) u8 {
    return switch (value) {
        .null => 0,
        .bool => |b| if (b) 2 else 1,
        .integer, .float, .number_string => 3,
        .string => 4,
        .array => 5,
        .object => 6,
    };
}

fn jsonToNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

fn jsonContains(haystack: std.json.Value, needle: std.json.Value) bool {
    return switch (needle) {
        .null => switch (haystack) {
            .null => true,
            else => false,
        },
        .bool => |nb| switch (haystack) {
            .bool => |hb| hb == nb,
            else => false,
        },
        .integer, .float => jsonEqual(haystack, needle),
        .string => |ns| switch (haystack) {
            .string => |hs| std.mem.indexOf(u8, hs, ns) != null,
            else => false,
        },
        .array => |narr| switch (haystack) {
            .array => |harr| blk: {
                for (narr.items) |nitem| {
                    var found = false;
                    for (harr.items) |hitem| {
                        if (jsonContains(hitem, nitem)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |nobj| switch (haystack) {
            .object => |hobj| blk: {
                var iter = nobj.iterator();
                while (iter.next()) |entry| {
                    const hval = hobj.get(entry.key_ptr.*) orelse break :blk false;
                    if (!jsonContains(hval, entry.value_ptr.*)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        else => false,
    };
}

fn flattenArray(allocator: std.mem.Allocator, items: []const std.json.Value, out: *std.json.Array, depth: usize) void {
    for (items) |item| {
        switch (item) {
            .array => |sub| {
                if (depth > 0) {
                    flattenArray(allocator, sub.items, out, depth - 1);
                } else {
                    out.append(item) catch return;
                }
            },
            else => out.append(item) catch return,
        }
    }
}

fn minMaxBy(allocator: std.mem.Allocator, value: std.json.Value, inner: []const u8, results: *std.ArrayListUnmanaged(std.json.Value), is_min: bool) bool {
    switch (value) {
        .array => |arr| {
            if (arr.items.len == 0) {
                results.append(allocator, .null) catch return true;
                return true;
            }
            var best = arr.items[0];
            var best_key: std.json.Value = .null;
            {
                var sub = std.ArrayListUnmanaged(std.json.Value).empty;
                defer sub.deinit(allocator);
                evaluateFilter(allocator, arr.items[0], inner, &sub) catch {};
                if (sub.items.len > 0) best_key = sub.items[0];
            }
            for (arr.items[1..]) |item| {
                var sub = std.ArrayListUnmanaged(std.json.Value).empty;
                defer sub.deinit(allocator);
                evaluateFilter(allocator, item, inner, &sub) catch continue;
                if (sub.items.len > 0) {
                    const key = sub.items[0];
                    if (is_min and jsonLessThan({}, key, best_key)) {
                        best = item;
                        best_key = key;
                    } else if (!is_min and jsonLessThan({}, best_key, key)) {
                        best = item;
                        best_key = key;
                    }
                }
            }
            results.append(allocator, best) catch return true;
            return true;
        },
        else => return false,
    }
}

fn jsonToString(allocator: std.mem.Allocator, value: std.json.Value, buf: *[4096]u8) []const u8 {
    _ = allocator;
    return switch (value) {
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "?",
        .float => |f| std.fmt.bufPrint(buf, "{d}", .{f}) catch "?",
        .string => |s| s,
        else => "<complex>",
    };
}

fn outputValue(allocator: std.mem.Allocator, value: std.json.Value, ctx: *OutputContext, depth: usize) void {
    if (ctx.options.raw_output) {
        switch (value) {
            .string => |s| {
                writeStdoutRaw(s);
                if (!ctx.options.join_output) {
                    writeStdout("\n", .{});
                }
            },
            else => {
                outputJson(allocator, value, ctx, depth);
            },
        }
    } else {
        outputJson(allocator, value, ctx, depth);
    }
}

fn outputJson(allocator: std.mem.Allocator, value: std.json.Value, ctx: *OutputContext, depth: usize) void {
    switch (value) {
        .null => {
            if (ctx.use_color) writeStdoutRaw(Color.null_color);
            writeStdout("null", .{});
            if (ctx.use_color) writeStdoutRaw(Color.reset);
        },
        .bool => |b| {
            if (ctx.use_color) writeStdoutRaw(Color.bool_color);
            writeStdout("{s}", .{if (b) "true" else "false"});
            if (ctx.use_color) writeStdoutRaw(Color.reset);
        },
        .integer => |n| {
            if (ctx.use_color) writeStdoutRaw(Color.number_color);
            writeStdout("{d}", .{n});
            if (ctx.use_color) writeStdoutRaw(Color.reset);
        },
        .float => |f| {
            if (ctx.use_color) writeStdoutRaw(Color.number_color);
            writeStdout("{d}", .{f});
            if (ctx.use_color) writeStdoutRaw(Color.reset);
        },
        .string => |s| {
            if (ctx.use_color) writeStdoutRaw(Color.string_color);
            outputEscapedString(s);
            if (ctx.use_color) writeStdoutRaw(Color.reset);
        },
        .array => |arr| {
            if (arr.items.len == 0) {
                writeStdout("[]", .{});
            } else if (ctx.options.compact) {
                writeStdout("[", .{});
                for (arr.items, 0..) |item, i| {
                    if (i > 0) writeStdout(",", .{});
                    outputJson(allocator, item, ctx, depth + 1);
                }
                writeStdout("]", .{});
            } else {
                writeStdout("[\n", .{});
                for (arr.items, 0..) |item, i| {
                    outputIndent(ctx, depth + 1);
                    outputJson(allocator, item, ctx, depth + 1);
                    if (i < arr.items.len - 1) {
                        writeStdout(",", .{});
                    }
                    writeStdout("\n", .{});
                }
                outputIndent(ctx, depth);
                writeStdout("]", .{});
            }
        },
        .object => |obj| {
            if (obj.count() == 0) {
                writeStdoutRaw("{}");
            } else if (ctx.options.compact) {
                writeStdoutRaw("{");
                var first = true;
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    if (!first) writeStdoutRaw(",");
                    first = false;
                    if (ctx.use_color) writeStdoutRaw(Color.key_color);
                    outputEscapedString(entry.key_ptr.*);
                    if (ctx.use_color) writeStdoutRaw(Color.reset);
                    writeStdoutRaw(":");
                    outputJson(allocator, entry.value_ptr.*, ctx, depth + 1);
                }
                writeStdoutRaw("}");
            } else {
                writeStdoutRaw("{\n");
                var iter = obj.iterator();
                var count: usize = 0;
                const total = obj.count();
                while (iter.next()) |entry| {
                    outputIndent(ctx, depth + 1);
                    if (ctx.use_color) writeStdoutRaw(Color.key_color);
                    outputEscapedString(entry.key_ptr.*);
                    if (ctx.use_color) writeStdoutRaw(Color.reset);
                    writeStdoutRaw(": ");
                    outputJson(allocator, entry.value_ptr.*, ctx, depth + 1);
                    count += 1;
                    if (count < total) {
                        writeStdoutRaw(",");
                    }
                    writeStdoutRaw("\n");
                }
                outputIndent(ctx, depth);
                writeStdoutRaw("}");
            }
        },
        .number_string => |s| {
            if (ctx.use_color) writeStdoutRaw(Color.number_color);
            writeStdoutRaw(s);
            if (ctx.use_color) writeStdoutRaw(Color.reset);
        },
    }

    if (depth == 0) {
        writeStdout("\n", .{});
    }
}

fn outputIndent(ctx: *OutputContext, depth: usize) void {
    for (0..depth) |_| {
        writeStdoutRaw(ctx.indent_str);
    }
}

fn outputEscapedString(s: []const u8) void {
    writeStdout("\"", .{});
    for (s) |c| {
        switch (c) {
            '"' => writeStdoutRaw("\\\""),
            '\\' => writeStdoutRaw("\\\\"),
            '\n' => writeStdoutRaw("\\n"),
            '\r' => writeStdoutRaw("\\r"),
            '\t' => writeStdoutRaw("\\t"),
            else => {
                if (c < 0x20) {
                    const hex_chars = "0123456789ABCDEF";
                    var hex_buf: [6]u8 = .{ '\\', 'u', '0', '0', hex_chars[c >> 4], hex_chars[c & 0xF] };
                    writeStdoutRaw(&hex_buf);
                } else {
                    var buf: [1]u8 = .{c};
                    writeStdoutRaw(&buf);
                }
            },
        }
    }
    writeStdout("\"", .{});
}

fn printHelp() void {
    writeStdout(
        \\Usage: zjq [OPTIONS] [FILTER] [FILE...]
        \\
        \\JSON query and manipulation tool.
        \\
        \\Options:
        \\  -c, --compact-output    Compact output (no pretty-print)
        \\  -r, --raw-output        Raw output for strings (no quotes)
        \\  -R, --raw-input         Read input as raw strings
        \\  -s, --slurp             Read all inputs into an array
        \\  -S, --sort-keys         Sort object keys
        \\  -M, --monochrome-output Disable colored output
        \\  -n, --null-input        Use null as input
        \\  -e, --exit-status       Set exit status based on output
        \\  -j, --join-output       No newline after raw output
        \\      --tab               Use tabs for indentation
        \\  -h, --help              Display this help
        \\      --version           Show version
        \\
        \\Filter syntax:
        \\  .                       Identity (entire input)
        \\  .foo                    Object field access
        \\  .foo.bar                Nested field access
        \\  .[0]                    Array index
        \\  .[-1]                   Negative array index (from end)
        \\  .[]                     Iterate array/object values
        \\  .foo[]                  Iterate array field
        \\  ."foo-bar"              Quoted field name
        \\  f | g                   Pipe (compose filters)
        \\  f, g                    Multiple outputs
        \\
        \\Built-in functions:
        \\  length, keys, values, type, has(k), contains(v),
        \\  select(f), map(f), map_values(f), sort, sort_by(f),
        \\  group_by(f), unique, unique_by(f), flatten, reverse,
        \\  add, any, all, min, max, first, last, range(n),
        \\  tostring, tonumber, ascii_downcase, ascii_upcase,
        \\  to_entries, from_entries, with_entries(f),
        \\  split(s), join(s), test(s), startswith(s), endswith(s),
        \\  ltrimstr(s), rtrimstr(s), not, empty, debug,
        \\  if-then-else, and, or, //, +, -, *, /, ==, !=, <, >
        \\
        \\Examples:
        \\  echo '{{"name":"john"}}' | zjq .name
        \\  zjq '.users[0].email' data.json
        \\  zjq -c . data.json              # Compact output
        \\  zjq -r '.items[].id' data.json  # Raw string output
        \\  printf '{{"a":1}}\n{{"b":2}}' | zjq .  # NDJSON support
        \\
    , .{});
}
