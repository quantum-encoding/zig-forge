const std = @import("std");
const pdf = @import("pdf-engine");

const Document = pdf.Document;

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    // Collect args
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch {
            std.debug.print("pdf-text: allocation failed\n", .{});
            return;
        };
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage(args[0]);
        return;
    }

    // Parse options
    var file_path: ?[]const u8 = null;
    var page_num: ?u32 = null;
    var show_help = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--page")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --page requires a number\n", .{});
                return;
            }
            page_num = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: Invalid page number '{s}'\n", .{args[i]});
                return;
            };
        } else if (arg[0] != '-') {
            file_path = arg;
        } else {
            std.debug.print("Error: Unknown option '{s}'\n", .{arg});
            return;
        }
    }

    if (show_help) {
        printUsage(args[0]);
        return;
    }

    const path = file_path orelse {
        std.debug.print("Error: No PDF file specified\n", .{});
        printUsage(args[0]);
        return;
    };

    // Open PDF
    var doc = Document.open(allocator, path) catch |err| {
        std.debug.print("Error: Failed to open PDF: {}\n", .{err});
        return;
    };
    defer doc.close();

    // Check encryption
    if (doc.isEncrypted()) {
        std.debug.print("Error: PDF is encrypted (not supported)\n", .{});
        return;
    }

    // Extract text
    if (page_num) |pn| {
        // Extract single page (convert to 0-based)
        if (pn == 0) {
            std.debug.print("Error: Page numbers start at 1\n", .{});
            return;
        }

        const page_count = doc.getPageCount() catch |err| {
            std.debug.print("Error: Failed to get page count: {}\n", .{err});
            return;
        };

        if (pn > page_count) {
            std.debug.print("Error: Page {d} does not exist (document has {d} pages)\n", .{ pn, page_count });
            return;
        }

        const text = doc.extractPageText(pn - 1) catch |err| {
            std.debug.print("Error: Failed to extract text from page {d}: {}\n", .{ pn, err });
            return;
        };
        defer allocator.free(text);

        std.debug.print("{s}\n", .{text});
    } else {
        // Extract all pages
        const text = doc.extractAllText() catch |err| {
            std.debug.print("Error: Failed to extract text: {}\n", .{err});
            return;
        };
        defer allocator.free(text);

        std.debug.print("{s}\n", .{text});
    }
}

fn printUsage(prog_name: []const u8) void {
    std.debug.print(
        \\pdf-text - Extract text from PDF files
        \\
        \\Usage: {s} [OPTIONS] <file.pdf>
        \\
        \\Options:
        \\  -p, --page <N>   Extract only page N (1-based)
        \\  -h, --help       Show this help
        \\
        \\Examples:
        \\  {s} document.pdf           Extract all text
        \\  {s} -p 1 document.pdf      Extract page 1 only
        \\
    , .{ prog_name, prog_name, prog_name });
}
