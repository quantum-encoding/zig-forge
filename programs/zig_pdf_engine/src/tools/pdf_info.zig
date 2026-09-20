const std = @import("std");
const pdf = @import("pdf-engine");

const usage =
    \\pdf-info - Print information about a PDF file
    \\
    \\Usage: pdf-info [OPTIONS] <file.pdf>
    \\
    \\Options:
    \\  -h, --help       Show this help
    \\
    \\The report goes to stdout. Exit status is 0 when the file opened as a PDF
    \\and non-zero otherwise, with the reason on stderr.
    \\
;

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    // Collect args
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch {
            std.debug.print("pdf-info: allocation failed\n", .{});
            std.process.exit(1);
        };
    }
    const args = args_list.items;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var file_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            stdout.writeAll(usage) catch {};
            stdout.flush() catch {};
            return;
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("Error: Unknown option '{s}'\n\n{s}", .{ arg, usage });
            std.process.exit(1);
        } else {
            file_path = arg;
        }
    }

    const path = file_path orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };

    // Open PDF
    var doc = pdf.Document.open(allocator, path) catch |err| {
        std.debug.print("Error opening '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer doc.close();

    report(stdout, &doc, path) catch {};
    stdout.flush() catch {};
}

fn report(out: *std.Io.Writer, doc: *pdf.Document, path: []const u8) !void {
    try out.writeAll("\nPDF Information\n===============\n\n");

    // File info
    try out.print("File: {s}\n", .{path});
    const size_info = pdf.document.formatFileSize(doc.getFileSize());
    try out.print("Size: {d:.2} {s}\n", .{ size_info.value, size_info.unit });
    try out.print("PDF Version: {s}\n", .{doc.getVersion()});

    // Object count
    try out.print("Objects: {}\n", .{doc.getObjectCount()});

    // Page count
    if (doc.getPageCount()) |count| {
        try out.print("Pages: {}\n", .{count});
    } else |_| {
        try out.writeAll("Pages: (unable to determine)\n");
    }

    // Encryption
    try out.print("Encrypted: {s}\n", .{if (doc.isEncrypted()) "Yes" else "No"});

    // Document info
    try out.writeAll("\n");

    if (doc.getInfo() catch null) |info| {
        try out.writeAll("Metadata\n--------\n");

        if (info.title) |t| try out.print("Title: {s}\n", .{t});
        if (info.author) |a| try out.print("Author: {s}\n", .{a});
        if (info.subject) |s| try out.print("Subject: {s}\n", .{s});
        if (info.keywords) |k| try out.print("Keywords: {s}\n", .{k});
        if (info.creator) |c| try out.print("Creator: {s}\n", .{c});
        if (info.producer) |p| try out.print("Producer: {s}\n", .{p});
        if (info.creation_date) |d| try out.print("Created: {s}\n", .{formatDate(d)});
        if (info.mod_date) |d| try out.print("Modified: {s}\n", .{formatDate(d)});

        if (info.title == null and info.author == null and info.subject == null and
            info.keywords == null and info.creator == null and info.producer == null and
            info.creation_date == null and info.mod_date == null)
        {
            try out.writeAll("(no metadata available)\n");
        }
    } else {
        try out.writeAll("Metadata: (none)\n");
    }

    try out.writeAll("\n");
}

fn formatDate(date: []const u8) []const u8 {
    // Strip D: prefix if present
    if (std.mem.startsWith(u8, date, "D:")) {
        return date[2..];
    }
    return date;
}
