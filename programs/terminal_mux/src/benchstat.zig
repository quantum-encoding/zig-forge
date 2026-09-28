//! What the benchmarks share: a metric's samples, their summary, and how a
//! metric is written into a report — one shape for every number, so a runner
//! (scripts/bench-run.py) can compare any metric between two runs without
//! knowing what it measures.
//!
//! In the report every metric is
//!   {"unit", "higher_is_better", "trend_only", "n", "median", "min", "max", "mean", "p90", "p99", "samples"}
//!
//! `trend_only` marks a number that describes rather than judges (frames per
//! second: fewer frames for the same output can be the better outcome), so a
//! comparison shows it but never calls it better or worse.

const std = @import("std");
const Stringify = std.json.Stringify;

pub fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub const Metric = struct {
    name: []const u8,
    unit: []const u8,
    /// A larger number is the better one (throughput), or not (latency).
    higher_is_better: bool,
    trend_only: bool = false,
    samples: std.ArrayList(f64) = .empty,

    pub fn add(self: *Metric, alloc: std.mem.Allocator, v: f64) !void {
        try self.samples.append(alloc, v);
    }

    pub fn deinit(self: *Metric, alloc: std.mem.Allocator) void {
        self.samples.deinit(alloc);
    }

    pub fn summary(self: *const Metric, alloc: std.mem.Allocator) !Summary {
        const s = try alloc.dupe(f64, self.samples.items);
        defer alloc.free(s);
        std.mem.sort(f64, s, {}, std.sort.asc(f64));
        return summarize(s);
    }

    pub fn write(self: *const Metric, s: *Stringify, alloc: std.mem.Allocator) !void {
        const sm = try self.summary(alloc);
        try s.objectField(self.name);
        try s.beginObject();
        try s.objectField("unit");
        try s.write(self.unit);
        try s.objectField("higher_is_better");
        try s.write(self.higher_is_better);
        try s.objectField("trend_only");
        try s.write(self.trend_only);
        try s.objectField("n");
        try s.write(sm.n);
        inline for (.{ "median", "min", "max", "mean", "p90", "p99" }) |f| {
            try s.objectField(f);
            try s.write(@field(sm, f));
        }
        try s.objectField("samples");
        try s.write(self.samples.items);
        try s.endObject();
    }

    /// One row of the human table.
    pub fn printRow(self: *const Metric, alloc: std.mem.Allocator) !void {
        const sm = try self.summary(alloc);
        std.debug.print("| {s} | {d:.3} | {d:.3} | {d:.3} | {d:.3} | {s} | {d} |\n", .{ self.name, sm.median, sm.min, sm.max, sm.p99, self.unit, sm.n });
    }
};

pub fn printHeader() void {
    std.debug.print("| metric | median | min | max | p99 | unit | n |\n|---|---:|---:|---:|---:|---|---:|\n", .{});
}

pub const Summary = struct {
    n: usize,
    median: f64,
    min: f64,
    max: f64,
    mean: f64,
    p90: f64,
    p99: f64,
};

/// Nearest-rank percentile of sorted samples (q in 0..1).
fn pct(sorted: []const f64, q: f64) f64 {
    const last: f64 = @floatFromInt(sorted.len - 1);
    const i: usize = @intFromFloat(@round(q * last));
    return sorted[@min(i, sorted.len - 1)];
}

pub fn summarize(sorted: []const f64) Summary {
    if (sorted.len == 0) return .{ .n = 0, .median = 0, .min = 0, .max = 0, .mean = 0, .p90 = 0, .p99 = 0 };
    const mid = sorted.len / 2;
    var sum: f64 = 0;
    for (sorted) |v| sum += v;
    return .{
        .n = sorted.len,
        .median = if (sorted.len % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2,
        .min = sorted[0],
        .max = sorted[sorted.len - 1],
        .mean = sum / @as(f64, @floatFromInt(sorted.len)),
        .p90 = pct(sorted, 0.90),
        .p99 = pct(sorted, 0.99),
    };
}

pub fn writeAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const r = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (r <= 0) return error.WriteFailed;
        off += @intCast(r);
    }
}

test "summary: median, extremes, mean and percentiles" {
    const odd = summarize(&.{ 1, 2, 9 });
    try std.testing.expectEqual(@as(f64, 2), odd.median);
    try std.testing.expectEqual(@as(f64, 4), odd.mean);
    try std.testing.expectEqual(@as(f64, 2.5), summarize(&.{ 1, 2, 3, 9 }).median);
    var hundred: [100]f64 = undefined;
    for (&hundred, 0..) |*v, i| v.* = @floatFromInt(i + 1);
    const h = summarize(&hundred);
    try std.testing.expectEqual(@as(f64, 1), h.min);
    try std.testing.expectEqual(@as(f64, 100), h.max);
    try std.testing.expectEqual(@as(f64, 90), h.p90);
    try std.testing.expectEqual(@as(f64, 99), h.p99);
    try std.testing.expectEqual(@as(usize, 0), summarize(&.{}).n);
}
