// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! FailLogger — thread-safe logger for failed requests.
//!
//! Writes two files:
//!   - {prefix}.jsonl        — original raw JSONL lines of failed requests (replay-ready)
//!   - {prefix}.errors.jsonl — structured diagnostics per failure
//!
//! The .jsonl file can be piped directly back into quantum-curl to rerun
//! only the failures: `quantum-curl --file failed.jsonl`

const std = @import("std");

// libc fflush isn't re-exported via std.c in Zig 0.16
extern "c" fn fflush(stream: ?*std.c.FILE) c_int;

pub const FailLogger = struct {
    allocator: std.mem.Allocator,
    replay_file: ?*std.c.FILE = null,
    errors_file: ?*std.c.FILE = null,
    mutex: Mutex = .{},
    failed_count: u32 = 0,

    /// Pthread mutex for thread-safe writes.
    const Mutex = struct {
        inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
        pub fn lock(self: *Mutex) void {
            _ = std.c.pthread_mutex_lock(&self.inner);
        }
        pub fn unlock(self: *Mutex) void {
            _ = std.c.pthread_mutex_unlock(&self.inner);
        }
    };

    /// Initialize the logger. If path_prefix is null, logging is disabled.
    /// Creates {prefix}.jsonl and {prefix}.errors.jsonl files.
    pub fn init(allocator: std.mem.Allocator, path_prefix: ?[]const u8) !FailLogger {
        if (path_prefix == null) {
            return FailLogger{ .allocator = allocator };
        }

        const prefix = path_prefix.?;

        // Build replay file path: {prefix}.jsonl (or use as-is if already ends in .jsonl)
        const replay_path = blk: {
            if (std.mem.endsWith(u8, prefix, ".jsonl")) {
                break :blk try allocator.dupeZ(u8, prefix);
            }
            break :blk try std.fmt.allocPrintSentinel(allocator, "{s}.jsonl", .{prefix}, 0);
        };
        defer allocator.free(replay_path);

        // Build errors file path
        const errors_path = blk: {
            if (std.mem.endsWith(u8, prefix, ".jsonl")) {
                // Strip .jsonl, append .errors.jsonl
                const stem = prefix[0 .. prefix.len - ".jsonl".len];
                break :blk try std.fmt.allocPrintSentinel(allocator, "{s}.errors.jsonl", .{stem}, 0);
            }
            break :blk try std.fmt.allocPrintSentinel(allocator, "{s}.errors.jsonl", .{prefix}, 0);
        };
        defer allocator.free(errors_path);

        const replay = std.c.fopen(replay_path.ptr, "w") orelse {
            std.debug.print("[fail-log] Error: cannot open {s}\n", .{replay_path});
            return error.CannotOpenFailLog;
        };

        const errors = std.c.fopen(errors_path.ptr, "w") orelse {
            _ = std.c.fclose(replay);
            std.debug.print("[fail-log] Error: cannot open {s}\n", .{errors_path});
            return error.CannotOpenFailLog;
        };

        std.debug.print("[fail-log] Logging failures to:\n  {s}\n  {s}\n", .{ replay_path, errors_path });

        return FailLogger{
            .allocator = allocator,
            .replay_file = replay,
            .errors_file = errors,
        };
    }

    pub fn deinit(self: *FailLogger) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.replay_file) |f| {
            _ = fflush(f);
            _ = std.c.fclose(f);
        }
        if (self.errors_file) |f| {
            _ = fflush(f);
            _ = std.c.fclose(f);
        }
    }

    /// Log a failed request. Writes the raw line to the replay file and
    /// structured details to the errors file.
    pub fn logFailure(
        self: *FailLogger,
        raw_line: ?[]const u8,
        id: []const u8,
        source_line: u32,
        status: u16,
        retry_count: u32,
        error_message: []const u8,
    ) void {
        if (self.replay_file == null) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.failed_count += 1;

        // Write original raw line to replay file (for `quantum-curl --file failed.jsonl`)
        if (raw_line) |line| {
            _ = std.c.fwrite(line.ptr, 1, line.len, self.replay_file.?);
            _ = std.c.fwrite("\n", 1, 1, self.replay_file.?);
            _ = fflush(self.replay_file.?);
        }

        // Write structured error record
        if (self.errors_file) |errf| {
            var buf: [4096]u8 = undefined;
            var bw = std.Io.Writer.fixed(&buf);
            var jw: std.json.Stringify = .{ .writer = &bw, .options = .{} };
            jw.write(.{
                .id = id,
                .source_line = source_line,
                .status = status,
                .retry_count = retry_count,
                .@"error" = error_message,
            }) catch return;
            bw.writeByte('\n') catch return;
            const record = bw.buffered();
            _ = std.c.fwrite(record.ptr, 1, record.len, errf);
            _ = fflush(errf);
        }
    }

    /// Log a parse-time error (before the request is even dispatched)
    pub fn logParseError(
        self: *FailLogger,
        raw_line: []const u8,
        source_line: u32,
        error_message: []const u8,
    ) void {
        if (self.replay_file == null) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.failed_count += 1;

        // Still write raw line to replay (user may want to fix and rerun)
        _ = std.c.fwrite(raw_line.ptr, 1, raw_line.len, self.replay_file.?);
        _ = std.c.fwrite("\n", 1, 1, self.replay_file.?);
        _ = fflush(self.replay_file.?);

        if (self.errors_file) |errf| {
            var buf: [4096]u8 = undefined;
            var bw = std.Io.Writer.fixed(&buf);
            var jw: std.json.Stringify = .{ .writer = &bw, .options = .{} };
            jw.write(.{
                .source_line = source_line,
                .stage = "parse",
                .@"error" = error_message,
            }) catch return;
            bw.writeByte('\n') catch return;
            const record = bw.buffered();
            _ = std.c.fwrite(record.ptr, 1, record.len, errf);
            _ = fflush(errf);
        }
    }
};
