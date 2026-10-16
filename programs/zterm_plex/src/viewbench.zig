//! View-protocol benchmark: what a front end (rust_gui, `zterm attach`)
//! experiences through a running `zterm server`, measured from the client side
//! of the socket (docs/VIEW-PROTOCOL.md).
//!
//!   keypress_us          one key sent as input → the frame that shows it. The
//!                        pane runs `cat`, so the key goes through the pane's
//!                        tty echo, zterm's parser and a frame, and back.
//!   resize_ms            a `resize` → the `full` frame at the new size.
//!   view_output_mibs_*   a shell prints a known stream; MiB/s until the frame
//!                        showing its end marker arrives, with 1, 4 and 16
//!                        reading viewers, and with one viewer that never reads
//!                        (backpressure must not slow the one that does).
//!   view_frames_per_s_v1, view_bytes_per_frame_v1
//!                        what that stream cost on the wire for one viewer.
//!   reattach_first_frame_ms, reattach_history_ms
//!                        a new view of a pane with 20 000 lines of history →
//!                        its first frame, then 10 000 lines of history.
//!
//! The client parses every message a front end would parse (the primary
//! viewer's frames), so its JSON decoding is inside the numbers — as it is in
//! a real client. Extra viewers read and discard.
//!
//! It does not start a server: scripts/bench-run.py starts one hermetically
//! (temp HOME, /bin/sh panes, a socket under /tmp) and passes `--socket`.
//!
//! Usage: zterm-viewbench --socket PATH [--json] [--keys N] [--repeat N] [--seq N]

const std = @import("std");
const ctl = @import("ctl.zig");
const bs = @import("benchstat.zig");
const c = std.c;
const posix = std.posix;
const Value = std.json.Value;
const Parsed = std.json.Parsed(Value);
const Metric = bs.Metric;
const nowNs = bs.nowNs;
const ms_ns = std.time.ns_per_ms;

const ROWS: u16 = 40;
const COLS: u16 = 120;
/// 2: the default stream grew from 500k to 3M lines (~23 MB). At 500k the
/// faster emulator finished in ~0.2 s, a quarter of it inside the 50 ms of
/// unpaced frames that answer the typed command — it measured start-up, not
/// the paced steady state. Schema-1 view numbers are not comparable.
const SCHEMA: u32 = 2;
/// The marker a stream ends with. The command that prints it computes the
/// number (`$((6*7))`), so the typed command line never matches it.
const DONE = "BENCH-42-DONE";
const DONE_CMD = "echo BENCH-$((6*7))-DONE";

// ── Connection ──────────────────────────────────────────────────────────────

const Conn = struct {
    fd: c.fd_t,
    buf: std.ArrayList(u8) = .empty,
    head: usize = 0,
    bytes_in: u64 = 0,
    eof: bool = false,

    fn open(path: []const u8) !Conn {
        var addr = try ctl.fillAddr(path);
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreateFailed;
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0) {
            _ = c.close(fd);
            return error.ConnectFailed;
        }
        return .{ .fd = fd };
    }

    fn close(self: *Conn, alloc: std.mem.Allocator) void {
        _ = c.close(self.fd);
        self.buf.deinit(alloc);
    }

    fn sendJson(self: *Conn, alloc: std.mem.Allocator, v: anytype) !void {
        const text = try std.json.Stringify.valueAlloc(alloc, v, .{ .emit_null_optional_fields = false });
        defer alloc.free(text);
        try bs.writeAll(self.fd, text);
        try bs.writeAll(self.fd, "\n");
    }

    /// One read of whatever the socket has.
    fn fill(self: *Conn, alloc: std.mem.Allocator) !void {
        if (self.head == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head > 1 << 20) {
            const rest = self.buf.items.len - self.head;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.head..]);
            self.buf.shrinkRetainingCapacity(rest);
            self.head = 0;
        }
        try self.buf.ensureUnusedCapacity(alloc, 1 << 16);
        const dst = self.buf.unusedCapacitySlice();
        const r = c.read(self.fd, dst.ptr, dst.len);
        if (r < 0) return error.ReadFailed;
        if (r == 0) {
            self.eof = true;
            return;
        }
        self.buf.items.len += @intCast(r);
        self.bytes_in += @intCast(r);
    }

    /// The next complete line, if one is buffered. Valid until the next fill.
    fn line(self: *Conn) ?[]const u8 {
        const rest = self.buf.items[self.head..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
        self.head += nl + 1;
        return rest[0..nl];
    }

    /// The next message, parsed (strings copied, so it outlives the buffer);
    /// null at the deadline or when the server closes.
    fn next(self: *Conn, alloc: std.mem.Allocator, deadline: u64) !?Parsed {
        while (true) {
            if (self.line()) |l| {
                return try std.json.parseFromSlice(Value, alloc, l, .{ .allocate = .alloc_always });
            }
            if (self.eof) return null;
            const now = nowNs();
            if (now >= deadline) return null;
            const wait: i32 = @intCast(@min((deadline - now) / ms_ns + 1, 1000));
            var pfd = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
            if ((posix.poll(&pfd, wait) catch return error.PollFailed) > 0) try self.fill(alloc);
        }
    }
};

fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn int(v: Value, key: []const u8) ?i64 {
    const x = get(v, key) orelse return null;
    return if (x == .integer) x.integer else null;
}

fn isType(v: Value, t: []const u8) bool {
    const x = get(v, "t") orelse return false;
    return x == .string and std.mem.eql(u8, x.string, t);
}

fn cursorX(frame: Value) ?i64 {
    return int(get(frame, "cursor") orelse return null, "x");
}

/// Whether any span of the frame's changed rows contains `needle`.
fn frameShows(frame: Value, needle: []const u8) bool {
    const lines = get(frame, "lines") orelse return false;
    if (lines != .array) return false;
    for (lines.array.items) |l| {
        const spans = get(l, "spans") orelse continue;
        if (spans != .array) continue;
        for (spans.array.items) |sp| {
            const t = get(sp, "text") orelse continue;
            if (t == .string and std.mem.indexOf(u8, t.string, needle) != null) return true;
        }
    }
    return false;
}

// ── Server requests ─────────────────────────────────────────────────────────

const Bench = struct {
    alloc: std.mem.Allocator,
    sock: []const u8,

    fn request(self: Bench, req: anytype) !Parsed {
        var conn = try Conn.open(self.sock);
        defer conn.close(self.alloc);
        try conn.sendJson(self.alloc, req);
        return (try conn.next(self.alloc, nowNs() + 5 * std.time.ns_per_s)) orelse error.NoAnswer;
    }

    fn spawn(self: Bench, run: ?[]const u8) !u64 {
        const p = try self.request(.{ .cmd = "spawn", .cwd = "/tmp", .rows = ROWS, .cols = COLS, .run = run });
        defer p.deinit();
        const id = int(p.value, "pane") orelse {
            std.debug.print("zterm-viewbench: spawn refused: {f}\n", .{std.json.fmt(p.value, .{})});
            return error.SpawnRefused;
        };
        return @intCast(id);
    }

    fn kill(self: Bench, pane: u64) void {
        const p = self.request(.{ .cmd = "kill", .pane = pane }) catch return;
        p.deinit();
    }

    /// A view connection; `sized` sends this client's size (a first viewer),
    /// otherwise the pane keeps its own (an extra or reattaching viewer).
    fn view(self: Bench, pane: u64, sized: bool) !Conn {
        var conn = try Conn.open(self.sock);
        errdefer conn.close(self.alloc);
        if (sized) {
            try conn.sendJson(self.alloc, .{ .cmd = "view", .pane = pane, .rows = ROWS, .cols = COLS });
        } else {
            try conn.sendJson(self.alloc, .{ .cmd = "view", .pane = pane });
        }
        return conn;
    }

    /// Read until nothing has arrived for `quiet_ms`; the last cursor x seen.
    fn settle(self: Bench, conn: *Conn, quiet_ms: u64, max_ms: u64) !i64 {
        const end = nowNs() + max_ms * ms_ns;
        var x: i64 = 0;
        while (nowNs() < end) {
            const m = (try conn.next(self.alloc, @min(end, nowNs() + quiet_ms * ms_ns))) orelse return x;
            defer m.deinit();
            if (isType(m.value, "frame")) x = cursorX(m.value) orelse x;
        }
        return x;
    }

    /// Frames until one satisfies `done`; false at the deadline.
    fn waitFrame(self: Bench, conn: *Conn, deadline: u64, ctx: anytype, comptime done: fn (@TypeOf(ctx), Value) bool) !bool {
        while (try conn.next(self.alloc, deadline)) |m| {
            defer m.deinit();
            if (isType(m.value, "frame") and done(ctx, m.value)) return true;
        }
        return false;
    }
};

// ── Stages ──────────────────────────────────────────────────────────────────

fn cursorAt(want: i64, frame: Value) bool {
    return cursorX(frame) == want;
}

fn keypress(b: Bench, m: *Metric, keys: usize) !void {
    const pane = try b.spawn("exec cat\n");
    defer b.kill(pane);
    var v = try b.view(pane, true);
    defer v.close(b.alloc);
    var x = try b.settle(&v, 300, 10_000);
    const warm = 20;
    for (0..warm + keys) |i| {
        if (x >= 100) {
            try v.sendJson(b.alloc, .{ .input = "text", .data = "\r" });
            x = try b.settle(&v, 50, 5000);
        }
        const t0 = nowNs();
        try v.sendJson(b.alloc, .{ .input = "text", .data = "k" });
        if (!try b.waitFrame(&v, t0 + 2 * std.time.ns_per_s, x + 1, cursorAt)) return error.KeyNeverDrawn;
        const dt = nowNs() - t0;
        x += 1;
        if (i >= warm) try m.add(b.alloc, @as(f64, @floatFromInt(dt)) / 1000.0);
    }
}

const Size = struct { rows: i64, cols: i64 };

fn fullAt(want: Size, frame: Value) bool {
    const full = get(frame, "full") orelse return false;
    return full == .bool and full.bool and int(frame, "rows") == want.rows and int(frame, "cols") == want.cols;
}

fn resize(b: Bench, m: *Metric, rounds: usize) !void {
    const pane = try b.spawn("exec cat\n");
    defer b.kill(pane);
    var v = try b.view(pane, true);
    defer v.close(b.alloc);
    _ = try b.settle(&v, 300, 10_000);
    for (0..rounds + 5) |i| {
        const want: Size = if (i % 2 == 0) .{ .rows = 30, .cols = 100 } else .{ .rows = ROWS, .cols = COLS };
        const t0 = nowNs();
        try v.sendJson(b.alloc, .{ .resize = .{ .rows = want.rows, .cols = want.cols } });
        if (!try b.waitFrame(&v, t0 + 2 * std.time.ns_per_s, want, fullAt)) return error.ResizeNeverDrawn;
        if (i >= 5) try m.add(b.alloc, @as(f64, @floatFromInt(nowNs() - t0)) / 1e6);
    }
}

/// Bytes `seq 1 n` prints: every number's digits plus a newline.
fn seqBytes(n: u64) u64 {
    var total: u64 = 0;
    var lo: u64 = 1;
    var digits: u64 = 1;
    while (lo <= n) : ({
        lo *= 10;
        digits += 1;
    }) {
        const hi = @min(n, lo * 10 - 1);
        total += (hi - lo + 1) * (digits + 1);
    }
    return total;
}

const StreamResult = struct { secs: f64, frames: u64, frame_bytes: u64 };

/// A shell pane prints `seq 1 n` and the end marker while `readers` extra
/// viewers read along and `stalled` more never read.
fn stream(b: Bench, n: u64, readers: usize, stalled: usize) !StreamResult {
    const pane = try b.spawn(null);
    defer b.kill(pane);
    var v = try b.view(pane, true);
    defer v.close(b.alloc);
    var extras: std.ArrayList(Conn) = .empty;
    defer {
        for (extras.items) |*e| e.close(b.alloc);
        extras.deinit(b.alloc);
    }
    for (0..readers + stalled) |_| try extras.append(b.alloc, try b.view(pane, false));
    _ = try b.settle(&v, 300, 10_000);

    var cmd_buf: [96]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "seq 1 {d}; {s}\r", .{ n, DONE_CMD });
    var pfds = try b.alloc.alloc(posix.pollfd, 1 + readers);
    defer b.alloc.free(pfds);
    var sink: [1 << 16]u8 = undefined;

    const t0 = nowNs();
    try v.sendJson(b.alloc, .{ .input = "text", .data = cmd });
    const deadline = t0 + 120 * std.time.ns_per_s;
    const bytes0 = v.bytes_in;
    var frames: u64 = 0;
    while (nowNs() < deadline) {
        while (v.line()) |l| {
            const p = try std.json.parseFromSlice(Value, b.alloc, l, .{ .allocate = .alloc_always });
            defer p.deinit();
            if (!isType(p.value, "frame")) continue;
            frames += 1;
            if (frameShows(p.value, DONE)) {
                const secs = @as(f64, @floatFromInt(nowNs() - t0)) / 1e9;
                return .{ .secs = secs, .frames = frames, .frame_bytes = v.bytes_in - bytes0 };
            }
        }
        if (v.eof) return error.ViewClosed;
        pfds[0] = .{ .fd = v.fd, .events = posix.POLL.IN, .revents = 0 };
        for (extras.items[0..readers], 1..) |e, k| pfds[k] = .{ .fd = e.fd, .events = posix.POLL.IN, .revents = 0 };
        _ = posix.poll(pfds, 1000) catch return error.PollFailed;
        for (extras.items[0..readers], 1..) |e, k| {
            if (pfds[k].revents & posix.POLL.IN != 0) _ = c.read(e.fd, &sink, sink.len);
        }
        if (pfds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) try v.fill(b.alloc);
    }
    return error.StreamNeverEnded;
}

fn reattach(b: Bench, first: *Metric, history: *Metric, rounds: usize) !void {
    const pane = try b.spawn(null);
    defer b.kill(pane);
    {
        var v = try b.view(pane, true);
        defer v.close(b.alloc);
        _ = try b.settle(&v, 300, 10_000);
        var cmd_buf: [64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf, "seq 1 20000; {s}\r", .{DONE_CMD});
        try v.sendJson(b.alloc, .{ .input = "text", .data = cmd });
        const Done = struct {
            fn f(_: void, fr: Value) bool {
                return frameShows(fr, DONE);
            }
        };
        if (!try b.waitFrame(&v, nowNs() + 60 * std.time.ns_per_s, {}, Done.f)) return error.StreamNeverEnded;
    }
    for (0..rounds + 2) |i| {
        const t0 = nowNs();
        var v = try b.view(pane, false);
        defer v.close(b.alloc);
        const deadline = t0 + 10 * std.time.ns_per_s;
        var live_top: i64 = 0;
        var oldest: i64 = 0;
        while (true) {
            const m = (try v.next(b.alloc, deadline)) orelse return error.NoFirstFrame;
            defer m.deinit();
            if (isType(m.value, "frame")) {
                live_top = int(m.value, "live_top") orelse 0;
                oldest = int(m.value, "oldest") orelse live_top;
                break;
            }
        }
        const t1 = nowNs();
        // What rust_gui asks for: up to 10 000 lines above the screen, in the
        // server's 5000-line chunks.
        const from = @max(oldest, live_top - 10_000);
        var at = from;
        var due: usize = 0;
        while (at < live_top) : (due += 1) {
            const count = @min(5000, live_top - at);
            try v.sendJson(b.alloc, .{ .history = .{ .from = at, .count = count } });
            at += count;
        }
        while (due > 0) {
            const m = (try v.next(b.alloc, deadline)) orelse return error.HistoryNeverArrived;
            defer m.deinit();
            if (isType(m.value, "history")) due -= 1;
        }
        const t2 = nowNs();
        if (i >= 2) {
            try first.add(b.alloc, @as(f64, @floatFromInt(t1 - t0)) / 1e6);
            try history.add(b.alloc, @as(f64, @floatFromInt(t2 - t1)) / 1e6);
        }
    }
}

// ── Main ────────────────────────────────────────────────────────────────────

const Config = struct {
    sock: []const u8 = "",
    json: bool = false,
    keys: usize = 500,
    repeat: usize = 3,
    seq: u64 = 3_000_000,
};

fn parseArgs(args: []const []const u8) !Config {
    var cfg: Config = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            cfg.json = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingValue;
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--socket")) {
            cfg.sock = v;
        } else if (std.mem.eql(u8, a, "--keys")) {
            cfg.keys = std.math.clamp(try std.fmt.parseInt(usize, v, 10), 10, 100_000);
        } else if (std.mem.eql(u8, a, "--repeat")) {
            cfg.repeat = std.math.clamp(try std.fmt.parseInt(usize, v, 10), 1, 100);
        } else if (std.mem.eql(u8, a, "--seq")) {
            cfg.seq = std.math.clamp(try std.fmt.parseInt(u64, v, 10), 1000, 100_000_000);
        } else return error.UnknownFlag;
    }
    if (cfg.sock.len == 0) return error.SocketRequired;
    return cfg;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(alloc);
    var ai = std.process.Args.Iterator.init(init.minimal.args);
    while (ai.next()) |a| try arg_list.append(alloc, a);
    const cfg = parseArgs(arg_list.items) catch |e| {
        std.debug.print("zterm-viewbench: {s}\nusage: zterm-viewbench --socket PATH [--json] [--keys N] [--repeat N] [--seq N]\n", .{@errorName(e)});
        std.process.exit(2);
    };
    const b: Bench = .{ .alloc = alloc, .sock = cfg.sock };

    var keys: Metric = .{ .name = "keypress_us", .unit = "us", .higher_is_better = false };
    var rsz: Metric = .{ .name = "resize_ms", .unit = "ms", .higher_is_better = false };
    var first: Metric = .{ .name = "reattach_first_frame_ms", .unit = "ms", .higher_is_better = false };
    var hist: Metric = .{ .name = "reattach_history_ms", .unit = "ms", .higher_is_better = false };
    var out1: Metric = .{ .name = "view_output_mibs_v1", .unit = "MiB/s", .higher_is_better = true };
    var out4: Metric = .{ .name = "view_output_mibs_v4", .unit = "MiB/s", .higher_is_better = true };
    var out16: Metric = .{ .name = "view_output_mibs_v16", .unit = "MiB/s", .higher_is_better = true };
    var outst: Metric = .{ .name = "view_output_mibs_v1_stalled1", .unit = "MiB/s", .higher_is_better = true };
    var fps: Metric = .{ .name = "view_frames_per_s_v1", .unit = "frames/s", .higher_is_better = false, .trend_only = true };
    var bpf: Metric = .{ .name = "view_bytes_per_frame_v1", .unit = "B/frame", .higher_is_better = false, .trend_only = true };
    const all = [_]*Metric{ &keys, &rsz, &out1, &out4, &out16, &outst, &fps, &bpf, &first, &hist };
    defer for (all) |m| m.deinit(alloc);

    std.debug.print("zterm-viewbench (schema {d}): socket={s} keys={d} repeat={d} seq={d}\n", .{ SCHEMA, cfg.sock, cfg.keys, cfg.repeat, cfg.seq });

    try keypress(b, &keys, cfg.keys);
    try resize(b, &rsz, 50);
    const mib = @as(f64, @floatFromInt(seqBytes(cfg.seq))) / (1024.0 * 1024.0);
    _ = try stream(b, cfg.seq / 10, 0, 0); // warm-up
    for (0..cfg.repeat) |_| {
        const r1 = try stream(b, cfg.seq, 0, 0);
        try out1.add(alloc, mib / r1.secs);
        try fps.add(alloc, @as(f64, @floatFromInt(r1.frames)) / r1.secs);
        try bpf.add(alloc, @as(f64, @floatFromInt(r1.frame_bytes)) / @as(f64, @floatFromInt(@max(1, r1.frames))));
        try out4.add(alloc, mib / (try stream(b, cfg.seq, 3, 0)).secs);
        try out16.add(alloc, mib / (try stream(b, cfg.seq, 15, 0)).secs);
        try outst.add(alloc, mib / (try stream(b, cfg.seq, 0, 1)).secs);
    }
    try reattach(b, &first, &hist, 20);

    bs.printHeader();
    for (all) |m| try m.printRow(alloc);

    if (!cfg.json) return;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("bench");
    try s.write("zterm-viewbench");
    try s.objectField("schema");
    try s.write(SCHEMA);
    try s.objectField("config");
    try s.write(.{ .keys = cfg.keys, .repeat = cfg.repeat, .seq = cfg.seq, .seq_bytes = seqBytes(cfg.seq), .rows = ROWS, .cols = COLS, .history_lines = 10_000 });
    try s.objectField("metrics");
    try s.beginObject();
    for (all) |m| try m.write(&s, alloc);
    try s.endObject();
    try s.endObject();
    try aw.writer.writeByte('\n');
    try bs.writeAll(1, aw.written());
}

test "seqBytes counts digits and newlines exactly" {
    try std.testing.expectEqual(@as(u64, 18), seqBytes(9)); // "1\n".."9\n"
    try std.testing.expectEqual(@as(u64, 18 + 3), seqBytes(10));
    try std.testing.expectEqual(@as(u64, 18 + 90 * 3 + 4), seqBytes(100));
}

test "the end marker is never in the command that prints it" {
    try std.testing.expect(std.mem.indexOf(u8, DONE_CMD, DONE) == null);
}
