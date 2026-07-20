//! zxargs - High-performance parallel xargs implementation
//!
//! Features:
//! - Parallel execution with configurable process count (-P)
//! - Null-delimited input for safe filename handling (-0)
//! - Batching with max args per command (-n)
//! - Replace string for placeholder substitution (-I)
//! - Command line length limiting (-s)
//! - Trace and prompt modes (-t, -p)

const std = @import("std");
const libc = std.c;

// Zig 0.16 compatible Mutex (Mutex was removed)
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

// Zig 0.16 compatible Condition (Condition was removed)
const Condition = struct {
    inner: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = std.c.pthread_cond_wait(&self.inner, &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        _ = std.c.pthread_cond_signal(&self.inner);
    }

    pub fn broadcast(self: *Condition) void {
        _ = std.c.pthread_cond_broadcast(&self.inner);
    }
};

extern "c" fn fork() std.c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn usleep(usec: c_uint) c_int;

// Simple I/O helpers
fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn writeStdout(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn printNum(n: usize) void {
    var buf: [20]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    writeStderr(str);
}

const Config = struct {
    command: []const []const u8 = &.{},
    max_args: ?usize = null, // -n: max args per command
    max_procs: usize = 1, // -P: parallel processes
    null_delim: bool = false, // -0: null delimiter
    replace_str: ?[]const u8 = null, // -I: replace string
    replace_str_owned: bool = false, // whether replace_str was heap-allocated
    max_chars: usize = 128 * 1024, // -s: max command line length (bytes)
    max_chars_set: bool = false, // whether -s was given explicitly
    trace: bool = false, // -t: print commands
    prompt: bool = false, // -p: prompt before execution
    no_run_if_empty: bool = false, // -r: skip if no input
    exit_if_too_big: bool = false, // -x: exit if an item won't fit -s (GNU semantics)
    verbose: bool = false,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.command) |arg| allocator.free(arg);
        allocator.free(self.command);
        if (self.replace_str_owned) {
            if (self.replace_str) |rs| allocator.free(rs);
        }
    }
};

const ArgBatch = struct {
    args: std.ArrayListUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator,
    total_len: usize = 0,

    fn init(allocator: std.mem.Allocator) ArgBatch {
        return .{
            .allocator = allocator,
        };
    }

    fn deinit(self: *ArgBatch) void {
        for (self.args.items) |arg| {
            self.allocator.free(arg);
        }
        self.args.deinit(self.allocator);
    }

    fn append(self: *ArgBatch, arg: []const u8) !void {
        const owned = try self.allocator.dupe(u8, arg);
        try self.args.append(self.allocator, owned);
        self.total_len += arg.len + 1; // +1 for space/null
    }

    fn clear(self: *ArgBatch) void {
        for (self.args.items) |arg| {
            self.allocator.free(arg);
        }
        self.args.clearRetainingCapacity();
        self.total_len = 0;
    }

    fn isEmpty(self: *const ArgBatch) bool {
        return self.args.items.len == 0;
    }
};

// Worker state for parallel execution
const WorkerPool = struct {
    threads: []std.Thread,
    queue: std.ArrayListUnmanaged([]const []const u8) = .empty,
    mutex: Mutex = .{},
    cond: Condition = .{},
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    error_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    config: *const Config,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, config: *const Config) !*WorkerPool {
        const pool = try allocator.create(WorkerPool);
        pool.* = .{
            .threads = try allocator.alloc(std.Thread, config.max_procs),
            .config = config,
            .allocator = allocator,
        };

        // Spawn worker threads
        for (pool.threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{ pool, i });
        }

        return pool;
    }

    fn deinit(self: *WorkerPool) void {
        // Signal shutdown
        self.shutdown.store(true, .release);

        // Wake all workers
        self.mutex.lock();
        self.cond.broadcast();
        self.mutex.unlock();

        // Join all threads
        for (self.threads) |thread| {
            thread.join();
        }

        // Free queued items
        for (self.queue.items) |args| {
            self.allocator.free(args);
        }
        self.queue.deinit(self.allocator);
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }

    fn submit(self: *WorkerPool, args: []const []const u8) !void {
        const owned = try self.allocator.dupe([]const u8, args);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.queue.append(self.allocator, owned);
        self.cond.signal();
    }

    fn waitForCompletion(self: *WorkerPool) void {
        while (true) {
            self.mutex.lock();
            const queue_empty = self.queue.items.len == 0;
            const active = self.active_count.load(.acquire);
            self.mutex.unlock();

            if (queue_empty and active == 0) break;
            // Yield the CPU between polls instead of busy-spinning a whole core.
            _ = usleep(500);
        }
    }

    fn getErrorCount(self: *WorkerPool) usize {
        return self.error_count.load(.acquire);
    }

    fn workerThread(pool: *WorkerPool, _: usize) void {
        while (true) {
            // Get work from queue
            var args: ?[]const []const u8 = null;

            {
                pool.mutex.lock();
                defer pool.mutex.unlock();

                while (pool.queue.items.len == 0 and !pool.shutdown.load(.acquire)) {
                    pool.cond.wait(&pool.mutex);
                }

                if (pool.shutdown.load(.acquire) and pool.queue.items.len == 0) {
                    return;
                }

                if (pool.queue.items.len > 0) {
                    args = pool.queue.orderedRemove(0);
                    _ = pool.active_count.fetchAdd(1, .acq_rel);
                }
            }

            if (args) |work| {
                defer {
                    pool.allocator.free(work);
                    _ = pool.active_count.fetchSub(1, .acq_rel);
                }

                // Execute command
                const result = executeCommand(pool.config, work, pool.allocator);
                if (result != 0) {
                    _ = pool.error_count.fetchAdd(1, .acq_rel);
                }
            }
        }
    }
};

fn printVerboseHeader(config: *const Config, arg_count: usize) void {
    if (!config.verbose) return;
    writeStderr("zxargs: ");
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{arg_count}) catch return;
    writeStderr(str);
    writeStderr(" argument(s)\n");
}

fn printVerboseExit(config: *const Config, exit_code: u8) void {
    if (!config.verbose) return;
    writeStderr("zxargs: exit ");
    var buf: [16]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{exit_code}) catch return;
    writeStderr(str);
    writeStderr("\n");
}

fn executeCommand(config: *const Config, args: []const []const u8, allocator: std.mem.Allocator) u8 {
    // Build full command line
    var cmd_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer cmd_args.deinit(allocator);

    // Add base command
    for (config.command) |arg| {
        cmd_args.append(allocator, arg) catch return 1;
    }

    // If no command specified, default to echo
    if (cmd_args.items.len == 0) {
        cmd_args.append(allocator, "echo") catch return 1;
    }

    // Handle replace string mode (-I)
    if (config.replace_str) |replace| {
        // For -I mode, we run one command per input item
        // Replace occurrences of replace_str with the argument
        var worst: u8 = 0;
        for (args) |arg| {
            var final_args: std.ArrayListUnmanaged([]const u8) = .empty;
            // Track, per entry, whether we allocated it (so we can free exactly those).
            var allocated: std.ArrayListUnmanaged(bool) = .empty;
            defer {
                for (final_args.items, allocated.items) |item, was_alloc| {
                    if (was_alloc) allocator.free(item);
                }
                final_args.deinit(allocator);
                allocated.deinit(allocator);
            }

            for (config.command) |cmd_arg| {
                if (std.mem.indexOf(u8, cmd_arg, replace)) |_| {
                    // Replace all occurrences
                    var result: std.ArrayListUnmanaged(u8) = .empty;
                    defer result.deinit(allocator);

                    var remaining = cmd_arg;
                    while (std.mem.indexOf(u8, remaining, replace)) |idx| {
                        result.appendSlice(allocator, remaining[0..idx]) catch return 1;
                        result.appendSlice(allocator, arg) catch return 1;
                        remaining = remaining[idx + replace.len ..];
                    }
                    result.appendSlice(allocator, remaining) catch return 1;

                    const owned = allocator.dupe(u8, result.items) catch return 1;
                    final_args.append(allocator, owned) catch {
                        allocator.free(owned);
                        return 1;
                    };
                    allocated.append(allocator, true) catch return 1;
                } else {
                    final_args.append(allocator, cmd_arg) catch return 1;
                    allocated.append(allocator, false) catch return 1;
                }
            }

            if (config.trace) {
                printCommand(final_args.items);
            }

            const ret = spawnAndWait(final_args.items, allocator);
            if (ret > worst) worst = ret;
            // Stop immediately on cannot-run / not-found / signal / exit-255,
            // matching GNU xargs (only a plain 1..125 exit -> 123 keeps going).
            if (ret != 0 and ret != 123) return ret;
        }
        return worst;
    }

    // Add input arguments
    for (args) |arg| {
        cmd_args.append(allocator, arg) catch return 1;
    }

    printVerboseHeader(config, args.len);

    if (config.trace) {
        printCommand(cmd_args.items);
    }

    if (config.prompt) {
        writeStderr("?...");
        // stdin has already been fully drained by readInput(); GNU reads the
        // confirmation from the controlling terminal, so open /dev/tty here.
        const tty_fd = libc.open("/dev/tty", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (tty_fd < 0) return 0; // no tty -> treat as "no", skip
        defer _ = libc.close(tty_fd);
        var buf: [16]u8 = undefined;
        const n = libc.read(tty_fd, &buf, buf.len);
        if (n <= 0 or (buf[0] != 'y' and buf[0] != 'Y')) {
            return 0; // Skip this command
        }
    }

    const ret = spawnAndWait(cmd_args.items, allocator);
    printVerboseExit(config, ret);
    return ret;
}

/// Map a child's raw exit code to the xargs exit-status convention for a single
/// invocation. Ref: GNU findutils `xargs(1)` EXIT STATUS:
///   0   all invocations exited 0
///   123 an invocation exited 1..125
///   124 an invocation exited 255
///   125 an invocation was killed by a signal   (handled in spawnAndWait)
///   126 the command was found but could not be run
///   127 the command was not found
fn mapExit(code: u8) u8 {
    if (code == 0) return 0;
    if (code == 255) return 124;
    if (code == 126) return 126; // child _exit(126): exec failed, not ENOENT
    if (code == 127) return 127; // child _exit(127): ENOENT
    return 123; // 1..125 (and any other nonzero) -> "command exited nonzero"
}

/// Fork/exec `args` and wait. Returns the xargs-convention code (see mapExit).
/// Distinguishes "not found" (127) from "cannot run" (126) in the child by errno,
/// and reports signal death as 125.
fn spawnAndWait(args: []const []const u8, allocator: std.mem.Allocator) u8 {
    // Guard: an empty argv (e.g. `-I{}` with no COMMAND) has no argv[0] to exec.
    if (args.len == 0) return 126;

    // Convert to null-terminated strings for execvp
    const argv = allocator.allocSentinel(?[*:0]const u8, args.len, null) catch return 126;
    defer allocator.free(argv);

    for (args, 0..) |arg, i| {
        argv[i] = allocator.dupeZ(u8, arg) catch return 126;
    }
    defer {
        for (argv) |ptr| {
            if (ptr) |p| {
                allocator.free(std.mem.span(p));
            }
        }
    }

    const pid = fork();
    if (pid < 0) return 126;

    if (pid == 0) {
        // Child process - execvp never returns on success
        _ = execvp(argv[0].?, argv);
        // exec failed: distinguish "not found" (127) from "cannot run" (126).
        const e = std.c._errno().*;
        const enoent = @intFromEnum(std.c.E.NOENT);
        std.c._exit(if (e == enoent) 127 else 126);
    }

    // Parent: wait for child
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    // Check if exited normally (WIFEXITED) and extract exit code (WEXITSTATUS)
    // WIFEXITED: (status & 0x7f) == 0
    // WEXITSTATUS: (status >> 8) & 0xff
    const wstatus: u32 = @bitCast(status);
    if ((wstatus & 0x7f) == 0) {
        return mapExit(@intCast((wstatus >> 8) & 0xff));
    }
    // Killed (or stopped) by a signal.
    return 125;
}

fn printCommand(args: []const []const u8) void {
    for (args, 0..) |arg, i| {
        if (i > 0) writeStderr(" ");
        // Quote if contains spaces
        if (std.mem.indexOfAny(u8, arg, " \t\n\"'")) |_| {
            writeStderr("\"");
            writeStderr(arg);
            writeStderr("\"");
        } else {
            writeStderr(arg);
        }
    }
    writeStderr("\n");
}

const InputList = struct {
    items: [][]const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *InputList) void {
        for (self.items) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.items);
    }
};

fn readInput(config: *const Config, allocator: std.mem.Allocator) !InputList {
    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(item);
        }
        items.deinit(allocator);
    }

    var buf: [64 * 1024]u8 = undefined;
    var current: std.ArrayListUnmanaged(u8) = .empty;
    defer current.deinit(allocator);

    var in_quote = false;
    var quote_char: u8 = 0;
    var escape_next = false;

    while (true) {
        const n = libc.read(libc.STDIN_FILENO, &buf, buf.len);
        if (n <= 0) break;

        for (buf[0..@intCast(n)]) |ch| {
            if (config.null_delim) {
                // Null-delimited mode: simple split on \0
                if (ch == 0) {
                    if (current.items.len > 0) {
                        const owned = try allocator.dupe(u8, current.items);
                        try items.append(allocator, owned);
                        current.clearRetainingCapacity();
                    }
                } else {
                    try current.append(allocator, ch);
                }
            } else {
                // Whitespace-delimited with quote handling
                if (escape_next) {
                    try current.append(allocator, ch);
                    escape_next = false;
                    continue;
                }

                if (ch == '\\' and !in_quote) {
                    escape_next = true;
                    continue;
                }

                if ((ch == '"' or ch == '\'') and !in_quote) {
                    in_quote = true;
                    quote_char = ch;
                    continue;
                }

                if (in_quote and ch == quote_char) {
                    in_quote = false;
                    continue;
                }

                if (!in_quote and (ch == ' ' or ch == '\t' or ch == '\n')) {
                    if (current.items.len > 0) {
                        const owned = try allocator.dupe(u8, current.items);
                        try items.append(allocator, owned);
                        current.clearRetainingCapacity();
                    }
                } else {
                    try current.append(allocator, ch);
                }
            }
        }
    }

    // GNU xargs treats an unmatched quote at EOF as a fatal error.
    if (in_quote) {
        writeStderr("zxargs: unmatched ");
        writeStderr(if (quote_char == '"') "double" else "single");
        writeStderr(" quote\n");
        return error.UnterminatedQuote;
    }

    // Don't forget the last item
    if (current.items.len > 0) {
        const owned = try allocator.dupe(u8, current.items);
        try items.append(allocator, owned);
    }

    return .{
        .items = try items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn parseArgs(allocator: std.mem.Allocator, init: std.process.Init) !Config {
    var config = Config{};
    var cmd_args: std.ArrayListUnmanaged([]const u8) = .empty;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var i: usize = 1;
    var found_command = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (found_command) {
            // Everything after command is part of it
            try cmd_args.append(allocator, try allocator.dupe(u8, arg));
            continue;
        }

        if (std.mem.eql(u8, arg, "-0") or std.mem.eql(u8, arg, "--null")) {
            config.null_delim = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--max-args")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.max_args = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--max-procs")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.max_procs = try std.fmt.parseInt(usize, args[i], 10);
            if (config.max_procs == 0) {
                // 0 means use all CPUs
                config.max_procs = std.Thread.getCpuCount() catch 4;
            }
        } else if (std.mem.eql(u8, arg, "-I") or std.mem.eql(u8, arg, "--replace")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.replace_str = try allocator.dupe(u8, args[i]);
            config.replace_str_owned = true;
            config.max_args = 1; // -I implies -n 1
        } else if (std.mem.eql(u8, arg, "-i")) {
            config.replace_str = "{}";
            config.max_args = 1;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--max-chars")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.max_chars = try std.fmt.parseInt(usize, args[i], 10);
            config.max_chars_set = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--trace")) {
            config.trace = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            config.trace = true;
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--interactive")) {
            config.prompt = true;
            config.trace = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--no-run-if-empty")) {
            config.no_run_if_empty = true;
        } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--exit")) {
            config.exit_if_too_big = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zxargs 1.0.0\n");
            std.process.exit(0);
        } else if (arg.len > 0 and arg[0] == '-') {
            // Check for combined short options like -n5 or -P4
            if (arg.len > 2 and arg[1] == 'n') {
                config.max_args = try std.fmt.parseInt(usize, arg[2..], 10);
            } else if (arg.len > 2 and arg[1] == 'P') {
                config.max_procs = try std.fmt.parseInt(usize, arg[2..], 10);
                if (config.max_procs == 0) {
                    config.max_procs = std.Thread.getCpuCount() catch 4;
                }
            } else if (arg.len > 2 and arg[1] == 's') {
                config.max_chars = try std.fmt.parseInt(usize, arg[2..], 10);
                config.max_chars_set = true;
            } else if (arg.len > 2 and arg[1] == 'I') {
                config.replace_str = try allocator.dupe(u8, arg[2..]);
                config.replace_str_owned = true;
                config.max_args = 1;
            } else {
                writeStderr("zxargs: unknown option: ");
                writeStderr(arg);
                writeStderr("\n");
                return error.Reported;
            }
        } else {
            // First non-option is the command
            found_command = true;
            try cmd_args.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // GNU xargs rejects `-n0`: "value for -n option should be >= 1".
    if (config.max_args) |ma| {
        if (ma == 0) {
            writeStderr("zxargs: value for -n option should be >= 1\n");
            for (cmd_args.items) |a| allocator.free(a);
            cmd_args.deinit(allocator);
            if (config.replace_str_owned) {
                if (config.replace_str) |rs| allocator.free(rs);
            }
            return error.Reported;
        }
    }

    config.command = try cmd_args.toOwnedSlice(allocator);
    return config;
}

fn printUsage() void {
    const usage =
        \\Usage: zxargs [OPTIONS] [COMMAND [INITIAL-ARGS]]
        \\
        \\Build and execute command lines from standard input.
        \\
        \\Options:
        \\  -0, --null           Input items are null-terminated (use with find -print0)
        \\  -n, --max-args N     Use at most N arguments per command line
        \\  -P, --max-procs N    Run up to N processes in parallel (0 = all CPUs)
        \\  -I, --replace STR    Replace STR in command with input item
        \\  -i                   Same as -I{}
        \\  -s, --max-chars N    Limit command line to N characters
        \\  -t, --trace          Print commands before executing
        \\  -v, --verbose        Trace mode + show arg count and exit status
        \\  -p, --interactive    Prompt (on /dev/tty) before each execution
        \\  -r, --no-run-if-empty  Don't run command if input is empty
        \\  -x, --exit           Exit if a single item won't fit the -s size limit
        \\  -h, --help           Show this help
        \\      --version        Show version
        \\
        \\Examples:
        \\  # Delete files found by find
        \\  find . -name "*.tmp" -print0 | zxargs -0 rm
        \\
        \\  # Parallel compression
        \\  find . -name "*.log" | zxargs -P4 gzip
        \\
        \\  # Move files with placeholder
        \\  ls *.txt | zxargs -I{} mv {} {}.bak
        \\
        \\  # Batch processing
        \\  cat urls.txt | zxargs -n10 wget
        \\
    ;
    writeStdout(usage);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init) catch |err| {
        // error.Reported means parseArgs already printed a specific message.
        if (err != error.Reported) {
            writeStderr("zxargs: ");
            writeStderr(@errorName(err));
            writeStderr("\n");
        }
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    // Read all input items
    var items = readInput(&config, allocator) catch |err| {
        // UnterminatedQuote already printed a specific message in readInput.
        if (err != error.UnterminatedQuote) {
            writeStderr("zxargs: error reading input: ");
            writeStderr(@errorName(err));
            writeStderr("\n");
        }
        std.process.exit(1);
    };
    defer items.deinit();

    // Handle empty input
    if (items.items.len == 0) {
        if (config.no_run_if_empty) {
            return;
        }
        // Run command once with no extra args if not -r
        if (config.command.len > 0) {
            const ret = executeCommand(&config, &.{}, allocator);
            if (ret != 0) std.process.exit(ret);
        }
        return;
    }

    // Length of the fixed leading command (each argv entry counts its bytes plus
    // one for the terminating NUL), used for the -s byte budget.
    const base_len = commandBaseLen(&config);

    if (config.max_procs <= 1) {
        // Sequential execution
        var worst: u8 = 0;
        var i: usize = 0;
        while (i < items.items.len) {
            const end = nextBatchEnd(&config, items.items, i, base_len) catch |err| switch (err) {
                error.ItemTooBig => {
                    writeStderr("zxargs: argument line too long\n");
                    std.process.exit(1);
                },
            };
            const batch = items.items[i..end];

            const ret = executeCommand(&config, batch, allocator);
            if (ret > worst) worst = ret;
            // GNU: stop immediately on cannot-run/not-found/signal/exit-255;
            // a plain 1..125 exit (-> 123) keeps going and is reported at the end.
            if (ret != 0 and ret != 123) std.process.exit(ret);

            i = end;
        }
        if (worst != 0) std.process.exit(worst);
    } else {
        // Parallel execution
        const pool = try WorkerPool.init(allocator, &config);
        defer pool.deinit();

        var i: usize = 0;
        while (i < items.items.len) {
            const end = nextBatchEnd(&config, items.items, i, base_len) catch |err| switch (err) {
                error.ItemTooBig => {
                    writeStderr("zxargs: argument line too long\n");
                    std.process.exit(1);
                },
            };
            const batch = items.items[i..end];

            try pool.submit(batch);
            i = end;
        }

        pool.waitForCompletion();

        if (pool.getErrorCount() > 0) {
            // We do not preserve the exact per-invocation code across threads;
            // report the generic "an invocation exited nonzero" status.
            std.process.exit(123);
        }
    }
}

/// Total byte length of the fixed leading command (argv[0..]) for -s accounting:
/// each entry's bytes plus one for the terminating NUL. Empty command -> "echo".
fn commandBaseLen(config: *const Config) usize {
    if (config.command.len == 0) return "echo".len + 1;
    var total: usize = 0;
    for (config.command) |arg| total += arg.len + 1;
    return total;
}

/// Compute the end index (exclusive) of the batch starting at `start`, honoring
/// both -n (max_args) and -s (max_chars). Always advances by at least one item so
/// the loop cannot stall (this also defends against a degenerate 0 batch size).
/// Ref: GNU findutils xargs -s "maximum number of bytes per command line".
fn nextBatchEnd(config: *const Config, items: []const []const u8, start: usize, base_len: usize) error{ItemTooBig}!usize {
    var end = start;
    var len = base_len;
    while (end < items.len) {
        if (config.max_args) |ma| {
            if (end - start >= ma) break;
        }
        const add = items[end].len + 1;
        if (end == start) {
            // First item always goes in; but with -x a single oversized item is fatal.
            if (base_len + add > config.max_chars and config.exit_if_too_big) {
                return error.ItemTooBig;
            }
        } else if (len + add > config.max_chars) {
            break;
        }
        len += add;
        end += 1;
    }
    if (end == start) end = start + 1; // guarantee forward progress
    return end;
}
