//! es-tap: print process events as they happen.
//!
//! Requires the EndpointSecurity entitlement, Developer ID signing with the
//! hardened runtime, Full Disk Access approval and root:
//!
//!     zig build && codesign --sign "Developer ID Application" \
//!         --entitlements examples/es_tap.entitlements --options runtime --force zig-out/bin/es-tap
//!     sudo zig-out/bin/es-tap [--auth-exec]
//!
//! With `--auth-exec` it also subscribes to AUTH_EXEC and allows everything,
//! printing how much of the deadline was left when it answered.

const std = @import("std");
const es = @import("endpoint_sec");
const darwin = @import("darwin_kit");

const State = struct {
    auth: bool,
    events: u64 = 0,
    exec_events: u64 = 0,
};

var running = std.atomic.Value(bool).init(true);

// Darwin's process arguments, without going through std.process.
extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*][*:0]u8;

fn onSignal(_: c_int) callconv(.c) void {
    running.store(false, .release);
}

fn onMessage(state: *State, client: es.Client, msg: es.Message) void {
    state.events += 1;
    const p = msg.process();
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    w.print("{s} pid={d} ppid={d} {s}", .{ es.shortName(msg.eventType()), p.pid(), p.ppid(), p.executable().path() }) catch {};
    if (p.responsibleAuditToken()) |r| w.print(" responsible={d}", .{r.pid()}) catch {};

    switch (msg.event()) {
        .exec => {
            state.exec_events += 1;
            const x = msg.exec().?;
            w.print(" -> {s}", .{x.target().executable().path()}) catch {};
            if (x.cwd()) |c| w.print(" cwd={s}", .{c.path()}) catch {};
            w.print(" argv=[", .{}) catch {};
            var it = x.args();
            var first = true;
            while (it.next()) |a| {
                w.print("{s}{s}", .{ if (first) "" else " ", a }) catch {};
                first = false;
            }
            w.print("]", .{}) catch {};
        },
        .fork => |f| w.print(" child={d}", .{f.child.audit_token.pid()}) catch {},
        .exit => |e| w.print(" status={d}", .{e.stat}) catch {},
        .unlink => |u| w.print(" target={s}", .{u.target.path.slice()}) catch {},
        .rename => |r| w.print(" source={s}", .{r.source.path.slice()}) catch {},
        else => {},
    }

    if (msg.isAuth()) {
        const left = msg.deadlineRemainingNanos() orelse 0;
        client.respond(msg, .allow, false) catch |err| {
            w.print(" respond-error={s}", .{@errorName(err)}) catch {};
        };
        w.print(" deadline-left={d}ms", .{left / std.time.ns_per_ms}) catch {};
    }
    w.writeByte('\n') catch {};
    _ = std.c.write(1, w.buffered().ptr, w.buffered().len);
}

pub fn main() !void {
    var state = State{ .auth = false };
    const argc: usize = @intCast(_NSGetArgc().*);
    const argv = _NSGetArgv().*;
    for (argv[1..argc]) |a| {
        if (std.mem.eql(u8, std.mem.span(a), "--auth-exec")) state.auth = true;
    }

    const version = darwin.os_version.current();
    std.debug.print("es-tap on macOS {d}.{d}, uid {d}\n", .{ if (version) |v| v.major else 0, if (version) |v| v.minor else 0, std.c.getuid() });

    var client = es.Client.init(State, &state, onMessage) catch |err| {
        std.debug.print("es_new_client failed: {s}\n", .{@errorName(err)});
        switch (err) {
            error.NotEntitled => std.debug.print("  sign with the com.apple.developer.endpoint-security.client entitlement\n", .{}),
            error.NotPermitted => std.debug.print("  grant Full Disk Access to this binary in System Settings\n", .{}),
            error.NotPrivileged => std.debug.print("  run as root\n", .{}),
            else => {},
        }
        return err;
    };
    defer client.deinit();

    // Do not deliver our own file writes back to ourselves.
    client.muteSelf() catch |err| std.debug.print("muteSelf: {s}\n", .{@errorName(err)});

    var subs: [8]es.EventType = undefined;
    var n: usize = 0;
    for ([_]es.EventType{ .ES_EVENT_TYPE_NOTIFY_EXEC, .ES_EVENT_TYPE_NOTIFY_FORK, .ES_EVENT_TYPE_NOTIFY_EXIT, .ES_EVENT_TYPE_NOTIFY_UNLINK, .ES_EVENT_TYPE_NOTIFY_RENAME }) |t| {
        subs[n] = t;
        n += 1;
    }
    if (state.auth) {
        subs[n] = .ES_EVENT_TYPE_AUTH_EXEC;
        n += 1;
    }
    try client.subscribe(subs[0..n]);

    const signal = struct {
        extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
    }.signal;
    _ = signal(@intFromEnum(std.c.SIG.INT), onSignal);
    _ = signal(@intFromEnum(std.c.SIG.TERM), onSignal);

    std.debug.print("subscribed to {d} event types; Ctrl-C to stop\n", .{n});
    while (running.load(.acquire)) {
        _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 200 * std.time.ns_per_ms }, null);
    }
    std.debug.print("\n{d} events ({d} exec)\n", .{ state.events, state.exec_events });
}
