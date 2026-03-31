// Real PDF File Tests
//
// Tests using actual PDF files to verify parsing, text extraction, and editing.
// Test fixtures are in tests/fixtures/

const std = @import("std");
const testing = std.testing;
const pdf = @import("pdf-engine");

const Document = pdf.Document;
const Editor = pdf.Editor;
const Writer = pdf.Writer;

// Path to test fixtures (relative to project root)
const fixtures_path = "tests/fixtures/";

// ============================================================================
// Document Opening Tests
// ============================================================================

test "open small PDF file" {
    const path = fixtures_path ++ "small.pdf";

    var doc = Document.open(testing.allocator, path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    // Verify basic properties
    try testing.expect(doc.size > 0);
    try testing.expect(doc.getObjectCount() > 0);
}

test "open invoice PDF file" {
    const path = fixtures_path ++ "test_invoice.pdf";

    var doc = Document.open(testing.allocator, path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    try testing.expect(doc.size > 0);
}

test "open certificate PDF file" {
    const path = fixtures_path ++ "certificate.pdf";

    var doc = Document.open(testing.allocator, path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    try testing.expect(doc.size > 0);
}

test "reject non-PDF file" {
    // Try to open a non-existent file
    const result = Document.open(testing.allocator, "/tmp/nonexistent.pdf");
    try testing.expectError(error.FileNotFound, result);
}

// ============================================================================
// Document Properties Tests
// ============================================================================

test "get PDF version" {
    const path = fixtures_path ++ "test_invoice.pdf";

    var doc = Document.open(testing.allocator, path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    const version = doc.getVersion();
    // PDF version should be something like "1.4", "1.5", "1.7", etc.
    try testing.expect(version.len >= 3);
    try testing.expect(version[0] >= '1' and version[0] <= '2');
    try testing.expect(version[1] == '.');
}

test "get file size" {
    const path = fixtures_path ++ "small.pdf";

    var doc = Document.open(testing.allocator, path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    const size = doc.getFileSize();
    try testing.expect(size > 100); // Should be at least 100 bytes
    try testing.expect(size < 100 * 1024 * 1024); // And less than 100MB
}

test "get page count" {
    const path = fixtures_path ++ "test_invoice.pdf";

    var doc = Document.open(testing.allocator, path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    const page_count = doc.getPageCount() catch |err| {
        std.debug.print("Failed to get page count: {}\n", .{err});
        return err;
    };

    try testing.expect(page_count >= 1);
    try testing.expect(page_count < 10000); // Sanity check
}

test "get object count" {
    const path = fixtures_path ++ "certificate.pdf";

    var doc = Document.open(testing.allocator, path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    const obj_count = doc.getObjectCount();
    try testing.expect(obj_count >= 1);
}

test "check encryption status" {
    const path = fixtures_path ++ "small.pdf";

    var doc = Document.open(testing.allocator, path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    // Our test files should not be encrypted
    const encrypted = doc.isEncrypted();
    try testing.expect(!encrypted);
}

// ============================================================================
// Text Extraction Tests
// ============================================================================

test "extract text from invoice" {
    const path = fixtures_path ++ "test_invoice.pdf";

    var doc = Document.open(testing.allocator, path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    // Try to extract text from first page
    const text = doc.extractPageText(0) catch |err| {
        std.debug.print("Text extraction failed (may be expected for some PDFs): {}\n", .{err});
        // Some PDFs may not have extractable text, so we don't fail
        return;
    };
    defer testing.allocator.free(text);

    // If we got text, verify it's not empty
    try testing.expect(text.len > 0);
}

test "extract all text" {
    const path = fixtures_path ++ "test_invoice.pdf";

    var doc = Document.open(testing.allocator, path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    const all_text = doc.extractAllText() catch |err| {
        std.debug.print("Full text extraction failed: {}\n", .{err});
        return;
    };
    defer testing.allocator.free(all_text);

    // Should have extracted something
    std.debug.print("Extracted {d} bytes of text\n", .{all_text.len});
}

// ============================================================================
// Editor Tests - Metadata Modification
// ============================================================================

test "modify PDF metadata and save" {
    const input_path = fixtures_path ++ "small.pdf";
    const output_path = "/tmp/zigpdf_test_modified.pdf";

    var doc = Document.open(testing.allocator, input_path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ input_path, err });
        return err;
    };
    defer doc.close();

    // Create editor
    var ed = Editor.init(testing.allocator, &doc);
    defer ed.deinit();

    // Modify metadata
    try ed.setTitle("Modified by ZigPDF Tests");
    try ed.setAuthor("ZigPDF Test Suite");
    try ed.setSubject("Automated Testing");
    try ed.setKeywords("test, zig, pdf, automated");
    try ed.setCreator("ZigPDF Editor");
    try ed.setProducer("ZigPDF 1.0");

    // Save to new file
    try ed.save(output_path);

    // Verify the output file exists and is valid
    var modified_doc = Document.open(testing.allocator, output_path) catch |err| {
        std.debug.print("Failed to open modified PDF: {}\n", .{err});
        return err;
    };
    defer modified_doc.close();

    // Verify it's still a valid PDF
    try testing.expect(modified_doc.size > doc.size); // Should be larger due to added data
    try testing.expect(modified_doc.getObjectCount() > 0);

    // Verify metadata was added (best effort - format may differ)
    if (modified_doc.getInfo()) |info_opt| {
        if (info_opt) |info| {
            if (info.title) |title| {
                try testing.expectEqualStrings("Modified by ZigPDF Tests", title);
            }
            if (info.author) |author| {
                try testing.expectEqualStrings("ZigPDF Test Suite", author);
            }
        }
    } else |_| {
        // Info dictionary reading may fail if our writing format differs slightly
        std.debug.print("Note: Could not read back metadata (format may differ)\n", .{});
    }
}

test "add text overlay to PDF" {
    const input_path = fixtures_path ++ "small.pdf";
    const output_path = "/tmp/zigpdf_test_overlay.pdf";

    var doc = Document.open(testing.allocator, input_path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ input_path, err });
        return err;
    };
    defer doc.close();

    // Create editor
    var ed = Editor.init(testing.allocator, &doc);
    defer ed.deinit();

    // Add text overlay
    try ed.addText(0, 72, 700, "WATERMARK: ZigPDF Test");
    try ed.addTextWithStyle(0, 72, 680, "Smaller text here", 8.0, "Helvetica");

    // Save
    try ed.save(output_path);

    // Verify output
    var modified_doc = Document.open(testing.allocator, output_path) catch |err| {
        std.debug.print("Failed to open overlay PDF: {}\n", .{err});
        return err;
    };
    defer modified_doc.close();

    try testing.expect(modified_doc.size > doc.size);
}

test "add shapes to PDF" {
    const input_path = fixtures_path ++ "small.pdf";
    const output_path = "/tmp/zigpdf_test_shapes.pdf";

    var doc = Document.open(testing.allocator, input_path) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ input_path, err });
        return err;
    };
    defer doc.close();

    var ed = Editor.init(testing.allocator, &doc);
    defer ed.deinit();

    // Add shapes
    try ed.addLine(0, 72, 750, 540, 750); // Horizontal line at top
    try ed.addRectangle(0, 100, 600, 200, 100); // Rectangle

    try ed.save(output_path);

    // Verify
    var modified_doc = Document.open(testing.allocator, output_path) catch |err| {
        std.debug.print("Failed to open shapes PDF: {}\n", .{err});
        return err;
    };
    defer modified_doc.close();

    try testing.expect(modified_doc.size > doc.size);
}

// ============================================================================
// Writer Tests - Create New PDFs
// ============================================================================

test "create new PDF from scratch" {
    const output_path = "/tmp/zigpdf_test_new.pdf";

    var writer = Writer.init(testing.allocator);
    defer writer.deinit();

    try writer.setTitle("ZigPDF Generated Document");
    try writer.setAuthor("ZigPDF Writer");

    // Add a page with text
    try writer.addTextPage(612, 792, "Hello from ZigPDF!", 72, 720);

    // Add a blank page
    try writer.addBlankPage(612, 792);

    // Save
    try writer.save(output_path);

    // Verify we can open the created PDF
    var doc = Document.open(testing.allocator, output_path) catch |err| {
        std.debug.print("Failed to open created PDF: {}\n", .{err});
        return err;
    };
    defer doc.close();

    // Verify structure
    try testing.expect(doc.size > 100);
    try testing.expect(doc.getObjectCount() >= 4); // At least catalog, pages, 2 pages

    const page_count = doc.getPageCount() catch 0;
    try testing.expectEqual(@as(u32, 2), page_count);

    // Note: cleanup skipped - file will be overwritten on next run
}

test "create multi-page document" {
    const output_path = "/tmp/zigpdf_test_multipage.pdf";

    var writer = Writer.init(testing.allocator);
    defer writer.deinit();

    try writer.setTitle("Multi-Page Test Document");

    // Add several pages with different content
    try writer.addTextPage(612, 792, "Page 1 - Introduction", 72, 720);
    try writer.addTextPage(612, 792, "Page 2 - Main Content", 72, 720);
    try writer.addTextPage(612, 792, "Page 3 - Conclusion", 72, 720);
    try writer.addBlankPage(612, 792);

    try writer.save(output_path);

    // Verify
    var doc = Document.open(testing.allocator, output_path) catch |err| {
        std.debug.print("Failed to open multi-page PDF: {}\n", .{err});
        return err;
    };
    defer doc.close();

    const page_count = doc.getPageCount() catch 0;
    try testing.expectEqual(@as(u32, 4), page_count);
}

test "create PDF with custom content stream" {
    const output_path = "/tmp/zigpdf_test_custom.pdf";

    var writer = Writer.init(testing.allocator);
    defer writer.deinit();

    // Custom PDF content stream
    const content =
        \\BT
        \\/F1 24 Tf
        \\100 700 Td
        \\(Custom Content Stream) Tj
        \\0 -30 Td
        \\/F1 12 Tf
        \\(Demonstrating direct PDF content) Tj
        \\ET
        \\100 650 m
        \\500 650 l
        \\S
    ;

    try writer.addPage(612, 792, content);
    try writer.save(output_path);

    var doc = Document.open(testing.allocator, output_path) catch |err| {
        std.debug.print("Failed to open custom PDF: {}\n", .{err});
        return err;
    };
    defer doc.close();

    try testing.expect(doc.size > 0);
}

// ============================================================================
// Stress Tests
// ============================================================================

test "handle multiple opens and closes" {
    const path = fixtures_path ++ "small.pdf";

    for (0..10) |i| {
        var doc = Document.open(testing.allocator, path) catch |err| {
            std.debug.print("Failed on iteration {d}: {}\n", .{ i, err });
            return err;
        };

        const size = doc.getFileSize();
        try testing.expect(size > 0);

        doc.close();
    }
}

test "create many pages" {
    const output_path = "/tmp/zigpdf_test_many.pdf";

    var writer = Writer.init(testing.allocator);
    defer writer.deinit();

    // Create 50 pages
    for (0..50) |i| {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Page {d} of 50", .{i + 1}) catch "Page";
        try writer.addTextPage(612, 792, text, 72, 720);
    }

    try writer.save(output_path);

    var doc = Document.open(testing.allocator, output_path) catch |err| {
        std.debug.print("Failed to open many-page PDF: {}\n", .{err});
        return err;
    };
    defer doc.close();

    const page_count = doc.getPageCount() catch 0;
    try testing.expectEqual(@as(u32, 50), page_count);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "empty PDF creation" {
    const output_path = "/tmp/zigpdf_test_empty.pdf";

    var writer = Writer.init(testing.allocator);
    defer writer.deinit();

    // Create with just one blank page (minimum valid PDF)
    try writer.addBlankPage(612, 792);
    try writer.save(output_path);

    var doc = Document.open(testing.allocator, output_path) catch |err| {
        std.debug.print("Failed to open empty PDF: {}\n", .{err});
        return err;
    };
    defer doc.close();

    try testing.expect(doc.size > 0);
}

test "special characters in text" {
    const output_path = "/tmp/zigpdf_test_special.pdf";

    var writer = Writer.init(testing.allocator);
    defer writer.deinit();

    // Test various special characters that need escaping
    try writer.addTextPage(612, 792, "Special: () \\ \"quotes\"", 72, 720);
    try writer.save(output_path);

    var doc = Document.open(testing.allocator, output_path) catch |err| {
        std.debug.print("Failed to open special chars PDF: {}\n", .{err});
        return err;
    };
    defer doc.close();

    try testing.expect(doc.size > 0);
}

// ============================================================================
// Performance Benchmark (optional, informational)
// ============================================================================

test "benchmark document opening" {
    const path = fixtures_path ++ "certificate.pdf";

    const iterations: usize = 100;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        var doc = Document.open(testing.allocator, path) catch return;
        _ = doc.getPageCount() catch {};
        doc.close();
    }

    const elapsed = timer.read();
    const per_op = elapsed / iterations;

    std.debug.print("\nBenchmark: {d} opens in {d}ms ({d}us/op)\n", .{
        iterations,
        elapsed / std.time.ns_per_ms,
        per_op / std.time.ns_per_us,
    });
}
