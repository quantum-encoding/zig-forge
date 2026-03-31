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

    // Output results
    switch (opts.format) {
        .text => outputText(&scan, opts),
        .json => try outputJson(allocator, &scan),
        .sarif => try outputSarif(allocator, &scan),
    }

    // Exit with error code if secrets found
    if (scan.hasFindings()) {
        std.process.exit(1);
    }
}

fn outputText(scan: *Scanner, opts: *Options) void {
    const findings = scan.getSortedFindings();

    if (opts.quiet) return;

    const reset = if (opts.color) "\x1b[0m" else "";

    if (findings.len == 0) {
        if (opts.verbose) {
            std.debug.print("No secrets detected.\n", .{});
            std.debug.print("Scanned {d} files ({d} bytes)\n", .{ scan.files_scanned, scan.bytes_scanned });
        }
        return;
    }

    // Print findings
    for (findings) |f| {
        const color = if (opts.color) f.severity.toColor() else "";

        std.debug.print("{s}[{s}]{s} {s}\n", .{
            color,
            f.severity.toString(),
            reset,
            f.pattern_name,
        });
        std.debug.print("  {s}:{d}:{d}\n", .{
            f.file_path,
            f.line_number,
            f.column,
        });
        std.debug.print("  Secret: {s}\n", .{f.matched_text});

        if (opts.verbose) {
            if (f.entropy_score) |ent| {
                std.debug.print("  Entropy: {d:.2}\n", .{ent});
            }
            std.debug.print("  Pattern: {s}\n", .{f.pattern_id});
        }
        std.debug.print("\n", .{});
    }

    // Summary
    const critical = scan.countBySeverity(.critical);
    const high = scan.countBySeverity(.high);
    const medium = scan.countBySeverity(.medium);
    const low = scan.countBySeverity(.low);

    std.debug.print("Found {d} secret(s): ", .{findings.len});
    if (critical > 0) std.debug.print("{s}{d} critical{s} ", .{ if (opts.color) "\x1b[91m" else "", critical, reset });
    if (high > 0) std.debug.print("{s}{d} high{s} ", .{ if (opts.color) "\x1b[31m" else "", high, reset });
    if (medium > 0) std.debug.print("{s}{d} medium{s} ", .{ if (opts.color) "\x1b[33m" else "", medium, reset });
    if (low > 0) std.debug.print("{s}{d} low{s} ", .{ if (opts.color) "\x1b[36m" else "", low, reset });
    std.debug.print("\n", .{});

    if (opts.verbose) {
        std.debug.print("Scanned {d} files ({d} bytes)\n", .{ scan.files_scanned, scan.bytes_scanned });
    }
}

fn outputJson(allocator: std.mem.Allocator, scan: *Scanner) !void {
    const findings = scan.getSortedFindings();

    std.debug.print("{{\n", .{});
    std.debug.print("  \"version\": \"{s}\",\n", .{VERSION});
    std.debug.print("  \"files_scanned\": {d},\n", .{scan.files_scanned});
    std.debug.print("  \"bytes_scanned\": {d},\n", .{scan.bytes_scanned});
    std.debug.print("  \"findings_count\": {d},\n", .{findings.len});
    std.debug.print("  \"findings\": [\n", .{});

    for (findings, 0..) |f, idx| {
        std.debug.print("    {{\n", .{});
        std.debug.print("      \"file\": \"{s}\",\n", .{f.file_path});
        std.debug.print("      \"line\": {d},\n", .{f.line_number});
        std.debug.print("      \"column\": {d},\n", .{f.column});
        std.debug.print("      \"severity\": \"{s}\",\n", .{f.severity.toString()});
        std.debug.print("      \"pattern_id\": \"{s}\",\n", .{f.pattern_id});
        std.debug.print("      \"pattern_name\": \"{s}\",\n", .{f.pattern_name});

        // Escape the secret for JSON
        var escaped_buf: [1024]u8 = undefined;
        const escaped = escapeJson(f.matched_text, &escaped_buf);
        std.debug.print("      \"secret\": \"{s}\"", .{escaped});

        if (f.entropy_score) |ent| {
            std.debug.print(",\n      \"entropy\": {d:.4}", .{ent});
        }

        std.debug.print("\n    }}", .{});
        if (idx < findings.len - 1) std.debug.print(",", .{});
        std.debug.print("\n", .{});
    }

    std.debug.print("  ]\n", .{});
    std.debug.print("}}\n", .{});

    _ = allocator;
}

fn outputSarif(allocator: std.mem.Allocator, scan: *Scanner) !void {
    const findings = scan.getSortedFindings();

    std.debug.print("{{\n", .{});
    std.debug.print("  \"$schema\": \"https://json.schemastore.org/sarif-2.1.0.json\",\n", .{});
    std.debug.print("  \"version\": \"2.1.0\",\n", .{});
    std.debug.print("  \"runs\": [\n", .{});
    std.debug.print("    {{\n", .{});
    std.debug.print("      \"tool\": {{\n", .{});
    std.debug.print("        \"driver\": {{\n", .{});
    std.debug.print("          \"name\": \"zss\",\n", .{});
    std.debug.print("          \"version\": \"{s}\",\n", .{VERSION});
    std.debug.print("          \"informationUri\": \"https://github.com/quantum-encoding/zig-forge/tree/master/programs/zig_secret_scanner\"\n", .{});
    std.debug.print("        }}\n", .{});
    std.debug.print("      }},\n", .{});
    std.debug.print("      \"results\": [\n", .{});

    for (findings, 0..) |f, idx| {
        const level = switch (f.severity) {
            .critical, .high => "error",
            .medium => "warning",
            .low, .info => "note",
        };

        std.debug.print("        {{\n", .{});
        std.debug.print("          \"ruleId\": \"{s}\",\n", .{f.pattern_id});
        std.debug.print("          \"level\": \"{s}\",\n", .{level});
        std.debug.print("          \"message\": {{\n", .{});
        std.debug.print("            \"text\": \"Detected {s}\"\n", .{f.pattern_name});
        std.debug.print("          }},\n", .{});
        std.debug.print("          \"locations\": [\n", .{});
        std.debug.print("            {{\n", .{});
        std.debug.print("              \"physicalLocation\": {{\n", .{});
        std.debug.print("                \"artifactLocation\": {{\n", .{});
        std.debug.print("                  \"uri\": \"{s}\"\n", .{f.file_path});
        std.debug.print("                }},\n", .{});
        std.debug.print("                \"region\": {{\n", .{});
        std.debug.print("                  \"startLine\": {d},\n", .{f.line_number});
        std.debug.print("                  \"startColumn\": {d}\n", .{f.column});
        std.debug.print("                }}\n", .{});
        std.debug.print("              }}\n", .{});
        std.debug.print("            }}\n", .{});
        std.debug.print("          ]\n", .{});
        std.debug.print("        }}", .{});
        if (idx < findings.len - 1) std.debug.print(",", .{});
        std.debug.print("\n", .{});
    }

    std.debug.print("      ]\n", .{});
    std.debug.print("    }}\n", .{});
    std.debug.print("  ]\n", .{});
    std.debug.print("}}\n", .{});

    _ = allocator;
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
    writer.interface.flush() catch {};

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

fn escapeJson(input: []const u8, buf: []u8) []const u8 {
    var out_idx: usize = 0;
    for (input) |c| {
        if (out_idx + 2 >= buf.len) break;
        switch (c) {
            '"' => {
                buf[out_idx] = '\\';
                buf[out_idx + 1] = '"';
                out_idx += 2;
            },
            '\\' => {
                buf[out_idx] = '\\';
                buf[out_idx + 1] = '\\';
                out_idx += 2;
            },
            '\n' => {
                buf[out_idx] = '\\';
                buf[out_idx + 1] = 'n';
                out_idx += 2;
            },
            '\r' => {
                buf[out_idx] = '\\';
                buf[out_idx + 1] = 'r';
                out_idx += 2;
            },
            '\t' => {
                buf[out_idx] = '\\';
                buf[out_idx + 1] = 't';
                out_idx += 2;
            },
            else => {
                buf[out_idx] = c;
                out_idx += 1;
            },
        }
    }
    return buf[0..out_idx];
}

// Re-export for tests
pub const Pattern = patterns.Pattern;
pub const calculateEntropy = entropy.calculate;

test {
    _ = @import("patterns.zig");
    _ = @import("entropy.zig");
    _ = @import("scanner.zig");
}
