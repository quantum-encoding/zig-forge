const std = @import("std");
const Ast = std.zig.Ast;
const models = @import("../models.zig");
const parser = @import("../parser.zig");

pub const PatternKind = enum {
    allocator_param,
    io_param,
    error_handling,
    comptime_generic,
    simd,
    packed_struct,
    extern_struct,
    vtable,
    catch_discard,
};

pub const PatternInfo = struct {
    kind: PatternKind,
    file: []const u8,
    line: u32,
    context: []const u8,
};

pub fn analyze(allocator: std.mem.Allocator, source: []const u8, report: *const models.FileReport) !std.ArrayListUnmanaged(PatternInfo) {
    var patterns: std.ArrayListUnmanaged(PatternInfo) = .empty;

    // Allocator params
    for (report.functions.items) |*f| {
        if (std.mem.indexOf(u8, f.params, "Allocator") != null) {
            try patterns.append(allocator, .{
                .kind = .allocator_param,
                .file = report.relative_path,
                .line = f.line,
                .context = f.name,
            });
        }
        if (std.mem.indexOf(u8, f.params, "Io") != null) {
            try patterns.append(allocator, .{
                .kind = .io_param,
                .file = report.relative_path,
                .line = f.line,
                .context = f.name,
            });
        }
    }

    // Packed/extern structs
    for (report.structs.items) |*s| {
        if (s.kind == .packed_struct) {
            try patterns.append(allocator, .{
                .kind = .packed_struct,
                .file = report.relative_path,
                .line = s.line,
                .context = s.name,
            });
        }
        if (s.kind == .extern_struct) {
            try patterns.append(allocator, .{
                .kind = .extern_struct,
                .file = report.relative_path,
                .line = s.line,
                .context = s.name,
            });
        }
    }

    // Source-level pattern detection
    var line_num: u32 = 1;
    var start: usize = 0;
    for (source, 0..) |c, i| {
        if (c == '\n' or i == source.len - 1) {
            const end = if (c == '\n') i else i + 1;
            const line = source[start..end];
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // catch {} — silent error swallowing
            if (std.mem.indexOf(u8, trimmed, "catch {}") != null or
                std.mem.indexOf(u8, trimmed, "catch |_| {}") != null)
            {
                try patterns.append(allocator, .{
                    .kind = .catch_discard,
                    .file = report.relative_path,
                    .line = line_num,
                    .context = "silent error swallow",
                });
            }

            // @Vector — SIMD usage
            if (std.mem.indexOf(u8, trimmed, "@Vector") != null or
                std.mem.indexOf(u8, trimmed, "@shuffle") != null or
                std.mem.indexOf(u8, trimmed, "@reduce") != null)
            {
                try patterns.append(allocator, .{
                    .kind = .simd,
                    .file = report.relative_path,
                    .line = line_num,
                    .context = "SIMD",
                });
            }

            line_num += 1;
            start = i + 1;
        }
    }

    return patterns;
}
