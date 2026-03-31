// zbench - Command-line Benchmarking Tool
// A pure Zig implementation inspired by hyperfine
// Features: statistical analysis, warmup runs, multi-command comparison

const std = @import("std");

// ============================================================================
// Configuration
// ============================================================================

const Config = struct {
    warmup_count: u32 = 3,
    run_count: u32 = 10,
    min_runs: u32 = 5,
    max_runs: u32 = 100,
    shell: []const u8 = "/bin/sh",
    show_output: bool = false,
    export_json: ?[]const u8 = null,
    export_markdown: ?[]const u8 = null,
    commands: std.ArrayListUnmanaged(Command) = .empty,
    prepare_cmd: ?[]const u8 = null,
    cleanup_cmd: ?[]const u8 = null,
    time_unit: TimeUnit = .auto,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.commands.items) |*cmd| {
            allocator.free(cmd.raw);
            if (cmd.name) |n| allocator.free(n);
        }
        self.commands.deinit(allocator);
        if (self.export_json) |p| allocator.free(p);
        if (self.export_markdown) |p| allocator.free(p);
    }
};

const Command = struct {
    raw: []const u8,
    name: ?[]const u8,
};

const TimeUnit = enum {
    auto,
    nanosecond,
    microsecond,
    millisecond,
    second,
};

// ============================================================================
// Statistics
// ============================================================================

const BenchmarkResult = struct {
    command: []const u8,
    name: ?[]const u8,
    times_ns: []const u64,
    mean_ns: f64,
    stddev_ns: f64,
    median_ns: f64,
    min_ns: u64,
    max_ns: u64,
    user_ns: u64,
    system_ns: u64,
    runs: u32,
    exit_codes: []const u8,
};

fn calculateStats(times: []u64) struct { mean: f64, stddev: f64, median: f64, min: u64, max: u64 } {
    if (times.len == 0) {
        return .{ .mean = 0, .stddev = 0, .median = 0, .min = 0, .max = 0 };
    }

    // Sort for median
    std.mem.sort(u64, times, {}, std.sort.asc(u64));

    var sum: u128 = 0;
    var min_val: u64 = times[0];
    var max_val: u64 = times[0];

    for (times) |t| {
        sum += t;
        if (t < min_val) min_val = t;
        if (t > max_val) max_val = t;
    }

    const mean: f64 = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(times.len));

    // Calculate standard deviation
    var variance_sum: f64 = 0;
    for (times) |t| {
        const diff = @as(f64, @floatFromInt(t)) - mean;
        variance_sum += diff * diff;
    }
    const stddev = @sqrt(variance_sum / @as(f64, @floatFromInt(times.len)));

    // Median
    const median: f64 = if (times.len % 2 == 0)
        (@as(f64, @floatFromInt(times[times.len / 2 - 1])) + @as(f64, @floatFromInt(times[times.len / 2]))) / 2.0
    else
        @as(f64, @floatFromInt(times[times.len / 2]));

    return .{
        .mean = mean,
        .stddev = stddev,
        .median = median,
        .min = min_val,
        .max = max_val,
    };
}

// ============================================================================
// Time Formatting
// ============================================================================

fn formatTime(ns: f64, unit: TimeUnit, buf: []u8) []const u8 {
    const actual_unit: TimeUnit = if (unit == .auto) blk: {
        if (ns >= 1_000_000_000) break :blk .second;
        if (ns >= 1_000_000) break :blk .millisecond;
        if (ns >= 1_000) break :blk .microsecond;
        break :blk .nanosecond;
    } else unit;

    const result = switch (actual_unit) {
        .second => std.fmt.bufPrint(buf, "{d:.3} s", .{ns / 1_000_000_000}),
        .millisecond => std.fmt.bufPrint(buf, "{d:.3} ms", .{ns / 1_000_000}),
        .microsecond => std.fmt.bufPrint(buf, "{d:.1} µs", .{ns / 1_000}),
        .nanosecond => std.fmt.bufPrint(buf, "{d:.0} ns", .{ns}),
        .auto => unreachable,
    };

    return result catch "???";
}

fn formatTimeShort(ns: f64, buf: []u8) []const u8 {
    if (ns >= 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d:.2}s", .{ns / 1_000_000_000}) catch "???";
    } else if (ns >= 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1}ms", .{ns / 1_000_000}) catch "???";
    } else if (ns >= 1_000) {
        return std.fmt.bufPrint(buf, "{d:.0}µs", .{ns / 1_000}) catch "???";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0}ns", .{ns}) catch "???";
    }
}

// ============================================================================
// Writer for Zig 0.16 I/O API
// ============================================================================

const Writer = struct {
    io: std.Io,
    buffer: *[8192]u8,
    file: std.Io.File,

    pub fn stdout() Writer {
        const io = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [8192]u8 = undefined;
        };
        return Writer{
            .io = io,
            .buffer = &static.buffer,
            .file = std.Io.File.stdout(),
        };
    }

    pub fn stderr() Writer {
        const io = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [8192]u8 = undefined;
        };
        return Writer{
            .io = io,
            .buffer = &static.buffer,
            .file = std.Io.File.stderr(),
        };
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        var writer = self.file.writer(self.io, self.buffer);
        writer.interface.print(fmt, args) catch {};
        writer.interface.flush() catch {};
    }

    pub fn write(self: *Writer, data: []const u8) void {
        var writer = self.file.writer(self.io, self.buffer);
        writer.interface.writeAll(data) catch {};
        writer.interface.flush() catch {};
    }
};

// ============================================================================
// Command Execution
// ============================================================================

const libc = std.c;
const posix = std.posix;

extern "c" fn fork() posix.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: posix.pid_t, status: *c_int, options: c_int) posix.pid_t;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;

const RunResult = struct {
    elapsed_ns: u64,
    user_ns: u64,
    system_ns: u64,
    exit_code: u8,
};

fn runCommand(allocator: std.mem.Allocator, shell: []const u8, command: []const u8, show_output: bool) !RunResult {
    _ = allocator;

    // Prepare null-terminated strings for exec
    var shell_buf: [256]u8 = undefined;
    var cmd_buf: [4096]u8 = undefined;

    if (shell.len >= shell_buf.len - 1) return error.ShellTooLong;
    if (command.len >= cmd_buf.len - 1) return error.CommandTooLong;

    @memcpy(shell_buf[0..shell.len], shell);
    shell_buf[shell.len] = 0;
    const shell_z: [*:0]const u8 = @ptrCast(&shell_buf);

    @memcpy(cmd_buf[0..command.len], command);
    cmd_buf[command.len] = 0;
    const cmd_z: [*:0]const u8 = @ptrCast(&cmd_buf);

    const c_flag: [*:0]const u8 = "-c";
    const argv: [4:null]?[*:0]const u8 = .{ shell_z, c_flag, cmd_z, null };

    // Start timing before fork for most accurate measurement
    var ts_start: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_start);

    const pid = fork();
    if (pid < 0) {
        return error.ForkFailed;
    }

    if (pid == 0) {
        // Child process
        if (!show_output) {
            // Redirect stdout/stderr to /dev/null
            const devnull = libc.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(libc.mode_t, 0));
            if (devnull >= 0) {
                _ = dup2(devnull, 1);
                _ = dup2(devnull, 2);
                _ = libc.close(devnull);
            }
        }

        _ = execvp(shell_z, &argv);
        _exit(127); // exec failed
    }

    // Parent: wait for child
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);

    // End timing
    var ts_end: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_end);
    const elapsed_ns: u64 = @intCast((@as(i128, ts_end.sec) - @as(i128, ts_start.sec)) * std.time.ns_per_s + (@as(i128, ts_end.nsec) - @as(i128, ts_start.nsec)));

    // Extract exit code from status
    const exit_code: u8 = if ((status & 0x7f) == 0)
        // Normal exit: extract exit status
        @truncate(@as(u32, @bitCast(status)) >> 8)
    else if ((status & 0x7f) != 0x7f)
        // Killed by signal
        @as(u8, @truncate(@as(u32, @bitCast(status)) & 0x7f)) + 128
    else
        255;

    return RunResult{
        .elapsed_ns = elapsed_ns,
        .user_ns = 0,
        .system_ns = 0,
        .exit_code = exit_code,
    };
}

// ============================================================================
// Progress Display
// ============================================================================

fn printProgress(w: *Writer, current: u32, total: u32, warmup: bool, cmd_name: []const u8) void {
    const pct = @as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(total)) * 100.0;
    const bar_width: u32 = 20;
    const filled: u32 = @intFromFloat(@as(f64, @floatFromInt(bar_width)) * pct / 100.0);

    var bar: [20]u8 = undefined;
    for (0..bar_width) |i| {
        bar[i] = if (i < filled) '#' else '-';
    }

    if (warmup) {
        w.print("\r  Warming up: [{s}] {d}/{d}   ", .{ &bar, current, total });
    } else {
        w.print("\r  {s}: [{s}] {d}/{d} ({d:.0}%)   ", .{ cmd_name, &bar, current, total, pct });
    }
}

fn clearProgress(w: *Writer) void {
    w.write("\r                                                                     \r");
}

// ============================================================================
// Benchmark Execution
// ============================================================================

fn runBenchmark(
    allocator: std.mem.Allocator,
    config: *const Config,
    cmd: *const Command,
    w: *Writer,
) !BenchmarkResult {
    const display_name = cmd.name orelse cmd.raw;

    w.print("\nBenchmark: {s}\n", .{display_name});

    // Warmup phase
    if (config.warmup_count > 0) {
        w.print("  Warming up ({d} runs)...\n", .{config.warmup_count});
        for (0..config.warmup_count) |i| {
            printProgress(w, @intCast(i + 1), config.warmup_count, true, display_name);

            if (config.prepare_cmd) |prep| {
                _ = runCommand(allocator, config.shell, prep, false) catch {};
            }

            _ = try runCommand(allocator, config.shell, cmd.raw, config.show_output);

            if (config.cleanup_cmd) |cleanup| {
                _ = runCommand(allocator, config.shell, cleanup, false) catch {};
            }
        }
        clearProgress(w);
    }

    // Benchmark runs
    var times = try allocator.alloc(u64, config.run_count);
    defer allocator.free(times);
    var exit_codes = try allocator.alloc(u8, config.run_count);
    defer allocator.free(exit_codes);

    var total_user: u64 = 0;
    var total_system: u64 = 0;

    for (0..config.run_count) |i| {
        printProgress(w, @intCast(i + 1), config.run_count, false, display_name);

        if (config.prepare_cmd) |prep| {
            _ = runCommand(allocator, config.shell, prep, false) catch {};
        }

        const result = try runCommand(allocator, config.shell, cmd.raw, config.show_output);

        times[i] = result.elapsed_ns;
        exit_codes[i] = result.exit_code;
        total_user += result.user_ns;
        total_system += result.system_ns;

        if (config.cleanup_cmd) |cleanup| {
            _ = runCommand(allocator, config.shell, cleanup, false) catch {};
        }
    }
    clearProgress(w);

    // Calculate statistics
    const stats = calculateStats(times);

    // Copy times for result
    const times_copy = try allocator.dupe(u64, times);
    const exit_codes_copy = try allocator.dupe(u8, exit_codes);

    return BenchmarkResult{
        .command = cmd.raw,
        .name = cmd.name,
        .times_ns = times_copy,
        .mean_ns = stats.mean,
        .stddev_ns = stats.stddev,
        .median_ns = stats.median,
        .min_ns = stats.min,
        .max_ns = stats.max,
        .user_ns = total_user / config.run_count,
        .system_ns = total_system / config.run_count,
        .runs = config.run_count,
        .exit_codes = exit_codes_copy,
    };
}

// ============================================================================
// Result Display
// ============================================================================

fn printResult(w: *Writer, result: *const BenchmarkResult, unit: TimeUnit) void {
    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    var buf3: [32]u8 = undefined;
    var buf4: [32]u8 = undefined;

    const display_name = result.name orelse result.command;

    w.print("  Time ({s}):\n", .{display_name});
    w.print("    Mean:    {s} ± {s}\n", .{
        formatTime(result.mean_ns, unit, &buf1),
        formatTime(result.stddev_ns, unit, &buf2),
    });
    w.print("    Range:   {s} … {s}\n", .{
        formatTime(@floatFromInt(result.min_ns), unit, &buf3),
        formatTime(@floatFromInt(result.max_ns), unit, &buf4),
    });
    w.print("    Median:  {s}\n", .{formatTime(result.median_ns, unit, &buf1)});
    w.print("    Runs:    {d}\n", .{result.runs});

    // Check for non-zero exit codes
    var non_zero: u32 = 0;
    for (result.exit_codes) |code| {
        if (code != 0) non_zero += 1;
    }
    if (non_zero > 0) {
        w.print("    Warning: {d} run(s) had non-zero exit code\n", .{non_zero});
    }
}

fn printComparison(w: *Writer, results: []const BenchmarkResult, unit: TimeUnit) void {
    if (results.len < 2) return;

    w.write("\n");
    w.write("Summary\n");

    // Find fastest
    var fastest_idx: usize = 0;
    var fastest_mean: f64 = results[0].mean_ns;
    for (results, 0..) |r, i| {
        if (r.mean_ns < fastest_mean) {
            fastest_mean = r.mean_ns;
            fastest_idx = i;
        }
    }

    const fastest = &results[fastest_idx];
    const fastest_name = fastest.name orelse fastest.command;

    var buf: [32]u8 = undefined;
    w.print("  '{s}' ran\n", .{fastest_name});

    for (results, 0..) |r, i| {
        if (i == fastest_idx) continue;

        const name = r.name orelse r.command;
        const ratio = r.mean_ns / fastest_mean;

        w.print("    {d:.2}x faster than '{s}' ({s})\n", .{
            ratio,
            name,
            formatTime(r.mean_ns, unit, &buf),
        });
    }
}

// ============================================================================
// Export Functions
// ============================================================================

fn exportJson(_: std.mem.Allocator, results: []const BenchmarkResult, path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    // Create output file - need to use proper path handling
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    try writer.interface.writeAll("{\n  \"results\": [\n");

    for (results, 0..) |r, i| {
        if (i > 0) try writer.interface.writeAll(",\n");

        try writer.interface.print("    {{\n", .{});
        try writer.interface.print("      \"command\": \"{s}\",\n", .{r.command});
        try writer.interface.print("      \"mean\": {d:.6},\n", .{r.mean_ns / 1_000_000_000.0});
        try writer.interface.print("      \"stddev\": {d:.6},\n", .{r.stddev_ns / 1_000_000_000.0});
        try writer.interface.print("      \"median\": {d:.6},\n", .{r.median_ns / 1_000_000_000.0});
        try writer.interface.print("      \"min\": {d:.6},\n", .{@as(f64, @floatFromInt(r.min_ns)) / 1_000_000_000.0});
        try writer.interface.print("      \"max\": {d:.6},\n", .{@as(f64, @floatFromInt(r.max_ns)) / 1_000_000_000.0});
        try writer.interface.print("      \"times\": [", .{});

        for (r.times_ns, 0..) |t, j| {
            if (j > 0) try writer.interface.writeAll(", ");
            try writer.interface.print("{d:.9}", .{@as(f64, @floatFromInt(t)) / 1_000_000_000.0});
        }

        try writer.interface.print("],\n", .{});
        try writer.interface.print("      \"runs\": {d}\n", .{r.runs});
        try writer.interface.print("    }}", .{});
    }

    try writer.interface.writeAll("\n  ]\n}\n");
    try writer.interface.flush();
}

fn exportMarkdown(allocator: std.mem.Allocator, results: []const BenchmarkResult, path: []const u8) !void {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    try writer.interface.writeAll("# Benchmark Results\n\n");
    try writer.interface.writeAll("| Command | Mean | Min | Max | Relative |\n");
    try writer.interface.writeAll("|---------|------|-----|-----|----------|\n");

    // Find fastest for relative comparison
    var fastest_mean: f64 = results[0].mean_ns;
    for (results) |r| {
        if (r.mean_ns < fastest_mean) fastest_mean = r.mean_ns;
    }

    for (results) |r| {
        const name = r.name orelse r.command;
        const relative = r.mean_ns / fastest_mean;

        var buf1: [32]u8 = undefined;
        var buf2: [32]u8 = undefined;
        var buf3: [32]u8 = undefined;

        try writer.interface.print("| `{s}` | {s} ± {s} | {s} | {s} | {d:.2}x |\n", .{
            name,
            formatTime(r.mean_ns, .auto, &buf1),
            formatTimeShort(r.stddev_ns, &buf2),
            formatTimeShort(@floatFromInt(r.min_ns), &buf3),
            formatTimeShort(@floatFromInt(r.max_ns), &buf1),
            relative,
        });
    }

    try writer.interface.flush();
}

// ============================================================================
// Argument Parsing
// ============================================================================

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    var config = Config{};

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--warmup")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.warmup_count = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--runs")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.run_count = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            // Store name for next command
            const name = try allocator.dupe(u8, args[i]);
            i += 1;
            if (i >= args.len) {
                allocator.free(name);
                return error.MissingCommand;
            }
            const cmd_str = try allocator.dupe(u8, args[i]);
            try config.commands.append(allocator, .{ .raw = cmd_str, .name = name });
        } else if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--shell")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.shell = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prepare")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.prepare_cmd = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cleanup")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.cleanup_cmd = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--export-json")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.export_json = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--export-markdown")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.export_markdown = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--show-output")) {
            config.show_output = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--time-unit")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            if (std.mem.eql(u8, args[i], "s") or std.mem.eql(u8, args[i], "second")) {
                config.time_unit = .second;
            } else if (std.mem.eql(u8, args[i], "ms") or std.mem.eql(u8, args[i], "millisecond")) {
                config.time_unit = .millisecond;
            } else if (std.mem.eql(u8, args[i], "us") or std.mem.eql(u8, args[i], "microsecond")) {
                config.time_unit = .microsecond;
            } else if (std.mem.eql(u8, args[i], "ns") or std.mem.eql(u8, args[i], "nanosecond")) {
                config.time_unit = .nanosecond;
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            // Command to benchmark
            const cmd_str = try allocator.dupe(u8, arg);
            try config.commands.append(allocator, .{ .raw = cmd_str, .name = null });
        } else {
            var w = Writer.stderr();
            w.print("Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        }
    }

    if (config.commands.items.len == 0) {
        printHelp();
        std.process.exit(1);
    }

    return config;
}

fn printHelp() void {
    var w = Writer.stdout();
    w.write(
        \\zbench - Command-line Benchmarking Tool
        \\
        \\USAGE:
        \\    zbench [OPTIONS] <COMMAND>...
        \\    zbench [OPTIONS] -n <NAME> <COMMAND>...
        \\
        \\ARGUMENTS:
        \\    <COMMAND>...    Commands to benchmark
        \\
        \\OPTIONS:
        \\    -w, --warmup <NUM>         Number of warmup runs [default: 3]
        \\    -r, --runs <NUM>           Number of benchmark runs [default: 10]
        \\    -n, --name <NAME> <CMD>    Name a command for display
        \\    -S, --shell <SHELL>        Shell to use [default: /bin/sh]
        \\    -p, --prepare <CMD>        Command to run before each benchmark
        \\    -c, --cleanup <CMD>        Command to run after each benchmark
        \\    -u, --time-unit <UNIT>     Time unit (s, ms, us, ns, auto)
        \\    --show-output              Show command output
        \\    --export-json <FILE>       Export results as JSON
        \\    --export-markdown <FILE>   Export results as Markdown
        \\    -h, --help                 Show this help
        \\
        \\EXAMPLES:
        \\    zbench 'sleep 0.1'
        \\    zbench -r 20 'ls -la' 'find . -name "*.zig"'
        \\    zbench -n fast 'cat file' -n slow 'grep pattern file'
        \\    zbench -w 5 -r 50 'zig build' --export-json results.json
        \\
    );
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch |err| {
        var w = Writer.stderr();
        w.print("Error parsing arguments: {}\n", .{err});
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    var w = Writer.stdout();

    // Print header
    w.write("zbench - Command-line Benchmarking Tool\n");
    w.print("Running {d} benchmark(s) with {d} runs each ({d} warmup)\n", .{
        config.commands.items.len,
        config.run_count,
        config.warmup_count,
    });

    // Run benchmarks
    var results: std.ArrayListUnmanaged(BenchmarkResult) = .empty;
    defer {
        for (results.items) |r| {
            allocator.free(r.times_ns);
            allocator.free(r.exit_codes);
        }
        results.deinit(allocator);
    }

    for (config.commands.items) |*cmd| {
        const result = runBenchmark(allocator, &config, cmd, &w) catch |err| {
            w.print("Error running benchmark: {}\n", .{err});
            continue;
        };
        results.append(allocator, result) catch continue;
    }

    // Print results
    w.write("\n");
    w.write("═══════════════════════════════════════════════════════════════════\n");
    w.write("Results\n");
    w.write("═══════════════════════════════════════════════════════════════════\n");

    for (results.items) |*r| {
        printResult(&w, r, config.time_unit);
        w.write("\n");
    }

    // Print comparison if multiple commands
    if (results.items.len > 1) {
        printComparison(&w, results.items, config.time_unit);
    }

    // Export if requested
    if (config.export_json) |path| {
        exportJson(allocator, results.items, path) catch |err| {
            w.print("Error exporting JSON: {}\n", .{err});
        };
        w.print("\nExported to: {s}\n", .{path});
    }

    if (config.export_markdown) |path| {
        exportMarkdown(allocator, results.items, path) catch |err| {
            w.print("Error exporting Markdown: {}\n", .{err});
        };
        w.print("\nExported to: {s}\n", .{path});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "calculate statistics" {
    var times = [_]u64{ 100, 200, 300, 400, 500 };
    const stats = calculateStats(&times);

    try std.testing.expectEqual(@as(f64, 300), stats.mean);
    try std.testing.expectEqual(@as(u64, 100), stats.min);
    try std.testing.expectEqual(@as(u64, 500), stats.max);
    try std.testing.expectEqual(@as(f64, 300), stats.median);
}

test "format time" {
    var buf: [32]u8 = undefined;

    const ns = formatTime(500, .auto, &buf);
    try std.testing.expect(std.mem.indexOf(u8, ns, "ns") != null);

    const us = formatTime(5000, .auto, &buf);
    try std.testing.expect(std.mem.indexOf(u8, us, "µs") != null);

    const ms = formatTime(5_000_000, .auto, &buf);
    try std.testing.expect(std.mem.indexOf(u8, ms, "ms") != null);

    const s = formatTime(5_000_000_000, .auto, &buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "s") != null);
}
