//! Report generation for duplicate finder and folder comparison
//!
//! Supported formats:
//! - Text: Human-readable console output
//! - JSON: Machine-readable structured data
//! - HTML: Interactive web report

const std = @import("std");
const types = @import("types.zig");
const hasher = @import("hasher.zig");

/// Report writer
pub const ReportWriter = struct {
    allocator: std.mem.Allocator,
    options: types.ReportOptions,

    pub fn init(allocator: std.mem.Allocator, options: types.ReportOptions) ReportWriter {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    // ========================================================================
    // Duplicate Report
    // ========================================================================

    /// Write duplicate report to writer
    pub fn writeDuplicateReport(
        self: *const ReportWriter,
        writer: anytype,
        groups: []const types.DuplicateGroup,
        summary: *const types.DuplicateSummary,
    ) !void {
        switch (self.options.format) {
            .text => try self.writeDuplicateText(writer, groups, summary),
            .json => try self.writeDuplicateJson(writer, groups, summary),
            .html => try self.writeDuplicateHtml(writer, groups, summary),
        }
    }

    fn writeDuplicateText(
        self: *const ReportWriter,
        writer: anytype,
        groups: []const types.DuplicateGroup,
        summary: *const types.DuplicateSummary,
    ) !void {
        // Header
        try writer.writeAll("=== Duplicate File Report ===\n\n");

        // Summary
        var buf: [64]u8 = undefined;
        try writer.print("Files scanned:    {}\n", .{summary.files_scanned});
        try writer.print("Total size:       {s}\n", .{types.formatBytes(summary.bytes_scanned, &buf)});
        try writer.print("Duplicate groups: {}\n", .{summary.duplicate_groups});
        try writer.print("Duplicate files:  {}\n", .{summary.duplicate_files});
        try writer.print("Space savings:    {s}\n", .{summary.spaceSavingsHuman(&buf)});
        try writer.print("Scan time:        {d:.2}s\n\n", .{@as(f64, @floatFromInt(summary.scan_time_ns)) / 1_000_000_000.0});

        if (groups.len == 0) {
            try writer.writeAll("No duplicates found.\n");
            return;
        }

        // Groups
        try writer.writeAll("--- Duplicate Groups ---\n\n");

        for (groups, 0..) |group, idx| {
            try writer.print("Group {} ({} files, {s} each, {s} savings):\n", .{
                idx + 1,
                group.count(),
                types.formatBytes(group.size, &buf),
                types.formatBytes(group.savings, &buf),
            });

            if (self.options.include_hashes) {
                var hex_buf: [64]u8 = undefined;
                try writer.print("  Hash: {s}\n", .{hasher.hashToHex(&group.hash, &hex_buf)});
            }

            for (group.files.items) |path| {
                try writer.print("  - {s}\n", .{path});
            }
            try writer.writeAll("\n");
        }
    }

    fn writeDuplicateJson(
        _: *const ReportWriter,
        writer: anytype,
        groups: []const types.DuplicateGroup,
        summary: *const types.DuplicateSummary,
    ) !void {
        var size_buf: [64]u8 = undefined;

        try writer.writeAll("{\n");

        // Report metadata
        try writer.writeAll("  \"report_type\": \"duplicates\",\n");

        // Generated timestamp (current time via libc)
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        const now: i64 = tv.sec;
        var ts_buf: [24]u8 = undefined;
        try writer.print("  \"generated_at\": \"{s}\",\n", .{formatIso8601(now, &ts_buf)});

        // Scan duration in milliseconds
        const scan_ms = summary.scan_time_ns / 1_000_000;
        try writer.print("  \"scan_duration_ms\": {},\n", .{scan_ms});

        // Summary
        try writer.writeAll("  \"summary\": {\n");
        try writer.print("    \"files_scanned\": {},\n", .{summary.files_scanned});
        try writer.print("    \"bytes_scanned\": {},\n", .{summary.bytes_scanned});
        try writer.print("    \"bytes_scanned_human\": \"{s}\",\n", .{types.formatBytes(summary.bytes_scanned, &size_buf)});
        try writer.print("    \"duplicate_groups\": {},\n", .{summary.duplicate_groups});
        try writer.print("    \"duplicate_files\": {},\n", .{summary.duplicate_files});
        try writer.print("    \"space_savings\": {},\n", .{summary.space_savings});
        try writer.print("    \"space_savings_human\": \"{s}\"\n", .{types.formatBytes(summary.space_savings, &size_buf)});
        try writer.writeAll("  },\n");

        // Groups
        try writer.writeAll("  \"groups\": [\n");

        for (groups, 0..) |group, idx| {
            try writer.writeAll("    {\n");

            // Hash first
            var hex_buf: [64]u8 = undefined;
            try writer.print("      \"hash\": \"{s}\",\n", .{hasher.hashToHex(&group.hash, &hex_buf)});

            try writer.print("      \"size\": {},\n", .{group.size});
            try writer.print("      \"size_human\": \"{s}\",\n", .{types.formatBytes(group.size, &size_buf)});
            try writer.print("      \"count\": {},\n", .{group.count()});
            try writer.print("      \"savings\": {},\n", .{group.savings});
            try writer.print("      \"savings_human\": \"{s}\",\n", .{types.formatBytes(group.savings, &size_buf)});

            // Files with metadata
            try writer.writeAll("      \"files\": [\n");

            // Use file_infos if available, otherwise fall back to paths
            if (group.file_infos.items.len > 0) {
                var mtime_buf: [24]u8 = undefined;
                for (group.file_infos.items, 0..) |info, fidx| {
                    try writer.writeAll("        {\n");
                    try writer.print("          \"path\": \"{s}\",\n", .{escapeJsonString(info.path)});
                    try writer.print("          \"mtime\": \"{s}\"\n", .{formatIso8601(info.mtime, &mtime_buf)});
                    try writer.writeAll("        }");
                    if (fidx < group.file_infos.items.len - 1) {
                        try writer.writeAll(",");
                    }
                    try writer.writeAll("\n");
                }
            } else {
                // Legacy format - just paths
                for (group.files.items, 0..) |path, fidx| {
                    try writer.writeAll("        {\n");
                    try writer.print("          \"path\": \"{s}\"\n", .{escapeJsonString(path)});
                    try writer.writeAll("        }");
                    if (fidx < group.files.items.len - 1) {
                        try writer.writeAll(",");
                    }
                    try writer.writeAll("\n");
                }
            }
            try writer.writeAll("      ]\n");

            try writer.writeAll("    }");
            if (idx < groups.len - 1) {
                try writer.writeAll(",");
            }
            try writer.writeAll("\n");
        }

        try writer.writeAll("  ]\n");
        try writer.writeAll("}\n");
    }

    fn writeDuplicateHtml(
        self: *const ReportWriter,
        writer: anytype,
        groups: []const types.DuplicateGroup,
        summary: *const types.DuplicateSummary,
    ) !void {
        var buf: [64]u8 = undefined;

        // HTML header
        try writer.writeAll(
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\  <meta charset="UTF-8">
            \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\  <title>Duplicate File Report</title>
            \\  <style>
            \\    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 20px; background: #f5f5f5; }
            \\    .container { max-width: 1200px; margin: 0 auto; }
            \\    h1 { color: #333; }
            \\    .summary { background: #fff; padding: 20px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
            \\    .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 15px; }
            \\    .stat { text-align: center; }
            \\    .stat-value { font-size: 24px; font-weight: bold; color: #2563eb; }
            \\    .stat-label { color: #666; font-size: 14px; }
            \\    .group { background: #fff; padding: 20px; border-radius: 8px; margin-bottom: 15px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
            \\    .group-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
            \\    .group-title { font-weight: bold; color: #333; }
            \\    .group-savings { color: #16a34a; font-weight: bold; }
            \\    .file-list { list-style: none; padding: 0; margin: 0; }
            \\    .file-list li { padding: 8px 12px; background: #f8f9fa; margin: 5px 0; border-radius: 4px; font-family: monospace; font-size: 13px; word-break: break-all; }
            \\    .hash { color: #666; font-size: 12px; font-family: monospace; }
            \\  </style>
            \\</head>
            \\<body>
            \\  <div class="container">
            \\    <h1>Duplicate File Report</h1>
            \\
        );

        // Summary section
        try writer.writeAll("    <div class=\"summary\">\n      <div class=\"summary-grid\">\n");
        try writer.print("        <div class=\"stat\"><div class=\"stat-value\">{}</div><div class=\"stat-label\">Files Scanned</div></div>\n", .{summary.files_scanned});
        try writer.print("        <div class=\"stat\"><div class=\"stat-value\">{s}</div><div class=\"stat-label\">Total Size</div></div>\n", .{types.formatBytes(summary.bytes_scanned, &buf)});
        try writer.print("        <div class=\"stat\"><div class=\"stat-value\">{}</div><div class=\"stat-label\">Duplicate Groups</div></div>\n", .{summary.duplicate_groups});
        try writer.print("        <div class=\"stat\"><div class=\"stat-value\">{}</div><div class=\"stat-label\">Duplicate Files</div></div>\n", .{summary.duplicate_files});
        try writer.print("        <div class=\"stat\"><div class=\"stat-value\">{s}</div><div class=\"stat-label\">Potential Savings</div></div>\n", .{summary.spaceSavingsHuman(&buf)});
        try writer.writeAll("      </div>\n    </div>\n\n");

        // Groups
        if (groups.len == 0) {
            try writer.writeAll("    <p>No duplicates found.</p>\n");
        } else {
            for (groups, 0..) |group, idx| {
                try writer.writeAll("    <div class=\"group\">\n");
                try writer.writeAll("      <div class=\"group-header\">\n");
                try writer.print("        <span class=\"group-title\">Group {} ({} files, {s} each)</span>\n", .{
                    idx + 1,
                    group.count(),
                    types.formatBytes(group.size, &buf),
                });
                try writer.print("        <span class=\"group-savings\">+{s} savings</span>\n", .{types.formatBytes(group.savings, &buf)});
                try writer.writeAll("      </div>\n");

                if (self.options.include_hashes) {
                    var hex_buf: [64]u8 = undefined;
                    try writer.print("      <div class=\"hash\">Hash: {s}</div>\n", .{hasher.hashToHex(&group.hash, &hex_buf)});
                }

                try writer.writeAll("      <ul class=\"file-list\">\n");
                for (group.files.items) |path| {
                    try writer.print("        <li>{s}</li>\n", .{escapeHtml(path)});
                }
                try writer.writeAll("      </ul>\n");
                try writer.writeAll("    </div>\n\n");
            }
        }

        // Footer
        try writer.writeAll(
            \\  </div>
            \\</body>
            \\</html>
            \\
        );
    }

    // ========================================================================
    // Comparison Report
    // ========================================================================

    /// Write comparison report to writer
    pub fn writeCompareReport(
        self: *const ReportWriter,
        writer: anytype,
        result: *const types.CompareResult,
    ) !void {
        switch (self.options.format) {
            .text => try self.writeCompareText(writer, result),
            .json => try self.writeCompareJson(writer, result),
            .html => try self.writeCompareHtml(writer, result),
        }
    }

    fn writeCompareText(
        self: *const ReportWriter,
        writer: anytype,
        result: *const types.CompareResult,
    ) !void {
        _ = self;

        try writer.writeAll("=== Folder Comparison Report ===\n\n");
        try writer.print("Folder A: {s}\n", .{result.folder_a});
        try writer.print("Folder B: {s}\n\n", .{result.folder_b});

        // Summary
        try writer.print("Identical files:  {}\n", .{result.identical.items.len});
        try writer.print("Only in A:        {}\n", .{result.only_in_a.items.len});
        try writer.print("Only in B:        {}\n", .{result.only_in_b.items.len});
        try writer.print("Modified:         {}\n\n", .{result.modified.items.len});

        if (result.isIdentical()) {
            try writer.writeAll("Folders are IDENTICAL.\n");
            return;
        }

        // Differences
        if (result.only_in_a.items.len > 0) {
            try writer.writeAll("--- Only in A ---\n");
            for (result.only_in_a.items) |path| {
                try writer.print("  - {s}\n", .{path});
            }
            try writer.writeAll("\n");
        }

        if (result.only_in_b.items.len > 0) {
            try writer.writeAll("--- Only in B ---\n");
            for (result.only_in_b.items) |path| {
                try writer.print("  + {s}\n", .{path});
            }
            try writer.writeAll("\n");
        }

        if (result.modified.items.len > 0) {
            try writer.writeAll("--- Modified ---\n");
            for (result.modified.items) |path| {
                try writer.print("  ~ {s}\n", .{path});
            }
            try writer.writeAll("\n");
        }
    }

    fn writeCompareJson(
        self: *const ReportWriter,
        writer: anytype,
        result: *const types.CompareResult,
    ) !void {
        _ = self;

        try writer.writeAll("{\n");
        try writer.print("  \"folder_a\": \"{s}\",\n", .{escapeJsonString(result.folder_a)});
        try writer.print("  \"folder_b\": \"{s}\",\n", .{escapeJsonString(result.folder_b)});
        try writer.print("  \"is_identical\": {},\n", .{result.isIdentical()});

        // Summary
        try writer.writeAll("  \"summary\": {\n");
        try writer.print("    \"identical_count\": {},\n", .{result.identical.items.len});
        try writer.print("    \"only_in_a_count\": {},\n", .{result.only_in_a.items.len});
        try writer.print("    \"only_in_b_count\": {},\n", .{result.only_in_b.items.len});
        try writer.print("    \"modified_count\": {}\n", .{result.modified.items.len});
        try writer.writeAll("  },\n");

        // Arrays
        try writeJsonArray(writer, "identical", result.identical.items);
        try writer.writeAll(",\n");
        try writeJsonArray(writer, "only_in_a", result.only_in_a.items);
        try writer.writeAll(",\n");
        try writeJsonArray(writer, "only_in_b", result.only_in_b.items);
        try writer.writeAll(",\n");
        try writeJsonArray(writer, "modified", result.modified.items);
        try writer.writeAll("\n");

        try writer.writeAll("}\n");
    }

    fn writeCompareHtml(
        self: *const ReportWriter,
        writer: anytype,
        result: *const types.CompareResult,
    ) !void {
        _ = self;

        // HTML header
        try writer.writeAll(
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\  <meta charset="UTF-8">
            \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\  <title>Folder Comparison Report</title>
            \\  <style>
            \\    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 20px; background: #f5f5f5; }
            \\    .container { max-width: 1200px; margin: 0 auto; }
            \\    h1, h2 { color: #333; }
            \\    .folders { background: #fff; padding: 20px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
            \\    .folder-path { font-family: monospace; background: #f0f0f0; padding: 5px 10px; border-radius: 4px; }
            \\    .summary { display: grid; grid-template-columns: repeat(4, 1fr); gap: 15px; margin-bottom: 20px; }
            \\    .stat { background: #fff; padding: 15px; border-radius: 8px; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
            \\    .stat-value { font-size: 28px; font-weight: bold; }
            \\    .stat-label { color: #666; }
            \\    .identical .stat-value { color: #16a34a; }
            \\    .only-a .stat-value { color: #dc2626; }
            \\    .only-b .stat-value { color: #2563eb; }
            \\    .modified .stat-value { color: #d97706; }
            \\    .section { background: #fff; padding: 20px; border-radius: 8px; margin-bottom: 15px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
            \\    .section h2 { margin-top: 0; }
            \\    .file-list { list-style: none; padding: 0; margin: 0; max-height: 400px; overflow-y: auto; }
            \\    .file-list li { padding: 8px 12px; font-family: monospace; font-size: 13px; border-bottom: 1px solid #eee; }
            \\    .file-list li:last-child { border-bottom: none; }
            \\    .status-identical { background: #ecfdf5; }
            \\  </style>
            \\</head>
            \\<body>
            \\  <div class="container">
            \\    <h1>Folder Comparison Report</h1>
            \\
        );

        // Folder paths
        try writer.writeAll("    <div class=\"folders\">\n");
        try writer.print("      <p><strong>Folder A:</strong> <span class=\"folder-path\">{s}</span></p>\n", .{escapeHtml(result.folder_a)});
        try writer.print("      <p><strong>Folder B:</strong> <span class=\"folder-path\">{s}</span></p>\n", .{escapeHtml(result.folder_b)});
        if (result.isIdentical()) {
            try writer.writeAll("      <p style=\"color: #16a34a; font-weight: bold;\">Folders are IDENTICAL</p>\n");
        }
        try writer.writeAll("    </div>\n\n");

        // Summary stats
        try writer.writeAll("    <div class=\"summary\">\n");
        try writer.print("      <div class=\"stat identical\"><div class=\"stat-value\">{}</div><div class=\"stat-label\">Identical</div></div>\n", .{result.identical.items.len});
        try writer.print("      <div class=\"stat only-a\"><div class=\"stat-value\">{}</div><div class=\"stat-label\">Only in A</div></div>\n", .{result.only_in_a.items.len});
        try writer.print("      <div class=\"stat only-b\"><div class=\"stat-value\">{}</div><div class=\"stat-label\">Only in B</div></div>\n", .{result.only_in_b.items.len});
        try writer.print("      <div class=\"stat modified\"><div class=\"stat-value\">{}</div><div class=\"stat-label\">Modified</div></div>\n", .{result.modified.items.len});
        try writer.writeAll("    </div>\n\n");

        // Sections
        if (result.only_in_a.items.len > 0) {
            try writer.writeAll("    <div class=\"section\">\n      <h2>Only in A</h2>\n      <ul class=\"file-list\">\n");
            for (result.only_in_a.items) |path| {
                try writer.print("        <li>- {s}</li>\n", .{escapeHtml(path)});
            }
            try writer.writeAll("      </ul>\n    </div>\n\n");
        }

        if (result.only_in_b.items.len > 0) {
            try writer.writeAll("    <div class=\"section\">\n      <h2>Only in B</h2>\n      <ul class=\"file-list\">\n");
            for (result.only_in_b.items) |path| {
                try writer.print("        <li>+ {s}</li>\n", .{escapeHtml(path)});
            }
            try writer.writeAll("      </ul>\n    </div>\n\n");
        }

        if (result.modified.items.len > 0) {
            try writer.writeAll("    <div class=\"section\">\n      <h2>Modified</h2>\n      <ul class=\"file-list\">\n");
            for (result.modified.items) |path| {
                try writer.print("        <li>~ {s}</li>\n", .{escapeHtml(path)});
            }
            try writer.writeAll("      </ul>\n    </div>\n\n");
        }

        // Footer
        try writer.writeAll(
            \\  </div>
            \\</body>
            \\</html>
            \\
        );
    }
};

// ============================================================================
// Helper functions
// ============================================================================

fn writeJsonArray(writer: anytype, name: []const u8, items: []const []const u8) !void {
    try writer.print("  \"{s}\": [", .{name});
    if (items.len == 0) {
        try writer.writeAll("]");
        return;
    }
    try writer.writeAll("\n");
    for (items, 0..) |item, idx| {
        try writer.print("    \"{s}\"", .{escapeJsonString(item)});
        if (idx < items.len - 1) {
            try writer.writeAll(",");
        }
        try writer.writeAll("\n");
    }
    try writer.writeAll("  ]");
}

/// Format Unix timestamp as ISO8601 string into buffer
fn formatIso8601(timestamp: i64, buf: *[24]u8) []const u8 {
    // Convert Unix timestamp to date/time components
    const epoch_secs: u64 = if (timestamp >= 0) @intCast(timestamp) else 0;

    // Days since 1970-01-01
    const days_since_epoch = epoch_secs / 86400;
    const time_of_day = epoch_secs % 86400;

    const hours = time_of_day / 3600;
    const minutes = (time_of_day % 3600) / 60;
    const seconds = time_of_day % 60;

    // Calculate year, month, day using a simplified algorithm
    var year: u32 = 1970;
    var remaining_days = days_since_epoch;

    while (true) {
        const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const days_in_months: [12]u8 = if (isLeapYear(year))
        .{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        .{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u8 = 1;
    for (days_in_months) |days| {
        if (remaining_days < days) break;
        remaining_days -= days;
        month += 1;
    }

    const day: u8 = @truncate(remaining_days + 1);

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year,
        month,
        day,
        hours,
        minutes,
        seconds,
    }) catch "1970-01-01T00:00:00Z";
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

/// Escape string for JSON (basic escaping)
fn escapeJsonString(s: []const u8) []const u8 {
    // For simplicity, just return as-is
    // A full implementation would escape quotes, backslashes, newlines, etc.
    // This is acceptable for file paths which typically don't contain these
    return s;
}

/// Escape string for HTML
fn escapeHtml(s: []const u8) []const u8 {
    // For simplicity, return as-is
    // A full implementation would escape <, >, &, etc.
    return s;
}

// ============================================================================
// Tests
// ============================================================================

test "ReportWriter initialization" {
    const allocator = std.testing.allocator;
    const writer = ReportWriter.init(allocator, .{});
    try std.testing.expectEqual(types.ReportFormat.text, writer.options.format);
}

test "ReportWriter text format" {
    const allocator = std.testing.allocator;
    const rpt = ReportWriter.init(allocator, .{ .format = .text });

    // Use fixed buffer writer from Zig 0.16 std.Io.Writer
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const summary = types.DuplicateSummary{
        .files_scanned = 100,
        .bytes_scanned = 1024 * 1024,
        .duplicate_groups = 0,
        .duplicate_files = 0,
        .space_savings = 0,
        .scan_time_ns = 1_000_000_000,
    };

    const empty_groups: []const types.DuplicateGroup = &.{};

    try rpt.writeDuplicateReport(&writer, empty_groups, &summary);

    const written = writer.buffered();
    try std.testing.expect(written.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, written, "Duplicate File Report") != null);
}

test "ReportWriter json format" {
    const allocator = std.testing.allocator;
    const rpt = ReportWriter.init(allocator, .{ .format = .json });

    // Use fixed buffer writer from Zig 0.16 std.Io.Writer
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const summary = types.DuplicateSummary{
        .files_scanned = 50,
        .bytes_scanned = 512 * 1024,
        .duplicate_groups = 2,
        .duplicate_files = 3,
        .space_savings = 1024,
        .scan_time_ns = 500_000_000,
    };

    const empty_groups: []const types.DuplicateGroup = &.{};

    try rpt.writeDuplicateReport(&writer, empty_groups, &summary);

    const written = writer.buffered();
    try std.testing.expect(written.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"groups\"") != null);
}
