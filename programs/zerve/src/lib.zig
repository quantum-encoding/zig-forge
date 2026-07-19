// zerve — a high-performance, evented HTTP/1.1 server core for Zig.
//
// Concurrency model: SO_REUSEPORT multi-worker, one kqueue (macOS/BSD) event
// loop per worker, non-blocking sockets, per-connection state machine, and a
// per-worker connection freelist (zero per-request heap alloc at steady state).
// This is the evented design the thread-per-connection AI gateway can't match
// on the Anton Putra benchmark.
//
// Public surface:
//   const zerve = @import("zerve");
//   fn handle(req: *const zerve.Request, res: *zerve.Response) void { ... }
//   var server = zerve.Server.init(.{ .port = 8080 }, handle);
//   try server.run();

const server = @import("server.zig");
const http = @import("http.zig");

pub const Server = server.Server;
pub const Config = server.Config;
pub const Handler = server.Handler;

pub const Request = http.Request;
pub const Response = http.Response;
pub const Method = http.Method;
pub const Parsed = http.Parsed;
pub const parse = http.parse;
pub const writeResponse = http.writeResponse;

pub const Reactor = @import("reactor.zig").Reactor;

test {
    // Pull in every module's test block: parser/response-builder (http),
    // server core + connection pool + loopback integration (server).
    _ = http;
    _ = server;
}
