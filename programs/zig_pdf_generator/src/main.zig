//! Zig PDF Generator CLI
//!
//! Command-line interface for generating PDFs from JSON input.
//! Supports four explicit, mutually exclusive template modes:
//!   --basic, --minimalist, --letter, --presentation
//!
//! Supports UNIX pipe composition:
//!   If input file is omitted, JSON is read from stdin.
//!   If output file is omitted, PDF binary bytes are written directly to stdout.

const std = @import("std");
const lib = @import("lib.zig");

const VERSION = "1.0.0";

// Global IO context from init
var global_io: std.Io = undefined;
var global_allocator: std.mem.Allocator = undefined;

const TemplateMode = enum {
    basic,
    minimalist,
    letter,
    presentation,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Store globals
    global_io = io;
    global_allocator = allocator;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Parser state
    var opt_basic = false;
    var opt_minimalist = false;
    var opt_letter = false;
    var opt_presentation = false;

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var pos_arg_count: usize = 0;

    // Loop starts at 1 to skip executable name
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage(stderr);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try stderr.print("zig-pdf-generator {s}\n", .{VERSION});
            try stderr.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--basic")) {
            opt_basic = true;
        } else if (std.mem.eql(u8, arg, "--minimalist")) {
            opt_minimalist = true;
        } else if (std.mem.eql(u8, arg, "--letter")) {
            opt_letter = true;
        } else if (std.mem.eql(u8, arg, "--presentation")) {
            opt_presentation = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("Error: Unrecognized flag '{s}'\n\n", .{arg});
            printUsage(stderr);
            std.process.exit(1);
        } else {
            // Positional argument
            if (pos_arg_count == 0) {
                input_path = arg;
                pos_arg_count += 1;
            } else if (pos_arg_count == 1) {
                output_path = arg;
                pos_arg_count += 1;
            } else {
                try stderr.writeAll("Error: Too many positional arguments. Max 2 expected: [input_file [output_file]]\n");
                try stderr.flush();
                std.process.exit(1);
            }
        }
    }

    // Arg Exclusivity Validation
    const basic_val: usize = if (opt_basic) 1 else 0;
    const minimalist_val: usize = if (opt_minimalist) 1 else 0;
    const letter_val: usize = if (opt_letter) 1 else 0;
    const presentation_val: usize = if (opt_presentation) 1 else 0;

    const total_flags = basic_val + minimalist_val + letter_val + presentation_val;
    if (total_flags > 1) {
        try stderr.writeAll("Error: Multiple template flags specified. Template flags (--basic, --minimalist, --letter, --presentation) are mutually exclusive.\n");
        try stderr.flush();
        std.process.exit(1);
    }

    // Resolve template mode (default is basic)
    const mode: TemplateMode = if (opt_minimalist)
        .minimalist
    else if (opt_letter)
        .letter
    else if (opt_presentation)
        .presentation
    else
        .basic;

    // Load JSON data (max 50MB)
    const json_data = readInputData(allocator, input_path, stderr) catch |err| {
        try stderr.print("Error: Failed to read input data: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(json_data);

    // Generate PDF bytes
    const pdf_bytes = generatePdfBytes(allocator, mode, json_data) catch |err| {
        try stderr.print("Error: PDF generation failed for mode --{s}: {s}\n", .{ @tagName(mode), @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(pdf_bytes);

    // Write output PDF bytes
    writeOutputData(output_path, pdf_bytes, stdout, stderr) catch |err| {
        try stderr.print("Error: Failed to write output data: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
}

fn printUsage(stderr: *std.Io.Writer) void {
    const usage =
        \\Zig PDF Generator CLI v1.0.0
        \\
        \\Usage:
        \\  pdf-gen [flags] [input_file [output_file]]
        \\
        \\If input_file is omitted, JSON is read from stdin.
        \\If output_file is omitted, compiled PDF bytes are written directly to stdout.
        \\
        \\Template Flags (Mutually Exclusive):
        \\  --basic           Standard invoice/receipt template (default)
        \\  --minimalist      Minimalist clean quote/invoice/handover template
        \\  --letter          Premium letter-style quote template with itemized estimation
        \\  --presentation    Freeform presentation/canvas-style template
        \\
        \\Other Flags:
        \\  -h, --help        Show this help message and exit
        \\  -v, --version     Show version information and exit
        \\
        \\
    ;
    stderr.writeAll(usage) catch {};
    stderr.flush() catch {};
}

fn readInputData(allocator: std.mem.Allocator, input_path: ?[]const u8, stderr: *std.Io.Writer) ![]const u8 {
    const io = global_io;
    if (input_path) |path| {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(50 * 1024 * 1024)) catch |err| {
            try stderr.print("Error: Cannot read input file '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        };
    } else {
        // Read from stdin (max 50MB) using streaming reader into an Allocating writer
        var read_buf: [4096]u8 = undefined;
        const stdin = std.Io.File.stdin();
        var reader = stdin.readerStreaming(io, &read_buf);
        var sink: std.Io.Writer.Allocating = .init(allocator);
        defer sink.deinit();
        
        _ = try reader.interface.streamRemaining(&sink.writer);
        const input_bytes = try sink.toOwnedSlice();
        if (input_bytes.len > 50 * 1024 * 1024) {
            allocator.free(input_bytes);
            return error.InputTooLarge;
        }
        return input_bytes;
    }
}

fn generatePdfBytes(allocator: std.mem.Allocator, mode: TemplateMode, json_data: []const u8) ![]const u8 {
    switch (mode) {
        .basic => {
            const data = try lib.json.parseInvoiceJson(allocator, json_data);
            defer lib.json.freeInvoiceData(allocator, &data);
            return try lib.generateInvoice(allocator, data);
        },
        .minimalist => {
            return try lib.generateCleanQuoteFromJson(allocator, json_data);
        },
        .letter => {
            return try lib.generateLetterQuoteFromJson(allocator, json_data);
        },
        .presentation => {
            return try lib.generatePresentationFromJson(allocator, json_data);
        },
    }
}

fn writeOutputData(output_path: ?[]const u8, pdf_bytes: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const io = global_io;
    if (output_path) |path| {
        const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            try stderr.print("Error: Cannot create output file '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        };
        defer file.close(io);

        var write_buf: [8192]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        writer.interface.writeAll(pdf_bytes) catch |err| {
            try stderr.print("Error: Cannot write to output file: {s}\n", .{@errorName(err)});
            return err;
        };
        try writer.interface.flush();
        try stderr.print("Generated: {s} ({d} bytes)\n", .{ path, pdf_bytes.len });
    } else {
        // Write binary PDF stream directly to stdout
        try stdout.writeAll(pdf_bytes);
        try stdout.flush();
    }
}
