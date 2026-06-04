//! Throughput / latency sanity benchmark for the terminal_mux C ABI.
//!
//! Drives the exported libterminal_mux entry points (src/capi.zig) exactly as a
//! host (e.g. the Swift front-end) would, and reports:
//!   1. Emulator ingest throughput  — bytes/sec fed straight through the VT
//!      parser into the grid (`tmux_feed`), the pure core hot path.
//!   2. End-to-end PTY throughput    — a shell emits a large stream; we measure
//!      how fast it flows through the PTY + parser (`tmux_pump`).
//!   3. Session lifecycle latency    — create / attach / detach / destroy.
//!
//! Run with:  zig build bench
//! All timing uses a monotonic clock (std.time.Timer).

const std = @import("std");
const capi = @import("capi.zig");

/// Zig 0.16-compatible monotonic timer (this toolchain's std has no
/// std.time.Timer; matches the clock_gettime pattern used elsewhere in the repo).
const Timer = struct {
    start_time: i128,

    pub fn start() !Timer {
        return Timer{ .start_time = nowNs() };
    }

    pub fn reset(self: *Timer) void {
        self.start_time = nowNs();
    }

    pub fn read(self: Timer) u64 {
        return @intCast(nowNs() - self.start_time);
    }

    fn nowNs() i128 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    }
};

fn mibPerSec(bytes: usize, ns: u64) f64 {
    if (ns == 0) return 0;
    const secs = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
    const mib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    return mib / secs;
}

/// Build a representative ANSI stream: colored text, SGR resets, CR/LF, digits.
fn buildSample(buf: []u8) usize {
    const line = "\x1b[1;32mterminal_mux\x1b[0m \x1b[38;5;208mbench\x1b[0m 0123456789 the quick brown fox\r\n";
    var i: usize = 0;
    while (i + line.len <= buf.len) : (i += line.len) {
        @memcpy(buf[i .. i + line.len], line);
    }
    return i;
}

fn benchEmulatorFeed() !void {
    const id_rows: u16 = 40;
    const id_cols: u16 = 120;

    const h = capi.tmux_create(id_rows, id_cols, null, null) orelse {
        std.debug.print("  [emulator] FAILED to create session\n", .{});
        return;
    };
    defer capi.tmux_destroy(h);

    // ~1 MiB synthetic chunk, fed repeatedly to reach the target volume.
    var chunk: [1 << 20]u8 = undefined;
    const chunk_len = buildSample(&chunk);

    const target: usize = 512 * 1024 * 1024; // 512 MiB
    const iters = target / chunk_len;

    var timer = try Timer.start();
    var fed: usize = 0;
    var n: usize = 0;
    while (n < iters) : (n += 1) {
        capi.tmux_feed(h, &chunk, chunk_len);
        fed += chunk_len;
    }
    const elapsed = timer.read();

    std.debug.print("  [emulator feed]  {d:>6.1} MiB in {d:>6.1} ms  =>  {d:>8.1} MiB/s\n", .{
        @as(f64, @floatFromInt(fed)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        mibPerSec(fed, elapsed),
    });
}

fn benchPtyThroughput() !void {
    const h = capi.tmux_create(40, 120, null, null) orelse {
        std.debug.print("  [pty] FAILED to create session\n", .{});
        return;
    };
    defer capi.tmux_destroy(h);

    // Let the shell start and print its prompt; drain that warm-up output.
    var warm: usize = 0;
    while (warm < 20) : (warm += 1) {
        _ = capi.tmux_pump(h, 50);
    }

    // Ask the shell to emit a large, cheap stream. `head -c` bounds it exactly;
    // `yes` is the canonical fast producer. 64 MiB.
    const target: usize = 64 * 1024 * 1024;
    const cmd = "yes ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghij 2>/dev/null | head -c 67108864\n";
    _ = capi.tmux_send(h, cmd, cmd.len);

    var timer = try Timer.start();
    var got: usize = 0;
    var idle: u8 = 0;
    while (got < target + (1 << 16)) {
        const r = capi.tmux_pump(h, 1000);
        if (r < 0) break;
        if (r == 0) {
            idle += 1;
            if (idle >= 2) break; // stream finished, shell back at prompt
            continue;
        }
        idle = 0;
        got += @intCast(r);
    }
    const elapsed = timer.read();

    std.debug.print("  [pty ingest]     {d:>6.1} MiB in {d:>6.1} ms  =>  {d:>8.1} MiB/s\n", .{
        @as(f64, @floatFromInt(got)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        mibPerSec(got, elapsed),
    });
}

fn benchLifecycle() !void {
    const rounds: usize = 200;

    // create + destroy
    var timer = try Timer.start();
    var i: usize = 0;
    var created: usize = 0;
    while (i < rounds) : (i += 1) {
        const h = capi.tmux_create(24, 80, null, null) orelse continue;
        created += 1;
        capi.tmux_destroy(h);
    }
    const create_destroy = timer.read();

    // attach + detach against one persistent session
    var id: u64 = 0;
    const persistent = capi.tmux_create(24, 80, null, &id) orelse {
        std.debug.print("  [lifecycle] FAILED to create persistent session\n", .{});
        return;
    };
    defer capi.tmux_destroy(persistent);

    timer.reset();
    i = 0;
    while (i < rounds) : (i += 1) {
        const h = capi.tmux_attach(id) orelse break;
        capi.tmux_detach(h);
    }
    const attach_detach = timer.read();

    if (created > 0) {
        std.debug.print("  [create+destroy] {d:>8.1} us/op  ({d} ops)\n", .{
            @as(f64, @floatFromInt(create_destroy)) / 1000.0 / @as(f64, @floatFromInt(created)),
            created,
        });
    }
    std.debug.print("  [attach+detach]  {d:>8.3} us/op  ({d} ops)\n", .{
        @as(f64, @floatFromInt(attach_detach)) / 1000.0 / @as(f64, @floatFromInt(rounds)),
        rounds,
    });
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("terminal_mux C ABI benchmark (v{s})\n", .{std.mem.sliceTo(capi.tmux_version(), 0)});
    std.debug.print("----------------------------------------------------------------\n", .{});
    try benchEmulatorFeed();
    try benchPtyThroughput();
    try benchLifecycle();
    std.debug.print("----------------------------------------------------------------\n", .{});
}
