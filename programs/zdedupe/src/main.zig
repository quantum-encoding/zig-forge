//! zdedupe - Duplicate file finder and folder comparator
//!
//! Usage:
//!   zdedupe [OPTIONS] <PATHS...>           Find duplicates in paths
//!   zdedupe compare <FOLDER_A> <FOLDER_B>  Compare two folders
//!   zdedupe scan <PATH>                    Fast scan (benchmark mode)
//!
//! Options:
//!   -h, --help             Show this help
//!   -V, --version          Show version
//!   -f, --format FORMAT    Output format: text, json, html (default: text)
//!   -o, --output FILE      Write report to file (default: stdout)
//!   -H, --hidden           Include hidden files
//!   -L, --follow-links     Follow symbolic links
//!   -m, --min-size SIZE    Minimum file size (e.g., 1KB, 1MB)
//!   -M, --max-size SIZE    Maximum file size (0 = unlimited)
//!   -j, --threads N        Number of threads (0 = auto, default: 0)
//!   --hashes               Include file hashes in output
//!   --sha256               Use SHA256 instead of BLAKE3

const std = @import("std");
const types = @import("types.zig");
const dedupe = @import("dedupe.zig");
const compare = @import("compare.zig");
const report = @import("report.zig");
const fast_walker = @import("fast_walker.zig");
const Io = std.Io;

const VERSION = "0.1.0";

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    runMain(allocator, init.minimal.args) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn runMain(allocator: std.mem.Allocator, minimal_args: anytype) !void {
    // Parse arguments
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var opts = Options{};
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                printHelp();
                return;
            } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
                printVersion();
                return;
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
                i += 1;
                if (i >= args.len) {
                    fatal("Missing argument for --format");
                }
                opts.format = parseFormat(args[i]) orelse {
                    fatal("Invalid format. Use: text, json, html");
                };
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                i += 1;
                if (i >= args.len) {
                    fatal("Missing argument for --output");
                }
                opts.output_file = args[i];
            } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--hidden")) {
                opts.include_hidden = true;
            } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--follow-links")) {
                opts.follow_symlinks = true;
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--min-size")) {
                i += 1;
                if (i >= args.len) {
                    fatal("Missing argument for --min-size");
                }
                opts.min_size = types.parseSize(args[i]) catch {
                    fatal("Invalid size format");
                };
            } else if (std.mem.eql(u8, arg, "-M") or std.mem.eql(u8, arg, "--max-size")) {
                i += 1;
                if (i >= args.len) {
                    fatal("Missing argument for --max-size");
                }
                opts.max_size = types.parseSize(args[i]) catch {
                    fatal("Invalid size format");
                };
            } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--threads")) {
                i += 1;
                if (i >= args.len) {
                    fatal("Missing argument for --threads");
                }
                opts.threads = std.fmt.parseInt(u32, args[i], 10) catch {
                    fatal("Invalid thread count");
                };
            } else if (std.mem.eql(u8, arg, "--hashes")) {
                opts.include_hashes = true;
            } else if (std.mem.eql(u8, arg, "--sha256")) {
                opts.hash_algorithm = .sha256;
            } else {
                std.debug.print("Unknown option: {s}\n", .{arg});
                fatal("Use --help for usage information");
            }
        } else {
            try paths.append(allocator, arg);
        }
    }

    // Check for subcommands
    if (paths.items.len >= 1 and std.mem.eql(u8, paths.items[0], "compare")) {
        if (paths.items.len != 3) {
            fatal("compare requires exactly two folder paths");
        }
        try runCompare(allocator, paths.items[1], paths.items[2], opts);
    } else if (paths.items.len >= 1 and std.mem.eql(u8, paths.items[0], "scan")) {
        if (paths.items.len != 2) {
            fatal("scan requires exactly one path");
        }
        try runFastScan(allocator, paths.items[1], opts);
    } else if (paths.items.len == 0) {
        printHelp();
    } else {
        try runDedupe(allocator, paths.items, opts);
    }
}

const Options = struct {
    format: types.ReportFormat = .text,
    output_file: ?[]const u8 = null,
    include_hidden: bool = true,
    follow_symlinks: bool = false,
    min_size: u64 = 1,
    max_size: u64 = 0,
    threads: u32 = 0,
    include_hashes: bool = false,
    hash_algorithm: types.Config.HashAlgorithm = .blake3,
};

fn runDedupe(allocator: std.mem.Allocator, paths: []const []const u8, opts: Options) !void {
    const config = types.Config{
        .min_size = opts.min_size,
        .max_size = opts.max_size,
        .include_hidden = opts.include_hidden,
        .follow_symlinks = opts.follow_symlinks,
        .hash_algorithm = opts.hash_algorithm,
        .threads = opts.threads,
    };

    var finder = dedupe.DupeFinder.init(allocator, config);
    defer finder.deinit();

    // Progress callback disabled - carriage returns cause terminal freeze with hooks
    // The scan is fast enough now (~550k items/sec) that progress isn't needed

    // Run scan
    try finder.scan(paths);

    // Clear progress line
    std.debug.print("\r                                                    \r", .{});

    // Get results
    const groups = finder.getGroups();
    const summary = finder.getSummary();

    // Write report
    const report_opts = types.ReportOptions{
        .format = opts.format,
        .include_hashes = opts.include_hashes,
    };

    const reporter = report.ReportWriter.init(allocator, report_opts);

    if (opts.output_file) |path| {
        // Write to dynamic buffer using Allocating writer
        var alloc_writer: Io.Writer.Allocating = .init(allocator);
        defer alloc_writer.deinit();
        try reporter.writeDuplicateReport(&alloc_writer.writer, groups, summary);

        // Write buffer to file using libc
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return error.CannotCreateFile;
        defer _ = std.c.close(fd);

        const content = alloc_writer.writer.buffered();
        var written: usize = 0;
        while (written < content.len) {
            const n = std.c.write(fd, content.ptr + written, content.len - written);
            if (n < 0) return error.WriteError;
            written += @intCast(n);
        }

        std.debug.print("Report written to: {s}\n", .{path});
    } else {
        // Write to stdout using Allocating writer
        var alloc_writer: Io.Writer.Allocating = .init(allocator);
        defer alloc_writer.deinit();
        try reporter.writeDuplicateReport(&alloc_writer.writer, groups, summary);

        const io = Io.Threaded.global_single_threaded.io();
        const stdout = Io.File.stdout();
        var buf: [8192]u8 = undefined;
        var writer = stdout.writerStreaming(io, &buf);

        writer.interface.writeAll(alloc_writer.writer.buffered()) catch {};
        writer.interface.flush() catch {};
    }
}

fn runCompare(allocator: std.mem.Allocator, folder_a: []const u8, folder_b: []const u8, opts: Options) !void {
    const config = types.Config{
        .include_hidden = opts.include_hidden,
        .follow_symlinks = opts.follow_symlinks,
        .hash_algorithm = opts.hash_algorithm,
    };

    var comparator = compare.FolderComparator.init(allocator, config);

    // Progress callback
    comparator.setProgressCallback(struct {
        fn callback(progress: *const types.Progress) void {
            if (progress.files_total > 0) {
                std.debug.print("\rComparing: {}/{} ({d:.1}%)     ", .{
                    progress.files_processed,
                    progress.files_total,
                    progress.percentComplete(),
                });
            }
        }
    }.callback);

    var result = try comparator.compare(folder_a, folder_b);
    defer result.deinit();

    // Clear progress line
    std.debug.print("\r                                                    \r", .{});

    // Write report
    const report_opts = types.ReportOptions{
        .format = opts.format,
    };

    const reporter = report.ReportWriter.init(allocator, report_opts);

    if (opts.output_file) |path| {
        // Write to dynamic buffer using Allocating writer
        var alloc_writer: Io.Writer.Allocating = .init(allocator);
        defer alloc_writer.deinit();
        try reporter.writeCompareReport(&alloc_writer.writer, &result);

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return error.CannotCreateFile;
        defer _ = std.c.close(fd);

        const content = alloc_writer.writer.buffered();
        var written: usize = 0;
        while (written < content.len) {
            const n = std.c.write(fd, content.ptr + written, content.len - written);
            if (n < 0) return error.WriteError;
            written += @intCast(n);
        }

        std.debug.print("Report written to: {s}\n", .{path});
    } else {
        // Write to stdout using Allocating writer
        var alloc_writer: Io.Writer.Allocating = .init(allocator);
        defer alloc_writer.deinit();
        try reporter.writeCompareReport(&alloc_writer.writer, &result);

        const io = Io.Threaded.global_single_threaded.io();
        const stdout = Io.File.stdout();
        var buf: [8192]u8 = undefined;
        var writer = stdout.writerStreaming(io, &buf);

        writer.interface.writeAll(alloc_writer.writer.buffered()) catch {};
        writer.interface.flush() catch {};
    }
}

fn runFastScan(allocator: std.mem.Allocator, path: []const u8, opts: Options) !void {
    var start_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &start_ts);

    var walker = fast_walker.FastWalker.init(allocator);
    defer walker.deinit();

    walker.setSizeFilter(opts.min_size, opts.max_size);
    walker.setIncludeHidden(opts.include_hidden);
    walker.enableHardLinkDetection(); // Important for accuracy - skip hard links
    walker.enableArenaAllocator(); // Use arena for faster path allocations

    // Progress callback - every 7000 items (fast counter check, no time syscall)
    walker.setProgress(struct {
        fn callback(stats: *const fast_walker.WalkStats, current_path: []const u8) void {
            std.debug.print("\r{} files | {} dirs | {} bytes | {s}                    ", .{
                stats.files_found,
                stats.dirs_traversed,
                stats.total_size,
                truncatePath(current_path, 40),
            });
        }

        fn truncatePath(p: []const u8, max_len: usize) []const u8 {
            if (p.len <= max_len) return p;
            return p[p.len - max_len ..];
        }
    }.callback, 7000);

    // Run fast scan
    try walker.walk(path);

    var end_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &end_ts);
    const start_ns: i128 = @as(i128, start_ts.sec) * 1_000_000_000 + start_ts.nsec;
    const end_ns: i128 = @as(i128, end_ts.sec) * 1_000_000_000 + end_ts.nsec;
    const elapsed_ns: u64 = @intCast(end_ns - start_ns);
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    // Clear progress line and print final stats
    std.debug.print("\r                                                                              \r", .{});

    const stats = walker.stats;
    const items_per_sec = @as(f64, @floatFromInt(stats.files_found + stats.dirs_traversed)) / elapsed_sec;

    std.debug.print(
        \\Fast Scan Results:
        \\  Files found:      {}
        \\  Directories:      {}
        \\  Total size:       {} bytes ({d:.2} GB)
        \\  Hard links skip:  {}
        \\  Errors:           {}
        \\  Time elapsed:     {d:.2}s
        \\  Items/second:     {d:.0}
        \\
    , .{
        stats.files_found,
        stats.dirs_traversed,
        stats.total_size,
        @as(f64, @floatFromInt(stats.total_size)) / (1024.0 * 1024.0 * 1024.0),
        stats.hard_links_skipped,
        stats.errors,
        elapsed_sec,
        items_per_sec,
    });
}

fn parseFormat(s: []const u8) ?types.ReportFormat {
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "json")) return .json;
    if (std.mem.eql(u8, s, "html")) return .html;
    return null;
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [2048]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\zdedupe - Fast duplicate file finder and folder comparator
        \\
        \\USAGE:
        \\  zdedupe [OPTIONS] <PATHS...>           Find duplicates in paths
        \\  zdedupe [OPTIONS] compare <A> <B>      Compare two folders
        \\
        \\OPTIONS:
        \\  -h, --help             Show this help
        \\  -V, --version          Show version
        \\  -f, --format FORMAT    Output format: text, json, html (default: text)
        \\  -o, --output FILE      Write report to file (default: stdout)
        \\  -H, --hidden           Include hidden files (default: true)
        \\  -L, --follow-links     Follow symbolic links
        \\  -m, --min-size SIZE    Minimum file size (e.g., 1KB, 1MB)
        \\  -M, --max-size SIZE    Maximum file size (0 = unlimited)
        \\  -j, --threads N        Parallel threads (0 = auto, default: 0)
        \\  --hashes               Include file hashes in output
        \\  --sha256               Use SHA256 instead of BLAKE3
        \\
        \\EXAMPLES:
        \\  zdedupe ~/Downloads ~/Documents
        \\  zdedupe -f json -o report.json /data
        \\  zdedupe compare /backup/old /backup/new
        \\  zdedupe -m 1MB --max-size 100MB ~/files
        \\
        \\SIZE FORMAT:
        \\  Supports: B, KB, MB, GB, TB (e.g., 100KB, 10MB, 1.5GB)
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.print("zdedupe {s}\n", .{VERSION}) catch {};
    writer.interface.flush() catch {};
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("Error: {s}\n", .{msg});
    std.process.exit(1);
}

// ============================================================================
// Tests
// ============================================================================

test "parseFormat" {
    try std.testing.expectEqual(types.ReportFormat.text, parseFormat("text").?);
    try std.testing.expectEqual(types.ReportFormat.json, parseFormat("json").?);
    try std.testing.expectEqual(types.ReportFormat.html, parseFormat("html").?);
    try std.testing.expect(parseFormat("invalid") == null);
}
