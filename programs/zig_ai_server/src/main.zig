// Zig AI Server — Concurrent HTTP API server
// Uses std.Io.net for TCP + std.http.Server for HTTP protocol
// Thread-per-connection model via std.Thread

const std = @import("std");
const net = std.Io.net;
const http = std.http;
const Io = std.Io;

const router = @import("router.zig");

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    max_workers: u32 = 64,
    read_buf_size: usize = 8192,
    write_buf_size: usize = 8192,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
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

    // Load server API key from env (optional — if not set, auth is disabled)
    const api_key = getEnv(allocator, "QAI_API_KEY");
    if (api_key) |key| {
        router.setApiKey(key);
        std.debug.print(
            \\
            \\  zig-ai-server v0.1.0
            \\  Listening on {s}:{d}
            \\  Workers: {d}
            \\  Auth: enabled (QAI_API_KEY)
            \\
            \\
        , .{ config.host, config.port, config.max_workers });
    } else {
        std.debug.print(
            \\
            \\  zig-ai-server v0.1.0
            \\  Listening on {s}:{d}
            \\  Workers: {d}
            \\  Auth: disabled (set QAI_API_KEY to enable)
            \\
            \\
        , .{ config.host, config.port, config.max_workers });
    }

    // Start the server
    try serve(allocator, &config);
}

fn serve(allocator: std.mem.Allocator, config: *const Config) !void {
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

    // Accept loop — spawn a thread per connection
    while (true) {
        const stream = server.accept(io) catch |err| {
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

        // Route and handle
        const result = router.dispatch(&request, ctx.allocator, io);

        // For requests with a body (POST/PUT/PATCH), we must either read
        // the body or close the connection. If the client sent no
        // content-length/transfer-encoding on a method that implies a body,
        // we can't reuse the connection safely.
        const has_body_header = request.head.content_length != null or
            request.head.transfer_encoding != .none;
        const method_expects_body = request.head.method == .POST or
            request.head.method == .PUT or
            request.head.method == .PATCH;
        const safe_keepalive = if (method_expects_body and !has_body_header)
            false
        else
            request.head.keep_alive;

        // Send response
        request.respond(result.body, .{
            .status = result.status,
            .extra_headers = result.headers,
            .keep_alive = safe_keepalive,
        }) catch return;

        // If not keep-alive, we're done
        if (!safe_keepalive) return;
    }
}

fn sendBadRequest(out: *Io.Writer) void {
    out.writeAll("HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n") catch {};
    out.flush() catch {};
}

fn getEnv(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const name_z = allocator.dupeZ(u8, name) catch return null;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return null;
    const len = std.mem.len(ptr);
    return allocator.dupe(u8, ptr[0..len]) catch null;
}
