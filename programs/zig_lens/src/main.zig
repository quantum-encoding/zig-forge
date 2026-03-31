const std = @import("std");
const Ast = std.zig.Ast;
const models = @import("models.zig");
const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
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
const graph_cycles = @import("graph/cycles.zig");
const report_gen = @import("output/report.zig");
const compile_output = @import("output/compile.zig");

const Format = enum {
    terminal,
    json,
    markdown,
    dot,
};

const Config = struct {
    target_path: []const u8 = "",
    format: Format = .terminal,
    compact: bool = false,
    output_file: []const u8 = "",
    report_dir: []const u8 = "",
    imports_only: bool = false,
    unsafe_only: bool = false,
    compile: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const backing = std.heap.c_allocator;

    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse CLI arguments
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--format") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) {
                config.format = .json;
            } else if (std.mem.eql(u8, args[i], "terminal")) {
                config.format = .terminal;
            } else if (std.mem.eql(u8, args[i], "markdown") or std.mem.eql(u8, args[i], "md")) {
                config.format = .markdown;
            } else if (std.mem.eql(u8, args[i], "dot")) {
                config.format = .dot;
            } else {
                std.debug.print("Unknown format: {s}\n", .{args[i]});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--compact")) {
            config.compact = true;
        } else if (std.mem.eql(u8, arg, "--output") and i + 1 < args.len) {
            i += 1;
            config.output_file = args[i];
        } else if (std.mem.eql(u8, arg, "--imports")) {
            config.imports_only = true;
        } else if (std.mem.eql(u8, arg, "--unsafe")) {
            config.unsafe_only = true;
        } else if (std.mem.eql(u8, arg, "--compile")) {
            config.compile = true;
        } else if (std.mem.eql(u8, arg, "--report") and i + 1 < args.len) {
            i += 1;
            config.report_dir = args[i];
        } else if (arg.len > 0 and arg[0] != '-') {
            config.target_path = arg;
        }
    }

    if (config.target_path.len == 0) {
        printUsage();
        return;
    }

    // --compact implies JSON format
    if (config.compact) config.format = .json;

    // Create IO context (needed by both compile and analysis modes)
    var io_threaded = std.Io.Threaded.init(allocator, .{ .environ = init.minimal.environ });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    // Compile mode: produce single-file codebase compilation
    if (config.compile) {
        const project_name = scanner.detectProjectName(config.target_path);
        const output = try compile_output.compileCodebase(allocator, io, config.target_path, project_name);
        if (config.output_file.len > 0) {
            writeOutputFile(io, config.output_file, output);
            std.debug.print("Compiled {s} -> {s}\n", .{ config.target_path, config.output_file });
        } else {
            std.debug.print("{s}", .{output});
        }
        return;
    }

    // Scan for files
    const is_single_file = std.mem.endsWith(u8, config.target_path, ".zig") or
        std.mem.endsWith(u8, config.target_path, ".rs") or
        std.mem.endsWith(u8, config.target_path, ".c") or
        std.mem.endsWith(u8, config.target_path, ".h") or
        std.mem.endsWith(u8, config.target_path, ".py") or
        std.mem.endsWith(u8, config.target_path, ".js") or
        std.mem.endsWith(u8, config.target_path, ".ts") or
        std.mem.endsWith(u8, config.target_path, ".tsx") or
        std.mem.endsWith(u8, config.target_path, ".jsx") or
        std.mem.endsWith(u8, config.target_path, ".svelte") or
        std.mem.endsWith(u8, config.target_path, ".go");
    const entries = if (is_single_file)
        try scanner.scanSingleFile(allocator, config.target_path)
    else
        try scanner.scanDirectory(allocator, io, config.target_path);

    // Build project report
    var report = models.ProjectReport.init();
    report.name = scanner.detectProjectName(config.target_path);
    report.root_path = config.target_path;

    // Parse and analyze each file
    for (entries.items) |entry| {
        var file_report = models.FileReport.init();
        file_report.path = entry.path;
        file_report.relative_path = entry.relative_path;
        file_report.size_bytes = entry.size_bytes;
        file_report.language = entry.language;

        switch (entry.language) {
            .zig => {
                const result = parser.parseFile(allocator, io, entry.path) catch {
                    file_report.parse_error = true;
                    try report.files.append(allocator, file_report);
                    continue;
                };
                var ast = result.ast;
                defer ast.deinit(allocator);
                const source = result.source;
                defer allocator.free(source);

                // Count lines
                const line_counts = parser.countLines(source);
                file_report.loc = line_counts.loc;
                file_report.blank_lines = line_counts.blank;
                file_report.comment_lines = line_counts.comments;
                file_report.size_bytes = source.len;

                // Structure analysis
                structure.analyze(allocator, &ast, &file_report) catch {
                    file_report.parse_error = true;
                };

                // Import analysis
                imports_analyzer.analyze(allocator, &ast, &file_report) catch {};

                // Unsafe operations analysis
                unsafe_ops.analyze(allocator, &ast, &file_report) catch {};
            },
            .rust, .c, .python, .javascript, .go => {
                // Read source file for line-based analysis
                const source = readSourceFile(io, allocator, entry.path) catch {
                    file_report.parse_error = true;
                    try report.files.append(allocator, file_report);
                    continue;
                };
                defer allocator.free(source);

                // Count lines (language-agnostic)
                const line_counts = parser.countLines(source);
                file_report.loc = line_counts.loc;
                file_report.blank_lines = line_counts.blank;
                file_report.comment_lines = line_counts.comments;
                file_report.size_bytes = source.len;

                // Language-specific analysis
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

    report.computeSummary();

    // Build dependency graph (needed for dot, markdown, and terminal with --imports)
    const graph = graph_builder.buildGraph(allocator, &report) catch graph_builder.DependencyGraph.init();

    // Report mode: generate all output formats into a directory
    if (config.report_dir.len > 0) {
        try report_gen.generateReports(allocator, io, &report, &graph, config.report_dir);
        return;
    }

    // Generate output
    const output = switch (config.format) {
        .json => try json_output.writeProjectReport(allocator, &report, config.compact),
        .terminal => try terminal_output.writeReport(allocator, &report),
        .markdown => try markdown_output.writeReport(allocator, &report, &graph),
        .dot => try graph_dot.writeDot(allocator, &graph, report.name),
    };

    // Write output
    if (config.output_file.len > 0) {
        writeOutputFile(io, config.output_file, output);
    } else {
        std.debug.print("{s}", .{output});
    }
}

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

fn writeOutputFile(io: std.Io, path: []const u8, content: []const u8) void {
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch {
        std.debug.print("Failed to create output file: {s}\n", .{path});
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, content) catch {
        std.debug.print("Failed to write output file: {s}\n", .{path});
    };
}

fn printUsage() void {
    std.debug.print(
        \\
        \\zig-lens — Multi-language source code analysis and visualization
        \\
        \\Supported: Zig, Rust, C, Python, JavaScript/TypeScript, Svelte
        \\
        \\Usage: zig-lens <path> [options]
        \\
        \\  <path>                File or directory to analyze
        \\
        \\Options:
        \\  --format <fmt>        Output format: terminal (default), json, markdown, dot
        \\  --compact             Compact JSON optimized for AI context windows
        \\  --compile             Compile entire codebase into single MD file for AI
        \\  --report <dir>        Generate all reports into directory
        \\  --imports             Import/dependency analysis only
        \\  --unsafe              Unsafe operations audit
        \\  --output <file>       Write output to file instead of stdout
        \\  --help, -h            Show this help
        \\
        \\Examples:
        \\  zig-lens src/main.zig                         Analyze single Zig file
        \\  zig-lens src/lib.rs                           Analyze single Rust file
        \\  zig-lens app.py                               Analyze single Python file
        \\  zig-lens programs/zig_dpdk/                   Analyze project directory
        \\  zig-lens /path/to/website/                    Analyze JS/TS project
        \\  zig-lens programs/zig_dpdk/ --format json     JSON output
        \\  zig-lens programs/zig_dpdk/ --compact         AI-optimized JSON
        \\  zig-lens programs/zig_dpdk/ --format dot      Graphviz dependency graph
        \\  zig-lens programs/zig_dpdk/ --format markdown Markdown report
        \\  zig-lens programs/zig_dpdk/ --report ./docs/  Generate all reports to docs/
        \\  zig-lens programs/zig_dpdk/ --compile --output codebase.md  Full codebase dump
        \\
    , .{});
}
