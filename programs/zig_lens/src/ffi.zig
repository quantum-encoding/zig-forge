// =============================================================================
// ZIG-LENS FFI — C-Compatible Source Code Analysis Interface
// =============================================================================
// Static library interface for importing zig-lens analysis into other programs.
// All functions use C calling conventions and C-compatible types.
//
// Memory model:
//   Functions returning variable-length data allocate internally.
//   Caller MUST call zig_lens_free_buffer(ptr, len) to release returned buffers.
//   zig_lens_count_lines and zig_lens_get_error use caller-owned storage — no free.
// =============================================================================

const std = @import("std");
const Ast = std.zig.Ast;
const models = @import("models.zig");
const scanner = @import("scanner.zig");
const parser_mod = @import("parser.zig");
const structure = @import("analyzers/structure.zig");
const imports_analyzer = @import("analyzers/imports.zig");
const unsafe_ops = @import("analyzers/unsafe_ops.zig");
const rust_analyzer = @import("analyzers/rust.zig");
const c_analyzer = @import("analyzers/c_lang.zig");
const python_analyzer = @import("analyzers/python.zig");
const js_analyzer = @import("analyzers/javascript.zig");
const go_analyzer = @import("analyzers/go.zig");
const json_output = @import("output/json.zig");
const terminal_output = @import("output/terminal.zig");
const markdown_output = @import("output/markdown.zig");
const graph_builder = @import("graph/builder.zig");
const graph_dot = @import("graph/dot.zig");
const report_gen = @import("output/report.zig");
const compile_output = @import("output/compile.zig");

// =============================================================================
// Result Codes
// =============================================================================

pub const ZigLensResult = enum(c_int) {
    ok = 0,
    err_null_ptr = -1,
    err_invalid_arg = -2,
    err_analysis = -3,
    err_io = -4,
    err_oom = -5,
};

// =============================================================================
// Format & Language Codes (matching C header #defines)
// =============================================================================

const OutputFormat = enum(c_int) {
    json = 0,
    compact = 1,
    terminal = 2,
    markdown = 3,
    dot = 4,
};

const LangCode = enum(c_int) {
    zig = 0,
    rust = 1,
    c_lang = 2,
    python = 3,
    javascript = 4,
    go = 5,
};

fn toOutputFormat(value: c_int) ?OutputFormat {
    return switch (value) {
        0 => .json,
        1 => .compact,
        2 => .terminal,
        3 => .markdown,
        4 => .dot,
        else => null,
    };
}

fn toLangCode(value: c_int) ?LangCode {
    return switch (value) {
        0 => .zig,
        1 => .rust,
        2 => .c_lang,
        3 => .python,
        4 => .javascript,
        5 => .go,
        else => null,
    };
}

// =============================================================================
// Progress Callback
// =============================================================================

pub const ZigLensProgressCallback = ?*const fn (percent: c_int, message: [*c]const u8) callconv(.c) void;

fn reportProgress(cb: ZigLensProgressCallback, percent: c_int, message: [*c]const u8) void {
    if (cb) |callback| {
        callback(percent, message);
    }
}

// =============================================================================
// Thread-Local Error Storage
// =============================================================================

threadlocal var last_error_msg: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setLastError(msg: []const u8) void {
    const copy_len = @min(msg.len, last_error_msg.len - 1);
    @memcpy(last_error_msg[0..copy_len], msg[0..copy_len]);
    last_error_msg[copy_len] = 0;
    last_error_len = copy_len;
}

/// Retrieve the last error message for this thread.
/// If buf is null or buf_size is 0, returns the required length.
/// Otherwise copies the error into buf (null-terminated) and returns the length.
/// Caller owns buf — no free needed.
export fn zig_lens_get_error(buf: [*c]u8, buf_size: usize) usize {
    if (@intFromPtr(buf) == 0 or buf_size == 0) return last_error_len;
    const copy_len = @min(last_error_len, buf_size - 1);
    @memcpy(buf[0..copy_len], last_error_msg[0..copy_len]);
    buf[copy_len] = 0;
    return copy_len;
}

// =============================================================================
// Version
// =============================================================================

/// Returns a pointer to a static null-terminated version string.
/// Do NOT free the returned pointer.
export fn zig_lens_version() [*c]const u8 {
    return "0.1.0";
}

// =============================================================================
// Internal Helpers
// =============================================================================

fn readSourceFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(10 * 1024 * 1024),
        .of(u8),
        0,
    ) catch {
        return error.FileReadFailed;
    };
}

fn isSingleFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") or
        std.mem.endsWith(u8, path, ".rs") or
        std.mem.endsWith(u8, path, ".c") or
        std.mem.endsWith(u8, path, ".h") or
        std.mem.endsWith(u8, path, ".py") or
        std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".tsx") or
        std.mem.endsWith(u8, path, ".jsx") or
        std.mem.endsWith(u8, path, ".svelte");
}

const AnalysisResult = struct {
    report: models.ProjectReport,
    graph: graph_builder.DependencyGraph,
};

/// Core analysis pipeline: scan → parse → analyze → summary → graph.
/// Mirrors the pipeline in main.zig but extracted for reuse.
fn buildProjectReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    target_path: []const u8,
    progress_cb: ZigLensProgressCallback,
) !AnalysisResult {
    reportProgress(progress_cb, 5, "Scanning files");

    const entries = if (isSingleFile(target_path))
        try scanner.scanSingleFile(allocator, target_path)
    else
        try scanner.scanDirectory(allocator, io, target_path);

    var report = models.ProjectReport.init();
    report.name = scanner.detectProjectName(target_path);
    report.root_path = target_path;

    const total_files = entries.items.len;

    reportProgress(progress_cb, 10, "Analyzing files");

    for (entries.items, 0..) |entry, file_idx| {
        if (total_files > 0) {
            const pct: c_int = @intCast(10 + (file_idx * 75 / total_files));
            reportProgress(progress_cb, pct, "Analyzing");
        }

        var file_report = models.FileReport.init();
        file_report.path = entry.path;
        file_report.relative_path = entry.relative_path;
        file_report.size_bytes = entry.size_bytes;
        file_report.language = entry.language;

        switch (entry.language) {
            .zig => {
                const result = parser_mod.parseFile(allocator, io, entry.path) catch {
                    file_report.parse_error = true;
                    try report.files.append(allocator, file_report);
                    continue;
                };
                var ast = result.ast;
                defer ast.deinit(allocator);
                const source = result.source;
                defer allocator.free(source);

                const line_counts = parser_mod.countLines(source);
                file_report.loc = line_counts.loc;
                file_report.blank_lines = line_counts.blank;
                file_report.comment_lines = line_counts.comments;
                file_report.size_bytes = source.len;

                structure.analyze(allocator, &ast, &file_report) catch {
                    file_report.parse_error = true;
                };
                imports_analyzer.analyze(allocator, &ast, &file_report) catch {};
                unsafe_ops.analyze(allocator, &ast, &file_report) catch {};
            },
            .rust, .c, .python, .javascript, .go => {
                const source = readSourceFile(io, allocator, entry.path) catch {
                    file_report.parse_error = true;
                    try report.files.append(allocator, file_report);
                    continue;
                };
                defer allocator.free(source);

                const line_counts = parser_mod.countLines(source);
                file_report.loc = line_counts.loc;
                file_report.blank_lines = line_counts.blank;
                file_report.comment_lines = line_counts.comments;
                file_report.size_bytes = source.len;

                switch (entry.language) {
                    .rust => rust_analyzer.analyze(allocator, source, &file_report) catch {
                        file_report.parse_error = true;
                    },
                    .c => c_analyzer.analyze(allocator, source, &file_report) catch {
                        file_report.parse_error = true;
                    },
                    .python => python_analyzer.analyze(allocator, source, &file_report) catch {
                        file_report.parse_error = true;
                    },
                    .javascript => js_analyzer.analyze(allocator, source, &file_report) catch {
                        file_report.parse_error = true;
                    },
                    .go => go_analyzer.analyze(allocator, source, &file_report) catch {
                        file_report.parse_error = true;
                    },
                    else => {},
                }
            },
        }

        try report.files.append(allocator, file_report);
    }

    reportProgress(progress_cb, 85, "Computing summary");
    report.computeSummary();

    reportProgress(progress_cb, 88, "Building dependency graph");
    const graph = graph_builder.buildGraph(allocator, &report) catch graph_builder.DependencyGraph.init();

    return .{ .report = report, .graph = graph };
}

/// Copy arena-allocated data to a standalone page_allocator allocation.
/// The returned slice survives arena teardown and must be freed via zig_lens_free_buffer.
fn dupeToPageAllocator(data: []const u8) ![]u8 {
    const alloc = std.heap.page_allocator;
    const copy = try alloc.alloc(u8, data.len);
    @memcpy(copy, data);
    return copy;
}

// =============================================================================
// Exported FFI Functions
// =============================================================================

/// Analyze a file or directory. Returns analysis results in the requested format.
///
/// Parameters:
///   path_ptr      — Null-terminated path to file or directory
///   format        — Output format (ZIG_LENS_FORMAT_*)
///   progress_cb   — Optional progress callback (NULL for no progress)
///   out_buf       — Receives pointer to result buffer (caller must free with zig_lens_free_buffer)
///   out_len       — Receives length of result buffer
///
/// Returns: ZIG_LENS_OK on success, negative error code on failure
export fn zig_lens_analyze_path(
    path_ptr: [*c]const u8,
    format: c_int,
    progress_cb: ZigLensProgressCallback,
    out_buf: *[*c]u8,
    out_len: *usize,
) c_int {
    if (@intFromPtr(path_ptr) == 0 or @intFromPtr(out_buf) == 0 or @intFromPtr(out_len) == 0) {
        setLastError("null pointer argument");
        return @intFromEnum(ZigLensResult.err_null_ptr);
    }

    const path = std.mem.span(path_ptr);
    if (path.len == 0) {
        setLastError("empty path");
        return @intFromEnum(ZigLensResult.err_invalid_arg);
    }

    const fmt = toOutputFormat(format) orelse {
        setLastError("unknown format code");
        return @intFromEnum(ZigLensResult.err_invalid_arg);
    };

    // Per-call arena
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // I/O context for file operations
    var io_threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    reportProgress(progress_cb, 0, "Starting analysis");

    const result = buildProjectReport(allocator, io, path, progress_cb) catch {
        setLastError("analysis pipeline failed");
        return @intFromEnum(ZigLensResult.err_analysis);
    };

    reportProgress(progress_cb, 90, "Generating output");

    const output = switch (fmt) {
        .json => json_output.writeProjectReport(allocator, &result.report, false),
        .compact => json_output.writeProjectReport(allocator, &result.report, true),
        .terminal => terminal_output.writeReport(allocator, &result.report),
        .markdown => markdown_output.writeReport(allocator, &result.report, &result.graph),
        .dot => graph_dot.writeDot(allocator, &result.graph, result.report.name),
    } catch {
        setLastError("output generation failed");
        return @intFromEnum(ZigLensResult.err_analysis);
    };

    const standalone = dupeToPageAllocator(output) catch {
        setLastError("out of memory copying result");
        return @intFromEnum(ZigLensResult.err_oom);
    };

    out_buf.* = standalone.ptr;
    out_len.* = standalone.len;

    reportProgress(progress_cb, 100, "Complete");
    return @intFromEnum(ZigLensResult.ok);
}

/// Compile an entire codebase into a single Markdown document.
///
/// Parameters:
///   path_ptr      — Null-terminated path to directory
///   progress_cb   — Optional progress callback
///   out_buf       — Receives pointer to result buffer (caller must free)
///   out_len       — Receives length of result buffer
///
/// Returns: ZIG_LENS_OK on success, negative error code on failure
export fn zig_lens_compile_codebase(
    path_ptr: [*c]const u8,
    progress_cb: ZigLensProgressCallback,
    out_buf: *[*c]u8,
    out_len: *usize,
) c_int {
    if (@intFromPtr(path_ptr) == 0 or @intFromPtr(out_buf) == 0 or @intFromPtr(out_len) == 0) {
        setLastError("null pointer argument");
        return @intFromEnum(ZigLensResult.err_null_ptr);
    }

    const path = std.mem.span(path_ptr);
    if (path.len == 0) {
        setLastError("empty path");
        return @intFromEnum(ZigLensResult.err_invalid_arg);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var io_threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    reportProgress(progress_cb, 0, "Compiling codebase");

    const project_name = scanner.detectProjectName(path);
    const output = compile_output.compileCodebase(allocator, io, path, project_name) catch {
        setLastError("codebase compilation failed");
        return @intFromEnum(ZigLensResult.err_analysis);
    };

    const standalone = dupeToPageAllocator(output) catch {
        setLastError("out of memory copying result");
        return @intFromEnum(ZigLensResult.err_oom);
    };

    out_buf.* = standalone.ptr;
    out_len.* = standalone.len;

    reportProgress(progress_cb, 100, "Complete");
    return @intFromEnum(ZigLensResult.ok);
}

/// Generate all report formats (JSON, Markdown, DOT, OVERVIEW) into a directory.
///
/// Parameters:
///   path_ptr       — Null-terminated path to file or directory to analyze
///   output_dir_ptr — Null-terminated path to output directory (created if needed)
///   progress_cb    — Optional progress callback
///
/// Returns: ZIG_LENS_OK on success, negative error code on failure
/// No buffer is returned — files are written to disk.
export fn zig_lens_generate_reports(
    path_ptr: [*c]const u8,
    output_dir_ptr: [*c]const u8,
    progress_cb: ZigLensProgressCallback,
) c_int {
    if (@intFromPtr(path_ptr) == 0 or @intFromPtr(output_dir_ptr) == 0) {
        setLastError("null pointer argument");
        return @intFromEnum(ZigLensResult.err_null_ptr);
    }

    const path = std.mem.span(path_ptr);
    const output_dir = std.mem.span(output_dir_ptr);

    if (path.len == 0 or output_dir.len == 0) {
        setLastError("empty path or output directory");
        return @intFromEnum(ZigLensResult.err_invalid_arg);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var io_threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    reportProgress(progress_cb, 0, "Generating reports");

    const result = buildProjectReport(allocator, io, path, progress_cb) catch {
        setLastError("analysis pipeline failed");
        return @intFromEnum(ZigLensResult.err_analysis);
    };

    reportProgress(progress_cb, 90, "Writing reports");

    report_gen.generateReports(allocator, io, &result.report, &result.graph, output_dir) catch {
        setLastError("report generation failed");
        return @intFromEnum(ZigLensResult.err_io);
    };

    reportProgress(progress_cb, 100, "Complete");
    return @intFromEnum(ZigLensResult.ok);
}

/// Analyze in-memory source code without file I/O.
/// Returns JSON analysis of a single source buffer.
///
/// Parameters:
///   source_ptr — Pointer to source code bytes
///   source_len — Length of source code
///   language   — Language code (ZIG_LENS_LANG_*)
///   out_buf    — Receives pointer to JSON result (caller must free)
///   out_len    — Receives length of result
///
/// Returns: ZIG_LENS_OK on success, negative error code on failure
export fn zig_lens_analyze_source(
    source_ptr: [*c]const u8,
    source_len: usize,
    language: c_int,
    out_buf: *[*c]u8,
    out_len: *usize,
) c_int {
    if (@intFromPtr(source_ptr) == 0 or @intFromPtr(out_buf) == 0 or @intFromPtr(out_len) == 0) {
        setLastError("null pointer argument");
        return @intFromEnum(ZigLensResult.err_null_ptr);
    }

    if (source_len == 0) {
        setLastError("empty source");
        return @intFromEnum(ZigLensResult.err_invalid_arg);
    }

    const lang = toLangCode(language) orelse {
        setLastError("unknown language code");
        return @intFromEnum(ZigLensResult.err_invalid_arg);
    };

    const source = source_ptr[0..source_len];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var file_report = models.FileReport.init();
    file_report.relative_path = "source";
    file_report.language = switch (lang) {
        .zig => .zig,
        .rust => .rust,
        .c_lang => .c,
        .python => .python,
        .javascript => .javascript,
        .go => .go,
    };

    // Line counting (language-agnostic)
    const line_counts = parser_mod.countLines(source);
    file_report.loc = line_counts.loc;
    file_report.blank_lines = line_counts.blank;
    file_report.comment_lines = line_counts.comments;
    file_report.size_bytes = source.len;

    // Language-specific analysis
    switch (lang) {
        .zig => {
            const source_z = allocator.dupeZ(u8, source) catch {
                setLastError("out of memory");
                return @intFromEnum(ZigLensResult.err_oom);
            };

            var ast = Ast.parse(allocator, source_z, .zig) catch {
                setLastError("zig parse failed");
                return @intFromEnum(ZigLensResult.err_analysis);
            };
            defer ast.deinit(allocator);

            structure.analyze(allocator, &ast, &file_report) catch {};
            imports_analyzer.analyze(allocator, &ast, &file_report) catch {};
            unsafe_ops.analyze(allocator, &ast, &file_report) catch {};
        },
        .rust => rust_analyzer.analyze(allocator, source, &file_report) catch {
            file_report.parse_error = true;
        },
        .c_lang => c_analyzer.analyze(allocator, source, &file_report) catch {
            file_report.parse_error = true;
        },
        .python => python_analyzer.analyze(allocator, source, &file_report) catch {
            file_report.parse_error = true;
        },
        .javascript => js_analyzer.analyze(allocator, source, &file_report) catch {
            file_report.parse_error = true;
        },
        .go => go_analyzer.analyze(allocator, source, &file_report) catch {
            file_report.parse_error = true;
        },
    }

    // Wrap in a ProjectReport for JSON serialization
    var report = models.ProjectReport.init();
    report.name = "source";
    report.files.append(allocator, file_report) catch {
        setLastError("out of memory");
        return @intFromEnum(ZigLensResult.err_oom);
    };
    report.computeSummary();

    const output = json_output.writeProjectReport(allocator, &report, false) catch {
        setLastError("JSON serialization failed");
        return @intFromEnum(ZigLensResult.err_analysis);
    };

    const standalone = dupeToPageAllocator(output) catch {
        setLastError("out of memory copying result");
        return @intFromEnum(ZigLensResult.err_oom);
    };

    out_buf.* = standalone.ptr;
    out_len.* = standalone.len;

    return @intFromEnum(ZigLensResult.ok);
}

/// Count lines, blank lines, and comment lines in source code.
/// Pure function — no allocation, no I/O, no free needed.
///
/// Parameters:
///   source_ptr   — Pointer to source code bytes
///   source_len   — Length of source code
///   out_loc      — Receives total line count
///   out_blank    — Receives blank line count
///   out_comments — Receives comment line count
///
/// Returns: ZIG_LENS_OK on success, negative error code on failure
export fn zig_lens_count_lines(
    source_ptr: [*c]const u8,
    source_len: usize,
    out_loc: *u32,
    out_blank: *u32,
    out_comments: *u32,
) c_int {
    if (@intFromPtr(source_ptr) == 0 or
        @intFromPtr(out_loc) == 0 or
        @intFromPtr(out_blank) == 0 or
        @intFromPtr(out_comments) == 0)
    {
        setLastError("null pointer argument");
        return @intFromEnum(ZigLensResult.err_null_ptr);
    }

    const source = source_ptr[0..source_len];
    const counts = parser_mod.countLines(source);

    out_loc.* = counts.loc;
    out_blank.* = counts.blank;
    out_comments.* = counts.comments;

    return @intFromEnum(ZigLensResult.ok);
}

/// Free a buffer previously allocated by zig-lens.
/// Must be called on buffers returned by zig_lens_analyze_path,
/// zig_lens_compile_codebase, and zig_lens_analyze_source.
///
/// Parameters:
///   ptr — Pointer returned via out_buf
///   len — Length returned via out_len
export fn zig_lens_free_buffer(ptr: [*c]u8, len: usize) void {
    if (@intFromPtr(ptr) == 0 or len == 0) return;
    std.heap.page_allocator.free(ptr[0..len]);
}

// =============================================================================
// Tests
// =============================================================================

test "zig_lens_version returns non-null string" {
    const ver = zig_lens_version();
    try std.testing.expect(@intFromPtr(ver) != 0);
    const version = std.mem.span(ver);
    try std.testing.expect(version.len > 0);
}

test "zig_lens_count_lines basic" {
    const source = "fn main() void {\n    return;\n}\n";
    var loc: u32 = 0;
    var blank: u32 = 0;
    var comments: u32 = 0;

    const result = zig_lens_count_lines(source, source.len, &loc, &blank, &comments);
    try std.testing.expectEqual(@intFromEnum(ZigLensResult.ok), result);
    try std.testing.expectEqual(@as(u32, 3), loc);
    try std.testing.expectEqual(@as(u32, 0), blank);
    try std.testing.expectEqual(@as(u32, 0), comments);
}

test "zig_lens_count_lines with comments and blanks" {
    const source = "// header\n\nfn foo() void {}\n";
    var loc: u32 = 0;
    var blank: u32 = 0;
    var comments: u32 = 0;

    const result = zig_lens_count_lines(source, source.len, &loc, &blank, &comments);
    try std.testing.expectEqual(@intFromEnum(ZigLensResult.ok), result);
    try std.testing.expectEqual(@as(u32, 3), loc);
    try std.testing.expectEqual(@as(u32, 1), blank);
    try std.testing.expectEqual(@as(u32, 1), comments);
}

test "zig_lens_count_lines null ptr returns error" {
    var loc: u32 = 0;
    var blank: u32 = 0;
    var comments: u32 = 0;

    const result = zig_lens_count_lines(@as([*c]const u8, @ptrFromInt(0)), 10, &loc, &blank, &comments);
    try std.testing.expectEqual(@intFromEnum(ZigLensResult.err_null_ptr), result);
}

test "zig_lens_get_error retrieves stored error" {
    setLastError("test error message");
    var buf: [64]u8 = undefined;
    const len = zig_lens_get_error(&buf, 64);
    try std.testing.expect(len > 0);
    try std.testing.expectEqualSlices(u8, "test error message", buf[0..len]);
}

test "zig_lens_free_buffer handles null safely" {
    zig_lens_free_buffer(@as([*c]u8, @ptrFromInt(0)), 0);
}

test "zig_lens_analyze_path rejects null" {
    var buf: [*c]u8 = undefined;
    var len: usize = 0;
    const result = zig_lens_analyze_path(@as([*c]const u8, @ptrFromInt(0)), 0, null, &buf, &len);
    try std.testing.expectEqual(@intFromEnum(ZigLensResult.err_null_ptr), result);
}

test "zig_lens_analyze_path rejects invalid format" {
    var buf: [*c]u8 = undefined;
    var len: usize = 0;
    const result = zig_lens_analyze_path("test.zig", 99, null, &buf, &len);
    try std.testing.expectEqual(@intFromEnum(ZigLensResult.err_invalid_arg), result);
}

test "zig_lens_analyze_source rejects null" {
    var buf: [*c]u8 = undefined;
    var len: usize = 0;
    const result = zig_lens_analyze_source(@as([*c]const u8, @ptrFromInt(0)), 0, 0, &buf, &len);
    try std.testing.expectEqual(@intFromEnum(ZigLensResult.err_null_ptr), result);
}

test "zig_lens_analyze_source rejects invalid language" {
    var buf: [*c]u8 = undefined;
    var len: usize = 0;
    const source = "fn main() void {}";
    const result = zig_lens_analyze_source(source, source.len, 99, &buf, &len);
    try std.testing.expectEqual(@intFromEnum(ZigLensResult.err_invalid_arg), result);
}

test "isSingleFile detects file extensions" {
    try std.testing.expect(isSingleFile("main.zig"));
    try std.testing.expect(isSingleFile("lib.rs"));
    try std.testing.expect(isSingleFile("app.py"));
    try std.testing.expect(isSingleFile("index.ts"));
    try std.testing.expect(isSingleFile("main.c"));
    try std.testing.expect(!isSingleFile("src/"));
    try std.testing.expect(!isSingleFile("project"));
}
