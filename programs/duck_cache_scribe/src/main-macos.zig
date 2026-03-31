//! DuckCache Scribe - macOS Version
//!
//! Automated git commit/push daemon using kqueue for file watching.
//! Zero polling - event-driven like inotify on Linux.
//!
//! Usage: duckcache-scribe-macos [--help]

const std = @import("std");
const json = std.json;
const mem = std.mem;
const posix = std.posix;
const c = std.c;

// kqueue constants
const EV = c.EV;
const NOTE = c.NOTE;
const EVFILT = c.EVFILT;

const RetryConfig = struct {
    max_attempts: u32 = 3,
    base_delay_ms: u64 = 1000,
    max_delay_ms: u64 = 30000,
};

const Config = struct {
    repo_path: []const u8,
    remote_name: []const u8,
    branch_name: []const u8,
    chronos_stamp_path: []const u8,
    agent_id: []const u8,
    debounce_ms: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Handle --help
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name
    if (args_iter.next()) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            const help_msg =
                \\duckcache-scribe-macos - Automated git commit/push daemon
                \\
                \\Usage: duckcache-scribe-macos [options]
                \\
                \\Options:
                \\  -h, --help    Show this help message
                \\
                \\Configuration:
                \\  Place duckcache-scribe-config.json or config.json in current directory.
                \\  Required fields: repo_path, remote_name, branch_name, chronos_stamp_path, agent_id
                \\
            ;
            _ = c.write(posix.STDOUT_FILENO, help_msg.ptr, help_msg.len);
            return;
        }
    }

    std.log.info("The Sovereign Scribe awakens (macOS/kqueue).", .{});

    // Load configuration
    const config = try loadConfig(allocator, io);
    defer {
        allocator.free(config.repo_path);
        allocator.free(config.remote_name);
        allocator.free(config.branch_name);
        allocator.free(config.chronos_stamp_path);
        allocator.free(config.agent_id);
    }

    // Validate configuration
    try validateConfig(allocator, io, config);

    var last_push_time: i64 = 0;
    var commit_count: u32 = 0;

    // The Eternal Loop
    while (true) {
        // Watch for changes using kqueue (blocks until event)
        try watchForChanges(config.repo_path);
        std.log.info("A new memory has been transcribed. The Scribe takes note.", .{});

        // Debounce
        const now = getTimestamp();
        const debounce_seconds: i64 = @intCast(config.debounce_ms / 1000);
        if (now - last_push_time < debounce_seconds) {
            std.log.info("Patience. The ink is not yet dry.", .{});
            continue;
        }

        // Commit
        performGitCommit(allocator, io, config) catch |err| {
            std.log.err("Failed to commit changes: {s}", .{@errorName(err)});
            continue;
        };
        commit_count += 1;

        // Push every 5 commits
        if (commit_count >= 5) {
            std.log.info("The chain grows long. Preserving the Chronicle with a push.", .{});
            performGitPush(allocator, io, config) catch |err| {
                std.log.err("Failed to push changes: {s}", .{@errorName(err)});
                continue;
            };
            commit_count = 0;
            last_push_time = getTimestamp();
        }
    }
}

fn getTimestamp() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

fn watchForChanges(repo_path: []const u8) !void {
    // Create kqueue
    const kq = c.kqueue();
    if (kq < 0) return error.KqueueFailed;
    defer _ = c.close(kq);

    // Open directory to watch
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{repo_path}) catch return error.PathTooLong;

    const dir_fd = c.open(path_z.ptr, @bitCast(posix.O{ .ACCMODE = .RDONLY }), @as(c.mode_t, 0));
    if (dir_fd < 0) return error.OpenFailed;
    defer _ = c.close(dir_fd);

    // Register for vnode events
    var changelist: [1]c.Kevent = .{.{
        .ident = @intCast(dir_fd),
        .filter = EVFILT.VNODE,
        .flags = EV.ADD | EV.ENABLE | EV.CLEAR,
        .fflags = NOTE.WRITE | NOTE.DELETE | NOTE.RENAME | NOTE.ATTRIB | NOTE.EXTEND,
        .data = 0,
        .udata = 0,
    }};

    var eventlist: [1]c.Kevent = undefined;

    // Block until an event occurs
    const nev = c.kevent(kq, &changelist, 1, &eventlist, 1, null);
    if (nev < 0) return error.KeventFailed;
}

fn performGitCommit(allocator: mem.Allocator, io: std.Io, config: Config) !void {
    std.log.info("Committing the new scripture to the Immutable Chronicle.", .{});

    // Get timestamp from chronos-stamp
    const commit_message = try executeChronosStamp(allocator, io, config);
    defer allocator.free(commit_message);

    std.log.info("Chronicle signature: {s}", .{commit_message});

    // Stage and commit
    const retry_config = RetryConfig{ .max_attempts = 3, .base_delay_ms = 1000, .max_delay_ms = 10000 };
    try executeCommandWithRetry(allocator, io, config.repo_path, &.{ "git", "add", "." }, retry_config);
    try executeCommandWithRetry(allocator, io, config.repo_path, &.{ "git", "commit", "-m", commit_message }, retry_config);

    std.log.info("The Chronicle entry is committed locally.", .{});
}

fn performGitPush(allocator: mem.Allocator, io: std.Io, config: Config) !void {
    std.log.info("Pushing the Chronicle to the remote repository.", .{});

    const retry_config = RetryConfig{ .max_attempts = 5, .base_delay_ms = 2000, .max_delay_ms = 30000 };
    try executeCommandWithRetry(allocator, io, config.repo_path, &.{ "git", "push", config.remote_name, config.branch_name }, retry_config);

    std.log.info("The Chronicle is updated in the remote repository.", .{});
}

fn executeChronosStamp(allocator: mem.Allocator, io: std.Io, config: Config) ![]u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ config.chronos_stamp_path, config.agent_id, "git-commit" },
        .stderr = .pipe,
    }) catch |err| {
        std.log.err("Failed to spawn chronos-stamp: {s}", .{@errorName(err)});
        return error.ChronosStampFailed;
    };

    // Read stderr pipe manually (collectOutput was removed in Zig 0.16)
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    if (child.stderr) |stderr_file| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n_signed = c.read(stderr_file.handle, &buf, buf.len);
            if (n_signed <= 0) break;
            const n: usize = @intCast(n_signed);
            stderr_buf.appendSlice(allocator, buf[0..n]) catch break;
            if (stderr_buf.items.len >= 64 * 1024) break;
        }
        _ = c.close(stderr_file.handle);
        child.stderr = null;
    }

    const term = child.wait(io) catch |err| {
        std.log.err("Failed to wait for chronos-stamp: {s}", .{@errorName(err)});
        return error.ChronosStampFailed;
    };

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.log.err("chronos-stamp failed with exit code: {d}", .{code});
                return error.ChronosStampFailed;
            }
        },
        else => return error.ChronosStampFailed,
    }

    // Extract CHRONOS line from stderr (chronos-stamp outputs to stderr)
    var lines = mem.splitScalar(u8, stderr_buf.items, '\n');
    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, &std.ascii.whitespace);
        if (mem.startsWith(u8, trimmed, "[CHRONOS]")) {
            return try allocator.dupe(u8, trimmed);
        }
    }

    std.log.err("No CHRONOS output found from chronos-stamp", .{});
    return error.ChronosStampFailed;
}

fn executeCommandWithRetry(allocator: mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8, retry_config: RetryConfig) !void {
    _ = allocator;
    var attempt: u32 = 0;
    var delay_ms: u64 = retry_config.base_delay_ms;

    while (attempt < retry_config.max_attempts) : (attempt += 1) {
        if (attempt > 0) {
            std.log.info("Retry attempt {d}/{d} for command: {s}", .{ attempt + 1, retry_config.max_attempts, args[0] });
            io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake) catch {};
            delay_ms = @min(delay_ms * 2, retry_config.max_delay_ms);
        }

        var child = std.process.spawn(io, .{
            .argv = args,
            .cwd = .{ .path = cwd },
        }) catch |err| {
            std.log.err("Failed to spawn command on attempt {d}: {s}", .{ attempt + 1, @errorName(err) });
            continue;
        };

        const term = child.wait(io) catch |err| {
            std.log.err("Failed to wait for command on attempt {d}: {s}", .{ attempt + 1, @errorName(err) });
            continue;
        };

        switch (term) {
            .exited => |code| {
                if (code == 0) return; // Success
                std.log.err("Command failed with exit code: {d} on attempt {d}", .{ code, attempt + 1 });
            },
            else => std.log.err("Command terminated abnormally on attempt {d}", .{attempt + 1}),
        }
    }

    std.log.err("All {d} attempts failed for command: {s}", .{ retry_config.max_attempts, args[0] });
    return error.AllRetriesFailed;
}

fn loadConfig(allocator: mem.Allocator, io: std.Io) !Config {
    const config_paths = [_][]const u8{
        "duckcache-scribe-config.json",
        "config.json",
    };

    var file_contents: ?[]u8 = null;
    var used_path: []const u8 = undefined;

    for (config_paths) |path| {
        file_contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch continue;
        used_path = path;
        break;
    }

    const contents = file_contents orelse {
        std.log.err("No configuration file found. Tried: duckcache-scribe-config.json, config.json", .{});
        return error.ConfigNotFound;
    };
    defer allocator.free(contents);

    std.log.info("Using configuration file: {s}", .{used_path});

    const parsed = try json.parseFromSlice(json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    return Config{
        .repo_path = try allocator.dupe(u8, root.get("repo_path").?.string),
        .remote_name = try allocator.dupe(u8, root.get("remote_name").?.string),
        .branch_name = try allocator.dupe(u8, root.get("branch_name").?.string),
        .chronos_stamp_path = try allocator.dupe(u8, root.get("chronos_stamp_path").?.string),
        .agent_id = try allocator.dupe(u8, root.get("agent_id").?.string),
        .debounce_ms = @intCast(root.get("debounce_ms").?.integer),
    };
}

fn validateConfig(allocator: mem.Allocator, io: std.Io, config: Config) !void {
    _ = allocator;
    std.log.info("Validating configuration...", .{});

    // Check repository path exists
    var repo_dir = std.Io.Dir.cwd().openDir(io, config.repo_path, .{}) catch |err| {
        std.log.err("Repository path does not exist: {s} ({s})", .{ config.repo_path, @errorName(err) });
        return error.InvalidRepoPath;
    };
    defer repo_dir.close(io);

    // Check .git directory exists
    const git_dir = repo_dir.openDir(io, ".git", .{}) catch |err| {
        std.log.err("Not a git repository: {s} ({s})", .{ config.repo_path, @errorName(err) });
        return error.NotGitRepository;
    };
    git_dir.close(io);

    // Check chronos-stamp exists
    std.Io.Dir.accessAbsolute(io, config.chronos_stamp_path, .{}) catch |err| {
        std.log.err("chronos-stamp not found: {s} ({s})", .{ config.chronos_stamp_path, @errorName(err) });
        return error.ChronosStampNotFound;
    };

    if (config.debounce_ms < 1000) {
        std.log.warn("Debounce time very short ({d}ms)", .{config.debounce_ms});
    }

    std.log.info("Configuration validation passed.", .{});
}
