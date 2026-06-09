// Zig AI Server — Concurrent HTTP API server
// Uses std.Io.net for TCP + std.http.Server for HTTP protocol
// Thread-per-connection model via std.Thread

const std = @import("std");
const net = std.Io.net;
const http = std.http;
const Io = std.Io;

const router = @import("router.zig");

// ── Graceful Shutdown ───────────────────────────────────────
var shutdown_requested: std.atomic.Value(u32) = .init(0);

// Active connection count — module-level so it survives serve() returning.
// Worker threads decrement this in their defer; main thread waits for drain.
var active_connections: std.atomic.Value(u32) = .init(0);

// ── Request ID counter (atomic, monotonic) ──────────────────
var request_id_counter: std.atomic.Value(u64) = .init(0);

// Pointers to things we need to flush on shutdown (set in main)
var shutdown_store: ?*@import("store/store.zig").Store = null;
var shutdown_bq: ?*@import("bq.zig").BqAudit = null;

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    max_workers: u32 = 64,
    read_buf_size: usize = 8192,
    write_buf_size: usize = 8192,
};

// ── Slowloris guard (audit H5) ──────────────────────────────
// Idle timeout (seconds) applied per-recv/send on accepted client
// sockets. A connection that goes silent mid-handshake is closed
// instead of being held open forever. The HTTP request body is
// expected to arrive within this window after the head; SSE writes
// cap the time we'll wait for the client to drain its buffer.
const SOCKET_IDLE_TIMEOUT_SECS: i64 = 30;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const environ_map = init.environ_map;
    var config = Config{};

    // Parse CLI args
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip argv[0]
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (args_iter.next()) |val| {
                config.port = std.fmt.parseInt(u16, val, 10) catch 8080;
            }
        } else if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "-h")) {
            if (args_iter.next()) |val| {
                config.host = val;
            }
        } else if (std.mem.eql(u8, arg, "--workers") or std.mem.eql(u8, arg, "-w")) {
            if (args_iter.next()) |val| {
                config.max_workers = std.fmt.parseInt(u32, val, 10) catch 64;
            }
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\zig-ai-server — Concurrent AI API Server
                \\
                \\Usage: zig-ai-server [options]
                \\
                \\Options:
                \\  -p, --port <port>       Listen port (default: 8080)
                \\  -h, --host <addr>       Bind address (default: 0.0.0.0)
                \\  -w, --workers <count>   Max worker threads (default: 64)
                \\      --help              Show this help
                \\
            , .{});
            return;
        }
    }

    // Single, process-wide I/O subsystem (audit H5). Previously each
    // accepted connection allocated its own `std.Io.Threaded`,
    // spawning a fresh worker-thread pool per request and burning
    // O(connections) kernel resources. We now share one pool across
    // the accept loop, background flush thread, and every connection
    // handler. `std.Io.Threaded` is explicitly thread-safe.
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    const boot_io = io_threaded.io();

    // Initialize GCP context (Firestore + BigQuery)
    const gcp_mod = @import("gcp.zig");
    const bq_mod = @import("bq.zig");
    var gcp_ctx = gcp_mod.GcpContext.init(allocator, "metatron-cloud-prod-v1", environ_map) catch |err| blk: {
        std.debug.print("  GCP auth not available ({s}) — running without Firestore/BigQuery\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (gcp_ctx) |*ctx| ctx.deinit();

    // Initialize the store
    const store_mod = @import("store/store.zig");
    var store = store_mod.Store.init(allocator, "data");

    // Connect store to Firestore for persistence
    if (gcp_ctx) |*ctx| {
        store.setGcpContext(ctx);
        store.loadFromFirestore(); // Cold start: load state from Firestore
    }
    const wal_replayed = store.recover(boot_io); // Replay local WAL (crash recovery)
    if (wal_replayed > 0) {
        std.debug.print("  WAL: replayed {d} entries\n", .{wal_replayed});
    }

    // Initialize BigQuery audit logger
    var bq_audit = bq_mod.BqAudit.init(
        allocator,
        if (gcp_ctx) |*ctx| ctx else null,
        "metatron-cloud-prod-v1",
    );

    // Bootstrap: create admin account + key from env if store is empty
    const bootstrap_key = environ_map.get("QAI_BOOTSTRAP_KEY");
    const legacy_key = environ_map.get("QAI_API_KEY");

    if (store.keys.count() == 0) {
        if (bootstrap_key orelse legacy_key) |raw_key| {
            // Audit H6: refuse weak bootstrap keys. The bootstrap admin
            // has unlimited spend cap + admin role; an operator who
            // sets a 16-char password as the bootstrap key effectively
            // hands the keys to anyone who guesses it. We require at
            // least 32 bytes (256 bits of entropy if hex-random) and
            // fail-closed if the env value is shorter — the server
            // refuses to boot rather than silently bootstrap with a
            // guessable key.
            const MIN_BOOTSTRAP_KEY_LEN: usize = 32;
            if (raw_key.len < MIN_BOOTSTRAP_KEY_LEN) {
                std.debug.print(
                    "FATAL: QAI_BOOTSTRAP_KEY / QAI_API_KEY must be at least {d} characters (got {d}). " ++
                        "Generate one with `openssl rand -hex 32` or equivalent.\n",
                    .{ MIN_BOOTSTRAP_KEY_LEN, raw_key.len },
                );
                std.process.exit(1);
            }

            // Create admin account
            const types = @import("store/types.zig");
            const now = types.nowMs(boot_io);
            store.createAccount(boot_io, .{
                .id = types.FixedStr64.fromSlice("admin"),
                .email = types.FixedStr256.fromSlice("admin@localhost"),
                .balance_ticks = 100_000_000_000_000, // 10,000 USD
                .role = .admin,
                .tier = .enterprise,
                .created_at = now,
                .updated_at = now,
            }) catch {};

            // Hash the bootstrap key and create an admin API key
            var key_hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(raw_key, &key_hash, .{});
            store.createKey(boot_io, .{
                .key_hash = key_hash,
                .account_id = types.FixedStr64.fromSlice("admin"),
                .name = types.FixedStr128.fromSlice("bootstrap-admin"),
                .prefix = types.FixedStr16.fromSlice("bootstrap_key"),
                .scope = .{}, // unlimited
                .created_at = now,
            }) catch {};

            std.debug.print("  Bootstrapped admin account from env key\n", .{});
        }
    }

    // Initialize ledger
    const ledger_mod = @import("ledger.zig");
    var ledger = ledger_mod.Ledger.init(allocator, "data");

    // Initialize rate limiter
    const ratelimit_mod = @import("ratelimit.zig");
    const auth_pipeline_mod = @import("auth_pipeline.zig");
    var rate_limiter = ratelimit_mod.RateLimiter.init(allocator);
    auth_pipeline_mod.setRateLimiter(&rate_limiter);

    // Auth endpoint rate limiter (IP-keyed, brute force protection)
    const auth_rl_mod = @import("auth_ratelimit.zig");
    var auth_rate_limiter = auth_rl_mod.AuthRateLimiter.init(allocator);
    defer auth_rate_limiter.deinit();
    router.setAuthRateLimiter(&auth_rate_limiter);

    // Set store + ledger + BQ audit + GCP context in the router
    router.setStore(&store);
    router.setLedger(&ledger);
    router.setBqAudit(&bq_audit);
    if (gcp_ctx) |*ctx| {
        router.setGcpContext(ctx);
    }

    // ── Network trust boundaries (audit H1, H2, NEW-4) ─────────
    // QAI_TRUST_XFF=true: deployment is fronted by a reverse proxy
    // that strips client-supplied X-Forwarded-For. Required for the
    // per-IP auth rate-limiter to work on Cloud Run.
    if (environ_map.get("QAI_TRUST_XFF")) |val| {
        if (std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true")) {
            router.setTrustXff(true);
            std.debug.print("  Network: trusting X-Forwarded-For (deployment is behind a known reverse proxy)\n", .{});
        }
    }

    // QAI_CORS_ORIGINS=comma,separated,list — explicit allowlist for
    // browser cross-origin requests. Default empty → CORS off, all
    // browser cross-origin calls blocked.
    var cors_origins_storage: std.ArrayListUnmanaged([]const u8) = .empty;
    defer cors_origins_storage.deinit(allocator);
    if (environ_map.get("QAI_CORS_ORIGINS")) |raw| {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t");
            if (trimmed.len > 0) cors_origins_storage.append(allocator, trimmed) catch break;
        }
        if (cors_origins_storage.items.len > 0) {
            router.setCorsAllowedOrigins(cors_origins_storage.items);
            std.debug.print("  CORS: {d} origin(s) allowlisted\n", .{cors_origins_storage.items.len});
        }
    }

    // Init Vertex dedicated endpoint registry
    const vertex_mod = @import("vertex.zig");
    vertex_mod.initRegistry(allocator, if (gcp_ctx) |*ctx| ctx else null);

    // Also set legacy key for backward compat
    if (legacy_key) |key| {
        router.setApiKey(key);
    }

    // Async job subsystem: in-process queue + a single background worker that
    // processes queued jobs by dispatching to the same body-core handlers the
    // sync routes use (billing happens once, at processing time).
    const jobs_mod = @import("jobs.zig");
    var job_store = jobs_mod.JobStore.init(allocator, boot_io, &store, &ledger, environ_map, &shutdown_requested);
    router.setJobStore(&job_store);
    const worker_thread = std.Thread.spawn(.{}, jobs_mod.workerLoop, .{&job_store}) catch null;
    if (worker_thread) |t| t.detach();

    // Set up graceful shutdown references
    shutdown_store = &store;
    shutdown_bq = &bq_audit;

    // Background flush thread: periodically push dirty account balances to Firestore
    // so a crash doesn't lose more than ~5 seconds of billing data.
    // Audit H5: shares the process-wide io subsystem instead of
    // spinning its own Threaded pool.
    const flush_thread = std.Thread.spawn(.{}, backgroundFlushLoop, .{ &store, boot_io }) catch null;
    if (flush_thread) |t| t.detach();

    // Register SIGTERM handler (Cloud Run sends this before SIGKILL)
    if (std.posix.Sigaction != void) {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSigterm },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &act, null);
        std.posix.sigaction(.INT, &act, null); // Also handle Ctrl-C
    }

    const auth_mode: []const u8 = if (store.keys.count() > 0) "store" else if (legacy_key != null) "legacy" else "disabled";
    const gcp_mode: []const u8 = if (gcp_ctx != null) "Firestore+BigQuery" else "local-only";

    std.debug.print(
        \\
        \\  zig-ai-server v0.4.0
        \\  Listening on {s}:{d}
        \\  Workers: {d}
        \\  Auth: {s} ({d} keys, {d} accounts)
        \\  Persistence: {s}
        \\
        \\
    , .{ config.host, config.port, config.max_workers, auth_mode, store.keys.count(), store.accounts.count(), gcp_mode });

    // Start the server (blocks until shutdown)
    serve(allocator, &config, environ_map, boot_io) catch {};

    // Graceful shutdown: drain active connections, then flush state
    std.debug.print("\n  Shutting down...\n", .{});

    // Wait for active connections to finish (max 5 seconds)
    var drain_wait: u32 = 0;
    while (active_connections.load(.acquire) > 0 and drain_wait < 50) : (drain_wait += 1) {
        boot_io.sleep(.{ .nanoseconds = 100_000_000 }, .real) catch break; // 100ms
    }
    if (active_connections.load(.acquire) > 0) {
        std.debug.print("  Warning: {d} connections still active after drain timeout\n", .{active_connections.load(.acquire)});
    }

    store.flushDirtyAccounts(boot_io);
    bq_audit.waitPending();
    store.snapshot(boot_io) catch {};
    std.debug.print("  Shutdown complete.\n", .{});

    // Exit immediately — skip defer cleanup which panics due to Zig 0.16
    // I/O subsystem teardown issues (integer overflow in Threaded.deinit).
    // All state is already flushed to Firestore + WAL.
    std.process.exit(0);
}

fn serve(
    allocator: std.mem.Allocator,
    config: *const Config,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,
) !void {
    // Parse and listen
    const address: net.IpAddress = net.IpAddress.parseLiteral(config.host) catch
        .{ .ip4 = net.Ip4Address.unspecified(config.port) };
    var addr = address;
    addr.setPort(config.port);

    var server = net.IpAddress.listen(&addr, io, .{
        .reuse_address = true,
    }) catch |err| {
        std.debug.print("Failed to listen: {any}\n", .{err});
        return err;
    };
    defer server.deinit(io);

    // Accept loop — spawn a thread per connection, stop on SIGTERM
    while (shutdown_requested.load(.acquire) == 0) {
        const stream = server.accept(io) catch |err| {
            if (shutdown_requested.load(.acquire) != 0) return; // Clean shutdown
            std.debug.print("Accept error: {any}\n", .{err});
            continue;
        };

        // Audit H5 (Slowloris): apply a hard idle timeout to the
        // accepted socket before any read. SO_RCVTIMEO/SO_SNDTIMEO
        // bound how long the kernel will block waiting for the
        // peer; attackers that open a socket and stop sending data
        // get reaped at the timeout instead of pinning a worker
        // thread forever. Best-effort — if setsockopt fails we
        // still serve the connection, we just lose the Slowloris
        // mitigation for that socket.
        applySocketIdleTimeout(stream.socket.handle, SOCKET_IDLE_TIMEOUT_SECS);

        const current = active_connections.load(.acquire);
        if (current >= config.max_workers) {
            // At capacity — close connection immediately
            var s = stream;
            s.close(io);
            continue;
        }

        _ = active_connections.fetchAdd(1, .monotonic);

        const ctx = allocator.create(ConnCtx) catch {
            _ = active_connections.fetchSub(1, .monotonic);
            var s = stream;
            s.close(io);
            continue;
        };
        ctx.* = .{
            .stream = stream,
            .allocator = allocator,
            .environ_map = environ_map,
            .io = io,
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{ctx}) catch {
            _ = active_connections.fetchSub(1, .monotonic);
            allocator.destroy(ctx);
            var s = stream;
            s.close(io);
            continue;
        };
        thread.detach();
    }
}

const ConnCtx = struct {
    stream: net.Stream,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    /// Shared, process-wide I/O subsystem (audit H5).
    io: std.Io,
};

/// Best-effort: set SO_RCVTIMEO + SO_SNDTIMEO on a connected socket
/// so blocked recv/send calls bail out after `seconds` of inactivity.
/// Used as the Slowloris guard on every accepted client socket
/// (audit H5).
fn applySocketIdleTimeout(fd: std.posix.fd_t, seconds: i64) void {
    const sec_field: @TypeOf((std.posix.timeval{ .sec = 0, .usec = 0 }).sec) = @intCast(seconds);
    const usec_field: @TypeOf((std.posix.timeval{ .sec = 0, .usec = 0 }).usec) = 0;
    const tv: std.posix.timeval = .{ .sec = sec_field, .usec = usec_field };
    const tv_bytes = std.mem.asBytes(&tv);
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, tv_bytes) catch {};
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, tv_bytes) catch {};
}

fn handleConnection(ctx: *ConnCtx) void {
    defer {
        _ = active_connections.fetchSub(1, .monotonic);
        ctx.allocator.destroy(ctx);
    }

    // Audit H5: reuse the process-wide io subsystem instead of
    // allocating a new thread pool per connection.
    const io = ctx.io;
    defer {
        var s = ctx.stream;
        s.close(io);
    }

    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;

    var stream_reader = ctx.stream.reader(io, &read_buf);
    var stream_writer = ctx.stream.writer(io, &write_buf);

    var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    const security = @import("security.zig");
    const types_mod = @import("store/types.zig");

    // Audit M13: per-connection request-id buffer outlives every
    // single request iteration but is owned exclusively by this
    // worker thread, so reusing it across iterations is safe (we
    // serialize requests on a keep-alive connection). Moving it out
    // of the loop also makes the lifetime self-evident — the slice
    // built here is borrowed into `resp_headers[i].value` and the
    // borrow is released the moment `request.respond(...)` returns.
    var req_id_buf: [24]u8 = undefined;

    // Audit M15: total-lifetime cap. The Slowloris idle timeout
    // from H5 bounds per-recv time, but a bot can keep issuing
    // legitimate-looking keep-alive requests at ~29s intervals to
    // pin a worker for hours. We close the connection once it has
    // been open longer than `max_conn_lifetime_ms` regardless of
    // request count or keep-alive status.
    const conn_start_ms = types_mod.nowMs(io);

    // Handle multiple requests on the same connection (keep-alive)
    var request_count: u32 = 0;
    while (request_count < security.Limits.max_requests_per_conn) : (request_count += 1) {
        if (types_mod.nowMs(io) - conn_start_ms > security.Limits.max_conn_lifetime_ms) return;

        var request = http_server.receiveHead() catch |err| {
            switch (err) {
                error.HttpHeadersInvalid => sendBadRequest(&stream_writer.interface),
                else => {},
            }
            return;
        };

        // Generate request ID. The slice borrows from `req_id_buf`
        // declared above; its lifetime covers the response below.
        const req_id = request_id_counter.fetchAdd(1, .monotonic) + 1;
        const req_id_str = std.fmt.bufPrint(&req_id_buf, "req-{d}", .{req_id}) catch "req-0";

        // Route and handle
        const result = router.dispatch(&request, ctx.allocator, io, ctx.environ_map);

        // If handler already wrote the response (SSE streaming), skip respond
        if (result.handled) {
            return; // SSE took over the connection — don't reuse
        }

        // Keep-alive safety check
        const has_body_header = request.head.content_length != null or
            request.head.transfer_encoding != .none;
        const method_expects_body = request.head.method == .POST or
            request.head.method == .PUT or
            request.head.method == .PATCH;
        const safe_keepalive = if (method_expects_body and !has_body_header)
            false
        else
            request.head.keep_alive;

        // Build response headers: original + request ID + (conditional) CORS.
        // CORS rules (audit H1, NEW-4):
        //   - No wildcard. The request's Origin is reflected only if
        //     it appears in router.cors_allowed_origins (populated from
        //     env at startup).
        //   - Preflight (OPTIONS) gets the full method/header allowlist;
        //     Authorization is advertised only on auth-required paths.
        //   - Non-preflight responses get just the reflected origin +
        //     Vary: Origin.
        //   - Unmatched origin → no CORS headers at all; browsers will
        //     block the cross-origin call.
        // Audit M1: response-header assembly now treats overflow as
        // an error rather than silently dropping headers past the
        // buffer end. `pushHeader` returns false on overflow; we
        // bail to 500 in that case. The cap is centralized in
        // security.Limits.max_response_headers and chosen to
        // comfortably cover the worst case (handler headers +
        // req-id + reflected origin + Vary + ACAM + ACAH).
        var resp_headers: [security.Limits.max_response_headers]http.Header = undefined;
        var header_count: usize = 0;
        var header_overflow: bool = false;
        const pushHeader = struct {
            fn run(
                slot: *[security.Limits.max_response_headers]http.Header,
                cnt: *usize,
                overflow: *bool,
                name: []const u8,
                value: []const u8,
            ) void {
                if (cnt.* >= slot.len) {
                    overflow.* = true;
                    return;
                }
                slot[cnt.*] = .{ .name = name, .value = value };
                cnt.* += 1;
            }
        }.run;

        // Copy original headers from the handler result.
        for (result.headers) |h| pushHeader(&resp_headers, &header_count, &header_overflow, h.name, h.value);

        // Add request ID
        pushHeader(&resp_headers, &header_count, &header_overflow, "x-request-id", req_id_str);

        // CORS — only when the request's Origin is allowlisted.
        if (router.matchOrigin(&request)) |origin| {
            const is_preflight = request.head.method == .OPTIONS;

            pushHeader(&resp_headers, &header_count, &header_overflow, "access-control-allow-origin", origin);
            pushHeader(&resp_headers, &header_count, &header_overflow, "vary", "Origin");
            if (is_preflight) {
                pushHeader(&resp_headers, &header_count, &header_overflow, "access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS");
                const target = request.head.target;
                const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;
                pushHeader(&resp_headers, &header_count, &header_overflow, "access-control-allow-headers", if (router.pathRequiresAuthorizationHeader(path))
                    "Authorization, Content-Type, X-API-Key"
                else
                    "Content-Type");
            }
        }

        // Fail-loud: if we ran out of slots, drop the assembled
        // response and emit a 500. Better a visible error than a
        // mystery missing `Set-Cookie` / `Content-Security-Policy`.
        if (header_overflow) {
            std.debug.print(
                "  response-header overflow on {s} {s}: handler emitted {d} headers but only {d} fit\n",
                .{ @tagName(request.head.method), request.head.target, result.headers.len, security.Limits.max_response_headers },
            );
            const minimal: [1]http.Header = .{.{ .name = "x-request-id", .value = req_id_str }};
            request.respond(
                "{\"error\":\"internal\",\"message\":\"response header overflow\"}",
                .{ .status = .internal_server_error, .extra_headers = &minimal, .keep_alive = false },
            ) catch return;
            return;
        }

        // Send response
        request.respond(result.body, .{
            .status = result.status,
            .extra_headers = resp_headers[0..header_count],
            .keep_alive = safe_keepalive,
        }) catch return;

        // If not keep-alive, we're done
        if (!safe_keepalive) return;
    }
}

fn handleSigterm(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(1, .release);
}

/// Background thread: flush dirty account balances to Firestore every 5 seconds.
/// Also rotates WAL when it exceeds 10MB (forces snapshot + truncate).
/// Prevents balance data loss on crashes and caps WAL growth.
/// Audit H5: shares the process-wide io subsystem.
fn backgroundFlushLoop(store: *@import("store/store.zig").Store, io: std.Io) void {
    const WAL_ROTATE_BYTES: usize = 10 * 1024 * 1024; // 10MB

    var tick: u32 = 0;
    while (shutdown_requested.load(.acquire) == 0) {
        io.sleep(.{ .nanoseconds = 5 * std.time.ns_per_s }, .real) catch break;
        if (shutdown_requested.load(.acquire) != 0) break;

        store.flushDirtyAccounts(io);
        tick += 1;

        // Every 12 ticks (60 seconds), check WAL size and rotate if needed
        if (tick % 12 == 0) {
            const wal_bytes = store.wal.sizeBytes(io);
            if (wal_bytes > WAL_ROTATE_BYTES) {
                std.debug.print("  WAL rotation: {d} bytes → snapshot + truncate\n", .{wal_bytes});
                store.snapshot(io) catch |err| {
                    std.debug.print("  WAL rotation failed: {s}\n", .{@errorName(err)});
                };
            }
        }
    }
}

fn sendBadRequest(out: *Io.Writer) void {
    out.writeAll("HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n") catch {};
    out.flush() catch {};
}

// getEnv removed — using environ_map from process.Init instead of std.c.getenv
