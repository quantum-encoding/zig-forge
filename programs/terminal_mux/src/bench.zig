//! Core benchmark for the terminal_mux C ABI: what one pane costs, with no
//! server and no client in the way.
//!
//! Drives the exported libterminal_mux entry points (src/capi.zig) exactly as a
//! host (e.g. the Swift front-end) would, and measures:
//!   1. Emulator ingest — MiB/s fed straight through the VT parser into the grid
//!      (`tmux_feed`), the pure core hot path, over four fixed inputs: mixed SGR
//!      text, plain text (the SIMD path), CJK + emoji (double-width cells), and
//!      full-screen cursor-addressed repaints (what a TUI such as htop does).
//!   2. PTY ingest — a shell emits an exact byte count; MiB/s through the PTY +
//!      parser (`tmux_pump`), timed to the LAST byte received.
//!   3. Lifecycle — create+destroy and attach+detach, microseconds per op.
//!
//! Every metric is sampled `--repeat` times after one unrecorded warm-up and
//! reported as median / min / max with the raw samples, so a run can be
//! compared with a later one (scripts/bench-run.py records them).
//!
//! Hermetic by construction: panes run `--shell` (default /bin/sh), never the
//! user's login shell — a personal startup file that prompts would otherwise
//! receive the command this benchmark types, and its start-up time would be
//! measured as zterm's.
//!
//! Usage:  zterm-bench [--json] [--repeat N] [--feed-mib M] [--pty-mib M] [--shell PATH]
//!   --json   the report as JSON on stdout (the table always goes to stderr)

const std = @import("std");
const capi = @import("capi.zig");
const bs = @import("benchstat.zig");
const Metric = bs.Metric;
const nowNs = bs.nowNs;
const Stringify = std.json.Stringify;

const ROWS: u16 = 40;
const COLS: u16 = 120;

/// Bump when a metric's meaning changes, so old and new runs are never
/// compared as if they measured the same thing. (Schema 1 was the text-only
/// output tracked in bench/results.csv; its PTY figure included two seconds of
/// idle wait and its lifecycle figures the user's login shell.)
const SCHEMA: u32 = 2;

fn mibPerSec(bytes: usize, ns: u64) f64 {
    if (ns == 0) return 0;
    const secs = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
    const mib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    return mib / secs;
}

// ── Fixed inputs ────────────────────────────────────────────────────────────
// Deterministic: the same bytes on every run and every machine. Each input's
// FNV-1a 64 goes into the report, so a changed input can never be mistaken
// for a faster or slower zterm.

/// Coloured text, SGR resets, CR/LF, digits.
fn buildMixed(buf: []u8) usize {
    return tile(buf, "\x1b[1;32mterminal_mux\x1b[0m \x1b[38;5;208mbench\x1b[0m 0123456789 the quick brown fox\r\n");
}

/// Plain printable text (long lines + LF), the case the SIMD fast path is built
/// for — representative of `cat`, logs, and source code.
fn buildPlain(buf: []u8) usize {
    return tile(buf, "the quick brown fox jumps over the lazy dog 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnop\n");
}

/// Double-width cells: CJK and emoji between ASCII, every line.
fn buildCjk(buf: []u8) usize {
    return tile(buf, "日本語のテキスト 中文字符 한국어 \xf0\x9f\x98\x80\xf0\x9f\x8e\x89 mixed ascii 0123 \x1b[33m黄色\x1b[0m\r\n");
}

/// Whole-screen repaints the way a TUI draws: home, then every row addressed
/// with CUP, a palette colour, text, erase-to-end-of-line. 0 if the frame did
/// not fit its buffer (the caller refuses an empty input).
fn buildRedraw(buf: []u8) usize {
    const text = "cpu[||||||||||||||||||||||||||||    43.2%]  mem[|||||||||||||||||    2.1G/15.4G]  PID USER  PRI  NI  VIRT   RES  SHR";
    var frame: [ROWS * (text.len + 48)]u8 = undefined;
    const n = redrawFrame(&frame, text) catch return 0;
    return tile(buf, frame[0..n]);
}

fn redrawFrame(frame: []u8, text: []const u8) error{NoSpaceLeft}!usize {
    var n: usize = (try std.fmt.bufPrint(frame, "\x1b[H", .{})).len;
    for (0..ROWS) |r| {
        n += (try std.fmt.bufPrint(frame[n..], "\x1b[{d};1H\x1b[38;5;{d}m", .{ r + 1, (r * 6) % 256 })).len;
        if (frame.len - n < text.len) return error.NoSpaceLeft;
        @memcpy(frame[n .. n + text.len], text);
        n += text.len;
        n += (try std.fmt.bufPrint(frame[n..], "\x1b[0m\x1b[K", .{})).len;
    }
    return n;
}

fn tile(buf: []u8, unit: []const u8) usize {
    var i: usize = 0;
    while (i + unit.len <= buf.len) : (i += unit.len) {
        @memcpy(buf[i .. i + unit.len], unit);
    }
    return i;
}

fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |b| h = (h ^ b) *% 0x0000_0100_0000_01b3;
    return h;
}

const Config = struct {
    repeat: usize = 5,
    feed_mib: usize = 128,
    pty_mib: usize = 16,
    shell: [:0]const u8 = "/bin/sh",
    json: bool = false,
};

// ── Stages ──────────────────────────────────────────────────────────────────

/// One timed pass of `mib` MiB of `input` through the parser. Null when a
/// session could not be created (reported, never recorded as zero).
fn feedOnce(input: []const u8, mib: usize, shell: [*:0]const u8) ?f64 {
    const h = capi.tmux_create(ROWS, COLS, shell, null) orelse return null;
    defer capi.tmux_destroy(h);
    const target = mib * 1024 * 1024;
    const iters = @max(1, target / @max(1, input.len));
    const t0 = nowNs();
    var fed: usize = 0;
    for (0..iters) |_| {
        capi.tmux_feed(h, input.ptr, input.len);
        fed += input.len;
    }
    return mibPerSec(fed, nowNs() - t0);
}

/// One timed pass of an exact byte stream from the pane's shell through the
/// PTY and parser. Timed from the command to the LAST byte of output: waiting
/// to be sure the stream has ended is not part of the measurement.
fn ptyOnce(mib: usize, shell: [*:0]const u8) ?f64 {
    const h = capi.tmux_create(ROWS, COLS, shell, null) orelse return null;
    defer capi.tmux_destroy(h);

    // Drain the shell's start-up output until it has been quiet for 300 ms.
    var quiet_since = nowNs();
    while (nowNs() - quiet_since < 300 * std.time.ns_per_ms) {
        if (capi.tmux_pump(h, 50) > 0) quiet_since = nowNs();
    }

    const bytes = mib * 1024 * 1024;
    var cmd_buf: [160]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "yes ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghij 2>/dev/null | head -c {d}\n", .{bytes}) catch return null;
    _ = capi.tmux_send(h, cmd.ptr, cmd.len);

    const t0 = nowNs();
    var got: usize = 0;
    var last = t0;
    // Ends once the stream has been delivered and the pane has been quiet for
    // 500 ms. The shell's echo of the command and its next prompt are counted
    // too: a few hundred bytes against megabytes. A 60 s ceiling bounds a wedge.
    while (nowNs() - t0 < 60 * std.time.ns_per_s) {
        const r = capi.tmux_pump(h, 100);
        if (r < 0) break;
        if (r > 0) {
            got += @intCast(r);
            last = nowNs();
        } else if (got >= bytes and nowNs() - last > 500 * std.time.ns_per_ms) break;
    }
    if (got < bytes) return null;
    return mibPerSec(got, last - t0);
}

/// Microseconds per create+destroy (a real PTY + `shell` each time).
fn createOnce(shell: [*:0]const u8) ?f64 {
    const rounds: usize = 100;
    const t0 = nowNs();
    var made: usize = 0;
    for (0..rounds) |_| {
        const h = capi.tmux_create(24, 80, shell, null) orelse continue;
        made += 1;
        capi.tmux_destroy(h);
    }
    if (made == 0) return null;
    return @as(f64, @floatFromInt(nowNs() - t0)) / 1000.0 / @as(f64, @floatFromInt(made));
}

/// Microseconds per attach+detach against one live session.
fn attachOnce(shell: [*:0]const u8) ?f64 {
    var id: u64 = 0;
    const keep = capi.tmux_create(24, 80, shell, &id) orelse return null;
    defer capi.tmux_destroy(keep);
    const rounds: usize = 2000;
    const t0 = nowNs();
    for (0..rounds) |_| {
        const h = capi.tmux_attach(id) orelse return null;
        capi.tmux_detach(h);
    }
    return @as(f64, @floatFromInt(nowNs() - t0)) / 1000.0 / @as(f64, @floatFromInt(rounds));
}

fn record(m: *Metric, alloc: std.mem.Allocator, v: ?f64) !void {
    if (v) |x| {
        try m.add(alloc, x);
    } else {
        std.debug.print("  [{s}] a sample FAILED (session could not be created or the stream did not arrive)\n", .{m.name});
    }
}

fn parseArgs(alloc: std.mem.Allocator, args: []const []const u8) !Config {
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
        if (std.mem.eql(u8, a, "--repeat")) {
            cfg.repeat = std.math.clamp(try std.fmt.parseInt(usize, v, 10), 1, 100);
        } else if (std.mem.eql(u8, a, "--feed-mib")) {
            cfg.feed_mib = std.math.clamp(try std.fmt.parseInt(usize, v, 10), 1, 4096);
        } else if (std.mem.eql(u8, a, "--pty-mib")) {
            cfg.pty_mib = std.math.clamp(try std.fmt.parseInt(usize, v, 10), 1, 1024);
        } else if (std.mem.eql(u8, a, "--shell")) {
            cfg.shell = try alloc.dupeZ(u8, v);
        } else return error.UnknownFlag;
    }
    return cfg;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(alloc);
    var ai = std.process.Args.Iterator.init(init.minimal.args);
    while (ai.next()) |a| try arg_list.append(alloc, a);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const cfg = parseArgs(arena.allocator(), arg_list.items) catch |e| {
        std.debug.print("zterm-bench: {s}\nusage: zterm-bench [--json] [--repeat N] [--feed-mib M] [--pty-mib M] [--shell PATH]\n", .{@errorName(e)});
        std.process.exit(2);
    };

    const inputs = [_]struct { key: []const u8, build: *const fn ([]u8) usize }{
        .{ .key = "mixed", .build = buildMixed },
        .{ .key = "plain", .build = buildPlain },
        .{ .key = "cjk", .build = buildCjk },
        .{ .key = "redraw", .build = buildRedraw },
    };
    const chunk = try alloc.alloc(u8, 1 << 20);
    defer alloc.free(chunk);

    var metrics = [_]Metric{
        .{ .name = "feed_mixed_mibs", .unit = "MiB/s", .higher_is_better = true },
        .{ .name = "feed_plain_mibs", .unit = "MiB/s", .higher_is_better = true },
        .{ .name = "feed_cjk_mibs", .unit = "MiB/s", .higher_is_better = true },
        .{ .name = "feed_redraw_mibs", .unit = "MiB/s", .higher_is_better = true },
        .{ .name = "pty_ingest_mibs", .unit = "MiB/s", .higher_is_better = true },
        .{ .name = "create_destroy_us", .unit = "us/op", .higher_is_better = false },
        // ~15 ns: a registry lookup. Its samples within a run are identical,
        // but between runs it moves 2x with the core and clock the process
        // lands on (measured: same commit, 0.013 vs 0.027) — shown, not judged.
        .{ .name = "attach_detach_us", .unit = "us/op", .higher_is_better = false, .trend_only = true },
    };
    defer for (&metrics) |*m| m.deinit(alloc);
    var checksums: [inputs.len]u64 = undefined;

    std.debug.print("zterm-bench v{s} (schema {d}): repeat={d} feed={d}MiB pty={d}MiB shell={s}\n", .{
        std.mem.sliceTo(capi.tmux_version(), 0), SCHEMA, cfg.repeat, cfg.feed_mib, cfg.pty_mib, cfg.shell,
    });

    for (inputs, 0..) |in, k| {
        const len = in.build(chunk);
        if (len == 0) {
            std.debug.print("zterm-bench: the {s} input could not be built\n", .{in.key});
            return error.InputBuildFailed;
        }
        const input = chunk[0..len];
        checksums[k] = fnv1a64(input);
        _ = feedOnce(input, @max(1, cfg.feed_mib / 8), cfg.shell); // warm-up
        for (0..cfg.repeat) |_| try record(&metrics[k], alloc, feedOnce(input, cfg.feed_mib, cfg.shell));
    }
    _ = ptyOnce(1, cfg.shell); // warm-up
    for (0..cfg.repeat) |_| try record(&metrics[4], alloc, ptyOnce(cfg.pty_mib, cfg.shell));
    _ = createOnce(cfg.shell);
    for (0..cfg.repeat) |_| try record(&metrics[5], alloc, createOnce(cfg.shell));
    _ = attachOnce(cfg.shell);
    for (0..cfg.repeat) |_| try record(&metrics[6], alloc, attachOnce(cfg.shell));

    // The table, always on stderr.
    bs.printHeader();
    for (&metrics) |*m| try m.printRow(alloc);

    if (!cfg.json) return;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("bench");
    try s.write("zterm-bench");
    try s.objectField("schema");
    try s.write(SCHEMA);
    try s.objectField("zterm_version");
    try s.write(std.mem.sliceTo(capi.tmux_version(), 0));
    try s.objectField("config");
    try s.beginObject();
    try s.objectField("repeat");
    try s.write(cfg.repeat);
    try s.objectField("feed_mib");
    try s.write(cfg.feed_mib);
    try s.objectField("pty_mib");
    try s.write(cfg.pty_mib);
    try s.objectField("rows");
    try s.write(ROWS);
    try s.objectField("cols");
    try s.write(COLS);
    try s.objectField("shell");
    try s.write(cfg.shell);
    try s.endObject();
    try s.objectField("inputs");
    try s.beginObject();
    for (inputs, 0..) |in, k| {
        var hex: [16]u8 = undefined;
        try s.objectField(in.key);
        try s.write(try std.fmt.bufPrint(&hex, "{x:0>16}", .{checksums[k]}));
    }
    try s.endObject();
    try s.objectField("metrics");
    try s.beginObject();
    for (&metrics) |*m| try m.write(&s, alloc);
    try s.endObject();
    try s.endObject();
    try aw.writer.writeByte('\n');
    try bs.writeAll(1, aw.written());
}

test "inputs are deterministic, whole units only" {
    var a: [16384]u8 = undefined;
    var b: [16384]u8 = undefined;
    const na = buildRedraw(&a);
    const nb = buildRedraw(&b);
    try std.testing.expectEqual(na, nb);
    try std.testing.expectEqual(fnv1a64(a[0..na]), fnv1a64(b[0..nb]));
    try std.testing.expect(na > 0);
    // The CJK unit is whole UTF-8: no code point is cut at the tile edge.
    const nc = buildCjk(&a);
    try std.testing.expect(nc > 0 and std.unicode.utf8ValidateSlice(a[0..nc]));
}
