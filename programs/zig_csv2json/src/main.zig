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

    emit(&jw, format, lines, opts) catch |err| switch (err) {
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
    lines: []const []const u8,
    opts: Opts,
) !void {
    const allocator = jw.allocator;
    switch (format) {
        .lines => {
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
            const table = try parser.parseCsv(allocator, lines, delimiter, !opts.no_headers);

            try jw.beginArray();
            for (table.rows) |row| {
                try jw.beginObject();
                for (row, 0..) |value, col| {
                    const col_name = if (col < table.headers.len) table.headers[col] else "?";
                    try jw.key(col_name);
                    if (opts.numbers and parser.isNumeric(value)) {
                        try jw.number(value);
                    } else {
                        try jw.string(value);
                    }
                }
                try jw.endObject();
            }
            try jw.endArray();
        },
        .kv => {
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
