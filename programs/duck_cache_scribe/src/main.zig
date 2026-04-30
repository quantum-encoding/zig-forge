const std = @import("std");
const json = std.json;
const Io = std.Io;
const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;
const time = std.time;
const time_compat = @import("time_compat.zig");

// Global state for signal handling
var running: std.atomic.Value(bool) = .{ .raw = true };

// Stashed at startup so spawn-site Threaded inits can pass the real
// process environment to children. Without this, child git/chronos-stamp
// processes inherit empty env → git fails with "empty ident name" because
// HOME isn't visible (gitconfig can't be located).
var process_environ: std.process.Environ = .empty;

// Statistics tracking
const Stats = struct {
    total_commits: u64 = 0,
    total_pushes: u64 = 0,
    total_failures: u64 = 0,
    last_commit_timestamp: i64 = 0,
    uptime_start: i64 = 0,
    files_changed: u64 = 0,

    fn printStats(self: *const Stats) void {
        const uptime_start_val = self.uptime_start;
        const current_time = time_compat.timestamp();
        const uptime_seconds: i64 = if (uptime_start_val > 0) current_time - uptime_start_val else 0;
        const uptime_hours = @divTrunc(uptime_seconds, 3600);
        const uptime_minutes = @divTrunc(@rem(uptime_seconds, 3600), 60);
        const uptime_secs = @rem(uptime_seconds, 60);

        std.log.info("=== STATISTICS ===", .{});
        std.log.info("Total commits: {d}", .{self.total_commits});
        std.log.info("Total pushes: {d}", .{self.total_pushes});
        std.log.info("Total failures: {d}", .{self.total_failures});
        std.log.info("Files changed: {d}", .{self.files_changed});
        std.log.info("Uptime: {d}h {d}m {d}s", .{ uptime_hours, uptime_minutes, uptime_secs });
        if (self.last_commit_timestamp > 0) {
            std.log.info("Last commit: {d}", .{self.last_commit_timestamp});
        }
        std.log.info("================", .{});
    }
};

// Retry configuration
const RetryConfig = struct {
    max_attempts: u32 = 3,
    base_delay_ms: u64 = 1000,
    max_delay_ms: u64 = 30000,
};

// The Scribe's Mind: Configuration Structure
const Config = struct {
    repo_path: []const u8,
    remote_name: []const u8,
    branch_name: []const u8,
    chronos_stamp_path: []const u8,
    agent_id: []const u8,
    debounce_ms: u64,
    dry_run: bool = false,
};

// Signal handler for graceful shutdown
fn signalHandler(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    running.store(false, .release);
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    process_environ = init.minimal.environ;

    // Handle --help before config load
    // Parse args using Args.Iterator for Zig 0.16.2187+
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var dry_run = false;
    for (args[1..]) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            const help_msg =
                \\duckcache-scribe - Automated git commit/push daemon
                \\
                \\Usage: duckcache-scribe [options]
                \\
                \\Options:
                \\  -h, --help     Show this help message
                \\  --dry-run      Log actions without executing git commands
                \\
                \\Configuration:
                \\  Place duckcache-scribe-config.json or config.json in current directory.
                \\  Required fields: repo_path, remote_name, branch_name, chronos_stamp_path, agent_id
                \\
            ;
            _ = linux.write(linux.STDOUT_FILENO, help_msg.ptr, help_msg.len);
            return;
        }
        if (mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        }
    }

    std.log.info("The Sovereign Scribe awakens.", .{});

    if (dry_run) {
        std.log.info("DRY-RUN MODE: Git commands will be logged but not executed.", .{});
    }

    // 1. Load the Mind
    var config = try loadConfig(allocator);
    config.dry_run = dry_run;
    defer {
        allocator.free(config.repo_path);
        allocator.free(config.remote_name);
        allocator.free(config.branch_name);
        allocator.free(config.chronos_stamp_path);
        allocator.free(config.agent_id);
    }

    // Validate configuration
    try validateConfig(config);

    // Register signal handlers for graceful shutdown
    var sa: std.c.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = undefined,
        .flags = 0,
    };
    _ = std.c.sigemptyset(&sa.mask);
    _ = std.c.sigaction(std.c.SIG.INT, &sa, null);
    _ = std.c.sigaction(std.c.SIG.TERM, &sa, null);

    std.log.info("Signal handlers registered for graceful shutdown.", .{});

    var last_push_time: i64 = 0;
    var commit_count: u32 = 0;

    var stats: Stats = .{
        .uptime_start = time_compat.timestamp(),
    };

    // 2. The Eternal Loop
    while (running.load(.acquire)) {
        // 3. The Unwavering Vigil (inotify)
        try watchForChanges(config.repo_path);
        std.log.info("A new memory has been transcribed. The Scribe takes note.", .{});

        // 4. The Debounce: Prevent a storm of commits
        const now = time_compat.timestamp();
        const debounce_seconds: i64 = @intCast(config.debounce_ms / 1000);
        if (now - last_push_time < debounce_seconds) {
            std.log.info("Patience. The ink is not yet dry.", .{});
            continue;
        }

        // 5. The Sacred Rite of Committal
        performGitCommit(allocator, config) catch |err| {
            std.log.err("Failed to commit changes: {s}", .{@errorName(err)});
            stats.total_failures += 1;
            continue; // Don't crash on commit failures
        };
        commit_count += 1;
        stats.total_commits += 1;
        stats.last_commit_timestamp = time_compat.timestamp();

        // Print stats every 10 commits
        if (stats.total_commits % 10 == 0) {
            stats.printStats();
        }

        // 6. The Chain Preservation: Push every 5 commits to preserve the chain
        if (commit_count >= 5) {
            std.log.info("The chain grows long. Preserving the Chronicle with a push.", .{});
            performGitPush(allocator, config) catch |err| {
                std.log.err("Failed to push changes: {s}", .{@errorName(err)});
                stats.total_failures += 1;
                // Don't reset commit_count on push failure - we'll retry next time
                continue;
            };
            commit_count = 0;
            last_push_time = time_compat.timestamp();
            stats.total_pushes += 1;
        }
    }

    // Graceful shutdown
    std.log.info("Shutting down gracefully...", .{});
    stats.printStats();
}

fn watchForChanges(repo_path: []const u8) !void {
    // Zig 0.16: Use std.os.linux.inotify_init1 directly instead of posix wrapper
    const init_result = linux.inotify_init1(0);
    if (@as(isize, @bitCast(init_result)) < 0) return error.InotifyInitFailed;
    const inotify_fd: posix.fd_t = @intCast(init_result);
    defer _ = linux.close(inotify_fd);

    // Watch the entire repository for changes, not just the entries directory
    const IN_CLOSE_WRITE = 0x00000008;
    const IN_MODIFY = 0x00000002;
    const IN_CREATE = 0x00000100;
    const IN_DELETE = 0x00000200;
    const IN_MOVED_FROM = 0x00000400;
    const IN_MOVED_TO = 0x00000800;

    const watch_mask = IN_CLOSE_WRITE | IN_MODIFY | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO;

    // Zig 0.16: Use std.os.linux.inotify_add_watch directly
    // repo_path needs to be null-terminated for the syscall
    const repo_path_z: [*:0]const u8 = @ptrCast(repo_path.ptr);
    const watch_result = linux.inotify_add_watch(inotify_fd, repo_path_z, watch_mask);
    if (@as(isize, @bitCast(watch_result)) < 0) return error.InotifyAddWatchFailed;

    // This will block until an event occurs. The heart of our efficiency.
    var event_buf: [1024]u8 = undefined;
    const read_result = linux.read(inotify_fd, &event_buf, event_buf.len);
    if (@as(isize, @bitCast(read_result)) < 0) return error.InotifyReadFailed;
}

fn performGitCommit(allocator: mem.Allocator, config: Config) !void {
    std.log.info("Committing the new scripture to the Immutable Chronicle.", .{});

    // Invoke chronos-stamp to get the 4th-dimensional timestamp
    const commit_message = try executeChronosStamp(allocator, config);
    defer allocator.free(commit_message);

    std.log.info("Chronicle signature: {s}", .{commit_message});

    if (config.dry_run) {
        std.log.info("[DRY-RUN] Would execute: git add .", .{});
        std.log.info("[DRY-RUN] Would execute: git commit -m {s}", .{commit_message});
        std.log.info("[DRY-RUN] The Chronicle entry would be committed locally.", .{});
        return;
    }

    // Stage and commit changes in the target repository with retry
    const retry_config = RetryConfig{ .max_attempts = 3, .base_delay_ms = 1000, .max_delay_ms = 10000 };
    try executeCommandWithRetry(allocator, config.repo_path, &.{ "git", "add", "." }, retry_config);
    try executeCommandWithRetry(allocator, config.repo_path, &.{ "git", "commit", "-m", commit_message }, retry_config);

    std.log.info("The Chronicle entry is committed locally.", .{});
}

fn performGitPush(allocator: mem.Allocator, config: Config) !void {
    std.log.info("Pushing the Chronicle to the remote repository.", .{});

    if (config.dry_run) {
        std.log.info("[DRY-RUN] Would execute: git push {s} {s}", .{ config.remote_name, config.branch_name });
        std.log.info("[DRY-RUN] The Chronicle would be updated in the remote repository.", .{});
        return;
    }

    // Push to remote repository with retry
    const retry_config = RetryConfig{ .max_attempts = 5, .base_delay_ms = 2000, .max_delay_ms = 30000 };
    try executeCommandWithRetry(allocator, config.repo_path, &.{ "git", "push", config.remote_name, config.branch_name }, retry_config);

    std.log.info("The Chronicle is updated in the remote repository.", .{});
}

fn executeChronosStamp(allocator: mem.Allocator, config: Config) ![]u8 {
    // CAUTION: do NOT use Io.Threaded.global_single_threaded here — that
    // singleton ships with `.allocator = .failing`, so std.process.spawn's
    // attempt to dup argv strings via the io allocator returns OutOfMemory
    // before any clone/execve syscall fires. Instead, init a per-call
    // Threaded with the real allocator. async_limit=.nothing keeps it
    // single-threaded; we only need a working allocator for spawn.
    var threaded = Io.Threaded.init(allocator, .{ .async_limit = .nothing, .environ = process_environ });
    defer threaded.deinit();
    const io = threaded.io();

    // Call chronos-stamp to get the 4th-dimensional timestamp
    // NOTE: chronos-stamp writes its output to stderr, not stdout
    var child = std.process.spawn(io, .{
        .argv = &.{ config.chronos_stamp_path, config.agent_id, "git-commit" },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        std.log.err("Failed to spawn chronos-stamp: {s}", .{@errorName(err)});
        return error.ChronosStampFailed;
    };

    // Zig 0.16: Manually read from stderr pipe using linux syscalls
    // We need to read before waiting, otherwise the pipe may block
    var stderr_list: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr_list.deinit(allocator);

    // Read stderr in chunks - extract the fd handle from the Io.File
    if (child.stderr) |stderr_file| {
        const stderr_fd = stderr_file.handle;
        var buf: [4096]u8 = undefined;
        while (true) {
            const read_result = linux.read(stderr_fd, &buf, buf.len);
            const bytes_read: isize = @bitCast(read_result);
            if (bytes_read <= 0) break;
            try stderr_list.appendSlice(allocator, buf[0..@intCast(bytes_read)]);
        }
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
        else => {
            return error.ChronosStampFailed;
        },
    }

    // Filter out libwarden output and extract only the CHRONOS line
    var lines = mem.splitScalar(u8, stderr_list.items, '\n');

    while (lines.next()) |line| {
        const trimmed_line = mem.trim(u8, line, &std.ascii.whitespace);
        if (mem.startsWith(u8, trimmed_line, "[CHRONOS]")) {
            return try allocator.dupe(u8, trimmed_line);
        }
    }

    // If no CHRONOS line found, return error
    std.log.err("No CHRONOS output found from chronos-stamp", .{});
    return error.ChronosStampFailed;
}

fn executeCommand(allocator: mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    // global_single_threaded.allocator = .failing — use a real Threaded for spawn.
    var threaded = Io.Threaded.init(allocator, .{ .async_limit = .nothing, .environ = process_environ });
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = args,
        .cwd = .{ .path = cwd },
    });
    const term = try child.wait(io);

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.log.err("Command failed with exit code: {d}", .{code});
                std.log.err("Command was: {s}", .{args[0]});
                return error.CommandFailed;
            }
        },
        else => {
            std.log.err("Command terminated abnormally", .{});
            return error.CommandFailed;
        },
    }
}

fn executeCommandWithRetry(allocator: mem.Allocator, cwd: []const u8, args: []const []const u8, retry_config: RetryConfig) !void {
    // global_single_threaded.allocator = .failing — use a real Threaded for spawn.
    var threaded = Io.Threaded.init(allocator, .{ .async_limit = .nothing, .environ = process_environ });
    defer threaded.deinit();
    const io = threaded.io();
    var attempt: u32 = 0;
    var delay_ms: u64 = retry_config.base_delay_ms;

    while (attempt < retry_config.max_attempts) : (attempt += 1) {
        if (attempt > 0) {
            std.log.info("Retry attempt {d}/{d} for command: {s}", .{attempt + 1, retry_config.max_attempts, args[0]});
            std.log.info("Waiting {d}ms before retry...", .{delay_ms});
            var ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(delay_ms * std.time.ns_per_ms) };
            _ = linux.nanosleep(&ts, null);

            // Exponential backoff with jitter
            delay_ms = @min(delay_ms * 2, retry_config.max_delay_ms);
        }

        var child = std.process.spawn(io, .{
            .argv = args,
            .cwd = .{ .path = cwd },
        }) catch |err| {
            std.log.err("Failed to spawn command on attempt {d}: {s}", .{attempt + 1, @errorName(err)});
            continue;
        };
        const term = child.wait(io) catch |err| {
            std.log.err("Failed to wait for command on attempt {d}: {s}", .{attempt + 1, @errorName(err)});
            continue;
        };

        switch (term) {
            .exited => |code| {
                if (code == 0) {
                    return; // Success!
                }
                std.log.err("Command failed with exit code: {d} on attempt {d}", .{code, attempt + 1});
            },
            else => {
                std.log.err("Command terminated abnormally on attempt {d}", .{attempt + 1});
            },
        }
    }

    std.log.err("All {d} attempts failed for command: {s}", .{retry_config.max_attempts, args[0]});
    return error.AllRetriesFailed;
}

fn loadConfig(allocator: mem.Allocator) !Config {
    const io = Io.Threaded.global_single_threaded.io();

    // Try to open config files in current directory
    const config_paths = [_][]const u8{
        "duckcache-scribe-config.json",
        "config.json",
    };

    var config_file: ?Io.File = null;
    var used_path: []const u8 = undefined;

    for (config_paths) |path| {
        if (Io.Dir.cwd().openFile(io, path, .{})) |file| {
            config_file = file;
            used_path = path;
            break;
        } else |_| {
            continue;
        }
    }

    const file = config_file orelse {
        std.log.err("No configuration file found. Tried: duckcache-scribe-config.json, config.json", .{});
        return error.ConfigNotFound;
    };
    defer file.close(io);

    std.log.info("Using configuration file: {s}", .{used_path});

    // Read file contents using readFileAlloc pattern (Zig 0.16.1859)
    const file_contents = try Io.Dir.cwd().readFileAlloc(io, used_path, allocator, Io.Limit.limited(1024 * 1024));
    defer allocator.free(file_contents);

    // Parse JSON
    const parsed = try json.parseFromSlice(
        json.Value,
        allocator,
        file_contents,
        .{}
    );
    defer parsed.deinit();

    const root = parsed.value.object;

    // Extract fields and duplicate strings
    const repo_path = try allocator.dupe(u8, root.get("repo_path").?.string);
    const remote_name = try allocator.dupe(u8, root.get("remote_name").?.string);
    const branch_name = try allocator.dupe(u8, root.get("branch_name").?.string);
    const chronos_stamp_path = try allocator.dupe(u8, root.get("chronos_stamp_path").?.string);
    const agent_id = try allocator.dupe(u8, root.get("agent_id").?.string);
    const debounce_ms: u64 = @intCast(root.get("debounce_ms").?.integer);

    return Config{
        .repo_path = repo_path,
        .remote_name = remote_name,
        .branch_name = branch_name,
        .chronos_stamp_path = chronos_stamp_path,
        .agent_id = agent_id,
        .debounce_ms = debounce_ms,
    };
}

fn validateConfig(config: Config) !void {
    const io = Io.Threaded.global_single_threaded.io();
    std.log.info("Validating configuration...", .{});

    // Check if repository path exists and is a git repository
    var repo_dir = Io.Dir.cwd().openDir(io, config.repo_path, .{}) catch |err| {
        std.log.err("Repository path does not exist or is not accessible: {s}", .{config.repo_path});
        std.log.err("Error: {s}", .{@errorName(err)});
        return error.InvalidRepoPath;
    };
    defer repo_dir.close(io);

    // Check if .git directory exists
    const git_dir = repo_dir.openDir(io, ".git", .{}) catch |err| {
        std.log.err("Repository path is not a git repository: {s}", .{config.repo_path});
        std.log.err("Error: {s}", .{@errorName(err)});
        return error.NotGitRepository;
    };
    git_dir.close(io);

    // Check if chronos-stamp executable exists and is executable
    Io.Dir.accessAbsolute(io, config.chronos_stamp_path, .{}) catch |err| {
        std.log.err("chronos-stamp executable not found or not accessible: {s}", .{config.chronos_stamp_path});
        std.log.err("Error: {s}", .{@errorName(err)});
        return error.ChronosStampNotFound;
    };

    // Validate debounce time is reasonable
    if (config.debounce_ms < 1000) {
        std.log.warn("Debounce time is very short ({d}ms), may cause excessive commits", .{config.debounce_ms});
    }
    if (config.debounce_ms > 60000) {
        std.log.warn("Debounce time is very long ({d}ms), may miss rapid changes", .{config.debounce_ms});
    }

    std.log.info("Configuration validation passed.", .{});
}
