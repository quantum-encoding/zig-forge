const std = @import("std");
const pdf = @import("pdf-engine");

const print = std.debug.print;

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    // Collect args
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch {
            print("pdf-info: allocation failed\n", .{});
            return;
        };
    }
    const args = args_list.items;

    if (args.len < 2) {
        print("Usage: {s} <file.pdf>\n", .{args[0]});
        print("\nPrint information about a PDF file.\n", .{});
        std.process.exit(1);
    }

    const path = args[1];

    // Open PDF
    var doc = pdf.Document.open(allocator, path) catch |err| {
        print("Error opening '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer doc.close();

    // Print header
    print("\n", .{});
    print("PDF Information\n", .{});
    print("===============\n\n", .{});

    // File info
    print("File: {s}\n", .{path});
    const size_info = pdf.document.formatFileSize(doc.getFileSize());
    print("Size: {d:.2} {s}\n", .{ size_info.value, size_info.unit });
    print("PDF Version: {s}\n", .{doc.getVersion()});

    // Object count
    print("Objects: {}\n", .{doc.getObjectCount()});

    // Page count
    if (doc.getPageCount()) |count| {
        print("Pages: {}\n", .{count});
    } else |_| {
        print("Pages: (unable to determine)\n", .{});
    }

    // Encryption
    print("Encrypted: {s}\n", .{if (doc.isEncrypted()) "Yes" else "No"});

    // Document info
    print("\n", .{});

    if (doc.getInfo() catch null) |info| {
        print("Metadata\n", .{});
        print("--------\n", .{});

        if (info.title) |t| print("Title: {s}\n", .{t});
        if (info.author) |a| print("Author: {s}\n", .{a});
        if (info.subject) |s| print("Subject: {s}\n", .{s});
        if (info.keywords) |k| print("Keywords: {s}\n", .{k});
        if (info.creator) |c| print("Creator: {s}\n", .{c});
        if (info.producer) |p| print("Producer: {s}\n", .{p});
        if (info.creation_date) |d| print("Created: {s}\n", .{formatDate(d)});
        if (info.mod_date) |d| print("Modified: {s}\n", .{formatDate(d)});

        // Check if any info was printed
        if (info.title == null and info.author == null and info.subject == null and
            info.keywords == null and info.creator == null and info.producer == null and
            info.creation_date == null and info.mod_date == null)
        {
            print("(no metadata available)\n", .{});
        }
    } else {
        print("Metadata: (none)\n", .{});
    }

    print("\n", .{});
}

fn formatDate(date: []const u8) []const u8 {
    // Strip D: prefix if present
    if (std.mem.startsWith(u8, date, "D:")) {
        return date[2..];
    }
    return date;
}
