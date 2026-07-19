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

/// Focused import/dependency view — the `--imports` flag. Lists every
/// file's `@import`s classified as std / local / package, so an operator
/// (or agent) can read the dependency surface without the full report.
pub fn writeImportsReport(allocator: std.mem.Allocator, report: *const models.ProjectReport) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    try appendFmt(allocator, &buf, "\n\x1b[1;36mzig-lens\x1b[0m — {s} \x1b[2m(imports)\x1b[0m\n", .{report.name});
    try appendFmt(allocator, &buf, "\n  \x1b[1mFiles:\x1b[0m {d:<8}  \x1b[1mImports:\x1b[0m {d}\n", .{ report.summary.total_files, report.summary.total_imports });

    for (report.files.items) |*file| {
        if (file.imports.items.len == 0) continue;
        try appendFmt(allocator, &buf, "\n\x1b[1;33m{s}\x1b[0m\n", .{file.relative_path});
        for (file.imports.items) |imp| {
            const kind = switch (imp.kind) {
                .std_lib => "\x1b[2mstd  \x1b[0m",
                .local => "\x1b[36mlocal\x1b[0m",
                .package => "\x1b[35mpkg  \x1b[0m",
            };
            if (imp.binding_name.len > 0) {
                try appendFmt(allocator, &buf, "  {s}  {s:<28} \x1b[2mas {s}\x1b[0m\n", .{ kind, imp.path, imp.binding_name });
            } else {
                try appendFmt(allocator, &buf, "  {s}  {s}\n", .{ kind, imp.path });
            }
        }
    }

    try buf.append(allocator, '\n');
    return buf.items;
}

/// Focused unsafe-operations audit — the `--unsafe` flag. Lists every
/// `@ptrCast` / `@intFromPtr` / `asm` / etc. the unsafe-ops analyzer
/// recorded, with its risk level and enclosing function.
pub fn writeUnsafeReport(allocator: std.mem.Allocator, report: *const models.ProjectReport) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    try appendFmt(allocator, &buf, "\n\x1b[1;36mzig-lens\x1b[0m — {s} \x1b[2m(unsafe operations)\x1b[0m\n", .{report.name});
    try appendFmt(allocator, &buf, "\n  \x1b[1mFiles:\x1b[0m {d:<8}  \x1b[1mUnsafe ops:\x1b[0m {d}\n", .{ report.summary.total_files, report.summary.total_unsafe_ops });

    if (report.summary.total_unsafe_ops == 0) {
        try appendFmt(allocator, &buf, "\n  \x1b[32mNo unsafe operations recorded.\x1b[0m\n", .{});
        return buf.items;
    }

    for (report.files.items) |*file| {
        if (file.unsafe_ops.items.len == 0) continue;
        try appendFmt(allocator, &buf, "\n\x1b[1;33m{s}\x1b[0m\n", .{file.relative_path});
        for (file.unsafe_ops.items) |op| {
            const risk = switch (op.risk_level) {
                .critical => "\x1b[1;31mCRITICAL\x1b[0m",
                .high => "\x1b[1;31mHIGH\x1b[0m    ",
                .medium => "\x1b[1;33mMEDIUM\x1b[0m  ",
                .low => "\x1b[2mLOW\x1b[0m     ",
            };
            const ctx = if (op.context_fn.len > 0) op.context_fn else "\x1b[2m(top-level)\x1b[0m";
            try appendFmt(allocator, &buf, "  {s}  {s:<18} :{d:<5} \x1b[2min\x1b[0m {s}\n", .{ risk, op.operation, op.line, ctx });
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

// ── Tests: the --imports / --unsafe focused views ────────────────────
//
// These guard against the flags regressing to no-ops (their prior
// state): the renderers must surface the imports / unsafe-ops the
// analyzers recorded.

test "writeImportsReport lists imports with kind + binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report = models.ProjectReport.init();
    var file = models.FileReport.init();
    file.relative_path = "core.zig";
    try file.imports.append(a, .{ .path = "std", .kind = .std_lib, .binding_name = "std", .line = 1 });
    try file.imports.append(a, .{ .path = "ring.zig", .kind = .local, .binding_name = "ring", .line = 2 });
    try report.files.append(a, file);
    report.computeSummary();

    const out = try writeImportsReport(a, &report);
    try std.testing.expect(std.mem.indexOf(u8, out, "core.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ring.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "as ring") != null);
}

test "writeUnsafeReport lists unsafe ops with risk + line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report = models.ProjectReport.init();
    var file = models.FileReport.init();
    file.relative_path = "mmio.zig";
    try file.unsafe_ops.append(a, .{ .line = 42, .operation = "@ptrCast", .context_fn = "mapReg", .risk_level = .high });
    try report.files.append(a, file);
    report.computeSummary();

    const out = try writeUnsafeReport(a, &report);
    try std.testing.expect(std.mem.indexOf(u8, out, "mmio.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@ptrCast") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mapReg") != null);
}

test "writeUnsafeReport reports clean when no unsafe ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report = models.ProjectReport.init();
    report.computeSummary();
    const out = try writeUnsafeReport(a, &report);
    try std.testing.expect(std.mem.indexOf(u8, out, "No unsafe operations") != null);
}
