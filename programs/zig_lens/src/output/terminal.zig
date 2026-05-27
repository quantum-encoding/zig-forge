const std = @import("std");
const models = @import("../models.zig");

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
    // the moment the scan completes — the rules are designed to be
    // ship-blockers (matched against the C5/H/M findings from the
    // zig_ai_server audit), so they shouldn't get buried behind a
    // page of summary data.
    {
        var total: u32 = 0;
        for (report.files.items) |*f| total += @intCast(f.security_findings.items.len);
        if (total > 0) {
            try appendFmt(allocator, &buf, "\n\x1b[1;31mSecurity findings ({d}):\x1b[0m\n", .{total});
            for (report.files.items) |*file| {
                for (file.security_findings.items) |sf| {
                    const tag = switch (sf.severity) {
                        .critical => "\x1b[1;31mCRITICAL\x1b[0m",
                        .high => "\x1b[1;33mHIGH\x1b[0m    ",
                        .medium => "\x1b[1;33mMEDIUM\x1b[0m  ",
                        .low => "\x1b[1;34mLOW\x1b[0m     ",
                    };
                    try appendFmt(allocator, &buf, "  {s} [{s:<18}] {s}:{d}\n    {s}\n    \x1b[2m{s}\x1b[0m\n", .{
                        tag,
                        sf.rule_id,
                        file.relative_path,
                        sf.line,
                        sf.message,
                        sf.snippet,
                    });
                }
            }
        }
    }

    try buf.append(allocator, '\n');
    return buf.items;
}

fn appendFmt(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}
