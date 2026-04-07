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

    // Initialize I/O for store operations
    var boot_io_threaded: std.Io.Threaded = .init(allocator, .{});
    const boot_io = boot_io_threaded.io();

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
    store.recover(boot_io); // Also replay any local WAL (belt + suspenders)

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
            // Create admin account
            const types = @import("store/types.zig");
            const now = types.nowMs();
            store.createAccount(boot_io, .{
                .id = types.FixedStr32.fromSlice("admin"),
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
                .account_id = types.FixedStr32.fromSlice("admin"),
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

    // Set store + ledger + BQ audit + GCP context in the router
    router.setStore(&store);
    router.setLedger(&ledger);
    router.setBqAudit(&bq_audit);
    if (gcp_ctx) |*ctx| {
        router.setGcpContext(ctx);
    }

    // Init Vertex dedicated endpoint registry
    const vertex_mod = @import("vertex.zig");
    vertex_mod.initRegistry(allocator, if (gcp_ctx) |*ctx| ctx else null);

    // Also set legacy key for backward compat
    if (legacy_key) |key| {
        router.setApiKey(key);
    }

    // Set up graceful shutdown references
    shutdown_store = &store;
    shutdown_bq = &bq_audit;

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
    serve(allocator, &config, environ_map) catch {};

    // Graceful shutdown: flush state
    std.debug.print("\n  Shutting down...\n", .{});
    store.flushDirtyAccounts();
    bq_audit.waitPending();
    store.snapshot(boot_io) catch {};
    std.debug.print("  Shutdown complete.\n", .{});
}

fn serve(allocator: std.mem.Allocator, config: *const Config, environ_map: *const std.process.Environ.Map) !void {
    // Initialize the I/O subsystem
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    const io = io_threaded.io();

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

    // Track active connections for graceful shutdown
    var active = std.atomic.Value(u32).init(0);

    // Accept loop — spawn a thread per connection, stop on SIGTERM
    while (shutdown_requested.load(.acquire) == 0) {
        const stream = server.accept(io) catch |err| {
            if (shutdown_requested.load(.acquire) != 0) return; // Clean shutdown
            std.debug.print("Accept error: {any}\n", .{err});
            continue;
        };

        const current = active.load(.acquire);
        if (current >= config.max_workers) {
            // At capacity — close connection immediately
            var s = stream;
            s.close(io);
            continue;
        }

        _ = active.fetchAdd(1, .monotonic);

        const ctx = allocator.create(ConnCtx) catch {
            _ = active.fetchSub(1, .monotonic);
            var s = stream;
            s.close(io);
            continue;
        };
        ctx.* = .{
            .stream = stream,
            .allocator = allocator,
            .active = &active,
            .environ_map = environ_map,
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{ctx}) catch {
            _ = active.fetchSub(1, .monotonic);
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
    active: *std.atomic.Value(u32),
    environ_map: *const std.process.Environ.Map,
};

fn handleConnection(ctx: *ConnCtx) void {
    defer {
        _ = ctx.active.fetchSub(1, .monotonic);
        ctx.allocator.destroy(ctx);
    }

    // Each connection gets its own I/O subsystem (thread-safe, zero contention)
    var io_threaded: std.Io.Threaded = .init(ctx.allocator, .{});
    const io = io_threaded.io();
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

    // Handle multiple requests on the same connection (keep-alive)
    var request_count: u32 = 0;
    while (request_count < security.Limits.max_requests_per_conn) : (request_count += 1) {
        var request = http_server.receiveHead() catch |err| {
            switch (err) {
                error.HttpHeadersInvalid => sendBadRequest(&stream_writer.interface),
                else => {},
            }
            return;
        };

        // Generate request ID
        const req_id = request_id_counter.fetchAdd(1, .monotonic) + 1;
        var req_id_buf: [24]u8 = undefined;
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

        // Build response headers: original + request ID + CORS
        var resp_headers: [8]http.Header = undefined;
        var header_count: usize = 0;

        // Copy original headers
        for (result.headers) |h| {
            if (header_count < resp_headers.len) {
                resp_headers[header_count] = h;
                header_count += 1;
            }
        }

        // Add request ID
        if (header_count < resp_headers.len) {
            resp_headers[header_count] = .{ .name = "x-request-id", .value = req_id_str };
            header_count += 1;
        }

        // Add CORS (on all responses, not just OPTIONS)
        if (header_count < resp_headers.len) {
            resp_headers[header_count] = .{ .name = "access-control-allow-origin", .value = "*" };
            header_count += 1;
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

fn sendBadRequest(out: *Io.Writer) void {
    out.writeAll("HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n") catch {};
    out.flush() catch {};
}

// getEnv removed — using environ_map from process.Init instead of std.c.getenv
