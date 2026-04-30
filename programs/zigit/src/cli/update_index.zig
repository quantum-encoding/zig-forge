// `zigit update-index --add <file>...`
//
// For each file: stat it, read it, hash-and-write as a blob, then
// upsert an entry in .git/index. Multiple files allowed in one shot.
//
// We don't yet support `--remove`, `--cacheinfo`, or `--refresh` —
// `--add` is enough to feed `write-tree`.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var add_mode = false;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--add")) {
            add_mode = true;
        } else {
            try paths.append(allocator, a);
        }
    }

    if (!add_mode) return error.OnlyAddSupportedYet;
    if (paths.items.len == 0) return error.MissingFileArgument;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    var index = try zigit.Index.load(allocator, io, repo.git_dir);
    defer index.deinit();

    var store = repo.looseStore();

    for (paths.items) |path| {
        try addOne(allocator, io, &repo, &store, &index, path);
    }

    try index.save(io, repo.git_dir);
}

fn addOne(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    store: *zigit.LooseStore,
    index: *zigit.Index,
    rel_path: []const u8,
) !void {
    _ = repo;
    // Open relative to cwd. The path is stored verbatim in the index
    // (git's index always uses cwd-relative paths from the work tree).
    var file = try Dir.cwd().openFile(io, rel_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);

    const content = try Dir.cwd().readFileAlloc(io, rel_path, allocator, .unlimited);
    defer allocator.free(content);

    const oid = zigit.object.computeOid(.blob, content);
    try store.write(allocator, .blob, content, oid);

    const mode_value: u32 = blk: {
        if (@TypeOf(stat.permissions).has_executable_bit) {
            const m = stat.permissions.toMode();
            if ((m & 0o111) != 0) break :blk @intFromEnum(zigit.index.Mode.executable);
        }
        break :blk @intFromEnum(zigit.index.Mode.regular);
    };

    const mtime_s: u32 = clampSeconds(stat.mtime.nanoseconds);
    const mtime_ns: u32 = clampNanos(stat.mtime.nanoseconds);
    const ctime_s: u32 = clampSeconds(stat.ctime.nanoseconds);
    const ctime_ns: u32 = clampNanos(stat.ctime.nanoseconds);

    const flags_path_len: u16 = if (rel_path.len > 0xFFF) 0xFFF else @intCast(rel_path.len);

    try index.upsert(.{
        .ctime_s = ctime_s,
        .ctime_ns = ctime_ns,
        .mtime_s = mtime_s,
        .mtime_ns = mtime_ns,
        // Io.File.Stat doesn't expose dev; git uses it only as a stat
        // cache hint, so 0 is safe — the price is one extra hash next
        // time we try to detect modifications.
        .dev = 0,
        .ino = @truncate(@as(u128, @bitCast(@as(i128, stat.inode)))),
        .mode = mode_value,
        .uid = 0,
        .gid = 0,
        .file_size = std.math.cast(u32, stat.size) orelse std.math.maxInt(u32),
        .oid = oid,
        .flags = flags_path_len,
        .path = rel_path,
    });
}

fn clampSeconds(ns: i96) u32 {
    const seconds = @divFloor(ns, std.time.ns_per_s);
    if (seconds < 0) return 0;
    if (seconds > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(seconds);
}

fn clampNanos(ns: i96) u32 {
    const remainder = @mod(ns, std.time.ns_per_s);
    return @intCast(remainder);
}
