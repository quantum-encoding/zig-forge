// Debug tool for PDF rendering
// Prints content stream and renders to PPM

const std = @import("std");
const pdf = @import("pdf-engine");

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    // Collect args
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch {
            std.debug.print("render-debug: allocation failed\n", .{});
            return;
        };
    }
    const args = args_list.items;

    if (args.len < 2) {
        std.debug.print("Usage: render_debug <pdf_file> [page_index]\n", .{});
        return;
    }

    const pdf_path = args[1];
    const page_index: u32 = if (args.len > 2) std.fmt.parseInt(u32, args[2], 10) catch 0 else 0;

    std.debug.print("Opening: {s}\n", .{pdf_path});

    // Open document
    var doc = pdf.Document.open(allocator, pdf_path) catch |err| {
        std.debug.print("Failed to open PDF: {}\n", .{err});
        return;
    };
    defer doc.close();

    std.debug.print("PDF opened successfully\n", .{});
    std.debug.print("  Version: {s}\n", .{doc.getVersion()});
    std.debug.print("  Size: {d} bytes\n", .{doc.getFileSize()});

    const page_count = doc.getPageCount() catch 0;
    std.debug.print("  Pages: {d}\n", .{page_count});

    if (page_index >= page_count) {
        std.debug.print("Page index {d} out of range\n", .{page_index});
        return;
    }

    // Get page dimensions
    const dims = if (doc.getPageDimensions(page_index)) |d|
        d
    else |_|
        pdf.Document.PageDimensions{ .width = 612, .height = 792 };
    std.debug.print("\nPage {d} dimensions: {d} x {d} points\n", .{ page_index, dims.width, dims.height });

    // Get content stream
    const content = doc.getPageContent(page_index) catch |err| {
        std.debug.print("Failed to get content stream: {}\n", .{err});
        return;
    };
    defer allocator.free(content);

    std.debug.print("\nContent stream: {d} bytes\n", .{content.len});
    std.debug.print("First 500 chars:\n", .{});
    std.debug.print("---\n{s}\n---\n", .{content[0..@min(500, content.len)]});

    // Count some operators
    var op_counts = std.StringHashMap(u32).init(allocator);
    defer op_counts.deinit();

    var i: usize = 0;
    while (i < content.len) {
        // Skip whitespace
        while (i < content.len and (content[i] == ' ' or content[i] == '\n' or content[i] == '\r' or content[i] == '\t')) {
            i += 1;
        }
        if (i >= content.len) break;

        // Check for common operators (single/double letter)
        if (content[i] >= 'A' and content[i] <= 'z') {
            var end = i;
            while (end < content.len and content[end] > ' ' and content[end] != '(' and content[end] != '[') {
                end += 1;
            }
            const op = content[i..end];
            if (op.len <= 3) {
                const entry = op_counts.getOrPut(op) catch continue;
                if (!entry.found_existing) {
                    entry.value_ptr.* = 0;
                }
                entry.value_ptr.* += 1;
            }
            i = end;
        } else {
            i += 1;
        }
    }

    std.debug.print("\nOperator counts:\n", .{});
    var iter = op_counts.iterator();
    while (iter.next()) |entry| {
        std.debug.print("  {s}: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    // Create renderer
    var renderer = pdf.PageRenderer.init(allocator);
    defer renderer.deinit();

    renderer.setDPI(72.0); // 1:1 with points
    renderer.setBackground(pdf.Color.white);

    const page_size = pdf.PageSize{ .width = dims.width, .height = dims.height };

    std.debug.print("\nRendering at 72 DPI...\n", .{});

    // Test with a simple colored rectangle first
    const test_content = "1 0 0 rg 50 50 200 200 re f"; // Red rectangle
    std.debug.print("Testing simple red rectangle: \"{s}\"\n", .{test_content});

    var test_result = renderer.render(test_content, page_size) catch |err| {
        std.debug.print("Test render failed: {}\n", .{err});
        return;
    };

    // Check test result
    var test_non_white: u32 = 0;
    for (test_result.bitmap.pixels) |px| {
        if (px.r != 255 or px.g != 255 or px.b != 255) {
            test_non_white += 1;
        }
    }
    std.debug.print("Test result: {d} non-white pixels\n", .{test_non_white});
    test_result.deinit();

    // Now render actual content
    var result = renderer.render(content, page_size) catch |err| {
        std.debug.print("Render failed: {}\n", .{err});
        return;
    };
    defer result.deinit();

    std.debug.print("Rendered to {d}x{d} pixels\n", .{ result.width, result.height });

    // Check for non-white pixels
    var non_white: u32 = 0;
    var non_black: u32 = 0;
    const pixels = result.bitmap.pixels;
    for (0..result.height) |y| {
        for (0..result.width) |x| {
            const idx = y * result.width + x;
            const color = pixels[idx];
            if (color.r != 255 or color.g != 255 or color.b != 255) {
                non_white += 1;
            }
            if (color.r != 0 or color.g != 0 or color.b != 0) {
                non_black += 1;
            }
        }
    }

    const total = result.width * result.height;
    std.debug.print("Pixel analysis:\n", .{});
    std.debug.print("  Total pixels: {d}\n", .{total});
    std.debug.print("  Non-white pixels: {d} ({d:.1}%)\n", .{ non_white, @as(f32, @floatFromInt(non_white)) / @as(f32, @floatFromInt(total)) * 100 });
    std.debug.print("  Non-black pixels: {d} ({d:.1}%)\n", .{ non_black, @as(f32, @floatFromInt(non_black)) / @as(f32, @floatFromInt(total)) * 100 });

    // Save as PPM
    const output_path: []const u8 = "/tmp/render_debug.ppm";
    result.bitmap.writePPM(output_path) catch |err| {
        std.debug.print("Failed to write PPM: {}\n", .{err});
        return;
    };
    std.debug.print("\nSaved to: {s}\n", .{output_path});
}
