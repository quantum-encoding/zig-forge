// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! zig-csv2json: CSV / TSV / key-value → JSON CLI formatter.
//!
//! Reads structured text (CSV, TSV, `key: value` lines, or one-string-per-
//! line) from a file or stdin, auto-detects the format, and writes a JSON
//! document to stdout or a chosen file.
//!
//! This tool ONLY writes JSON. It does NOT read JSON — see CLAUDE.md at the
//! repo root for the rule that named this `zig_csv2json` rather than the
//! original misleading `zig_json`.

const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const json_writer = @import("json_writer.zig");
const JsonWriter = json_writer.JsonWriter;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // ------------------------------------------------------------------
    // Args
    // ------------------------------------------------------------------
    const args = try init.minimal.args.toSlice(allocator);
    const opts = parseArgs(args, stderr, stdout) catch |err| switch (err) {
        error.ShowedHelp => {
            try stdout.flush();
            return 0;
        },
        error.BadArgs => {
            try stderr.flush();
            return 2;
        },
        else => return err,
    };

    // ------------------------------------------------------------------
    // Read input
    // ------------------------------------------------------------------
    const data = if (opts.file_path) |path|
        Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
            try stderr.print("Error: failed to read '{s}': {s}\n", .{ path, @errorName(err) });
            try stderr.flush();
            return 1;
        }
    else
        try readStdin(io, allocator);

    if (data.len == 0) {
        try stderr.writeAll("Error: empty input\n");
        try stderr.flush();
        return 1;
    }

    const lines = try parser.splitIntoLines(allocator, data);
    if (lines.len == 0) {
        try stderr.writeAll("Error: no non-empty lines in input\n");
        try stderr.flush();
        return 1;
    }

    const format = opts.format orelse parser.detect(lines);

    // ------------------------------------------------------------------
    // Choose output sink
    // ------------------------------------------------------------------
    // We write through a JsonWriter wrapping either stdout or a file Writer.
    // If --output is given, the file writer is created here and closed at
    // function exit; otherwise stdout is reused.
    var out_file: ?Io.File = null;
    defer if (out_file) |f| f.close(io);

    var out_buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = undefined;
    const out: *Io.Writer = if (opts.output_path) |path| blk: {
        const f = try Io.Dir.cwd().createFile(io, path, .{});
        out_file = f;
        file_writer = f.writer(io, &out_buffer);
        break :blk &file_writer.interface;
    } else stdout;

    // Show detected format on stderr if auto-detected (after sink is ready
    // so the user sees the format hint before any JSON output).
    if (opts.format == null) {
        try stderr.print("[auto-detected: {s}]\n", .{format.name()});
        try stderr.flush();
    }

    var jw = JsonWriter.init(allocator, out, opts.pretty);
    defer jw.deinit();

    emit(&jw, format, data, opts) catch |err| switch (err) {
        error.UnclosedQuote => {
            try stderr.writeAll("Error: malformed CSV — unclosed quoted field\n");
            try stderr.flush();
            return 1;
        },
        error.InvalidNumber => {
            // Should be impossible: --numbers gates writes by isNumeric.
            // If it ever fires it's a parser/writer grammar disagreement —
            // surface it loudly rather than silently truncating output.
            try stderr.writeAll("Error: internal grammar mismatch — please file a bug\n");
            try stderr.flush();
            return 1;
        },
        else => return err,
    };
    try jw.newline();

    if (!jw.isBalanced()) {
        // Programming error in the emit functions, not user-visible. Should
        // never happen; failing loudly here beats producing half-valid JSON.
        try stderr.writeAll("Error: internal — JSON document closed with unbalanced containers\n");
        try stderr.flush();
        return 1;
    }

    try out.flush();
    return 0;
}

fn emit(
    jw: *JsonWriter,
    format: parser.Format,
    data: []const u8,
    opts: Opts,
) !void {
    const allocator = jw.allocator;
    switch (format) {
        .lines => {
            const lines = try parser.splitIntoLines(allocator, data);
            const items = try parser.parseLines(allocator, lines);
            try jw.beginArray();
            for (items) |item| {
                if (opts.numbers and parser.isNumeric(item)) {
                    try jw.number(item);
                } else {
                    try jw.string(item);
                }
            }
            try jw.endArray();
        },
        .csv, .tsv => {
            const delimiter: u8 = if (format == .tsv) '\t' else ',';
            // Quote-aware record split (RFC 4180 §2.6): a newline inside a
            // quoted field stays part of the record instead of erroring.
            const records = try parser.splitIntoRecords(allocator, data);
            const table = try parser.parseCsv(allocator, records, delimiter, !opts.no_headers);

            try jw.beginArray();
            for (table.rows) |row| {
                try jw.beginObject();
                // Ragged rows: emit one key per column across the wider of the
                // header count and this row's field count. Extra columns beyond
                // the header get a synthetic `col{N}` name (reusing parseCsv's
                // no-header convention) instead of duplicate ambiguous `"?"`
                // keys; trailing columns absent from a short row are emitted as
                // JSON `null` so a consumer can tell "absent" from "empty".
                const width = @max(row.len, table.headers.len);
                for (0..width) |col| {
                    if (col < table.headers.len) {
                        try jw.key(table.headers[col]);
                    } else {
                        try jw.key(try std.fmt.allocPrint(allocator, "col{d}", .{col}));
                    }
                    if (col < row.len) {
                        const value = row[col];
                        if (opts.numbers and parser.isNumeric(value)) {
                            try jw.number(value);
                        } else {
                            try jw.string(value);
                        }
                    } else {
                        try jw.writeNull();
                    }
                }
                try jw.endObject();
            }
            try jw.endArray();
        },
        .kv => {
            const lines = try parser.splitIntoLines(allocator, data);
            const kv = try parser.parseKv(allocator, lines);
            try jw.beginObject();
            for (kv.keys, kv.values) |k, v| {
                try jw.key(k);
                if (opts.numbers and parser.isNumeric(v)) {
                    try jw.number(v);
                } else {
                    try jw.string(v);
                }
            }
            try jw.endObject();
        },
    }
}

fn readStdin(io: Io, allocator: std.mem.Allocator) ![]u8 {
    var read_buf: [4096]u8 = undefined;
    const stdin = Io.File.stdin();
    var reader = stdin.readerStreaming(io, &read_buf);
    var sink: Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    _ = try reader.interface.streamRemaining(&sink.writer);
    return try sink.toOwnedSlice();
}

// ------------------------------------------------------------------------
// Argument parsing
// ------------------------------------------------------------------------

const Opts = struct {
    file_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    format: ?parser.Format = null,
    pretty: bool = false,
    no_headers: bool = false,
    numbers: bool = false,
};

const ArgError = error{ ShowedHelp, BadArgs } || std.Io.Writer.Error;

fn parseArgs(
    args: []const []const u8,
    stderr: *Io.Writer,
    stdout: *Io.Writer,
) ArgError!Opts {
    var result = Opts{};

    var i: usize = 1; // skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(stdout);
            return ArgError.ShowedHelp;
        } else if (std.mem.eql(u8, arg, "--pretty") or std.mem.eql(u8, arg, "-p")) {
            result.pretty = true;
        } else if (std.mem.eql(u8, arg, "--numbers") or std.mem.eql(u8, arg, "-n")) {
            result.numbers = true;
        } else if (std.mem.eql(u8, arg, "--no-headers")) {
            result.no_headers = true;
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("Error: --format requires a value (csv/tsv/kv/lines)\n");
                return ArgError.BadArgs;
            }
            result.format = parser.parseFormat(args[i]) orelse {
                try stderr.print("Error: unknown format '{s}'. Use: csv, tsv, kv, lines\n", .{args[i]});
                return ArgError.BadArgs;
            };
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("Error: -o/--output requires a file path\n");
                return ArgError.BadArgs;
            }
            result.output_path = args[i];
        } else if (std.mem.eql(u8, arg, "-")) {
            result.file_path = null; // explicit stdin
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            result.file_path = arg;
        } else {
            try stderr.print("Unknown option: {s}\n", .{arg});
            return ArgError.BadArgs;
        }
    }

    return result;
}

fn printHelp(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\zig-csv2json - CSV/TSV/key-value -> JSON formatter
        \\
        \\Usage:
        \\  zig-csv2json [file] [options]
        \\  cat data.csv | zig-csv2json [options]
        \\
        \\Options:
        \\  -f, --format <fmt>    Force format: csv, tsv, kv, lines
        \\  -o, --output <path>   Write JSON to file (default: stdout)
        \\  -p, --pretty          Pretty-print JSON output
        \\  -n, --numbers         Detect numeric values (output as JSON numbers,
        \\                        with RFC 8259 grammar — "007" stays a string)
        \\      --no-headers      CSV/TSV: treat first row as data, not headers
        \\  -h, --help            Show this help
        \\
        \\Auto-detection priority:
        \\  1. CSV  - lines with consistent comma count
        \\  2. TSV  - lines with consistent tab count
        \\  3. KV   - lines matching "key: value" or "key = value"
        \\  4. Lines - each line becomes a string in a JSON array
        \\
        \\This tool ONLY writes JSON. It does NOT parse JSON. See CLAUDE.md.
        \\
        \\Examples:
        \\  zig-csv2json names.txt                       # Auto-detect
        \\  zig-csv2json data.csv --pretty --numbers     # CSV with numbers
        \\  echo -e "name: Alice\nage: 30" | zig-csv2json
        \\  cat items.txt | zig-csv2json -f lines -p
        \\
    );
}

// ============================================================================
// Tests
//
// main.zig previously had ZERO coverage: parseArgs, emit, and the end-to-end
// CSV->JSON path were all untested. These tests drive `emit` through an
// in-memory sink and `parseArgs` through in-memory writers, so no real I/O is
// needed.
//
// Tier 1 (external cross-implementation anchor): the csv-spectrum corpus
// (github.com/maxogden/csv-spectrum) — the de-facto CSV golden set used to
// validate CSV parsers across languages. Each case pairs the fixture's exact
// `.csv` input with its exact expected `.json`. We render our JSON and compare
// it to the fixture's JSON *canonically* (both parsed by the independent
// std.json reader and re-serialized), so the assertion is semantic, not
// whitespace-sensitive — this is the anti-roundtrip-blindness anchor the
// golden rule requires, sourced from a different implementation's golden file.
// ============================================================================

const testing = std.testing;

/// Render `data` to JSON via the full emit pipeline into an in-memory sink.
fn renderToJson(a: std.mem.Allocator, format: parser.Format, data: []const u8, opts: Opts) ![]u8 {
    var sink: Io.Writer.Allocating = .init(a);
    var jw = JsonWriter.init(a, &sink.writer, opts.pretty);
    try emit(&jw, format, data, opts);
    return sink.toOwnedSlice();
}

/// Assert two JSON documents are semantically equal by parsing both with the
/// independent std.json reader and comparing their canonical re-serializations
/// (std.json preserves object key insertion order, which our emitter and the
/// fixtures share, so the canonical forms match iff the trees match).
fn expectJsonEquiv(a: std.mem.Allocator, mine: []const u8, expected: []const u8) !void {
    var pm = try std.json.parseFromSlice(std.json.Value, a, mine, .{});
    defer pm.deinit();
    var pe = try std.json.parseFromSlice(std.json.Value, a, expected, .{});
    defer pe.deinit();
    const canon_mine = try std.json.Stringify.valueAlloc(a, pm.value, .{});
    const canon_exp = try std.json.Stringify.valueAlloc(a, pe.value, .{});
    try testing.expectEqualStrings(canon_exp, canon_mine);
}

fn checkCsvCase(a: std.mem.Allocator, csv: []const u8, expected_json: []const u8) !void {
    const mine = try renderToJson(a, .csv, csv, .{});
    try expectJsonEquiv(a, mine, expected_json);
}

test "csv-spectrum: golden CSV->JSON fixtures (external cross-impl anchor)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // simple.csv
    try checkCsvCase(a, "a,b,c\n1,2,3\n",
        \\[{"a":"1","b":"2","c":"3"}]
    );
    // comma_in_quotes.csv — comma protected by quotes (no trailing newline).
    try checkCsvCase(a, "first,last,address,city,zip\nJohn,Doe,120 any st.,\"Anytown, WW\",08123",
        \\[{"first":"John","last":"Doe","address":"120 any st.","city":"Anytown, WW","zip":"08123"}]
    );
    // escaped_quotes.csv — doubled quotes unescape to a single quote (§2.7).
    try checkCsvCase(a, "a,b\n1,\"ha \"\"ha\"\" ha\"\n3,4\n",
        \\[{"a":"1","b":"ha \"ha\" ha"},{"a":"3","b":"4"}]
    );
    // newlines.csv — a bare LF inside a quoted field stays in the field (§2.6).
    try checkCsvCase(a, "a,b,c\n1,2,3\n\"Once upon \na time\",5,6\n7,8,9\n",
        \\[{"a":"1","b":"2","c":"3"},{"a":"Once upon \na time","b":"5","c":"6"},{"a":"7","b":"8","c":"9"}]
    );
    // quotes_and_newlines.csv — embedded newlines AND escaped quotes together.
    try checkCsvCase(a, "a,b\n1,\"ha \n\"\"ha\"\" \nha\"\n3,4\n",
        \\[{"a":"1","b":"ha \n\"ha\" \nha"},{"a":"3","b":"4"}]
    );
    // empty.csv — empty quoted fields become empty strings (no trailing newline).
    try checkCsvCase(a, "a,b,c\n1,\"\",\"\"\n2,3,4",
        \\[{"a":"1","b":"","c":""},{"a":"2","b":"3","c":"4"}]
    );
    // utf8.csv — multibyte content passes through verbatim (no trailing newline).
    try checkCsvCase(a, "a,b,c\n1,2,3\n4,5,ʤ",
        \\[{"a":"1","b":"2","c":"3"},{"a":"4","b":"5","c":"ʤ"}]
    );
}

test "emit: --numbers emits bare numbers but keeps 007 a string (RFC 8259 §6)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mine = try renderToJson(a, .csv, "id,code\n1,007\n2,42\n", .{ .numbers = true });
    try expectJsonEquiv(a, mine,
        \\[{"id":1,"code":"007"},{"id":2,"code":42}]
    );
}

test "emit: ragged CSV rows null-fill short rows and col{N}-name extras" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Header is 3 wide; row 2 is short (2 fields), row 3 is long (4 fields).
    const mine = try renderToJson(a, .csv, "a,b,c\n1,2\n1,2,3,4\n", .{});
    try expectJsonEquiv(a, mine,
        \\[{"a":"1","b":"2","c":null},{"a":"1","b":"2","c":"3","col3":"4"}]
    );
}

test "emit: kv and lines paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const kv = try renderToJson(a, .kv, "name: Alice\nage: 30\n", .{ .numbers = true });
    try expectJsonEquiv(a, kv,
        \\{"name":"Alice","age":30}
    );

    const lines = try renderToJson(a, .lines, "Alice\nBob\nCharlie\n", .{});
    try expectJsonEquiv(a, lines,
        \\["Alice","Bob","Charlie"]
    );
}

test "parseArgs: valid flags populate Opts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var err: Io.Writer.Allocating = .init(a);

    const args = [_][]const u8{ "prog", "data.csv", "-p", "-n", "--no-headers", "-f", "csv", "-o", "out.json" };
    const opts = try parseArgs(&args, &err.writer, &out.writer);
    try testing.expectEqualStrings("data.csv", opts.file_path.?);
    try testing.expectEqualStrings("out.json", opts.output_path.?);
    try testing.expectEqual(parser.Format.csv, opts.format.?);
    try testing.expect(opts.pretty);
    try testing.expect(opts.numbers);
    try testing.expect(opts.no_headers);
}

test "parseArgs: '-' selects stdin (file_path stays null)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var err: Io.Writer.Allocating = .init(a);

    const args = [_][]const u8{ "prog", "-" };
    const opts = try parseArgs(&args, &err.writer, &out.writer);
    try testing.expect(opts.file_path == null);
}

test "parseArgs: error paths return BadArgs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var err: Io.Writer.Allocating = .init(a);

    // Unknown flag.
    try testing.expectError(error.BadArgs, parseArgs(
        &[_][]const u8{ "prog", "--nope" },
        &err.writer,
        &out.writer,
    ));
    // -f with no value.
    try testing.expectError(error.BadArgs, parseArgs(
        &[_][]const u8{ "prog", "-f" },
        &err.writer,
        &out.writer,
    ));
    // -f with an unrecognized format.
    try testing.expectError(error.BadArgs, parseArgs(
        &[_][]const u8{ "prog", "-f", "yaml" },
        &err.writer,
        &out.writer,
    ));
    // -o with no value.
    try testing.expectError(error.BadArgs, parseArgs(
        &[_][]const u8{ "prog", "-o" },
        &err.writer,
        &out.writer,
    ));
}

test "parseArgs: --help returns ShowedHelp" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var err: Io.Writer.Allocating = .init(a);

    try testing.expectError(error.ShowedHelp, parseArgs(
        &[_][]const u8{ "prog", "--help" },
        &err.writer,
        &out.writer,
    ));
}
