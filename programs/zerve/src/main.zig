// zerve benchmark binary — serves the Anton Putra `GET /api/devices` endpoint
// the Rust/Actix vs Zig/Zap vs Go comparison hammers, so zerve's evented core
// can be measured on the same wire as Zap.
//
//   zig build run            # listen on 0.0.0.0:8080, workers = CPU count
//   zig build run -- 9000    # override the port
//
// The handler is allocation-free: it returns a static JSON body. All the work
// is in the server core (accept → parse → dispatch → write → keep-alive).

const std = @import("std");
const zerve = @import("zerve");

// A small fixed device list, matching the shape the benchmark expects.
const DEVICES_JSON =
    \\[{"id":1,"name":"device-1","type":"sensor","status":"online"},
    ++
    \\{"id":2,"name":"device-2","type":"actuator","status":"online"},
    ++
    \\{"id":3,"name":"device-3","type":"gateway","status":"offline"}]
;

fn handle(req: *const zerve.Request, res: *zerve.Response) void {
    if (req.method == .GET and req.pathEquals("/api/devices")) {
        res.json(DEVICES_JSON);
    } else if (req.method == .GET and req.pathEquals("/healthz")) {
        res.text("ok");
    } else {
        res.notFound();
    }
}

pub fn main() !void {
    var port: u16 = 8080;
    var args = std.process.args();
    _ = args.next(); // exe name
    if (args.next()) |arg| {
        port = std.fmt.parseInt(u16, arg, 10) catch 8080;
    }

    var server = zerve.Server.init(.{ .port = port }, handle);
    std.debug.print("zerve listening on 0.0.0.0:{d} (workers = CPU count)\n", .{port});
    try server.run();
}
