// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! AuthRefresher — periodically refreshes a Bearer token and injects it into
//! every outgoing request's `Authorization` header.
//!
//! Motivation: long-running quantum-curl batches (hours of embedding inference,
//! chunked chronos runs, etc.) outlive the typical 1-hour GCP access token
//! lifetime. Without refresh, the tail of the batch silently 401s — we
//! observed 2419 / 2820 auth failures on a real embedding run.
//!
//! Two source strategies:
//!   1. `.gcp`      — native gcp_auth.TokenProvider (SA / ADC / metadata)
//!   2. `.command`  — external shell command (e.g. `gcloud auth
//!                    print-access-token`) run via std.process.Child
//!
//! Thread safety: the refresher spawns a background thread that periodically
//! re-fetches the token and swaps it into a pthread-mutex-protected slot.
//! Worker threads call `getAuthHeader(allocator)` which returns an owned
//! duplicate under lock — workers never share the internal buffer.

const std = @import("std");
const gcp = @import("gcp-auth");
const http_sentinel = @import("http-sentinel");
const HttpClient = http_sentinel.HttpClient;

/// pthread mutex — same pattern used elsewhere in quantum_curl (Zig 0.16
/// removed std.Thread.Mutex from the public API we can rely on for this
/// project's codebase, so we go direct to libc).
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }
    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

/// A command-based token source. The command is run via `sh -c <cmd>` so the
/// user can pass a full shell expression (e.g. `gcloud auth
/// print-access-token`). Stdout is trimmed of trailing whitespace.
pub const CommandSource = struct {
    command: []const u8, // owned copy of the user-supplied shell string

    pub fn init(allocator: std.mem.Allocator, command: []const u8) !CommandSource {
        return .{ .command = try allocator.dupe(u8, command) };
    }

    pub fn deinit(self: *CommandSource, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
    }

    /// Run the command, capture stdout, trim trailing whitespace, dupe.
    /// Returns a freshly-allocated token string (caller owns).
    pub fn fetch(
        self: *const CommandSource,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) ![]u8 {
        const argv = [_][]const u8{ "/bin/sh", "-c", self.command };

        // Zig 0.16: std.process.run is top-level and Io-aware. 64 KB stdout
        // cap — tokens are a few KB at most; any more means the command is
        // misconfigured (spitting logs / error pages into stdout).
        const result = std.process.run(allocator, io, .{
            .argv = &argv,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch |err| {
            std.debug.print("[auth-refresh] command spawn failed: {}\n", .{err});
            return error.AuthCommandFailed;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| {
                if (code != 0) {
                    std.debug.print(
                        "[auth-refresh] command exited {}: {s}\n",
                        .{ code, result.stderr },
                    );
                    return error.AuthCommandFailed;
                }
            },
            else => {
                std.debug.print(
                    "[auth-refresh] command abnormal termination: {}\n",
                    .{result.term},
                );
                return error.AuthCommandFailed;
            },
        }

        // Trim whitespace/newlines — `gcloud auth print-access-token` ends with \n
        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (trimmed.len == 0) return error.AuthCommandEmptyOutput;
        return allocator.dupe(u8, trimmed);
    }
};

/// GCP source wraps a gcp_auth.TokenProvider and its own HttpClient (the
/// token provider's getToken call makes HTTP requests to the token endpoint,
/// which needs a client). Refresh threads can't share worker clients.
pub const GcpSource = struct {
    allocator: std.mem.Allocator,
    provider: gcp.TokenProvider,
    client: HttpClient,

    pub fn init(
        allocator: std.mem.Allocator,
        provider: gcp.TokenProvider,
    ) !GcpSource {
        return .{
            .allocator = allocator,
            .provider = provider,
            .client = try HttpClient.init(allocator),
        };
    }

    pub fn deinit(self: *GcpSource) void {
        self.provider.deinit();
        self.client.deinit();
    }

    /// Fetch a fresh (or cached-if-valid) access token. The underlying
    /// provider handles expiry checks; we always dupe the returned slice
    /// since the provider's cache can be invalidated on the next call.
    pub fn fetch(self: *GcpSource, allocator: std.mem.Allocator) ![]u8 {
        const token = self.provider.getToken(&self.client) catch |err| {
            std.debug.print("[auth-refresh] gcp_auth getToken failed: {}\n", .{err});
            return error.AuthGcpFailed;
        };
        return allocator.dupe(u8, token);
    }
};

/// Tagged union of supported token sources.
pub const Source = union(enum) {
    command: CommandSource,
    gcp: GcpSource,

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .command => |*c| c.deinit(allocator),
            .gcp => |*g| g.deinit(),
        }
    }

    /// Dispatch to the underlying source. `io` is only consumed by the
    /// command path; GcpSource uses its own internal HttpClient so the
    /// handle is ignored there.
    pub fn fetch(self: *Source, allocator: std.mem.Allocator, io: std.Io) ![]u8 {
        return switch (self.*) {
            .command => |*c| c.fetch(allocator, io),
            .gcp => |*g| g.fetch(allocator),
        };
    }
};

/// The refresher. Owns the source, the current bearer buffer, and the
/// background thread. Intended lifetime: one per quantum-curl invocation,
/// outliving the entire batch.
pub const AuthRefresher = struct {
    allocator: std.mem.Allocator,
    source: Source,

    /// Own Io for the command-source path (std.process.run needs one).
    /// Heap-allocated so its address is stable across moves.
    io_threaded: *std.Io.Threaded,

    /// Full header value — "Bearer <token>" or raw value depending on prefix.
    /// Owned by AuthRefresher; workers get dupes via getAuthHeader.
    current_value: ?[]u8 = null,

    /// Lock guarding current_value. Pthread — see Mutex comment above.
    mutex: Mutex = .{},

    /// Refresh interval, in nanoseconds. Default 30 minutes (1800 s).
    interval_ns: u64 = 1800 * std.time.ns_per_s,

    /// Optional prefix (usually "Bearer "). Emptying this lets users inject
    /// non-OAuth headers (e.g. AWS Signature v4 already in the command output).
    prefix: []const u8 = "Bearer ",

    /// Background refresh thread. Null until start() is called.
    thread: ?std.Thread = null,

    /// Signals the refresh thread to exit cleanly.
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Number of successful refreshes since start — useful for diagnostics.
    refresh_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(allocator: std.mem.Allocator, source: Source) !AuthRefresher {
        const io = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(io);
        io.* = std.Io.Threaded.init(allocator, .{});
        return .{
            .allocator = allocator,
            .source = source,
            .io_threaded = io,
        };
    }

    pub fn deinit(self: *AuthRefresher) void {
        self.stop();
        self.mutex.lock();
        if (self.current_value) |v| {
            std.crypto.secureZero(u8, v);
            self.allocator.free(v);
            self.current_value = null;
        }
        self.mutex.unlock();
        self.source.deinit(self.allocator);
        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);
    }

    /// Perform an initial synchronous fetch, then spawn the background
    /// refresh thread. Fails hard if the initial fetch can't be satisfied —
    /// starting a batch with no valid token is always a user error.
    pub fn start(self: *AuthRefresher) !void {
        try self.refreshOnce();

        self.thread = std.Thread.spawn(.{}, refreshLoop, .{self}) catch |err| {
            std.debug.print("[auth-refresh] failed to spawn refresh thread: {}\n", .{err});
            return err;
        };
    }

    /// Signal the refresh thread to exit and join it. Safe to call multiple
    /// times; becomes a no-op once the thread has been joined.
    pub fn stop(self: *AuthRefresher) void {
        if (self.thread) |t| {
            self.stop_flag.store(true, .seq_cst);
            t.join();
            self.thread = null;
        }
    }

    /// Thread entry point: sleeps for interval_ns, then refreshes, until
    /// stop_flag is set. Checks the flag every 500 ms so shutdown isn't
    /// blocked by a long sleep.
    fn refreshLoop(self: *AuthRefresher) void {
        const sleep_chunk_ns: u64 = 500 * std.time.ns_per_ms;
        while (!self.stop_flag.load(.seq_cst)) {
            var elapsed: u64 = 0;
            while (elapsed < self.interval_ns) {
                if (self.stop_flag.load(.seq_cst)) return;
                var ts: std.c.timespec = .{
                    .sec = 0,
                    .nsec = @intCast(sleep_chunk_ns),
                };
                _ = std.c.nanosleep(&ts, null);
                elapsed += sleep_chunk_ns;
            }
            self.refreshOnce() catch |err| {
                // Non-fatal: keep the old token and try again next cycle.
                // The old token may be stale but it's strictly better than
                // nothing — workers will 401 if it's truly dead and the
                // fail-logger will capture them for replay.
                std.debug.print("[auth-refresh] refresh failed, keeping prior token: {}\n", .{err});
            };
        }
    }

    /// Fetch a fresh token and swap it into current_value under lock.
    /// Separate from the thread loop so start() can use it synchronously.
    fn refreshOnce(self: *AuthRefresher) !void {
        const raw_token = try self.source.fetch(self.allocator, self.io_threaded.io());
        defer {
            // If we successfully built new_value we still need to zero the
            // raw token bytes — allocPrint below copies them. Belt-and-braces.
            std.crypto.secureZero(u8, raw_token);
            self.allocator.free(raw_token);
        }

        const new_value = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{ self.prefix, raw_token },
        );

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.current_value) |old| {
            std.crypto.secureZero(u8, old);
            self.allocator.free(old);
        }
        self.current_value = new_value;
        _ = self.refresh_count.fetchAdd(1, .seq_cst);
    }

    /// Returns an owned duplicate of the current auth header value. Caller
    /// must free with its own allocator. Returns error.AuthNotInitialized if
    /// start() hasn't completed successfully.
    pub fn getAuthHeader(self: *AuthRefresher, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const v = self.current_value orelse return error.AuthNotInitialized;
        return allocator.dupe(u8, v);
    }
};
