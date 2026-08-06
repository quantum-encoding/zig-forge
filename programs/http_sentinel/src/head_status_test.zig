// Copyright (c) 2026 QUANTUM ENCODING LTD
//
// Externally-anchored regression tests for HttpClient.head status reporting.
//
// A loopback listener replays byte-for-byte status lines taken from the RFC
// that defines each code, then asserts `head()` reports exactly that status.
// The inputs (wire bytes) and the expected outputs (status codes) both come
// from the specs below, not from this codebase — these are external anchors,
// not roundtrips.
//
// External anchors:
//   * RFC 9110 §15.3.1  — 200 OK
//   * RFC 9110 §15.3.5  — 204 No Content
//   * RFC 9110 §15.5.2  — 401 Unauthorized
//   * RFC 9110 §15.5.5  — 404 Not Found
//   * RFC 9110 §15.5.16 — 415 Unsupported Media Type
//   * RFC 9110 §15.6.1  — 500 Internal Server Error
//   * RFC 9110 §15.6.4  — 503 Service Unavailable
//   * RFC 9110 §9.3.2   — a HEAD response carries the header section the
//                         equivalent GET would have sent, including
//                         Content-Length, but MUST NOT carry a body. The
//                         404/503 vectors below therefore advertise a
//                         Content-Length the server never sends, which is
//                         the exact shape a health check sees in the wild.
//
// The bug these pin: `head()` returned a hardcoded `.status = .ok` and
// discarded the parsed response head, so every consumer using it for a
// health check saw a fake 200 no matter what the server said.

const std = @import("std");
const HttpClient = @import("http_client.zig").HttpClient;

/// One replayed server response: the literal wire bytes, and the status the
/// client must report for them.
const Vector = struct {
    name: []const u8,
    wire: []const u8,
    expect: std.http.Status,
};

const vectors = [_]Vector{
    .{
        .name = "RFC 9110 §15.3.1 200 OK",
        .wire = "HTTP/1.1 200 OK\r\nContent-Length: 1024\r\nContent-Type: text/plain\r\n\r\n",
        .expect = .ok,
    },
    .{
        .name = "RFC 9110 §15.3.5 204 No Content",
        .wire = "HTTP/1.1 204 No Content\r\n\r\n",
        .expect = .no_content,
    },
    .{
        .name = "RFC 9110 §15.5.2 401 Unauthorized",
        .wire = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\n\r\n",
        .expect = .unauthorized,
    },
    .{
        .name = "RFC 9110 §15.5.5 404 Not Found",
        .wire = "HTTP/1.1 404 Not Found\r\nContent-Length: 57\r\nContent-Type: text/html\r\n\r\n",
        .expect = .not_found,
    },
    .{
        .name = "RFC 9110 §15.5.16 415 Unsupported Media Type",
        .wire = "HTTP/1.1 415 Unsupported Media Type\r\nContent-Length: 0\r\n\r\n",
        .expect = .unsupported_media_type,
    },
    .{
        .name = "RFC 9110 §15.6.1 500 Internal Server Error",
        .wire = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n",
        .expect = .internal_server_error,
    },
    .{
        .name = "RFC 9110 §15.6.4 503 Service Unavailable",
        .wire = "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 120\r\nContent-Length: 19\r\n\r\n",
        .expect = .service_unavailable,
    },
};

/// A one-shot loopback server that accepts a single connection, drains the
/// request head, and replays `wire` verbatim. Runs on its own OS thread so the
/// client call in the test body can block on the response.
const Replay = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    wire: []const u8,
    failed: ?anyerror = null,

    fn run(self: *Replay) void {
        self.serve() catch |err| {
            self.failed = err;
        };
    }

    fn serve(self: *Replay) !void {
        const stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        // Drain the request head so the client's write completes before we
        // reply — closing on an unread socket surfaces as a reset, not a status.
        var read_buffer: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            if (line.len <= 2) break; // bare CRLF terminates the head
        }

        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.writeAll(self.wire);
        try writer.interface.flush();
    }
};

/// Bind a listener on an ephemeral-ish loopback port. `std.Io.net` has no
/// read-back of the bound address, so walk a fixed range until one is free
/// and report the port we actually took.
fn listenLoopback(io: std.Io) !struct { server: std.Io.net.Server, port: u16 } {
    var port: u16 = 39701;
    while (port < 39760) : (port += 1) {
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
        const server = address.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
            error.AddressInUse, error.AddressUnavailable => continue,
            else => return err,
        };
        return .{ .server = server, .port = port };
    }
    return error.NoFreeLoopbackPort;
}

test "HEAD reports the server's real status, not a hardcoded 200" {
    const allocator = std.testing.allocator;

    var io_threaded = std.Io.Threaded.init(allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    for (vectors) |vector| {
        var bound = try listenLoopback(io);
        defer bound.server.deinit(io);

        var replay: Replay = .{ .io = io, .server = &bound.server, .wire = vector.wire };
        const thread = try std.Thread.spawn(.{}, Replay.run, .{&replay});

        var url_buffer: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/health", .{bound.port});

        var client = try HttpClient.init(allocator);
        defer client.deinit();

        var response = client.head(url, &.{}) catch |err| {
            thread.join();
            std.debug.print("FAIL: {s} — head() errored: {t}\n", .{ vector.name, err });
            return err;
        };
        defer response.deinit();
        thread.join();

        if (replay.failed) |err| {
            std.debug.print("FAIL: {s} — replay server errored: {t}\n", .{ vector.name, err });
            return err;
        }

        std.testing.expectEqual(vector.expect, response.status) catch |err| {
            std.debug.print(
                "FAIL: {s} — expected {d}, got {d}\n",
                .{ vector.name, @intFromEnum(vector.expect), @intFromEnum(response.status) },
            );
            return err;
        };
        // RFC 9110 §9.3.2: no body accompanies a HEAD response, even when the
        // header section advertises a Content-Length.
        try std.testing.expectEqual(@as(usize, 0), response.body.len);
    }
}
