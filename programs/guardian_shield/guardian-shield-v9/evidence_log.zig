// evidence_log.zig
// Bounded, flood-resistant event logging for the Guardian Shield loader.
//
// Why this exists: the loader used to append every kernel event to one
// uncapped file on `/`. One looping agent shell (a zsh retrying a denied
// unlink of ~/.zsh_history.LOCK ~33x/s for two hours) grew it to 34 GB and
// filled the root filesystem. That is also an attack: flood the log, fill the
// drive, and both availability and the evidence trail go with it. Write
// failures were ignored, so the gap left no trace either.
//
// What this module guarantees instead:
//
//   * Amplification is gone. An event identical to one seen in the current
//     window (same event, verdict, pid, comm, paths, target) is counted, not
//     written; each window with repeats ends in ONE `repeat` summary carrying
//     the count, the first/last timestamps and the original event. A flood of
//     N identical events costs ~N/(rate*window) lines, not N.
//   * Two outputs with different jobs:
//       - the FEED (`log_file`, world-readable, as `baton shield` expects) is
//         a convenience view, capped at `feed_max_bytes` with one rotated copy;
//       - the EVIDENCE record (`evidence_dir`) is root-only (0640 files in a
//         0750 dir), rotated into segments and hash-chained: every line carries
//         `seq`, `wall_ms` and `prev` = SHA-256 of the previous line, and the
//         chain continues across segment rotation and loader restarts. A
//         truncated, edited or reordered record fails verification.
//   * Evidence never lands on `/`. `evidence_dir`'s parent must be on a
//     different filesystem from `/` (a dedicated volume). If it is not
//     mounted, evidence writes are refused and retried, instead of silently
//     recreating the directory on the root filesystem.
//   * Loss is recorded. A failed or short write is counted; the next write
//     that succeeds is preceded by a `log_gap` record with the count.
//   * Low space degrades, it does not fill. Below `min_free_bytes` on the
//     evidence volume, full events are withheld and only a periodic
//     `evidence_withheld` count is written, so the reserve records that
//     something happened even when there is no room to say everything.
//   * The daemon never deletes evidence. Retention is an operator decision
//     (or an off-box shipper's), not something a flood can trigger.
//
// Logging must never take enforcement down: every function here is
// best-effort and returns nothing that the caller has to handle.

const std = @import("std");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/statvfs.h");
    @cInclude("dirent.h");
    @cInclude("errno.h");
    @cInclude("time.h");
    @cInclude("string.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Config = struct {
    /// Live feed (world-readable). Empty = no feed.
    feed_path: []const u8 = "",
    feed_max_bytes: u64 = 64 << 20,
    /// Evidence directory on a dedicated volume. Empty = no evidence record.
    evidence_dir: []const u8 = "",
    segment_max_bytes: u64 = 256 << 20,
    min_free_bytes: u64 = 1 << 30,
    repeat_window_ns: u64 = 30 * std.time.ns_per_s,
    /// Refuse evidence writes unless evidence_dir's parent is a different
    /// filesystem from `/`. Only tests turn this off.
    require_separate_fs: bool = true,
};

const MAX_LINE = 4096;
const MAX_SAMPLE = 1024;
const TABLE_SIZE = 1024; // power of two
const PROBE = 8;
const SEGMENT_PREFIX = "guardian-";
const SEGMENT_SUFFIX = ".jsonl";

const Entry = struct {
    used: bool = false,
    key: u64 = 0,
    window_start: u64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,
    last_seen: u64 = 0,
    count: u64 = 0, // suppressed repeats in the current window
    sample_len: usize = 0,
    sample: [MAX_SAMPLE]u8 = undefined,
};

pub const Sink = struct {
    cfg: Config,

    feed_fd: c_int = -1,
    feed_bytes: u64 = 0,

    ev_fd: c_int = -1,
    ev_bytes: u64 = 0,
    ev_segment: [256]u8 = undefined,
    ev_segment_len: usize = 0,
    ev_warned: bool = false,
    ev_last_attempt: u64 = 0,
    ev_low_space: bool = false,
    ev_withheld: u64 = 0,

    seq: u64 = 0,
    prev: [32]u8 = [_]u8{0} ** 32,
    chain_started: bool = false,

    lost_feed: u64 = 0,
    lost_evidence: u64 = 0,
    suppressed_total: u64 = 0,

    last_tick: u64 = 0,
    table: [TABLE_SIZE]Entry = [_]Entry{.{}} ** TABLE_SIZE,

    /// Open both outputs. Never fails: an output that cannot be opened is
    /// retried from `tick`.
    pub fn init(self: *Sink, cfg: Config, now: u64) void {
        self.* = .{ .cfg = cfg };
        self.openFeed();
        self.tryOpenEvidence(now);
    }

    pub fn deinit(self: *Sink, now: u64) void {
        self.flushAll(now);
        if (self.feed_fd >= 0) _ = c.close(self.feed_fd);
        if (self.ev_fd >= 0) {
            _ = c.fsync(self.ev_fd);
            _ = c.close(self.ev_fd);
        }
        self.feed_fd = -1;
        self.ev_fd = -1;
    }

    /// Record one event. `key` identifies "the same event" (the caller hashes
    /// every field except the timestamp); `line` is its JSON object, no
    /// newline. Returns true when the line was written, false when it was
    /// counted as a repeat — callers use this to keep their own side output
    /// (the journal) from amplifying the flood too.
    pub fn record(self: *Sink, key: u64, line: []const u8, now: u64) bool {
        const e = self.lookup(key, now);
        if (e.used and e.key == key) {
            e.last_seen = now;
            if (now -| e.window_start < self.cfg.repeat_window_ns) {
                if (e.count == 0) e.first_ns = now;
                e.count += 1;
                e.last_ns = now;
                self.suppressed_total += 1;
                return false;
            }
            self.flushEntry(e, now);
            e.window_start = now;
        } else {
            e.* = .{
                .used = true,
                .key = key,
                .window_start = now,
                .last_seen = now,
            };
        }
        const n = @min(line.len, MAX_SAMPLE);
        @memcpy(e.sample[0..n], line[0..n]);
        e.sample_len = if (line.len <= MAX_SAMPLE) n else 0; // never splice a cut object
        self.emit(line);
        return true;
    }

    /// Periodic housekeeping: close repeat windows, retry the evidence
    /// volume, check free space, report withheld events. Call often (it is
    /// cheap when nothing is due).
    pub fn tick(self: *Sink, now: u64) void {
        for (&self.table) |*e| {
            if (!e.used) continue;
            if (e.count > 0 and now -| e.window_start >= self.cfg.repeat_window_ns) {
                self.flushEntry(e, now);
                e.window_start = now;
            } else if (e.count == 0 and now -| e.last_seen >= 4 * self.cfg.repeat_window_ns) {
                e.used = false;
            }
        }
        if (now -| self.last_tick < 10 * std.time.ns_per_s) return;
        self.last_tick = now;

        if (self.ev_fd < 0) self.tryOpenEvidence(now);
        self.checkSpace();
        if (self.ev_withheld > 0 and self.ev_fd >= 0) {
            var buf: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{{\"event\":\"evidence_withheld\",\"count\":{d},\"reason\":\"low_space\",\"min_free_bytes\":{d}}}", .{ self.ev_withheld, self.cfg.min_free_bytes }) catch return;
            if (self.writeEvidenceForced(s)) self.ev_withheld = 0;
        }
    }

    // ── dedup table ──────────────────────────────────────────────────────

    fn lookup(self: *Sink, key: u64, now: u64) *Entry {
        const mask = TABLE_SIZE - 1;
        var victim: *Entry = &self.table[key & mask];
        var i: usize = 0;
        while (i < PROBE) : (i += 1) {
            const e = &self.table[(key +% i) & mask];
            if (!e.used or e.key == key) return e;
            if (e.last_seen < victim.last_seen) victim = e;
        }
        // Full neighbourhood: evict the stalest, reporting what it held.
        self.flushEntry(victim, now);
        victim.used = false;
        return victim;
    }

    fn flushEntry(self: *Sink, e: *Entry, now: u64) void {
        _ = now;
        if (e.count == 0) return;
        var buf: [MAX_LINE]u8 = undefined;
        const of: []const u8 = if (e.sample_len > 0) e.sample[0..e.sample_len] else "null";
        const s = std.fmt.bufPrint(&buf, "{{\"event\":\"repeat\",\"count\":{d},\"window_s\":{d},\"first_ts_ns\":{d},\"last_ts_ns\":{d},\"of\":{s}}}", .{
            e.count,
            self.cfg.repeat_window_ns / std.time.ns_per_s,
            e.first_ns,
            e.last_ns,
            of,
        }) catch return;
        e.count = 0;
        self.emit(s);
    }

    fn flushAll(self: *Sink, now: u64) void {
        for (&self.table) |*e| {
            if (e.used) self.flushEntry(e, now);
        }
    }

    // ── output ───────────────────────────────────────────────────────────

    fn emit(self: *Sink, line: []const u8) void {
        self.writeFeed(line);
        if (self.ev_low_space) {
            self.ev_withheld += 1;
            return;
        }
        _ = self.writeEvidence(line);
    }

    fn writeAll(fd: c_int, bytes: []const u8) bool {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(fd, bytes.ptr + off, bytes.len - off);
            if (n < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                return false;
            }
            if (n == 0) return false;
            off += @intCast(n);
        }
        return true;
    }

    fn openFeed(self: *Sink) void {
        if (self.cfg.feed_path.len == 0) return;
        var zb: [512]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zb, "{s}", .{self.cfg.feed_path}) catch return;
        const fd = c.open(z.ptr, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_CLOEXEC, @as(c_uint, 0o644));
        if (fd < 0) return;
        var st: c.struct_stat = undefined;
        self.feed_bytes = if (c.fstat(fd, &st) == 0) @intCast(st.st_size) else 0;
        self.feed_fd = fd;
    }

    fn writeFeed(self: *Sink, line: []const u8) void {
        if (self.feed_fd < 0) return;
        if (self.feed_bytes + line.len + 1 > self.cfg.feed_max_bytes) self.rotateFeed();
        if (self.feed_fd < 0) return;
        if (self.lost_feed > 0) {
            var gb: [128]u8 = undefined;
            const g = std.fmt.bufPrint(&gb, "{{\"event\":\"log_gap\",\"lost_events\":{d}}}\n", .{self.lost_feed}) catch "";
            if (writeAll(self.feed_fd, g)) {
                self.feed_bytes += g.len;
                self.lost_feed = 0;
            }
        }
        var buf: [MAX_LINE + 1]u8 = undefined;
        const out = joinNewline(&buf, line) orelse return;
        if (writeAll(self.feed_fd, out)) {
            self.feed_bytes += out.len;
        } else {
            self.lost_feed += 1;
        }
    }

    /// The feed keeps exactly one previous generation: it is a view, and the
    /// evidence record is the complete copy.
    fn rotateFeed(self: *Sink) void {
        var zb: [512]u8 = undefined;
        var zb1: [520]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zb, "{s}", .{self.cfg.feed_path}) catch return;
        const z1 = std.fmt.bufPrintZ(&zb1, "{s}.1", .{self.cfg.feed_path}) catch return;
        _ = c.close(self.feed_fd);
        self.feed_fd = -1;
        _ = c.rename(z.ptr, z1.ptr);
        self.openFeed();
    }

    fn evidenceParentIsSeparate(self: *Sink) bool {
        if (!self.cfg.require_separate_fs) return true;
        const parent = std.fs.path.dirname(self.cfg.evidence_dir) orelse return false;
        var zb: [512]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zb, "{s}", .{parent}) catch return false;
        var st_parent: c.struct_stat = undefined;
        var st_root: c.struct_stat = undefined;
        if (c.stat(z.ptr, &st_parent) != 0) return false;
        if (c.stat("/", &st_root) != 0) return false;
        return st_parent.st_dev != st_root.st_dev;
    }

    fn tryOpenEvidence(self: *Sink, now: u64) void {
        if (self.cfg.evidence_dir.len == 0) return;
        self.ev_last_attempt = now;
        if (!self.evidenceParentIsSeparate()) {
            if (!self.ev_warned) {
                self.ev_warned = true;
                std.log.warn("evidence dir '{s}' is not on a separate, mounted filesystem - evidence writes refused (retrying every 10s) so a flood cannot fill '/'", .{self.cfg.evidence_dir});
            }
            return;
        }
        var zb: [512]u8 = undefined;
        const zdir = std.fmt.bufPrintZ(&zb, "{s}", .{self.cfg.evidence_dir}) catch return;
        _ = c.mkdir(zdir.ptr, 0o750);
        _ = c.chmod(zdir.ptr, 0o750);
        if (!self.chain_started) self.resumeChain();
        self.openSegment();
        if (self.ev_fd < 0) return;
        self.ev_warned = false;
        self.checkSpace();
        var buf: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{{\"event\":\"chain_start\",\"reason\":\"{s}\",\"segment\":\"{s}\"}}", .{
            if (self.seq == 0) "new_chain" else "loader_start",
            self.ev_segment[0..self.ev_segment_len],
        }) catch return;
        _ = self.writeEvidenceForced(s);
        self.chain_started = true;
    }

    /// Continue the chain from the newest existing segment: seq and prev are
    /// recomputed from its last line, so a restart does not break
    /// verification — and a newest segment whose tail was cut shows up as a
    /// mismatch there, not as a silent reset here.
    fn resumeChain(self: *Sink) void {
        var name_buf: [256]u8 = undefined;
        const newest = self.newestSegment(&name_buf) orelse return;
        var pb: [768]u8 = undefined;
        const path = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ self.cfg.evidence_dir, newest }) catch return;
        const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) return;
        defer _ = c.close(fd);
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0 or st.st_size <= 0) return;
        const size: u64 = @intCast(st.st_size);
        var tail: [MAX_LINE * 2]u8 = undefined;
        const want: u64 = @min(size, tail.len);
        const got = c.pread(fd, &tail, want, @intCast(size - want));
        if (got <= 0) return;
        const t = tail[0..@intCast(got)];
        const last = lastLine(t) orelse return;
        Sha256.hash(last, &self.prev, .{});
        self.seq = parseSeq(last) orelse 0;
    }

    fn newestSegment(self: *Sink, out: *[256]u8) ?[]const u8 {
        var zb: [512]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zb, "{s}", .{self.cfg.evidence_dir}) catch return null;
        const d = c.opendir(z.ptr) orelse return null;
        defer _ = c.closedir(d);
        var best_len: usize = 0;
        while (c.readdir(d)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
            if (!std.mem.startsWith(u8, name, SEGMENT_PREFIX) or !std.mem.endsWith(u8, name, SEGMENT_SUFFIX)) continue;
            if (name.len > out.len) continue;
            if (best_len == 0 or std.mem.order(u8, name, out[0..best_len]) == .gt) {
                @memcpy(out[0..name.len], name);
                best_len = name.len;
            }
        }
        return if (best_len == 0) null else out[0..best_len];
    }

    fn openSegment(self: *Sink) void {
        // Name sorts chronologically: UTC start time, then the next seq, so
        // two segments opened within one second still order correctly.
        const t = c.time(null);
        var tmv: c.struct_tm = undefined;
        _ = c.gmtime_r(&t, &tmv);
        const name = std.fmt.bufPrint(&self.ev_segment, SEGMENT_PREFIX ++ "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z-{d:0>12}" ++ SEGMENT_SUFFIX, .{
            @as(u32, @intCast(tmv.tm_year + 1900)),
            @as(u32, @intCast(tmv.tm_mon + 1)),
            @as(u32, @intCast(tmv.tm_mday)),
            @as(u32, @intCast(tmv.tm_hour)),
            @as(u32, @intCast(tmv.tm_min)),
            @as(u32, @intCast(tmv.tm_sec)),
            self.seq + 1,
        }) catch return;
        self.ev_segment_len = name.len;
        var pb: [768]u8 = undefined;
        const path = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ self.cfg.evidence_dir, name }) catch return;
        const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_CLOEXEC, @as(c_uint, 0o640));
        if (fd < 0) return;
        _ = c.fchmod(fd, 0o640);
        var st: c.struct_stat = undefined;
        self.ev_bytes = if (c.fstat(fd, &st) == 0) @intCast(st.st_size) else 0;
        self.ev_fd = fd;
    }

    fn rotateSegment(self: *Sink) void {
        var prev_name: [256]u8 = undefined;
        const plen = self.ev_segment_len;
        @memcpy(prev_name[0..plen], self.ev_segment[0..plen]);
        _ = c.fsync(self.ev_fd);
        // A closed segment is finished: mark it read-only (a signal, and a
        // guard against accidental appends — root can still write it).
        _ = c.fchmod(self.ev_fd, 0o440);
        _ = c.close(self.ev_fd);
        self.ev_fd = -1;
        self.openSegment();
        if (self.ev_fd < 0) return;
        var buf: [640]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{{\"event\":\"segment_start\",\"prev_segment\":\"{s}\"}}", .{prev_name[0..plen]}) catch return;
        _ = self.writeEvidenceForced(s);
    }

    fn checkSpace(self: *Sink) void {
        if (self.ev_fd < 0) return;
        var sv: c.struct_statvfs = undefined;
        if (c.fstatvfs(self.ev_fd, &sv) != 0) return;
        const free: u64 = @as(u64, @intCast(sv.f_bavail)) * @as(u64, @intCast(sv.f_frsize));
        self.ev_low_space = free < self.cfg.min_free_bytes;
    }

    fn writeEvidence(self: *Sink, line: []const u8) bool {
        if (self.ev_fd < 0) {
            if (self.cfg.evidence_dir.len > 0) self.lost_evidence += 1;
            return false;
        }
        if (self.lost_evidence > 0) {
            var gb: [128]u8 = undefined;
            const g = std.fmt.bufPrint(&gb, "{{\"event\":\"log_gap\",\"lost_events\":{d}}}", .{self.lost_evidence}) catch "";
            const lost = self.lost_evidence;
            self.lost_evidence = 0;
            if (!self.writeEvidenceForced(g)) {
                self.lost_evidence = lost + 1;
                return false;
            }
        }
        if (self.ev_bytes >= self.cfg.segment_max_bytes) self.rotateSegment();
        if (!self.writeEvidenceForced(line)) {
            self.lost_evidence += 1;
            return false;
        }
        return true;
    }

    /// Append one chained line: `{…original…,"seq":N,"wall_ms":T,"prev":"<hex>"}`.
    /// `prev` is SHA-256 of the previous line as written (without newline).
    fn writeEvidenceForced(self: *Sink, line: []const u8) bool {
        if (self.ev_fd < 0) return false;
        if (line.len < 2 or line[line.len - 1] != '}') return false;
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
        const wall_ms: u64 = @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
        const hex = std.fmt.bytesToHex(self.prev, .lower);
        var buf: [MAX_LINE + 256]u8 = undefined;
        const sep: []const u8 = if (line.len == 2) "" else ",";
        const body = std.fmt.bufPrint(&buf, "{s}{s}\"seq\":{d},\"wall_ms\":{d},\"prev\":\"{s}\"}}", .{
            line[0 .. line.len - 1],
            sep,
            self.seq + 1,
            wall_ms,
            hex,
        }) catch return false;
        if (body.len + 1 > buf.len) return false;
        buf[body.len] = '\n';
        const out = buf[0 .. body.len + 1];
        if (!writeAll(self.ev_fd, out)) return false;
        self.ev_bytes += out.len;
        self.seq += 1;
        Sha256.hash(body, &self.prev, .{});
        return true;
    }
};

fn joinNewline(buf: []u8, line: []const u8) ?[]const u8 {
    if (line.len + 1 > buf.len) return null;
    @memcpy(buf[0..line.len], line);
    buf[line.len] = '\n';
    return buf[0 .. line.len + 1];
}

fn lastLine(t: []const u8) ?[]const u8 {
    var end = t.len;
    while (end > 0 and t[end - 1] == '\n') end -= 1;
    if (end == 0) return null;
    const start = if (std.mem.lastIndexOfScalar(u8, t[0..end], '\n')) |i| i + 1 else 0;
    // A tail window that began mid-line cannot be trusted as a whole line.
    if (start == 0 and t.len == MAX_LINE * 2) return null;
    return t[start..end];
}

fn parseSeq(line: []const u8) ?u64 {
    const tag = "\"seq\":";
    const i = std.mem.lastIndexOf(u8, line, tag) orelse return null;
    var j = i + tag.len;
    var v: u64 = 0;
    var any = false;
    while (j < line.len and line[j] >= '0' and line[j] <= '9') : (j += 1) {
        v = v * 10 + (line[j] - '0');
        any = true;
    }
    return if (any) v else null;
}

/// Verify an evidence segment sequence: each line's `prev` must equal the
/// SHA-256 of the line before it, and `seq` must increase by one. Used by
/// the tests and by `--verify-evidence`. Returns the number of lines checked,
/// or error.ChainBroken with the 1-based line number in `bad_line`.
pub fn verifyChain(data: []const u8, start_prev: [32]u8, start_seq: u64, bad_line: *usize) !struct { lines: usize, prev: [32]u8, seq: u64 } {
    var prev = start_prev;
    var seq = start_seq;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        n += 1;
        const tag = "\"prev\":\"";
        const i = std.mem.lastIndexOf(u8, line, tag) orelse {
            bad_line.* = n;
            return error.ChainBroken;
        };
        const h = line[i + tag.len ..];
        if (h.len < 64) {
            bad_line.* = n;
            return error.ChainBroken;
        }
        const want = std.fmt.bytesToHex(prev, .lower);
        const got_seq = parseSeq(line) orelse 0;
        if (!std.mem.eql(u8, h[0..64], &want) or got_seq != seq + 1) {
            bad_line.* = n;
            return error.ChainBroken;
        }
        Sha256.hash(line, &prev, .{});
        seq = got_seq;
    }
    return .{ .lines = n, .prev = prev, .seq = seq };
}

/// Result of verifying a whole evidence directory.
pub const DirReport = struct {
    segments: usize = 0,
    lines: usize = 0,
    /// Set when the chain breaks: the segment name and 1-based line in it.
    bad_segment: ?[]u8 = null,
    bad_line: usize = 0,
};

/// Verify every segment in `dir`, in chronological order, as ONE chain.
/// Streams each file (segments can be hundreds of MB). A missing, cut,
/// edited or reordered line anywhere shows up as the first bad line.
pub fn verifyDir(alloc: std.mem.Allocator, dir: []const u8) !DirReport {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    {
        var zb: [512]u8 = undefined;
        const z = try std.fmt.bufPrintZ(&zb, "{s}", .{dir});
        const d = c.opendir(z.ptr) orelse return error.OpenDirFailed;
        defer _ = c.closedir(d);
        while (c.readdir(d)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
            if (!std.mem.startsWith(u8, name, SEGMENT_PREFIX) or !std.mem.endsWith(u8, name, SEGMENT_SUFFIX)) continue;
            try names.append(alloc, try alloc.dupe(u8, name));
        }
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var rep: DirReport = .{};
    var prev = [_]u8{0} ** 32;
    var seq: u64 = 0;
    const chunk = try alloc.alloc(u8, 1 << 16);
    defer alloc.free(chunk);
    const carry = try alloc.alloc(u8, MAX_LINE * 2 + 256);
    defer alloc.free(carry);

    for (names.items) |name| {
        rep.segments += 1;
        var pb: [768]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, name });
        const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);
        var carry_len: usize = 0;
        var line_no: usize = 0;
        while (true) {
            const n = c.read(fd, chunk.ptr, chunk.len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            var data = chunk[0..@intCast(n)];
            while (std.mem.indexOfScalar(u8, data, '\n')) |nl| {
                const piece = data[0..nl];
                data = data[nl + 1 ..];
                const line = if (carry_len > 0) blk: {
                    if (carry_len + piece.len > carry.len) return error.LineTooLong;
                    @memcpy(carry[carry_len .. carry_len + piece.len], piece);
                    const l = carry[0 .. carry_len + piece.len];
                    carry_len = 0;
                    break :blk l;
                } else piece;
                if (line.len == 0) continue;
                line_no += 1;
                var bad: usize = 0;
                const r = verifyChain(line, prev, seq, &bad) catch {
                    rep.bad_segment = try alloc.dupe(u8, name);
                    rep.bad_line = line_no;
                    return rep;
                };
                prev = r.prev;
                seq = r.seq;
                rep.lines += 1;
            }
            if (carry_len + data.len > carry.len) return error.LineTooLong;
            @memcpy(carry[carry_len .. carry_len + data.len], data);
            carry_len += data.len;
        }
        if (carry_len > 0) {
            // A final line with no newline: a torn write, i.e. a cut record.
            rep.bad_segment = try alloc.dupe(u8, name);
            rep.bad_line = line_no + 1;
            return rep;
        }
    }
    return rep;
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpDir(buf: []u8) ![:0]const u8 {
    var tmpl: [64]u8 = undefined;
    const t = try std.fmt.bufPrintZ(&tmpl, "/tmp/gs-evtest-XXXXXX", .{});
    const p = c.mkdtemp(@constCast(t.ptr)) orelse return error.MkdtempFailed;
    const s = std.mem.sliceTo(p, 0);
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

fn readFile(path: []const u8, out: []u8) ![]u8 {
    var zb: [512]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&zb, "{s}", .{path});
    const fd = c.open(z.ptr, c.O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var total: usize = 0;
    while (total < out.len) {
        const n = c.read(fd, out.ptr + total, out.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return out[0..total];
}

/// Every segment in `dir`, concatenated in chronological (name) order.
fn allSegments(dir: []const u8, out: []u8) ![]u8 {
    var names: [16][256]u8 = undefined;
    var lens: [16]usize = undefined;
    var n: usize = 0;
    var zb: [512]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&zb, "{s}", .{dir});
    const d = c.opendir(z.ptr) orelse return error.OpenDirFailed;
    while (c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (!std.mem.startsWith(u8, name, SEGMENT_PREFIX)) continue;
        @memcpy(names[n][0..name.len], name);
        lens[n] = name.len;
        n += 1;
    }
    _ = c.closedir(d);
    // insertion sort by name
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, names[j][0..lens[j]], names[j - 1][0..lens[j - 1]]) == .lt) : (j -= 1) {
            std.mem.swap([256]u8, &names[j], &names[j - 1]);
            std.mem.swap(usize, &lens[j], &lens[j - 1]);
        }
    }
    var total: usize = 0;
    for (0..n) |k| {
        var pb: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, names[k][0..lens[k]] });
        const got = try readFile(path, out[total..]);
        total += got.len;
    }
    return out[0..total];
}

fn onlySegment(dir: []const u8, name_out: *[256]u8) ![]const u8 {
    var s: Sink = .{ .cfg = .{ .evidence_dir = dir } };
    return s.newestSegment(name_out) orelse error.NoSegment;
}

test "a flood of identical events becomes one line plus one repeat summary" {
    var db: [128]u8 = undefined;
    const dir = try tmpDir(&db);
    var fb: [256]u8 = undefined;
    const feed = try std.fmt.bufPrint(&fb, "{s}/feed.jsonl", .{dir});
    var eb: [256]u8 = undefined;
    const ev = try std.fmt.bufPrint(&eb, "{s}/evidence", .{dir});

    const s = try testing.allocator.create(Sink);
    defer testing.allocator.destroy(s);
    s.init(.{ .feed_path = feed, .evidence_dir = ev, .require_separate_fs = false, .min_free_bytes = 0 }, 1);

    const line = "{\"event\":\"unlink\",\"comm\":\"zsh\",\"path\":\"/home/u/.zsh_history.LOCK\"}";
    var written: usize = 0;
    var t: u64 = 10;
    for (0..100_000) |_| {
        if (s.record(42, line, t)) written += 1;
        t += 1000; // 100k events in 0.1 s
    }
    s.tick(t + 31 * std.time.ns_per_s);
    try testing.expectEqual(@as(usize, 1), written);
    try testing.expectEqual(@as(u64, 99_999), s.suppressed_total);

    var rb: [1 << 16]u8 = undefined;
    const f = try readFile(feed, &rb);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, f, "\n"));
    try testing.expect(std.mem.indexOf(u8, f, "\"event\":\"repeat\",\"count\":99999") != null);
    try testing.expect(std.mem.indexOf(u8, f, "\"of\":{\"event\":\"unlink\"") != null);
    s.deinit(t);
}

test "evidence lines are hash-chained and the chain survives a restart" {
    var db: [128]u8 = undefined;
    const dir = try tmpDir(&db);
    var eb: [256]u8 = undefined;
    const ev = try std.fmt.bufPrint(&eb, "{s}/evidence", .{dir});
    const cfg: Config = .{ .evidence_dir = ev, .require_separate_fs = false, .min_free_bytes = 0 };

    const s = try testing.allocator.create(Sink);
    defer testing.allocator.destroy(s);
    s.init(cfg, 1);
    _ = s.record(1, "{\"event\":\"a\"}", 2);
    _ = s.record(2, "{\"event\":\"b\"}", 3);
    s.deinit(4);
    const seq_after_first = s.seq;

    s.init(cfg, 5); // restart: must resume, not reset
    _ = s.record(3, "{\"event\":\"c\"}", 6);
    s.deinit(7);
    try testing.expect(s.seq > seq_after_first);

    // The restart opened a new segment; the chain runs across all of them.
    var rb: [1 << 16]u8 = undefined;
    const data = try allSegments(ev, &rb);
    var bad: usize = 0;
    const r = try verifyChain(data, [_]u8{0} ** 32, 0, &bad);
    try testing.expect(r.lines >= 5); // chain_start, a, b, chain_start, c
    try testing.expect(std.mem.indexOf(u8, data, "\"reason\":\"loader_start\"") != null);

    // Tamper: edit one byte of event "b" → verification must fail.
    var tampered: [1 << 16]u8 = undefined;
    @memcpy(tampered[0..data.len], data);
    const i = std.mem.indexOf(u8, tampered[0..data.len], "\"event\":\"b\"").?;
    tampered[i + 9] = 'x';
    try testing.expectError(error.ChainBroken, verifyChain(tampered[0..data.len], [_]u8{0} ** 32, 0, &bad));
}

test "segments rotate at the size cap and keep the chain across the boundary" {
    var db: [128]u8 = undefined;
    const dir = try tmpDir(&db);
    var eb: [256]u8 = undefined;
    const ev = try std.fmt.bufPrint(&eb, "{s}/evidence", .{dir});
    const s = try testing.allocator.create(Sink);
    defer testing.allocator.destroy(s);
    s.init(.{ .evidence_dir = ev, .require_separate_fs = false, .min_free_bytes = 0, .segment_max_bytes = 400 }, 1);
    for (0..20) |k| _ = s.record(@intCast(k + 100), "{\"event\":\"distinct\"}", 10 + k);
    s.deinit(100);
    // More than one segment, and the newest starts with segment_start.
    var nb: [256]u8 = undefined;
    const name = try onlySegment(ev, &nb);
    var pb: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ ev, name });
    var rb: [1 << 16]u8 = undefined;
    const data = try readFile(path, &rb);
    try testing.expect(std.mem.startsWith(u8, data, "{\"event\":\"segment_start\""));
    var ab: [1 << 16]u8 = undefined;
    const whole = try allSegments(ev, &ab);
    var bad: usize = 0;
    const r = try verifyChain(whole, [_]u8{0} ** 32, 0, &bad);
    try testing.expect(r.lines >= 21);

    const rep = try verifyDir(testing.allocator, ev);
    try testing.expect(rep.bad_segment == null);
    try testing.expect(rep.segments > 1);
    try testing.expectEqual(r.lines, rep.lines);
}

test "evidence is refused when its parent is on the root filesystem" {
    // The refusal logs a warning by design; the build's test runner would
    // count that as a failure, so hide it for this test only.
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const s = try testing.allocator.create(Sink);
    defer testing.allocator.destroy(s);
    // /tmp may be tmpfs (separate) on some hosts; /var is on / on most. Use a
    // path whose parent is certainly the root filesystem itself.
    s.init(.{ .evidence_dir = "/gs-evidence-should-not-exist", .require_separate_fs = true }, 1);
    try testing.expect(s.ev_fd < 0);
    try testing.expect(!s.record(1, "{\"event\":\"x\"}", 2) or s.ev_fd < 0);
    var st: c.struct_stat = undefined;
    try testing.expect(c.stat("/gs-evidence-should-not-exist", &st) != 0);
    s.deinit(3);
}

test "the feed is capped and keeps one previous generation" {
    var db: [128]u8 = undefined;
    const dir = try tmpDir(&db);
    var fb: [256]u8 = undefined;
    const feed = try std.fmt.bufPrint(&fb, "{s}/feed.jsonl", .{dir});
    const s = try testing.allocator.create(Sink);
    defer testing.allocator.destroy(s);
    s.init(.{ .feed_path = feed, .feed_max_bytes = 1000 }, 1);
    for (0..500) |k| _ = s.record(@intCast(k), "{\"event\":\"distinct-event-padding-padding\"}", 10 + k);
    s.deinit(1000);
    var zb: [300]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&zb, "{s}", .{feed});
    var st: c.struct_stat = undefined;
    try testing.expect(c.stat(z.ptr, &st) == 0);
    try testing.expect(st.st_size <= 1000);
    var z1b: [300]u8 = undefined;
    const z1 = try std.fmt.bufPrintZ(&z1b, "{s}.1", .{feed});
    try testing.expect(c.stat(z1.ptr, &st) == 0);
    try testing.expect(st.st_size <= 1000);
}
