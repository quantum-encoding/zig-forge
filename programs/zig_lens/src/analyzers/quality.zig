const std = @import("std");
const models = @import("../models.zig");

pub const QualityReport = struct {
    doc_coverage_pct: u32,
    pub_with_docs: u32,
    pub_without_docs: u32,
    test_count: u32,
    function_count: u32,
    test_density_pct: u32,
    todo_count: u32,
    fixme_count: u32,
    hack_count: u32,
    catch_discard_count: u32,
};

pub fn analyze(source: []const u8, report: *const models.FileReport) QualityReport {
    var pub_with_docs: u32 = 0;
    var pub_without_docs: u32 = 0;

    // Check doc coverage on public functions
    for (report.functions.items) |*f| {
        if (f.is_pub) {
            if (f.doc_comment.len > 0) {
                pub_with_docs += 1;
            } else {
                pub_without_docs += 1;
            }
        }
    }
    // Check doc coverage on public structs
    for (report.structs.items) |*s| {
        if (s.is_pub) {
            if (s.doc_comment.len > 0) {
                pub_with_docs += 1;
            } else {
                pub_without_docs += 1;
            }
        }
    }

    const total_pub = pub_with_docs + pub_without_docs;
    const doc_pct = if (total_pub > 0) (pub_with_docs * 100) / total_pub else 0;

    const fn_count: u32 = @intCast(report.functions.items.len);
    const test_count: u32 = @intCast(report.tests.items.len);
    const test_density = if (fn_count > 0) (test_count * 100) / fn_count else 0;

    // Source-level markers
    var todo_count: u32 = 0;
    var fixme_count: u32 = 0;
    var hack_count: u32 = 0;
    var catch_discard_count: u32 = 0;

    var start: usize = 0;
    for (source, 0..) |c, i| {
        if (c == '\n' or i == source.len - 1) {
            const end = if (c == '\n') i else i + 1;
            const line = source[start..end];

            if (std.mem.indexOf(u8, line, "TODO") != null) todo_count += 1;
            if (std.mem.indexOf(u8, line, "FIXME") != null) fixme_count += 1;
            if (std.mem.indexOf(u8, line, "HACK") != null) hack_count += 1;
            if (std.mem.indexOf(u8, line, "catch {}") != null or
                std.mem.indexOf(u8, line, "catch |_| {}") != null)
            {
                catch_discard_count += 1;
            }

            start = i + 1;
        }
    }

    return .{
        .doc_coverage_pct = doc_pct,
        .pub_with_docs = pub_with_docs,
        .pub_without_docs = pub_without_docs,
        .test_count = test_count,
        .function_count = fn_count,
        .test_density_pct = test_density,
        .todo_count = todo_count,
        .fixme_count = fixme_count,
        .hack_count = hack_count,
        .catch_discard_count = catch_discard_count,
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "QualityReport with no functions no docs" {
    var report = models.FileReport.init();
    const quality = analyze("", &report);
    try std.testing.expectEqual(quality.doc_coverage_pct, 0);
    try std.testing.expectEqual(quality.pub_with_docs, 0);
    try std.testing.expectEqual(quality.pub_without_docs, 0);
}

test "QualityReport detects TODO markers" {
    var report = models.FileReport.init();
    const source = "// TODO: implement this\nconst x = 5;\n";
    const quality = analyze(source, &report);
    try std.testing.expectEqual(quality.todo_count, 1);
}

test "QualityReport detects FIXME markers" {
    var report = models.FileReport.init();
    const source = "// FIXME: bug here\nconst x = 5;\n";
    const quality = analyze(source, &report);
    try std.testing.expectEqual(quality.fixme_count, 1);
}

test "QualityReport detects HACK markers" {
    var report = models.FileReport.init();
    const source = "// HACK: workaround\nconst x = 5;\n";
    const quality = analyze(source, &report);
    try std.testing.expectEqual(quality.hack_count, 1);
}

test "QualityReport detects catch discards" {
    var report = models.FileReport.init();
    const source = "const result = foo() catch {};\n";
    const quality = analyze(source, &report);
    try std.testing.expectEqual(quality.catch_discard_count, 1);
}

test "QualityReport zero test density with no functions" {
    var report = models.FileReport.init();
    const quality = analyze("", &report);
    try std.testing.expectEqual(quality.test_density_pct, 0);
}
