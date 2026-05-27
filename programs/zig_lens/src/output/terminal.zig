const std = @import("std");
const models = @import("../models.zig");
const security_patterns = @import("../analyzers/security_patterns.zig");

pub fn writeReport(allocator: std.mem.Allocator, report: *const models.ProjectReport) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    try appendFmt(allocator, &buf, "\n\x1b[1;36mzig-lens\x1b[0m — {s}\n\n", .{report.name});

    const s = &report.summary;

    // Summary grid
    try appendFmt(allocator, &buf, "  \x1b[1mFiles:\x1b[0m     {d:<8}  \x1b[1mFunctions:\x1b[0m  {d}\n", .{ s.total_files, s.total_functions });
    try appendFmt(allocator, &buf, "  \x1b[1mStructs:\x1b[0m   {d:<8}  \x1b[1mEnums:\x1b[0m      {d}\n", .{ s.total_structs, s.total_enums });
    try appendFmt(allocator, &buf, "  \x1b[1mLOC:\x1b[0m       {d:<8}  \x1b[1mTests:\x1b[0m      {d}\n", .{ s.total_loc, s.total_tests });
    try appendFmt(allocator, &buf, "  \x1b[1mPub API:\x1b[0m   {d:<8}  \x1b[1mImports:\x1b[0m    {d}\n", .{ s.total_pub_functions, s.total_imports });

    if (s.total_unions > 0) {
        try appendFmt(allocator, &buf, "  \x1b[1mUnions:\x1b[0m    {d:<8}  \x1b[1mConstants:\x1b[0m  {d}\n", .{ s.total_unions, s.total_constants });
    }
    if (s.total_unsafe_ops > 0) {
        try appendFmt(allocator, &buf, "  \x1b[1mUnsafe:\x1b[0m    {d}\n", .{s.total_unsafe_ops});
    }
    if (s.parse_errors > 0) {
        try appendFmt(allocator, &buf, "  \x1b[1;31mParse errors:\x1b[0m {d}\n", .{s.parse_errors});
    }

    // Largest files (top 10)
    if (report.files.items.len > 0) {
        try appendFmt(allocator, &buf, "\n\x1b[1;33mLargest files:\x1b[0m\n", .{});

        // Sort files by LOC (descending) — copy indices
        var indices = try allocator.alloc(usize, report.files.items.len);
        defer allocator.free(indices);
        for (indices, 0..) |*idx, i| idx.* = i;

        std.mem.sortUnstable(usize, indices, report.files.items, struct {
            fn lessThan(files: []const models.FileReport, a: usize, b: usize) bool {
                return files[a].loc > files[b].loc;
            }
        }.lessThan);

        const show = @min(indices.len, 10);
        for (indices[0..show]) |idx| {
            const f = &report.files.items[idx];
            try appendFmt(allocator, &buf, "  {s:<40} {d:>5} lines  ({d} fns, {d} structs)\n", .{
                f.relative_path,
                f.loc,
                f.functions.items.len,
                f.structs.items.len,
            });
        }
    }

    // Hotspots (largest functions)
    {
        const FnRef = struct { file: []const u8, name: []const u8, lines: u32, line: u32 };
        var hotspots: std.ArrayListUnmanaged(FnRef) = .empty;
        defer hotspots.deinit(allocator);

        for (report.files.items) |*file| {
            for (file.functions.items) |*f| {
                if (f.body_lines >= 10) {
                    try hotspots.append(allocator, .{
                        .file = file.relative_path,
                        .name = f.name,
                        .lines = f.body_lines,
                        .line = f.line,
                    });
                }
            }
        }

        if (hotspots.items.len > 0) {
            std.mem.sortUnstable(FnRef, hotspots.items, {}, struct {
                fn lessThan(_: void, a: FnRef, b: FnRef) bool {
                    return a.lines > b.lines;
                }
            }.lessThan);

            try appendFmt(allocator, &buf, "\n\x1b[1;33mHotspots (largest functions):\x1b[0m\n", .{});
            const show = @min(hotspots.items.len, 10);
            for (hotspots.items[0..show]) |h| {
                try appendFmt(allocator, &buf, "  {s}:{s:<25} {d:>4} lines\n", .{ h.file, h.name, h.lines });
            }
        }
    }

    // Security anti-patterns. Surfacing these at the end of the
    // terminal output puts them in the operator's line of sight at
    // the moment the scan completes. Gating findings (high
    // confidence + gate=true) print with severity tags;
    // advisory findings (everything else) print with a WARN tag so
    // operators can tell which ones contribute to --strict and which
    // are informational.
    {
        var gating: u32 = 0;
        var advisory: u32 = 0;
        for (report.files.items) |*f| {
            for (f.security_findings.items) |sf| {
                if (sf.gate and sf.confidence == .high) gating += 1 else advisory += 1;
            }
        }
        if (gating + advisory > 0) {
            try appendFmt(allocator, &buf,
                "\n\x1b[1;31mSecurity findings ({d} gating, {d} advisory):\x1b[0m\n",
                .{ gating, advisory },
            );
            for (report.files.items) |*file| {
                for (file.security_findings.items) |sf| {
                    const is_gating = sf.gate and sf.confidence == .high;
                    const tag = if (is_gating) switch (sf.severity) {
                        .critical => "\x1b[1;31mCRITICAL\x1b[0m",
                        .high => "\x1b[1;33mHIGH\x1b[0m    ",
                        .medium => "\x1b[1;33mMEDIUM\x1b[0m  ",
                        .low => "\x1b[1;34mLOW\x1b[0m     ",
                    } else "\x1b[1;36mWARN\x1b[0m    ";
                    try appendFmt(allocator, &buf,
                        "  {s} [{s:<18}] conf={s:<6} gate={s} {s}:{d}\n    {s}\n    \x1b[2m{s}\x1b[0m\n",
                        .{
                            tag,
                            sf.rule_id,
                            sf.confidence.toString(),
                            if (sf.gate) "yes" else "no ",
                            file.relative_path,
                            sf.line,
                            sf.message,
                            sf.snippet,
                        },
                    );
                }
            }
        }

        // Coverage panel — ALWAYS printed, even when the scan is
        // clean. The whole point: a scanner that's read as a
        // trusted gate must declare its gaps in-band, so "no
        // findings" is never confused with "this class is
        // handled." Each rule states what it catches and what it
        // does NOT catch.
        try appendFmt(allocator, &buf,
            "\n\x1b[1mSecurity scanner coverage:\x1b[0m \x1b[2m(a clean scan \xe2\x89\xa0 \"no vulnerabilities\" \xe2\x80\x94 each rule has gaps)\x1b[0m\n",
            .{},
        );
        for (security_patterns.ruleCoverage()) |rc| {
            try appendFmt(allocator, &buf,
                "\n  \x1b[1m[{s}]\x1b[0m {s} \x1b[2m(conf={s}, gate={s})\x1b[0m\n",
                .{ rc.id, rc.summary, rc.confidence, if (rc.gate) "yes" else "no" },
            );
            try appendFmt(allocator, &buf, "    \x1b[32mCovers:\x1b[0m\n", .{});
            try indentedBlock(allocator, &buf, rc.covers, "      ");
            try appendFmt(allocator, &buf, "    \x1b[33mDoes NOT cover:\x1b[0m\n", .{});
            try indentedBlock(allocator, &buf, rc.does_not_cover, "      ");
        }
    }

    try buf.append(allocator, '\n');
    return buf.items;
}

fn indentedBlock(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), text: []const u8, indent: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try buf.appendSlice(allocator, indent);
        try buf.appendSlice(allocator, line);
        try buf.append(allocator, '\n');
    }
}

fn appendFmt(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}
