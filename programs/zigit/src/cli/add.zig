// `zigit add <pathspec...>`
//
// Stage one or more paths. Each argument is independently classified:
//
//   File (or symlink) → staged verbatim, BYPASSING the .gitignore
//                       ruleset. Real git refuses explicit-named
//                       ignored files without `-f`; zigit v1.1 picks
//                       the more permissive policy — if you typed the
//                       file name, you get the staging. The bypass is
//                       keyed on "explicit FILE argument," not "any
//                       explicit argument."
//   Directory         → filtered walk. Ignored files inside are
//                       skipped (directory expansion HONOURS the
//                       ruleset). If the directory itself is excluded
//                       by `.gitignore`, the walk emits nothing under
//                       it; we warn and exit 1, matching git's
//                       "paths are ignored" message.
//
// "." is a directory arg meaning "the whole work tree."
//
// Limitations recorded in docs/V1_1_SPEC.md:
//   * No `-f`/`--force` yet. v1.1 doesn't need it because explicit-
//     named ignored FILES are already added (it's only ignored
//     DIRECTORIES that need a future `-f` to escape the warn-exit).
//   * `zigit add` assumes cwd == work-tree root. Running from a
//     subdir would write cwd-relative paths into the index — a
//     pre-existing v1.0 bug, not regressed by this commit.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingFileArgument;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    var work_root = try openWorkRoot(io, &repo);
    defer work_root.close(io);

    // Load .git/info/exclude bytes (optional). core.excludesFile
    // resolution is a follow-up — same TODO as status.zig.
    const info_exclude_bytes_opt = repo.git_dir.readFileAlloc(io, "info/exclude", allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => null,
        else => |e| return e,
    };
    defer if (info_exclude_bytes_opt) |b| allocator.free(b);

    var rs = try zigit.ignore.load(allocator, io, work_root, .{
        .info_exclude_bytes = info_exclude_bytes_opt orelse "",
    });
    defer rs.deinit();

    // Classify each arg.
    var explicit_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer explicit_files.deinit(allocator);
    var dir_prefixes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer dir_prefixes.deinit(allocator);
    var ignored_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ignored_dirs.deinit(allocator);
    var missing_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer missing_paths.deinit(allocator);

    for (args) |raw_arg| {
        const norm = normalizeArg(raw_arg);

        // Stat to determine kind. For "." (which normalizes to ""),
        // we represent it explicitly as the empty-prefix walk over
        // the whole work tree.
        if (norm.len == 0) {
            try dir_prefixes.append(allocator, "");
            continue;
        }

        const stat = work_root.statFile(io, norm, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try missing_paths.append(allocator, raw_arg);
                continue;
            },
            else => return err,
        };

        switch (stat.kind) {
            .file, .sym_link => {
                // Explicit file argument — bypass the ruleset.
                try explicit_files.append(allocator, norm);
            },
            .directory => {
                if (rs.isIgnoredDir(norm)) {
                    try ignored_dirs.append(allocator, norm);
                } else {
                    try dir_prefixes.append(allocator, norm);
                }
            },
            else => {
                // Block device / socket / etc. — refuse with a clear
                // pathspec-style message; behave like missing.
                try missing_paths.append(allocator, raw_arg);
            },
        }
    }

    // Emit pathspec-not-found errors first (matches git's order).
    if (missing_paths.items.len > 0) {
        var buf: [Dir.max_path_bytes + 64]u8 = undefined;
        for (missing_paths.items) |p| {
            const msg = std.fmt.bufPrint(&buf, "fatal: pathspec '{s}' did not match any files\n", .{p}) catch continue;
            File.stderr().writeStreamingAll(io, msg) catch {};
        }
        return error.PathspecNotFound;
    }

    // Collect every path to stage. Order: explicit files first (in
    // arg order), then sorted directory expansion.
    var to_stage: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (to_stage.items) |p| allocator.free(p);
        to_stage.deinit(allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (explicit_files.items) |p| {
        const gop = try seen.getOrPut(allocator, p);
        if (!gop.found_existing) try to_stage.append(allocator, try allocator.dupe(u8, p));
    }

    if (dir_prefixes.items.len > 0) {
        const listing = try zigit.workdir.walk(allocator, io, work_root, &rs);
        defer zigit.workdir.freeEntries(allocator, listing);
        for (listing) |w_entry| {
            if (!matchesAnyPrefix(w_entry.path, dir_prefixes.items)) continue;
            const gop = try seen.getOrPut(allocator, w_entry.path);
            if (gop.found_existing) continue;
            try to_stage.append(allocator, try allocator.dupe(u8, w_entry.path));
            // The key for `seen` must live as long as the entry
            // does — point it at the (now-owned) staged copy.
            gop.key_ptr.* = to_stage.items[to_stage.items.len - 1];
        }
    }

    // Warning for ignored directories (matches git's wording; the
    // "Use -f" hint stays even though we don't have -f yet — when
    // we add it the message will be accurate).
    if (ignored_dirs.items.len > 0) {
        try File.stderr().writeStreamingAll(io, "The following paths are ignored by one of your .gitignore files:\n");
        var buf: [Dir.max_path_bytes + 8]u8 = undefined;
        for (ignored_dirs.items) |p| {
            const msg = std.fmt.bufPrint(&buf, "{s}\n", .{p}) catch continue;
            File.stderr().writeStreamingAll(io, msg) catch {};
        }
        try File.stderr().writeStreamingAll(io, "hint: Use -f if you really want to add them.\n");
    }

    // Stage everything.
    if (to_stage.items.len > 0) {
        var index = try zigit.Index.load(allocator, io, repo.git_dir);
        defer index.deinit();
        var store = repo.looseStore();
        for (to_stage.items) |p| {
            try addOne(allocator, io, &store, &index, p);
        }
        try index.save(io, repo.git_dir);
    }

    // Exit 1 when any directory arg was ignored. Matches git.
    if (ignored_dirs.items.len > 0) return error.PathsIgnored;
}

// ── Helpers ─────────────────────────────────────────────────────────

/// Strip a single trailing '/' (so "src/" and "src" hit the same
/// code path), and normalise "." to the empty string (which the
/// caller interprets as "walk the whole work tree").
fn normalizeArg(arg: []const u8) []const u8 {
    if (std.mem.eql(u8, arg, ".")) return "";
    if (arg.len > 0 and arg[arg.len - 1] == '/') return arg[0 .. arg.len - 1];
    return arg;
}

/// True when `path` falls under any of the supplied prefixes. An
/// empty prefix matches everything (the "." case). Strict ancestry
/// check — `foo` does NOT match prefix `fo`, only prefixes followed
/// by '/' (or the empty prefix) count.
fn matchesAnyPrefix(path: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (prefix.len == 0) return true;
        if (path.len <= prefix.len) continue;
        if (!std.mem.startsWith(u8, path, prefix)) continue;
        if (path[prefix.len] != '/') continue;
        return true;
    }
    return false;
}

fn openWorkRoot(io: Io, repo: *zigit.Repository) !Dir {
    const root_path = std.fs.path.dirname(repo.git_dir_path) orelse return error.NoWorkTree;
    return Dir.openDirAbsolute(io, root_path, .{ .iterate = true });
}

/// Read a file, blob-hash it, write into the loose store, upsert an
/// index entry. Copy of update_index.zig:addOne so we don't have to
/// expose its internals.
fn addOne(
    allocator: std.mem.Allocator,
    io: Io,
    store: *zigit.LooseStore,
    index: *zigit.Index,
    rel_path: []const u8,
) !void {
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

    const flags_path_len: u16 = if (rel_path.len > 0xFFF) 0xFFF else @intCast(rel_path.len);

    try index.upsert(.{
        .ctime_s = clampSeconds(stat.ctime.nanoseconds),
        .ctime_ns = clampNanos(stat.ctime.nanoseconds),
        .mtime_s = clampSeconds(stat.mtime.nanoseconds),
        .mtime_ns = clampNanos(stat.mtime.nanoseconds),
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
    return @intCast(@mod(ns, std.time.ns_per_s));
}
