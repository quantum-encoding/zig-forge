// Reflog — append-only log of every ref movement.
//
// On disk each ref has a parallel log file under .git/logs/. The
// branch ref `refs/heads/main` has its log at `.git/logs/refs/heads/main`,
// and the symbolic HEAD ref has its log at `.git/logs/HEAD`. When HEAD
// is a symref pointing at a branch, ref updates to that branch ALSO
// append to HEAD's log — which is what makes `git reflog` (no args)
// equivalent to `git reflog show HEAD`.
//
// Wire format (one entry per line, tab-separated message):
//
//   <40-hex old> <40-hex new> <Name> <email> <unix-ts> <tz>\t<message>\n
//
// `<Name>` may contain spaces; `<email>` is wrapped in `<>` braces.
// We always emit `+0000` for the timezone, matching what zigit's
// commit-tree path does (real git looks up the local TZ — a libc
// detour we don't link for).
//
// Public surface:
//
//   appendForRef(...)      — write one entry to a single log
//   logUpdate(...)         — convenience: write to ref's log AND
//                            (if HEAD points at it) to HEAD's log too
//   logHeadCheckout(...)   — special form for switch/checkout — only
//                            HEAD's log moves; the branch refs don't
//
// Reading:
//
//   Entries(...) iterator   — cheap line-by-line walk for `reflog show`

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Oid = @import("object/oid.zig").Oid;

pub const Identity = struct {
    name: []const u8,
    email: []const u8,
};

/// Resolve a reflog identity from env vars + ~/.gitconfig, falling
/// back to "zigit"/"zigit@local" if neither is available. Caller
/// owns the returned strings (`allocator.free` on `name` and `email`).
pub fn identityFromEnviron(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    git_dir: Dir,
) !Identity {
    var cfg = @import("config.zig").loadWithGlobal(allocator, io, environ, git_dir) catch
        @import("config.zig").Config{ .arena = .init(allocator) };
    defer cfg.deinit();

    const env_name = environ.getPosix("GIT_COMMITTER_NAME") orelse environ.getPosix("GIT_AUTHOR_NAME");
    const env_email = environ.getPosix("GIT_COMMITTER_EMAIL") orelse environ.getPosix("GIT_AUTHOR_EMAIL");

    const name = if (env_name) |n|
        try allocator.dupe(u8, n)
    else if (cfg.get("user.name")) |n|
        try allocator.dupe(u8, n)
    else
        try allocator.dupe(u8, "zigit");
    errdefer allocator.free(name);

    const email = if (env_email) |e|
        try allocator.dupe(u8, e)
    else if (cfg.get("user.email")) |e|
        try allocator.dupe(u8, e)
    else
        try allocator.dupe(u8, "zigit@local");

    return .{ .name = name, .email = email };
}

pub fn deinitIdentity(allocator: std.mem.Allocator, id: Identity) void {
    allocator.free(id.name);
    allocator.free(id.email);
}

/// Pick a unix timestamp: GIT_COMMITTER_DATE if set, otherwise
/// GIT_AUTHOR_DATE, otherwise the system clock.
pub fn timestampFromEnviron(io: Io, environ: std.process.Environ) !i64 {
    if (environ.getPosix("GIT_COMMITTER_DATE")) |v| return try std.fmt.parseInt(i64, v, 10);
    if (environ.getPosix("GIT_AUTHOR_DATE")) |v| return try std.fmt.parseInt(i64, v, 10);
    const now: std.Io.Timestamp = .now(io, .real);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
}

pub const head_path = "HEAD";
pub const head_log_path = "logs/HEAD";

pub const zero_oid_hex: [40]u8 = @splat('0');

/// Append a single reflog entry to the log for `ref_name`. `ref_name`
/// is e.g. "refs/heads/main" or "HEAD"; the log path is
/// `.git/logs/<ref_name>`. Creates parent dirs as needed.
pub fn appendForRef(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    ref_name: []const u8,
    old_oid: ?Oid,
    new_oid: ?Oid,
    who: Identity,
    when: i64,
    message: []const u8,
) !void {
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&path_buf, "logs/{s}", .{ref_name});
    if (std.fs.path.dirname(log_path)) |parent| {
        try git_dir.createDirPath(io, parent);
    }

    var old_hex: [40]u8 = zero_oid_hex;
    if (old_oid) |o| o.toHex(&old_hex);
    var new_hex: [40]u8 = zero_oid_hex;
    if (new_oid) |o| o.toHex(&new_hex);

    // Build the line in an Allocating writer (message length is unbounded).
    var allocating: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer allocating.deinit();
    const w = &allocating.writer;
    try w.print("{s} {s} {s} <{s}> {d} +0000\t{s}\n", .{
        old_hex, new_hex, who.name, who.email, when, message,
    });

    // Append: open the file (or create it), seek-write at its current
    // length. std.Io.File doesn't expose seek() on its own — use
    // writePositionalAll with the file's length as the offset.
    var f = git_dir.openFile(io, log_path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try git_dir.createFile(io, log_path, .{ .read = false }),
        else => return err,
    };
    defer f.close(io);
    const len = try f.length(io);
    try f.writePositionalAll(io, allocating.written(), len);
}

/// Write a reflog entry for an updated ref AND, if HEAD is a symref
/// pointing at that ref, mirror the entry to HEAD's log. This is the
/// usual "I just moved a branch tip" case (commit, merge, push reset, …).
pub fn logUpdate(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    ref_name: []const u8,
    old_oid: ?Oid,
    new_oid: ?Oid,
    who: Identity,
    when: i64,
    message: []const u8,
) !void {
    try appendForRef(allocator, io, git_dir, ref_name, old_oid, new_oid, who, when, message);

    if (try headSymrefTarget(allocator, io, git_dir)) |target| {
        defer allocator.free(target);
        if (std.mem.eql(u8, target, ref_name)) {
            try appendForRef(allocator, io, git_dir, head_path, old_oid, new_oid, who, when, message);
        }
    }
}

/// Special form for switch/checkout: only HEAD's log moves (the
/// branch refs themselves stay where they are). Caller supplies the
/// before/after oids.
pub fn logHeadCheckout(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    old_oid: Oid,
    new_oid: Oid,
    from_branch: []const u8,
    to_branch: []const u8,
    who: Identity,
    when: i64,
) !void {
    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &msg_buf,
        "checkout: moving from {s} to {s}",
        .{ from_branch, to_branch },
    );
    try appendForRef(allocator, io, git_dir, head_path, old_oid, new_oid, who, when, msg);
}

/// Returns the target ref of a symbolic HEAD (e.g. "refs/heads/main")
/// or null if HEAD is detached / missing.
pub fn headSymrefTarget(allocator: std.mem.Allocator, io: Io, git_dir: Dir) !?[]u8 {
    const bytes = git_dir.readFileAlloc(io, head_path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "ref: ")) return null;
    return try allocator.dupe(u8, trimmed[5..]);
}

// ── Read side: iterate entries from a log file ───────────────────

pub const Entry = struct {
    old_hex: [40]u8,
    new_hex: [40]u8,
    /// Borrowed slice into the iterator's buffer. Make a copy if you
    /// need to outlive the next .next() call.
    name: []const u8,
    email: []const u8,
    when_unix: i64,
    tz: []const u8,
    message: []const u8,
};

pub const EntryIterator = struct {
    bytes: []const u8,
    cursor: usize,

    pub fn next(self: *EntryIterator) ?Entry {
        while (self.cursor < self.bytes.len) {
            const start = self.cursor;
            const end = std.mem.indexOfScalarPos(u8, self.bytes, start, '\n') orelse self.bytes.len;
            self.cursor = end + 1;
            const line = self.bytes[start..end];
            if (line.len == 0) continue;
            return parseLine(line) orelse continue;
        }
        return null;
    }
};

pub fn iterate(bytes: []const u8) EntryIterator {
    return .{ .bytes = bytes, .cursor = 0 };
}

fn parseLine(line: []const u8) ?Entry {
    if (line.len < 82) return null; // 40 + space + 40 + space minimum
    if (line[40] != ' ' or line[81] != ' ') return null;

    var entry: Entry = undefined;
    @memcpy(&entry.old_hex, line[0..40]);
    @memcpy(&entry.new_hex, line[41..81]);

    const rest = line[82..];
    // rest = "Name <email> <ts> <tz>\t<message>"
    const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
    const head = rest[0..tab];
    entry.message = rest[tab + 1 ..];

    // From the right: tz, ts, then "<email>".
    const tz_sp = std.mem.lastIndexOfScalar(u8, head, ' ') orelse return null;
    entry.tz = head[tz_sp + 1 ..];
    const before_tz = head[0..tz_sp];

    const ts_sp = std.mem.lastIndexOfScalar(u8, before_tz, ' ') orelse return null;
    const ts_str = before_tz[ts_sp + 1 ..];
    entry.when_unix = std.fmt.parseInt(i64, ts_str, 10) catch return null;
    const before_ts = before_tz[0..ts_sp];

    // before_ts ends with "<email>" preceded by a space.
    if (before_ts.len < 3) return null;
    if (before_ts[before_ts.len - 1] != '>') return null;
    const open = std.mem.lastIndexOfScalar(u8, before_ts, '<') orelse return null;
    if (open == 0 or before_ts[open - 1] != ' ') return null;
    entry.email = before_ts[open + 1 .. before_ts.len - 1];
    entry.name = before_ts[0 .. open - 1];

    return entry;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "parseLine extracts every field" {
    const line = "0000000000000000000000000000000000000000 1234567890abcdef1234567890abcdef12345678 Alice Tester <alice@example.com> 1700000000 +0000" ++ "\t" ++ "commit (initial): bootstrap";
    const e = parseLine(line) orelse return error.UnexpectedNullParse;
    try testing.expectEqualStrings("0000000000000000000000000000000000000000", &e.old_hex);
    try testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", &e.new_hex);
    try testing.expectEqualStrings("Alice Tester", e.name);
    try testing.expectEqualStrings("alice@example.com", e.email);
    try testing.expectEqual(@as(i64, 1700000000), e.when_unix);
    try testing.expectEqualStrings("+0000", e.tz);
    try testing.expectEqualStrings("commit (initial): bootstrap", e.message);
}

test "iterate skips blanks, walks every entry" {
    const log =
        "0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 A B <a@b> 1700000000 +0000\tone\n" ++
        "1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 A B <a@b> 1700000100 +0000\ttwo\n";

    var it = iterate(log);
    const a = it.next() orelse return error.MissingFirst;
    try testing.expectEqualStrings("one", a.message);
    const b = it.next() orelse return error.MissingSecond;
    try testing.expectEqualStrings("two", b.message);
    try testing.expect(it.next() == null);
}
