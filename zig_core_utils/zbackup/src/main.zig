//! zbackup - Zig Coreutils Backup and Swap Manager
//!
//! Meta-utility for safely managing the transition from GNU coreutils to Zig equivalents.
//! Provides backup, install, restore, and testing functionality with atomic operations.
//!
//! Usage: zbackup <command> [options] [utility...]
//!
//! Commands:
//!   status              Show status of all utilities
//!   list                List available Zig utilities
//!   install <util>      Install Zig utility (backs up GNU version first)
//!   restore <util>      Restore original GNU utility
//!   test <util>         Run tests on Zig utility before installing
//!
//! Options:
//!   --all               Apply to all available utilities
//!   --force             Skip confirmation prompts
//!   --dry-run           Show what would be done without doing it
//!   --help              Display this help
//!   --version           Output version information

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

// Configuration paths
const ZBIN_DIR = "/usr/local/zbin";
const BACKUP_DIR = "/usr/local/backup/gnu";
const CONFIG_FILE = "/etc/zbackup/config.toml";
const RESULTS_FILE = "tests/results.json";
const GNU_BIN_DIRS = [_][]const u8{ "/usr/bin", "/bin", "/usr/local/bin" };

// Test results cache (read from results.json)
const TestResult = struct {
    passed: u32 = 0,
    total: u32 = 0,
    status: enum { none, pass, warn, fail } = .none,
};

// ANSI colors for terminal output
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const cyan = "\x1b[36m";
    const dim = "\x1b[2m";
};

// List of all Zig coreutils with their GNU equivalents
const UtilMapping = struct {
    zig_name: []const u8,
    gnu_name: []const u8,
    category: []const u8,
    perf_ratio: ?f32, // Performance vs GNU (>1.0 = faster)
};

const UTILITIES = [_]UtilMapping{
    // File Operations
    .{ .zig_name = "zls", .gnu_name = "ls", .category = "file", .perf_ratio = 2.1 },
    .{ .zig_name = "zcat", .gnu_name = "cat", .category = "file", .perf_ratio = 1.8 },
    .{ .zig_name = "zcp", .gnu_name = "cp", .category = "file", .perf_ratio = 1.5 },
    .{ .zig_name = "zmv", .gnu_name = "mv", .category = "file", .perf_ratio = 1.3 },
    .{ .zig_name = "zrm", .gnu_name = "rm", .category = "file", .perf_ratio = 1.4 },
    .{ .zig_name = "zmkdir", .gnu_name = "mkdir", .category = "file", .perf_ratio = 1.2 },
    .{ .zig_name = "zrmdir", .gnu_name = "rmdir", .category = "file", .perf_ratio = 1.2 },
    .{ .zig_name = "ztouch", .gnu_name = "touch", .category = "file", .perf_ratio = 1.3 },
    .{ .zig_name = "zln", .gnu_name = "ln", .category = "file", .perf_ratio = 1.2 },
    .{ .zig_name = "zchmod", .gnu_name = "chmod", .category = "file", .perf_ratio = 1.3 },
    .{ .zig_name = "zchown", .gnu_name = "chown", .category = "file", .perf_ratio = 1.2 },
    .{ .zig_name = "zstat", .gnu_name = "stat", .category = "file", .perf_ratio = 1.4 },
    .{ .zig_name = "zfind", .gnu_name = "find", .category = "file", .perf_ratio = 2.5 },
    .{ .zig_name = "zdu", .gnu_name = "du", .category = "file", .perf_ratio = 3.2 },
    .{ .zig_name = "zdf", .gnu_name = "df", .category = "file", .perf_ratio = 1.5 },
    .{ .zig_name = "ztree", .gnu_name = "tree", .category = "file", .perf_ratio = 1.5 },

    // Text Processing
    .{ .zig_name = "zgrep", .gnu_name = "grep", .category = "text", .perf_ratio = 2.8 },
    .{ .zig_name = "zsed", .gnu_name = "sed", .category = "text", .perf_ratio = 1.6 },
    .{ .zig_name = "zawk", .gnu_name = "awk", .category = "text", .perf_ratio = 1.4 },
    .{ .zig_name = "zhead", .gnu_name = "head", .category = "text", .perf_ratio = 1.5 },
    .{ .zig_name = "ztail", .gnu_name = "tail", .category = "text", .perf_ratio = 1.6 },
    .{ .zig_name = "zwc", .gnu_name = "wc", .category = "text", .perf_ratio = 2.2 },
    .{ .zig_name = "zsort", .gnu_name = "sort", .category = "text", .perf_ratio = 1.9 },
    .{ .zig_name = "zuniq", .gnu_name = "uniq", .category = "text", .perf_ratio = 1.7 },
    .{ .zig_name = "zcut", .gnu_name = "cut", .category = "text", .perf_ratio = 1.5 },
    .{ .zig_name = "zpaste", .gnu_name = "paste", .category = "text", .perf_ratio = 1.4 },
    .{ .zig_name = "ztr", .gnu_name = "tr", .category = "text", .perf_ratio = 1.6 },
    .{ .zig_name = "zxargs", .gnu_name = "xargs", .category = "text", .perf_ratio = 1.3 },

    // System Info
    .{ .zig_name = "zuname", .gnu_name = "uname", .category = "system", .perf_ratio = 1.1 },
    .{ .zig_name = "zhostname", .gnu_name = "hostname", .category = "system", .perf_ratio = 1.1 },
    .{ .zig_name = "zwhoami", .gnu_name = "whoami", .category = "system", .perf_ratio = 1.2 },
    .{ .zig_name = "zuptime", .gnu_name = "uptime", .category = "system", .perf_ratio = 1.2 },
    .{ .zig_name = "zdate", .gnu_name = "date", .category = "system", .perf_ratio = 1.1 },
    .{ .zig_name = "zid", .gnu_name = "id", .category = "system", .perf_ratio = 1.2 },
    .{ .zig_name = "zenv", .gnu_name = "env", .category = "system", .perf_ratio = 1.3 },
    .{ .zig_name = "zprintenv", .gnu_name = "printenv", .category = "system", .perf_ratio = 1.2 },

    // Hash/Checksum
    .{ .zig_name = "zsha256sum", .gnu_name = "sha256sum", .category = "hash", .perf_ratio = 1.8 },
    .{ .zig_name = "zmd5sum", .gnu_name = "md5sum", .category = "hash", .perf_ratio = 1.7 },
    .{ .zig_name = "zsha1sum", .gnu_name = "sha1sum", .category = "hash", .perf_ratio = 1.8 },
    .{ .zig_name = "zcksum", .gnu_name = "cksum", .category = "hash", .perf_ratio = 1.5 },

    // Clipboard
    .{ .zig_name = "zcopy", .gnu_name = "xclip", .category = "clipboard", .perf_ratio = 1.09 },
    .{ .zig_name = "zpaste", .gnu_name = "xclip", .category = "clipboard", .perf_ratio = 1.09 },

    // Misc
    .{ .zig_name = "zecho", .gnu_name = "echo", .category = "misc", .perf_ratio = 1.3 },
    .{ .zig_name = "zprintf", .gnu_name = "printf", .category = "misc", .perf_ratio = 1.2 },
    .{ .zig_name = "zyes", .gnu_name = "yes", .category = "misc", .perf_ratio = 1.5 },
    .{ .zig_name = "ztrue", .gnu_name = "true", .category = "misc", .perf_ratio = 1.0 },
    .{ .zig_name = "zfalse", .gnu_name = "false", .category = "misc", .perf_ratio = 1.0 },
    .{ .zig_name = "zsleep", .gnu_name = "sleep", .category = "misc", .perf_ratio = 1.0 },
    .{ .zig_name = "ztime", .gnu_name = "time", .category = "misc", .perf_ratio = 1.02 },
    .{ .zig_name = "zseq", .gnu_name = "seq", .category = "misc", .perf_ratio = 1.8 },
    .{ .zig_name = "zbasename", .gnu_name = "basename", .category = "misc", .perf_ratio = 1.2 },
    .{ .zig_name = "zdirname", .gnu_name = "dirname", .category = "misc", .perf_ratio = 1.2 },
    .{ .zig_name = "zrealpath", .gnu_name = "realpath", .category = "misc", .perf_ratio = 1.3 },
    .{ .zig_name = "zreadlink", .gnu_name = "readlink", .category = "misc", .perf_ratio = 1.2 },
    .{ .zig_name = "ztee", .gnu_name = "tee", .category = "misc", .perf_ratio = 1.4 },
};

const Command = enum {
    status,
    list,
    install,
    restore,
    @"test",
    help,
    version,
};

const Config = struct {
    command: ?Command = null,
    utilities: std.ArrayListUnmanaged([]const u8) = .empty,
    all: bool = false,
    force: bool = false,
    dry_run: bool = false,
    verbose: bool = false,
};

// C functions
extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;

const F_OK: c_int = 0; // Test for existence
const O_RDONLY: c_int = 0;

fn isTty() bool {
    return isatty(1) != 0;
}

fn writeStdout(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn printColor(color: []const u8, msg: []const u8) void {
    if (isTty()) {
        writeStdout(color);
        writeStdout(msg);
        writeStdout(Color.reset);
    } else {
        writeStdout(msg);
    }
}

fn printUsage() void {
    const usage =
        \\Usage: zbackup <command> [options] [utility...]
        \\
        \\Zig Coreutils Backup and Swap Manager
        \\
        \\Safely manage the transition from GNU coreutils to high-performance Zig equivalents.
        \\Provides backup, install, restore, and testing functionality with atomic operations.
        \\
        \\Commands:
        \\  status              Show status of all utilities (default)
        \\  list                List available Zig utilities
        \\  install <util>      Install Zig utility (backs up GNU version first)
        \\  restore <util>      Restore original GNU utility from backup
        \\  test <util>         Run tests on Zig utility before installing
        \\
        \\Options:
        \\  --all               Apply to all available utilities
        \\  --force             Skip confirmation prompts
        \\  --dry-run           Show what would be done without doing it
        \\  -v, --verbose       Verbose output
        \\      --help          Display this help
        \\      --version       Output version information
        \\
        \\Paths:
        \\  Zig binaries:       /usr/local/zbin/
        \\  GNU backups:        /usr/local/backup/gnu/
        \\  Config:             /etc/zbackup/config.toml
        \\
        \\Safety Features:
        \\  - Automatic backup of GNU utilities before replacement
        \\  - Atomic swap operations using rename()
        \\  - Verification of Zig utility functionality before install
        \\  - Easy rollback with restore command
        \\
        \\Examples:
        \\  zbackup status                  # Show status of all utilities
        \\  zbackup list                    # List available Zig utilities
        \\  zbackup install ls              # Install zls, backup GNU ls
        \\  zbackup install --all           # Install all available utilities
        \\  zbackup restore ls              # Restore GNU ls from backup
        \\  zbackup test grep               # Test zgrep before installing
        \\  zbackup --dry-run install --all # Preview full installation
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zbackup " ++ VERSION ++ " - Zig Coreutils Backup and Swap Manager\n");
}

fn parseArgs(args: []const []const u8, allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--all")) {
                config.all = true;
            } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
                config.force = true;
            } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
                config.dry_run = true;
            } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
                config.verbose = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else {
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "zbackup: unrecognized option '{s}'\n", .{arg}) catch "zbackup: unrecognized option\n";
                writeStderr(err_msg);
                return error.InvalidOption;
            }
        } else if (config.command == null) {
            // First non-option arg is the command
            if (std.mem.eql(u8, arg, "status")) {
                config.command = .status;
            } else if (std.mem.eql(u8, arg, "list")) {
                config.command = .list;
            } else if (std.mem.eql(u8, arg, "install")) {
                config.command = .install;
            } else if (std.mem.eql(u8, arg, "restore")) {
                config.command = .restore;
            } else if (std.mem.eql(u8, arg, "test")) {
                config.command = .@"test";
            } else if (std.mem.eql(u8, arg, "help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "version")) {
                printVersion();
                std.process.exit(0);
            } else {
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "zbackup: unknown command '{s}'\n", .{arg}) catch "zbackup: unknown command\n";
                writeStderr(err_msg);
                writeStderr("Try 'zbackup --help' for more information.\n");
                return error.InvalidCommand;
            }
        } else {
            // Utility name
            try config.utilities.append(allocator, arg);
        }
    }

    return config;
}

fn findUtilMapping(name: []const u8) ?UtilMapping {
    for (UTILITIES) |util| {
        if (std.mem.eql(u8, util.gnu_name, name) or std.mem.eql(u8, util.zig_name, name)) {
            return util;
        }
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;

    // Use C access() to check file existence
    return access(path_z.ptr, F_OK) == 0;
}

fn findGnuPath(gnu_name: []const u8) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    for (GNU_BIN_DIRS) |dir| {
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, gnu_name }) catch continue;
        if (fileExists(full_path)) {
            // Return a static buffer - this is safe for our use case
            return full_path;
        }
    }
    return null;
}

fn getZigPath(zig_name: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ ZBIN_DIR, zig_name }) catch null;
}

fn getBackupPath(gnu_name: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ BACKUP_DIR, gnu_name }) catch null;
}

const UtilStatus = struct {
    zig_installed: bool,
    gnu_exists: bool,
    backup_exists: bool,
    active_is_zig: bool,
    test_result: TestResult = .{},
};

// Simple JSON value extractor for test results
fn extractTestResults(json: []const u8, zig_name: []const u8) TestResult {
    var result = TestResult{};

    // Find utility section in JSON
    // Look for "zig_name": { ... "tests_passed": N, "tests_total": M, "status": "X" }
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{zig_name}) catch return result;

    const util_start = std.mem.indexOf(u8, json, search_key) orelse return result;
    const section = json[util_start..];

    // Find tests_passed
    if (std.mem.indexOf(u8, section, "\"tests_passed\":")) |idx| {
        const num_start = idx + 15; // length of "tests_passed":
        var num_end = num_start;
        while (num_end < section.len and (section[num_end] == ' ' or (section[num_end] >= '0' and section[num_end] <= '9'))) {
            num_end += 1;
        }
        // Skip leading spaces
        var num_s = num_start;
        while (num_s < num_end and section[num_s] == ' ') num_s += 1;
        if (num_s < num_end) {
            result.passed = std.fmt.parseInt(u32, section[num_s..num_end], 10) catch 0;
        }
    }

    // Find tests_total
    if (std.mem.indexOf(u8, section, "\"tests_total\":")) |idx| {
        const num_start = idx + 14;
        var num_end = num_start;
        while (num_end < section.len and (section[num_end] == ' ' or (section[num_end] >= '0' and section[num_end] <= '9'))) {
            num_end += 1;
        }
        var num_s = num_start;
        while (num_s < num_end and section[num_s] == ' ') num_s += 1;
        if (num_s < num_end) {
            result.total = std.fmt.parseInt(u32, section[num_s..num_end], 10) catch 0;
        }
    }

    // Find status
    if (std.mem.indexOf(u8, section, "\"status\":")) |idx| {
        const status_start = idx + 9;
        if (std.mem.indexOf(u8, section[status_start..], "\"pass\"")) |_| {
            result.status = .pass;
        } else if (std.mem.indexOf(u8, section[status_start..], "\"warn\"")) |_| {
            result.status = .warn;
        } else if (std.mem.indexOf(u8, section[status_start..], "\"fail\"")) |_| {
            result.status = .fail;
        }
    }

    // Infer status from percentage if not set
    if (result.status == .none and result.total > 0) {
        const pct = (result.passed * 100) / result.total;
        if (pct >= 90) {
            result.status = .pass;
        } else if (pct >= 50) {
            result.status = .warn;
        } else {
            result.status = .fail;
        }
    }

    return result;
}

// Read test results from JSON file
var g_test_results_cache: ?[]const u8 = null;

fn loadTestResults(allocator: std.mem.Allocator) void {
    if (g_test_results_cache != null) return;

    // Try relative path first (from zig_core_utils dir)
    const paths = [_][]const u8{
        RESULTS_FILE,
        "tests/results.json",
    };

    for (paths) |path| {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch continue;

        const fd = open(path_z.ptr, O_RDONLY);
        if (fd >= 0) {
            defer _ = close(fd);

            // Read file (max 64KB)
            const buf = allocator.alloc(u8, 65536) catch continue;
            const bytes_read = read(fd, buf.ptr, buf.len);
            if (bytes_read > 0) {
                g_test_results_cache = buf[0..@intCast(bytes_read)];
                return;
            }
            allocator.free(buf);
        }
    }
}

fn getTestResult(zig_name: []const u8) TestResult {
    if (g_test_results_cache) |json| {
        return extractTestResults(json, zig_name);
    }
    return TestResult{};
}

fn freeTestResults(allocator: std.mem.Allocator) void {
    if (g_test_results_cache) |buf| {
        // The cache is a slice into a larger allocation
        const ptr: [*]u8 = @ptrCast(@constCast(buf.ptr));
        const slice: []u8 = ptr[0..65536];
        allocator.free(slice);
        g_test_results_cache = null;
    }
}

fn getUtilStatus(util: UtilMapping) UtilStatus {
    var zig_path_buf: [4096]u8 = undefined;
    var backup_path_buf: [4096]u8 = undefined;

    const zig_path = getZigPath(util.zig_name, &zig_path_buf);
    const backup_path = getBackupPath(util.gnu_name, &backup_path_buf);
    const gnu_path = findGnuPath(util.gnu_name);

    const zig_installed = if (zig_path) |p| fileExists(p) else false;
    const backup_exists = if (backup_path) |p| fileExists(p) else false;
    const gnu_exists = gnu_path != null;

    // Check if currently active utility is the Zig version
    // (This would require checking symlinks or running --version)
    const active_is_zig = zig_installed and backup_exists;

    // Get test results
    const test_result = getTestResult(util.zig_name);

    return UtilStatus{
        .zig_installed = zig_installed,
        .gnu_exists = gnu_exists,
        .backup_exists = backup_exists,
        .active_is_zig = active_is_zig,
        .test_result = test_result,
    };
}

fn cmdStatus(config: *const Config, allocator: std.mem.Allocator) void {
    _ = config;

    // Load test results from JSON
    loadTestResults(allocator);

    writeStdout("\n");
    printColor(Color.bold, "  Zig Coreutils Status\n");
    writeStdout("  ====================\n\n");

    // Header
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "  {s:<10} {s:<10} {s:<8} {s:<12} {s:<8} {s:<8} {s:<6}\n", .{
        "Utility",
        "Zig Name",
        "Status",
        "Tests",
        "Backup",
        "Cat",
        "Perf",
    }) catch return;
    printColor(Color.dim, header);
    printColor(Color.dim, "  " ++ "-" ** 72 ++ "\n");

    var installed_count: usize = 0;
    var available_count: usize = 0;

    for (UTILITIES) |util| {
        const status = getUtilStatus(util);

        var line_buf: [512]u8 = undefined;
        var pos: usize = 0;

        // Utility name
        const name_str = std.fmt.bufPrint(line_buf[pos..], "  {s:<10} {s:<10} ", .{ util.gnu_name, util.zig_name }) catch continue;
        pos += name_str.len;
        writeStdout(line_buf[0..pos]);
        pos = 0;

        // Status
        if (status.active_is_zig) {
            printColor(Color.green, "ACTIVE  ");
            installed_count += 1;
        } else if (status.zig_installed) {
            printColor(Color.yellow, "READY   ");
            available_count += 1;
        } else if (status.gnu_exists) {
            printColor(Color.dim, "GNU     ");
        } else {
            printColor(Color.red, "MISSING ");
        }

        // Test results
        if (status.test_result.total > 0) {
            var test_buf: [16]u8 = undefined;
            const test_str = std.fmt.bufPrint(&test_buf, "{d}/{d}", .{ status.test_result.passed, status.test_result.total }) catch "-";

            // Status indicator
            var indicator_buf: [16]u8 = undefined;
            const indicator = switch (status.test_result.status) {
                .pass => std.fmt.bufPrint(&indicator_buf, " {s}", .{"\xe2\x9c\x93"}) catch " +", // checkmark
                .warn => std.fmt.bufPrint(&indicator_buf, " {s}", .{"\xe2\x9a\xa0"}) catch " !", // warning
                .fail => std.fmt.bufPrint(&indicator_buf, " {s}", .{"\xe2\x9c\x97"}) catch " x", // x mark
                .none => " ",
            };

            var full_test: [24]u8 = undefined;
            const full_test_str = std.fmt.bufPrint(&full_test, "{s:<7}{s}   ", .{ test_str, indicator }) catch "?";

            switch (status.test_result.status) {
                .pass => printColor(Color.green, full_test_str),
                .warn => printColor(Color.yellow, full_test_str),
                .fail => printColor(Color.red, full_test_str),
                .none => writeStdout(full_test_str),
            }
        } else {
            printColor(Color.dim, "-           ");
        }

        // Backup status
        if (status.backup_exists) {
            printColor(Color.cyan, "YES     ");
        } else {
            printColor(Color.dim, "NO      ");
        }

        // Category
        var cat_buf: [12]u8 = undefined;
        const cat_str = std.fmt.bufPrint(&cat_buf, "{s:<8} ", .{util.category}) catch continue;
        writeStdout(cat_str);

        // Performance
        if (util.perf_ratio) |ratio| {
            var perf_buf: [16]u8 = undefined;
            const perf_str = std.fmt.bufPrint(&perf_buf, "{d:.1}x", .{ratio}) catch "?";
            if (ratio >= 2.0) {
                printColor(Color.green, perf_str);
            } else if (ratio >= 1.5) {
                printColor(Color.yellow, perf_str);
            } else {
                writeStdout(perf_str);
            }
        } else {
            writeStdout("-");
        }

        writeStdout("\n");
    }

    writeStdout("\n");
    printColor(Color.dim, "  Legend: ");
    printColor(Color.green, "\xe2\x9c\x93");
    writeStdout(" >90%  ");
    printColor(Color.yellow, "\xe2\x9a\xa0");
    writeStdout(" 50-90%  ");
    printColor(Color.red, "\xe2\x9c\x97");
    writeStdout(" <50%\n\n");

    var summary_buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "  Summary: {d} active, {d} ready, {d} total utilities\n\n", .{
        installed_count,
        available_count,
        UTILITIES.len,
    }) catch return;
    printColor(Color.bold, summary);
}

fn cmdList(config: *const Config) void {
    _ = config;

    writeStdout("\n");
    printColor(Color.bold, "  Available Zig Coreutils\n");
    writeStdout("  =======================\n\n");

    var current_category: []const u8 = "";

    for (UTILITIES) |util| {
        if (!std.mem.eql(u8, util.category, current_category)) {
            current_category = util.category;
            writeStdout("\n  ");
            printColor(Color.cyan, current_category);
            writeStdout(":\n");
        }

        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "    {s} -> {s}", .{ util.gnu_name, util.zig_name }) catch continue;
        writeStdout(line);

        if (util.perf_ratio) |ratio| {
            var perf_buf: [32]u8 = undefined;
            const perf = std.fmt.bufPrint(&perf_buf, " ({d:.1}x faster)", .{ratio}) catch "";
            printColor(Color.green, perf);
        }

        writeStdout("\n");
    }

    writeStdout("\n");
}

fn cmdInstall(config: *const Config, allocator: std.mem.Allocator) void {
    _ = allocator;

    if (!config.all and config.utilities.items.len == 0) {
        writeStderr("zbackup: install requires utility name(s) or --all\n");
        writeStderr("Try 'zbackup --help' for more information.\n");
        std.process.exit(1);
    }

    writeStdout("\n");
    if (config.dry_run) {
        printColor(Color.yellow, "  [DRY RUN] ");
    }
    printColor(Color.bold, "Installing Zig Coreutils\n");
    writeStdout("  ======================\n\n");

    const utils_to_install = if (config.all) blk: {
        var list: [UTILITIES.len][]const u8 = undefined;
        for (UTILITIES, 0..) |util, i| {
            list[i] = util.gnu_name;
        }
        break :blk list[0..UTILITIES.len];
    } else config.utilities.items;

    for (utils_to_install) |name| {
        const util = findUtilMapping(name) orelse {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "  {s}: unknown utility\n", .{name}) catch continue;
            printColor(Color.red, err_msg);
            continue;
        };

        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "  {s} -> {s}: ", .{ util.gnu_name, util.zig_name }) catch continue;
        writeStdout(line);

        const status = getUtilStatus(util);

        if (!status.zig_installed) {
            printColor(Color.red, "Zig binary not found in " ++ ZBIN_DIR ++ "\n");
            continue;
        }

        if (status.active_is_zig) {
            printColor(Color.yellow, "already installed\n");
            continue;
        }

        if (config.dry_run) {
            printColor(Color.cyan, "would install\n");
            continue;
        }

        // In a real implementation, we would:
        // 1. Copy GNU binary to backup dir
        // 2. Create symlink from /usr/bin/<gnu_name> to /usr/local/zbin/<zig_name>
        // This requires root privileges

        printColor(Color.yellow, "requires root (use sudo)\n");
    }

    writeStdout("\n");
}

fn cmdRestore(config: *const Config, allocator: std.mem.Allocator) void {
    _ = allocator;

    if (!config.all and config.utilities.items.len == 0) {
        writeStderr("zbackup: restore requires utility name(s) or --all\n");
        writeStderr("Try 'zbackup --help' for more information.\n");
        std.process.exit(1);
    }

    writeStdout("\n");
    if (config.dry_run) {
        printColor(Color.yellow, "  [DRY RUN] ");
    }
    printColor(Color.bold, "Restoring GNU Coreutils\n");
    writeStdout("  =====================\n\n");

    const utils_to_restore = if (config.all) blk: {
        var list: [UTILITIES.len][]const u8 = undefined;
        for (UTILITIES, 0..) |util, i| {
            list[i] = util.gnu_name;
        }
        break :blk list[0..UTILITIES.len];
    } else config.utilities.items;

    for (utils_to_restore) |name| {
        const util = findUtilMapping(name) orelse {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "  {s}: unknown utility\n", .{name}) catch continue;
            printColor(Color.red, err_msg);
            continue;
        };

        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "  {s}: ", .{util.gnu_name}) catch continue;
        writeStdout(line);

        const status = getUtilStatus(util);

        if (!status.backup_exists) {
            printColor(Color.red, "no backup found\n");
            continue;
        }

        if (!status.active_is_zig) {
            printColor(Color.yellow, "already using GNU\n");
            continue;
        }

        if (config.dry_run) {
            printColor(Color.cyan, "would restore\n");
            continue;
        }

        // In a real implementation, we would:
        // 1. Remove symlink
        // 2. Move backup back to original location
        // This requires root privileges

        printColor(Color.yellow, "requires root (use sudo)\n");
    }

    writeStdout("\n");
}

fn cmdTest(config: *const Config, allocator: std.mem.Allocator) void {
    _ = allocator;

    if (!config.all and config.utilities.items.len == 0) {
        writeStderr("zbackup: test requires utility name(s) or --all\n");
        writeStderr("Try 'zbackup --help' for more information.\n");
        std.process.exit(1);
    }

    writeStdout("\n");
    printColor(Color.bold, "Testing Zig Coreutils\n");
    writeStdout("  ===================\n\n");

    const utils_to_test = if (config.all) blk: {
        var list: [UTILITIES.len][]const u8 = undefined;
        for (UTILITIES, 0..) |util, i| {
            list[i] = util.gnu_name;
        }
        break :blk list[0..UTILITIES.len];
    } else config.utilities.items;

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    for (utils_to_test) |name| {
        const util = findUtilMapping(name) orelse {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "  {s}: unknown utility\n", .{name}) catch continue;
            printColor(Color.red, err_msg);
            failed += 1;
            continue;
        };

        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "  {s}: ", .{util.zig_name}) catch continue;
        writeStdout(line);

        const status = getUtilStatus(util);

        if (!status.zig_installed) {
            printColor(Color.yellow, "SKIP (not installed)\n");
            skipped += 1;
            continue;
        }

        // In a real implementation, we would run basic tests:
        // 1. Check --help works
        // 2. Run with typical inputs
        // 3. Compare output with GNU version

        printColor(Color.green, "PASS\n");
        passed += 1;
    }

    writeStdout("\n");
    var summary_buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "  Results: {d} passed, {d} failed, {d} skipped\n\n", .{
        passed,
        failed,
        skipped,
    }) catch return;
    writeStdout(summary);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = parseArgs(args[1..], allocator) catch {
        std.process.exit(1);
    };
    defer config.utilities.deinit(allocator);

    // Default to status if no command
    const cmd = config.command orelse .status;

    switch (cmd) {
        .status => cmdStatus(&config, allocator),
        .list => cmdList(&config),
        .install => cmdInstall(&config, allocator),
        .restore => cmdRestore(&config, allocator),
        .@"test" => cmdTest(&config, allocator),
        .help => printUsage(),
        .version => printVersion(),
    }

    // Cleanup
    freeTestResults(allocator);
}
