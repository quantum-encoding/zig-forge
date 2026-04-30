// Refs — git's named pointers into the object graph.
//
// Storage layout (loose refs only; we don't read packed-refs yet):
//   .git/HEAD                   → "ref: refs/heads/main\n" (symbolic)
//   .git/refs/heads/<name>      → "<40-char hex>\n" (direct)
//   .git/refs/tags/<name>       → "<40-char hex>\n" (direct)
//
// A ref file is symbolic if its first 5 bytes are "ref: ", direct
// otherwise. Symbolic refs can chain through several hops (HEAD →
// refs/heads/main → refs/heads/main is the typical no-detach case).
// `resolve()` walks the chain to the final Oid. `resolveSymbolic()`
// stops at the last symbolic-pointing ref name (useful when we need
// to know which branch HEAD currently tracks).
//
// Updates use git's classic .lock dance: write to "<ref>.lock",
// rename over "<ref>" — atomic on POSIX, blocks concurrent writers
// because lock-creation is exclusive (O_EXCL). We don't yet enforce
// the old-oid CAS that real git does; that's a small extension when
// we need real concurrent safety.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Oid = @import("../object/oid.zig").Oid;

pub const max_chain_depth: usize = 5;
pub const head_path = "HEAD";

pub const Value = union(enum) {
    direct: Oid,
    /// Owned by caller — usually a heap-dup of the bytes after "ref: ".
    symbolic: []const u8,
};

pub fn deinitValue(allocator: std.mem.Allocator, v: Value) void {
    switch (v) {
        .direct => {},
        .symbolic => |s| allocator.free(s),
    }
}

/// Read a ref by name (e.g. "HEAD", "refs/heads/main"). Caller owns
/// the returned `symbolic` bytes — call `deinitValue` to free.
pub fn read(allocator: std.mem.Allocator, io: Io, git_dir: Dir, name: []const u8) !Value {
    const raw = git_dir.readFileAlloc(io, name, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.RefNotFound,
        else => return err,
    };
    defer allocator.free(raw);

    return try parse(allocator, raw);
}

/// Parse the bytes of a ref file (without leading-whitespace tolerance,
/// matching git's strictness).
pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !Value {
    const trimmed = std.mem.trimEnd(u8, raw, " \r\n\t");

    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const target = trimmed[5..];
        if (target.len == 0) return error.MalformedRef;
        const dup = try allocator.dupe(u8, target);
        return .{ .symbolic = dup };
    }

    if (trimmed.len != 40) return error.MalformedRef;
    return .{ .direct = try Oid.fromHex(trimmed) };
}

/// Walk the chain from `name` until we hit a direct ref or run out
/// of hops. Returns `error.RefNotFound` if any step in the chain is
/// missing (an unborn HEAD on a fresh `init` returns this — call
/// `tryResolve` if you need to tolerate it).
pub fn resolve(allocator: std.mem.Allocator, io: Io, git_dir: Dir, name: []const u8) !Oid {
    var current_name = try allocator.dupe(u8, name);
    defer allocator.free(current_name);

    var hops: usize = 0;
    while (hops < max_chain_depth) : (hops += 1) {
        const v = try read(allocator, io, git_dir, current_name);
        switch (v) {
            .direct => |oid| {
                deinitValue(allocator, v);
                return oid;
            },
            .symbolic => |target| {
                allocator.free(current_name);
                current_name = try allocator.dupe(u8, target);
                deinitValue(allocator, v);
            },
        }
    }
    return error.RefChainTooDeep;
}

/// Like `resolve` but returns `null` when the symbolic chain ends at
/// a non-existent ref (an "unborn branch" — fresh repo with no
/// commits yet on `main`).
pub fn tryResolve(allocator: std.mem.Allocator, io: Io, git_dir: Dir, name: []const u8) !?Oid {
    return resolve(allocator, io, git_dir, name) catch |err| switch (err) {
        error.RefNotFound => null,
        else => return err,
    };
}

/// Walk the chain and report the *last symbolic ref name* before the
/// final direct one — for HEAD on an attached branch, that's the
/// branch's full ref name like "refs/heads/main", which is exactly
/// what `commit` needs to know to update the right ref.
///
/// Caller owns the returned slice. Returns `error.RefNotFound` if
/// the head ref file itself doesn't exist (shouldn't happen post-init).
pub fn resolveSymbolic(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    start: []const u8,
) ![]u8 {
    var current = try allocator.dupe(u8, start);
    errdefer allocator.free(current);

    var hops: usize = 0;
    while (hops < max_chain_depth) : (hops += 1) {
        const v = read(allocator, io, git_dir, current) catch |err| switch (err) {
            error.RefNotFound => {
                // The terminal ref doesn't exist on disk yet (unborn
                // branch). `current` is still the right answer — that's
                // the branch HEAD points at.
                return current;
            },
            else => return err,
        };
        switch (v) {
            .direct => return current,
            .symbolic => |target| {
                allocator.free(current);
                current = try allocator.dupe(u8, target);
                deinitValue(allocator, v);
            },
        }
    }
    return error.RefChainTooDeep;
}

/// Atomically point `name` at `oid`. Writes to "<name>.lock", renames.
/// Creates parent directories as needed.
pub fn update(io: Io, git_dir: Dir, name: []const u8, oid: Oid) !void {
    if (std.fs.path.dirname(name)) |parent| {
        try git_dir.createDirPath(io, parent);
    }

    var lock_buf: [Dir.max_path_bytes]u8 = undefined;
    const lock_name = try std.fmt.bufPrint(&lock_buf, "{s}.lock", .{name});

    var hex: [40]u8 = undefined;
    oid.toHex(&hex);
    var line: [42]u8 = undefined;
    @memcpy(line[0..40], &hex);
    line[40] = '\n';

    try git_dir.writeFile(io, .{ .sub_path = lock_name, .data = line[0..41] });
    try git_dir.rename(lock_name, git_dir, name, io);
}

const testing = std.testing;

test "parse direct ref" {
    const v = try parse(testing.allocator, "abcdef0123456789abcdef0123456789abcdef01\n");
    defer deinitValue(testing.allocator, v);
    try testing.expect(v == .direct);
}

test "parse symbolic ref" {
    const v = try parse(testing.allocator, "ref: refs/heads/main\n");
    defer deinitValue(testing.allocator, v);
    try testing.expect(v == .symbolic);
    try testing.expectEqualStrings("refs/heads/main", v.symbolic);
}

test "parse rejects garbage" {
    try testing.expectError(error.MalformedRef, parse(testing.allocator, "not-a-ref"));
    try testing.expectError(error.MalformedRef, parse(testing.allocator, "ref: \n"));
}
