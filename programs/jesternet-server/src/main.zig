// jesternet-server — HTTP shell.
//
// Lifted from programs/zig_ai_server/src/main.zig with three deliberate
// changes per ZIG_PORT_AUDIT.md's audit caveats:
//
//   1. AI bootstrap (GCP context, Vertex, BigQuery, model registry,
//      legacy-key flow) is removed entirely. Replaced with jesternet
//      bootstrap: open data_dir, set up store + events log + auth
//      pipeline. Store + WAL land in task #62; for now this is a TODO
//      stub that lets the shell compile and accept connections.
//
//   2. The blanket `access-control-allow-origin: *` that main.zig
//      injected on every response is REMOVED. Per audit caveat #3,
//      smart-HTTP routes MUST NOT carry CORS (git clients are
//      unforgiving about response shape), and JSON Layer A/C routes
//      need *specific* CORS, not the AI server's wildcard. CORS now
//      lives in the router's per-route `Response.headers` selection.
//
//   3. SIGTERM/INT shutdown drains active connections, then flushes
//      the store WAL via `appendDurable` semantics (task #62). That's
//      the same shape as the AI server's flushDirtyAccounts + WAL
//      snapshot, but routed through jesternet's two-path WAL.
//
// The accept loop, ConnCtx, per-conn std.Io.Threaded, graceful
// shutdown atomics, keep-alive limits, and request-id generation are
// all lifted as-is.

const std = @import("std");
const net = std.Io.net;
const http = std.http;
const Io = std.Io;

const router = @import("router.zig");
const store_mod = @import("store/store.zig");

// ── Graceful shutdown ───────────────────────────────────────
var shutdown_requested: std.atomic.Value(u32) = .init(0);

// Active connection count. Worker threads decrement in their defer;
// main thread waits for drain before flushing state.
var active_connections: std.atomic.Value(u32) = .init(0);

// ── Request ID counter (atomic, monotonic) ──────────────────
var request_id_counter: std.atomic.Value(u64) = .init(0);

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    max_workers: u32 = 64,
    data_dir: []const u8 = "data",
    read_buf_size: usize = 8192,
    write_buf_size: usize = 8192,
    // Keep-alive cap. Mirrors security.Limits.max_requests_per_conn
    // from the AI server; a per-conn limit is a Slowloris-class
    // defense — the AI server audit (qai sessions notebook) called
    // out the lack of one as a HIGH issue. Worth carrying over.
    max_requests_per_conn: u32 = 100,
};

pub fn main(init: std.process.Init) !void {
    // smp_allocator is the 0.16 page-backed, multi-thread-safe general
    // allocator. Picked over c_allocator so the binary works on any
    // target without linking libc (the build.zig has `link_libc=false`).
    const allocator = std.heap.smp_allocator;
    const environ_map = init.environ_map;
    var config = Config{};

    // ── CLI args ──
    //
    // Strict: a malformed value (a typo'd `--port` or `--workers`) or a
    // flag with its value missing is a hard error with a non-zero exit,
    // NOT a silent fall-back to the default. Previously `catch 8080` /
    // `catch 64` meant `--port 80O` (letter O) bound the default 8080
    // and the operator never knew — a deploy-correctness footgun on the
    // same footing as the old `--data-dir` no-op.
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip argv[0]
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            const val = args_iter.next() orelse fatalMissingValue(arg);
            config.port = std.fmt.parseInt(u16, val, 10) catch
                fatalBadValue(arg, val, "an integer in 0..65535");
        } else if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "-h")) {
            config.host = args_iter.next() orelse fatalMissingValue(arg);
        } else if (std.mem.eql(u8, arg, "--workers") or std.mem.eql(u8, arg, "-w")) {
            const val = args_iter.next() orelse fatalMissingValue(arg);
            config.max_workers = std.fmt.parseInt(u32, val, 10) catch
                fatalBadValue(arg, val, "a positive integer");
            if (config.max_workers == 0) fatalBadValue(arg, val, "a positive integer");
        } else if (std.mem.eql(u8, arg, "--data-dir") or std.mem.eql(u8, arg, "-d")) {
            config.data_dir = args_iter.next() orelse fatalMissingValue(arg);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            std.debug.print("error: unknown argument '{s}' (try --help)\n", .{arg});
            std.process.exit(2);
        }
    }

    // ── Bootstrap ──
    var boot_io_threaded: std.Io.Threaded = .init(allocator, .{});
    const boot_io = boot_io_threaded.io();

    // environ_map will be used by auth pipeline bootstrap (token bootstrap
    // from $JESTERNET_BOOTSTRAP_TOKEN env var) in a follow-up. It's
    // already threaded into serve() → handleConnection → router.dispatch.

    // Open the store. WAL replay happens here; counts get printed for ops
    // visibility.
    var store = store_mod.Store.open(allocator, boot_io, config.data_dir) catch |err| {
        std.debug.print("  Failed to open store: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer store.deinit(boot_io);

    // Wire the store into the router. Router holds an opaque pointer
    // until #64 retypes setStore to *store_mod.Store; for now this is
    // dead-code-but-correct: the wiring path exists so #64 just changes
    // the type signature.
    router.setStore(@ptrCast(&store));

    // Background sync thread — periodically fsyncs the WAL so batched
    // writes (token_audit, last_used_at, loc updates) have a bounded
    // loss window on crash. Durable writes are already fsync'd
    // synchronously inside appendDurable; this thread is purely for
    // the batched tier.
    const flush_thread = std.Thread.spawn(.{}, backgroundFlushLoop, .{&store}) catch null;
    if (flush_thread) |t| t.detach();

    // ── SIGTERM/INT handler ──
    if (std.posix.Sigaction != void) {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSigterm },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &act, null);
        std.posix.sigaction(.INT, &act, null);
    }

    std.debug.print(
        \\
        \\  jesternet-server
        \\  Listening on {s}:{d}
        \\  Workers: {d}
        \\  Data dir: {s}
        \\  Live: /healthz, /api/notifications/recent, /api/notifications/seen.
        \\  Stubbed (501): Layer A/B, PRs, SSE stream, commit-diff.
        \\
        \\
    , .{ config.host, config.port, config.max_workers, config.data_dir });

    // ── Serve (blocks until shutdown) ──
    serve(allocator, &config, environ_map) catch {};

    // ── Graceful shutdown ──
    std.debug.print("\n  Shutting down...\n", .{});

    // Wait for active connections to finish (max 5s).
    var drain_wait: u32 = 0;
    while (active_connections.load(.acquire) > 0 and drain_wait < 50) : (drain_wait += 1) {
        boot_io.sleep(.{ .nanoseconds = 100_000_000 }, .real) catch break;
    }
    if (active_connections.load(.acquire) > 0) {
        std.debug.print("  Warning: {d} connections still active after drain timeout\n", .{active_connections.load(.acquire)});
    }

    // Force any batched WAL writes (token_audit, last_used_at, etc.)
    // to disk before exit. Durable writes are already fsync'd at
    // appendDurable; this only matters for the batched tier whose
    // loss window the background thread bounds.
    store.flushDurable(boot_io) catch {};

    std.debug.print("  Shutdown complete.\n", .{});

    // Skip defer cleanup — same Zig 0.16 I/O teardown issue the AI
    // server documented. All state is already in WAL once #62 lands.
    std.process.exit(0);
}

/// Print a "flag needs a value" error and exit non-zero. `noreturn` so
/// the caller can use it as the `orelse` branch of an argument fetch.
fn fatalMissingValue(flag: []const u8) noreturn {
    std.debug.print("error: '{s}' requires a value (try --help)\n", .{flag});
    std.process.exit(2);
}

/// Print a "bad value for flag" error and exit non-zero. `noreturn` so
/// it can be the `catch` branch of a parse.
fn fatalBadValue(flag: []const u8, value: []const u8, expected: []const u8) noreturn {
    std.debug.print("error: invalid value '{s}' for '{s}' (expected {s})\n", .{ value, flag, expected });
    std.process.exit(2);
}

fn printUsage() void {
    std.debug.print(
        \\jesternet-server — Zig backend speaking jesternet's contract
        \\
        \\Usage: jesternet-server [options]
        \\
        \\Options:
        \\  -p, --port <port>       Listen port (default: 8080)
        \\  -h, --host <addr>       Bind address (default: 0.0.0.0)
        \\  -w, --workers <count>   Max worker threads (default: 64)
        \\  -d, --data-dir <path>   Data directory (default: data)
        \\      --help              Show this help
        \\
    , .{});
}

fn serve(allocator: std.mem.Allocator, config: *const Config, environ_map: *const std.process.Environ.Map) !void {
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    const io = io_threaded.io();

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

    // Accept loop — spawn a thread per connection, stop on SIGTERM.
    while (shutdown_requested.load(.acquire) == 0) {
        const stream = server.accept(io) catch |err| {
            if (shutdown_requested.load(.acquire) != 0) return; // Clean shutdown
            std.debug.print("Accept error: {any}\n", .{err});
            continue;
        };

        const current = active_connections.load(.acquire);
        if (current >= config.max_workers) {
            // At capacity — close connection immediately.
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
            .config = config,
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
    config: *const Config,
};

fn handleConnection(ctx: *ConnCtx) void {
    defer {
        _ = active_connections.fetchSub(1, .monotonic);
        ctx.allocator.destroy(ctx);
    }

    // Per-conn I/O subsystem — zero contention between connections.
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

    // Keep-alive loop with per-conn request cap.
    var request_count: u32 = 0;
    while (request_count < ctx.config.max_requests_per_conn) : (request_count += 1) {
        var request = http_server.receiveHead() catch |err| {
            switch (err) {
                error.HttpHeadersInvalid => sendBadRequest(&stream_writer.interface),
                else => {},
            }
            return;
        };

        // Per-request id, monotonic. Threaded into router → handler →
        // structured log/audit so a failing push can be correlated to
        // its commit.pushed event, ref-update WAL entry, and any
        // downstream audit row by one identifier.
        const req_id = request_id_counter.fetchAdd(1, .monotonic) + 1;
        var req_id_buf: [24]u8 = undefined;
        const req_id_str = std.fmt.bufPrint(&req_id_buf, "req-{d}", .{req_id}) catch "req-0";

        // Per-request arena. Bounds handler memory to one request;
        // frees on arena.deinit() after respond(). Without this the
        // conn allocator would grow unboundedly across keep-alive
        // requests.
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        const req_allocator = arena.allocator();

        // Dispatch. Router decides headers (incl. CORS or not — see
        // audit caveat #3); main does NOT inject blanket CORS.
        const result = router.dispatch(&request, req_allocator, io, ctx.environ_map);

        // SSE handoff: handler wrote directly to the stream, drop the
        // connection rather than reuse (SSE expects no more requests
        // on this conn).
        if (result.handled) return;

        // Keep-alive safety: a POST/PUT/PATCH without a body header
        // (Content-Length or Transfer-Encoding) can desync the parser;
        // close after responding rather than risk a misaligned next
        // request boundary.
        const has_body_header = request.head.content_length != null or
            request.head.transfer_encoding != .none;
        const method_expects_body = request.head.method == .POST or
            request.head.method == .PUT or
            request.head.method == .PATCH;
        const safe_keepalive = if (method_expects_body and !has_body_header)
            false
        else
            request.head.keep_alive;

        // Build response headers: route's own + x-request-id.
        // NO blanket CORS injected here — CORS, when present, comes
        // from the route's headers list. This is the audit caveat #3
        // fix: the AI server's `access-control-allow-origin: *` on
        // every response would break smart-HTTP routes that need
        // `application/x-git-receive-pack-result` with specific
        // cache headers and no CORS.
        var resp_headers: [16]http.Header = undefined;
        var header_count: usize = 0;

        for (result.headers) |h| {
            if (header_count < resp_headers.len) {
                resp_headers[header_count] = h;
                header_count += 1;
            }
        }
        if (header_count < resp_headers.len) {
            resp_headers[header_count] = .{ .name = "x-request-id", .value = req_id_str };
            header_count += 1;
        }

        request.respond(result.body, .{
            .status = result.status,
            .extra_headers = resp_headers[0..header_count],
            .keep_alive = safe_keepalive,
        }) catch return;

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

// ── Background WAL sync thread ──────────────────────────────────────
//
// Per audit caveat #2 and the principal architect's #62 note: batched
// WAL writes (token_audit, last_used_at, loc updates, event_seen
// flips) skip the per-write fsync to keep read-heavy paths like
// info/refs fast. The cost is a small loss window on crash. This
// thread runs fsync() every BG_SYNC_INTERVAL_MS to bound that window.
//
// Durable writes (ref updates, commit_meta, event_insert) are already
// fsync'd inside appendDurable BEFORE the handler returns. The thread
// does NOT affect them.

const BG_SYNC_INTERVAL_MS: u64 = 2_000;

fn backgroundFlushLoop(store: *store_mod.Store) void {
    var io_threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    const io = io_threaded.io();

    while (shutdown_requested.load(.acquire) == 0) {
        io.sleep(.{ .nanoseconds = BG_SYNC_INTERVAL_MS * std.time.ns_per_ms }, .real) catch break;
        if (shutdown_requested.load(.acquire) != 0) break;
        store.flushDurable(io) catch {};
    }
}
