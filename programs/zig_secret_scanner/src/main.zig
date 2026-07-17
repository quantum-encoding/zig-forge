//! Zig Secret Scanner (zss)
//!
//! High-performance secret detection for preventing credential leaks.
//!
//! Usage:
//!   zss scan [path]           Scan directory or file for secrets
//!   zss hook install          Install git pre-push hook
//!   zss hook uninstall        Remove git pre-push hook
//!   zss patterns              List all detection patterns
//!   zss version               Show version
//!
//! Options:
//!   -s, --severity <level>    Minimum severity (critical, high, medium, low)
//!   -f, --format <fmt>        Output format (text, json, sarif)
//!   -o, --output <file>       Write output to file
//!   -q, --quiet               Suppress output, exit code only
//!   -v, --verbose             Show detailed output
//!   --no-color                Disable colored output
//!   --no-redact               Show full secrets (dangerous)

const std = @import("std");
const scanner = @import("scanner.zig");
const patterns = @import("patterns.zig");
const entropy = @import("entropy.zig");

const Scanner = scanner.Scanner;
const Config = scanner.Config;
const Finding = scanner.Finding;
const Severity = patterns.Severity;

const VERSION = "1.0.0";

const OutputFormat = enum {
    text,
    json,
    sarif,
};

const Options = struct {
    command: Command = .scan,
    paths: std.ArrayListUnmanaged([]const u8) = .empty,
    severity: Severity = .low,
    format: OutputFormat = .text,
    output_file: ?[]const u8 = null,
    quiet: bool = false,
    verbose: bool = false,
    color: bool = true,
    redact: bool = true,
    io: std.Io = undefined,

    const Command = enum {
        scan,
        hook_install,
        hook_uninstall,
        list_patterns,
        version,
        help,
    };
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var opts = Options{};
    defer opts.paths.deinit(allocator);
    opts.io = io;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "scan")) {
            opts.command = .scan;
        } else if (std.mem.eql(u8, arg, "hook")) {
            if (i + 1 < args.len) {
                i += 1;
                if (std.mem.eql(u8, args[i], "install")) {
                    opts.command = .hook_install;
                } else if (std.mem.eql(u8, args[i], "uninstall")) {
                    opts.command = .hook_uninstall;
                }
            }
        } else if (std.mem.eql(u8, arg, "patterns")) {
            opts.command = .list_patterns;
        } else if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            opts.command = .version;
        } else if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.command = .help;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--severity")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.severity = parseSeverity(args[i]) orelse .low;
            }
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.format = parseFormat(args[i]) orelse .text;
            }
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.output_file = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.color = false;
        } else if (std.mem.eql(u8, arg, "--no-redact")) {
            opts.redact = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try opts.paths.append(allocator, arg);
        }
    }

    // Execute command
    switch (opts.command) {
        .scan => try runScan(allocator, &opts),
        .hook_install => try installHook(opts.io),
        .hook_uninstall => try uninstallHook(opts.io),
        .list_patterns => listPatterns(opts.color),
        .version => showVersion(),
        .help => showHelp(),
    }
}

fn runScan(allocator: std.mem.Allocator, opts: *Options) !void {
    // Default to current directory if no paths specified
    if (opts.paths.items.len == 0) {
        try opts.paths.append(allocator, ".");
    }

    const config = Config{
        .min_severity = opts.severity,
        .redact_secrets = opts.redact,
    };

    var scan = Scanner.init(allocator, config, opts.io);
    defer scan.deinit();

    // Scan all specified paths
    for (opts.paths.items) |path| {
        const stat = std.Io.Dir.cwd().statFile(opts.io, path, .{}) catch {
            try scan.scanDirectory(path);
            continue;
        };

        if (stat.kind == .directory) {
            try scan.scanDirectory(path);
        } else {
            try scan.scanFile(path);
        }
    }

    // Resolve the output sink. Machine-readable formats (json/sarif) and text
    // all go to the chosen writer — stdout by default, or the file named by
    // -o/--output. Previously every formatter used std.debug.print (stderr), so
    // `zss scan -f sarif . > out.sarif` and `-o out.sarif` both produced an
    // empty file. Human diagnostics still go to stderr elsewhere.
    const to_file = opts.output_file != null;
    const out_file = if (opts.output_file) |path|
        std.Io.Dir.cwd().createFile(opts.io, path, .{}) catch |err| {
            std.debug.print("Error creating output file '{s}': {s}\n", .{ path, @errorName(err) });
            std.process.exit(2);
        }
    else
        std.Io.File.stdout();
    defer if (to_file) out_file.close(opts.io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(opts.io, &out_buf);
    const w = &out_writer.interface;

    switch (opts.format) {
        .text => try outputText(&scan, opts, w),
        .json => try outputJson(allocator, &scan, w),
        .sarif => try outputSarif(allocator, &scan, w),
    }
    try w.flush();

    // Exit with error code if secrets found
    if (scan.hasFindings()) {
        std.process.exit(1);
    }
}

fn outputText(scan: *Scanner, opts: *Options, w: *std.Io.Writer) !void {
    const findings = scan.getSortedFindings();

    if (opts.quiet) return;

    const reset = if (opts.color) "\x1b[0m" else "";

    if (findings.len == 0) {
        if (opts.verbose) {
            try w.writeAll("No secrets detected.\n");
            try w.print("Scanned {d} files ({d} bytes)\n", .{ scan.files_scanned, scan.bytes_scanned });
        }
        return;
    }

    // Print findings
    for (findings) |f| {
        const color = if (opts.color) f.severity.toColor() else "";

        try w.print("{s}[{s}]{s} {s}\n", .{
            color,
            f.severity.toString(),
            reset,
            f.pattern_name,
        });
        try w.print("  {s}:{d}:{d}\n", .{
            f.file_path,
            f.line_number,
            f.column,
        });
        try w.print("  Secret: {s}\n", .{f.matched_text});

        if (opts.verbose) {
            if (f.entropy_score) |ent| {
                try w.print("  Entropy: {d:.2}\n", .{ent});
            }
            try w.print("  Pattern: {s}\n", .{f.pattern_id});
        }
        try w.writeAll("\n");
    }

    // Summary
    const critical = scan.countBySeverity(.critical);
    const high = scan.countBySeverity(.high);
    const medium = scan.countBySeverity(.medium);
    const low = scan.countBySeverity(.low);

    try w.print("Found {d} secret(s): ", .{findings.len});
    if (critical > 0) try w.print("{s}{d} critical{s} ", .{ if (opts.color) "\x1b[91m" else "", critical, reset });
    if (high > 0) try w.print("{s}{d} high{s} ", .{ if (opts.color) "\x1b[31m" else "", high, reset });
    if (medium > 0) try w.print("{s}{d} medium{s} ", .{ if (opts.color) "\x1b[33m" else "", medium, reset });
    if (low > 0) try w.print("{s}{d} low{s} ", .{ if (opts.color) "\x1b[36m" else "", low, reset });
    try w.writeAll("\n");

    if (opts.verbose) {
        try w.print("Scanned {d} files ({d} bytes)\n", .{ scan.files_scanned, scan.bytes_scanned });
    }
}

fn outputJson(allocator: std.mem.Allocator, scan: *Scanner, w: *std.Io.Writer) !void {
    const findings = scan.getSortedFindings();

    // One anonymous-struct row per finding. std.json.Stringify escapes every
    // string field (file paths, pattern names, secrets), so a hostile filename
    // or matched value containing '"' / '\' / control chars can no longer break
    // the document or inject fields (JSON-IN-FMT). Replaces the hand-rolled,
    // truncating escapeJson helper entirely.
    const JsonFinding = struct {
        file: []const u8,
        line: usize,
        column: usize,
        severity: []const u8,
        pattern_id: []const u8,
        pattern_name: []const u8,
        secret: []const u8,
        entropy: ?f32,
    };

    var rows = try allocator.alloc(JsonFinding, findings.len);
    defer allocator.free(rows);
    for (findings, 0..) |f, idx| {
        rows[idx] = .{
            .file = f.file_path,
            .line = f.line_number,
            .column = f.column,
            .severity = f.severity.toString(),
            .pattern_id = f.pattern_id,
            .pattern_name = f.pattern_name,
            .secret = f.matched_text,
            .entropy = f.entropy_score,
        };
    }

    var stringify: std.json.Stringify = .{
        .writer = w,
        .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false },
    };
    try stringify.write(.{
        .version = VERSION,
        .files_scanned = scan.files_scanned,
        .bytes_scanned = scan.bytes_scanned,
        .findings_count = findings.len,
        .findings = rows,
    });
    try w.writeAll("\n");
}

fn outputSarif(allocator: std.mem.Allocator, scan: *Scanner, w: *std.Io.Writer) !void {
    const findings = scan.getSortedFindings();

    // Build the SARIF 2.1.0 document from typed structs and let
    // std.json.Stringify escape every value. Previously file_path and
    // pattern_name were interpolated unescaped (main.zig:252/313 in the old
    // build), so a repo containing a file named with '"'/SARIF control text
    // could forge or suppress results uploaded to code scanning (JSON-IN-FMT).
    const SarifResult = struct {
        ruleId: []const u8,
        level: []const u8,
        message: struct { text: []const u8 },
        locations: [1]struct {
            physicalLocation: struct {
                artifactLocation: struct { uri: []const u8 },
                region: struct { startLine: usize, startColumn: usize },
            },
        },
    };

    var results = try allocator.alloc(SarifResult, findings.len);
    defer allocator.free(results);

    // "Detected <name>" message text is allocated per finding so it can be
    // escaped by Stringify along with everything else.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (findings, 0..) |f, idx| {
        const level = switch (f.severity) {
            .critical, .high => "error",
            .medium => "warning",
            .low, .info => "note",
        };
        const text = try std.fmt.allocPrint(arena, "Detected {s}", .{f.pattern_name});
        results[idx] = .{
            .ruleId = f.pattern_id,
            .level = level,
            .message = .{ .text = text },
            .locations = .{.{
                .physicalLocation = .{
                    .artifactLocation = .{ .uri = f.file_path },
                    .region = .{ .startLine = f.line_number, .startColumn = f.column },
                },
            }},
        };
    }

    var stringify: std.json.Stringify = .{
        .writer = w,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.write(.{
        .@"$schema" = "https://json.schemastore.org/sarif-2.1.0.json",
        .version = "2.1.0",
        .runs = .{.{
            .tool = .{
                .driver = .{
                    .name = "zss",
                    .version = VERSION,
                    .informationUri = "https://github.com/quantum-encoding/zig-forge/tree/master/programs/zig_secret_scanner",
                },
            },
            .results = results,
        }},
    });
    try w.writeAll("\n");
}

fn installHook(io: std.Io) !void {
    // Find .git directory
    const git_dir = std.Io.Dir.cwd().openDir(io, ".git/hooks", .{}) catch {
        std.debug.print("Error: Not a git repository (or .git/hooks not found)\n", .{});
        std.process.exit(1);
    };
    defer git_dir.close(io);

    const hook_content =
        \\#!/bin/sh
        \\# Zig Secret Scanner pre-push hook
        \\# Prevents pushing commits containing secrets
        \\
        \\echo "Running secret scan..."
        \\
        \\# Find zss binary
        \\if command -v zss >/dev/null 2>&1; then
        \\    ZSS="zss"
        \\elif [ -x "./zig-out/bin/zss" ]; then
        \\    ZSS="./zig-out/bin/zss"
        \\else
        \\    echo "Warning: zss not found, skipping secret scan"
        \\    exit 0
        \\fi
        \\
        \\# Run scan with high+ severity
        \\$ZSS scan --severity high --quiet .
        \\
        \\if [ $? -ne 0 ]; then
        \\    echo ""
        \\    echo "Secret scan failed! Secrets detected in repository."
        \\    echo "Run 'zss scan .' to see details."
        \\    echo ""
        \\    echo "To bypass this check (not recommended):"
        \\    echo "  git push --no-verify"
        \\    exit 1
        \\fi
        \\
        \\echo "No secrets detected."
        \\exit 0
        \\
    ;

    const hook_file = git_dir.createFile(io, "pre-push", .{}) catch |err| {
        std.debug.print("Error creating hook: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer hook_file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = hook_file.writer(io, &write_buf);
    writer.interface.writeAll(hook_content) catch |err| {
        std.debug.print("Error writing hook: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    writer.interface.flush() catch |err| {
        std.debug.print("Error writing hook: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Git silently ignores non-executable hooks. createFile leaves the file at
    // the default 0o666 (minus umask) with no exec bit, so the previously
    // "installed" hook never ran and the tool reported success while providing
    // zero push protection. chmod 0o755 and verify the exec bit before claiming
    // success.
    hook_file.setPermissions(io, .fromMode(0o755)) catch |err| {
        std.debug.print("Error setting hook permissions: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const hook_stat = hook_file.stat(io) catch |err| {
        std.debug.print("Error verifying hook permissions: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if ((hook_stat.permissions.toMode() & 0o111) == 0) {
        std.debug.print("Error: pre-push hook is not executable after install.\n", .{});
        std.process.exit(1);
    }

    std.debug.print("Installed pre-push hook at .git/hooks/pre-push\n", .{});
    std.debug.print("Secrets will be scanned before each push.\n", .{});
}

fn uninstallHook(io: std.Io) !void {
    std.Io.Dir.cwd().deleteFile(io, ".git/hooks/pre-push") catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Hook not installed.\n", .{});
            return;
        }
        std.debug.print("Error removing hook: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    std.debug.print("Removed pre-push hook.\n", .{});
}

fn listPatterns(color: bool) void {
    const all = patterns.getAllPatterns();
    const reset = if (color) "\x1b[0m" else "";

    std.debug.print("Available detection patterns ({d} total):\n\n", .{all.len});

    var last_severity: ?Severity = null;
    for (all) |p| {
        if (last_severity == null or last_severity.? != p.severity) {
            last_severity = p.severity;
            const sev_color = if (color) p.severity.toColor() else "";
            std.debug.print("\n{s}[{s}]{s}\n", .{ sev_color, p.severity.toString(), reset });
        }

        const status = if (p.enabled) "" else " (disabled)";
        std.debug.print("  {s}{s}\n", .{ p.id, status });
        std.debug.print("    {s}\n", .{p.description});
    }
}

fn showVersion() void {
    std.debug.print("zss (Zig Secret Scanner) {s}\n", .{VERSION});
}

fn showHelp() void {
    const help =
        \\zss - Zig Secret Scanner
        \\
        \\High-performance secret detection for preventing credential leaks.
        \\
        \\USAGE:
        \\    zss <command> [options] [path...]
        \\
        \\COMMANDS:
        \\    scan [path]         Scan directory or file for secrets (default: .)
        \\    hook install        Install git pre-push hook
        \\    hook uninstall      Remove git pre-push hook
        \\    patterns            List all detection patterns
        \\    version             Show version information
        \\    help                Show this help message
        \\
        \\OPTIONS:
        \\    -s, --severity <level>   Minimum severity to report
        \\                             (critical, high, medium, low)
        \\    -f, --format <fmt>       Output format (text, json, sarif)
        \\    -o, --output <file>      Write output to file
        \\    -q, --quiet              Suppress output, exit code only
        \\    -v, --verbose            Show detailed output
        \\    --no-color               Disable colored output
        \\    --no-redact              Show full secrets (dangerous!)
        \\
        \\EXAMPLES:
        \\    zss scan .                    Scan current directory
        \\    zss scan src/ config/         Scan multiple directories
        \\    zss scan -s high              Only report high+ severity
        \\    zss scan -f json              Output as JSON
        \\    zss hook install              Install git hook
        \\
        \\EXIT CODES:
        \\    0    No secrets found
        \\    1    Secrets detected
        \\    2    Error occurred
        \\
        \\PATTERNS:
        \\    Detects 50+ secret types including:
        \\    - AWS access keys and secrets
        \\    - GitHub/GitLab tokens
        \\    - Stripe API keys
        \\    - Database connection strings
        \\    - Private keys (RSA, EC, SSH)
        \\    - JWT tokens
        \\    - Generic API keys/secrets
        \\
        \\For more information: https://github.com/quantum-encoding/zig-forge/tree/master/programs/zig_secret_scanner
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn parseSeverity(s: []const u8) ?Severity {
    if (std.mem.eql(u8, s, "critical")) return .critical;
    if (std.mem.eql(u8, s, "high")) return .high;
    if (std.mem.eql(u8, s, "medium")) return .medium;
    if (std.mem.eql(u8, s, "low")) return .low;
    if (std.mem.eql(u8, s, "info")) return .info;
    return null;
}

fn parseFormat(s: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "json")) return .json;
    if (std.mem.eql(u8, s, "sarif")) return .sarif;
    return null;
}

// Re-export for tests
pub const Pattern = patterns.Pattern;
pub const calculateEntropy = entropy.calculate;

test {
    _ = @import("patterns.zig");
    _ = @import("entropy.zig");
    _ = @import("scanner.zig");
}
