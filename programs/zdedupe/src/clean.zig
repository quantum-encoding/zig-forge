//! `zdedupe clean`: build leftovers under a set of roots, whose they are, and
//! which of them can go to the Trash
//!
//! Three questions, for the roots an agent or a person names (a scratch area,
//! a worktrees folder, a projects folder):
//!
//!   * **What is build output?** The core's own rule, the one Disk Space
//!     suggests from: a folder named in `space.build_dirs`, a folder named in
//!     `space.build_dirs_beside` next to one of its manifests, or any folder
//!     carrying a valid CACHEDIR.TAG (`fast_walker.hasCacheDirTag`). The walk
//!     stays on the roots' filesystems, never follows a link, never enters a
//!     version-control store or a credential store, and does not look for
//!     build output inside build output. A root is the scope, never a finding.
//!   * **Which of it is the same?** Identical-folder analysis (dirs.zig) over
//!     the build folders: content-identical, not name-identical. A folder
//!     with anything unreadable in it is never called a copy.
//!   * **Whose is it?** Each build folder's project is the nearest folder
//!     above it holding `.git` or a manifest (`project_manifests`). Every
//!     checkout under the roots, and every outermost project (one inside no
//!     other), is a project too: each copy is reported, build output or not.
//!     gitinfo.zig says where its main code lives and whether this copy holds
//!     work found nowhere else.
//!
//! **What it may change: build output, to the Trash, nothing else.** A build
//! folder is eligible when nothing in it, the folders included, was modified
//! or had its status changed for `older_s` (default a day): a status change
//! is set by the system, so an unpacker that restores old modification
//! times still counts as fresh. It must also lie below a root (never be
//! one), not be or hold a protected location (protect.zig, on the real path:
//! macOS's `/private`, which holds `/tmp`, is protected), not be inside a
//! version-control store, and have been read completely. Just before a move
//! each folder is checked again: the same folder (device and inode, not a
//! link), still build output by the same rule, still old enough, still on one
//! filesystem. Whole project copies are reported with their verdict and are
//! never moved by this module.

const std = @import("std");
const builtin = @import("builtin");
const libc = @import("sys.zig").c;
const types = @import("types.zig");
const fast_walker = @import("fast_walker.zig");
const dedupe = @import("dedupe.zig");
const space = @import("space.zig");
const protect = @import("protect.zig");
const filters = @import("filters.zig");
const pstat = @import("pstat.zig");
const session = @import("session.zig");
const gitinfo = @import("gitinfo.zig");
const trash_mod = @import("trash.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Names the JSON document; bumped only when a field changes meaning or goes.
pub const schema_version = "zdedupe-clean/1";
pub const default_older_s: i64 = 24 * std.time.s_per_hour;
/// Shortest `older_s` accepted: a build that is writing is never moved.
pub const min_older_s: i64 = 10 * std.time.s_per_min;

/// Besides `.git`, the files that make a folder a project root.
pub const project_manifests = [_][]const u8{
    "package.json", "Cargo.toml",    "build.zig", "Package.swift",  "pyproject.toml",
    "setup.py",     "go.mod",        "pom.xml",   "build.gradle",   "build.gradle.kts",
    "Gemfile",      "composer.json", "deno.json", "CMakeLists.txt", "meson.build",
    "mix.exs",      "pubspec.yaml",
};

comptime {
    // Every manifest the build-output rule looks for marks a project.
    for (space.build_dirs_beside) |b| for (b.manifests) |m| {
        for (project_manifests) |p| {
            if (std.mem.eql(u8, p, m)) break;
        } else @compileError("project_manifests lacks " ++ m);
    };
    std.debug.assert(project_manifests.len < 63);
}

/// Names the finding walk prunes: build output (each is then a finding),
/// version-control stores (each marks a checkout) and credential stores.
const walk_excludes = space.build_dirs ++ protect.component_names ++ types.Config.credential_excludes;

const vcs_bit: u64 = 1 << 63;

/// Build folders the text report lists per root; the JSON lists them all.
const text_rows_per_root: usize = 25;

// ===========================================================================
// The report
// ===========================================================================

pub const Rule = enum { name, beside_manifest, cachedir_tag };

pub const Root = struct {
    /// As given.
    given: []const u8,
    /// Real path (links resolved).
    path: []const u8,
    /// Why it was not scanned.
    err: ?[]const u8 = null,
    build_dirs: u64 = 0,
    bytes: u64 = 0,
    files: u64 = 0,
    /// Entries the walk could not read.
    unreadable: u64 = 0,
    /// Entries not read on purpose: credential stores, another app's
    /// library, another volume.
    left_out: u64 = 0,
};

/// What `trash` would do with a build folder now.
pub const Check = struct {
    eligible: bool = false,
    refusal: ?[]const u8 = null,
    /// Newest modification or status change inside, the folder included.
    newest_change: ?i64 = null,
};

pub const BuildDir = struct {
    path: []const u8,
    /// Its name.
    kind: []const u8,
    rule: Rule,
    root: usize,
    project: ?usize = null,
    dev: u64,
    ino: u64,
    /// On disk (allocated blocks); each inode once.
    bytes: u64 = 0,
    logical_bytes: u64 = 0,
    files: u64 = 0,
    /// Allocated bytes of files here with other hard links: removing the
    /// folder frees them only if every other link goes too.
    hardlinked_bytes: u64 = 0,
    newest_mtime: ?i64 = null,
    complete: bool = true,
    duplicate_set: ?usize = null,
    trash: Check = .{},
};

pub const DuplicateSet = struct {
    /// The members' name, or `mixed`.
    kind: []const u8,
    /// Build folder indices, by path.
    members: []const usize,
    bytes_each: u64,
    files_each: u64,
    /// What removing all but the largest copy frees.
    reclaimable: u64,
};

pub const Project = struct {
    path: []const u8,
    root: usize,
    markers: []const []const u8,
    build_dirs: u64 = 0,
    build_bytes: u64 = 0,
    /// Null when git is not available.
    facts: ?gitinfo.Facts = null,
};

pub const Moved = struct { path: []const u8, bytes: u64, trashed_as: []const u8 };
pub const Skipped = struct { path: []const u8, bytes: u64, reason: []const u8 };

pub const TrashRun = struct {
    moved: []const Moved = &.{},
    skipped: []const Skipped = &.{},
    bytes_moved: u64 = 0,
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    generated_at: i64 = 0,
    older_s: i64 = default_older_s,
    roots: []Root = &.{},
    main_roots: []const []const u8 = &.{},
    /// Largest first.
    build_dirs: []BuildDir = &.{},
    /// Most reclaimable first.
    duplicate_sets: []DuplicateSet = &.{},
    /// Largest build output first, then by path.
    projects: []Project = &.{},
    git_version: ?[]const u8 = null,
    trash: ?TrashRun = null,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
    }

    pub fn eligibleBytes(self: *const Report) struct { count: u64, bytes: u64 } {
        var count: u64 = 0;
        var bytes: u64 = 0;
        for (self.build_dirs) |b| if (b.trash.eligible) {
            count += 1;
            bytes += b.bytes;
        };
        return .{ .count = count, .bytes = bytes };
    }
};

/// Moves one item to the Trash; tests substitute their own.
pub const TrashFn = *const fn (arena: Allocator, path: []const u8, is_dir: bool) trash_mod.Outcome;
/// True when a folder must not be moved; tests substitute their own.
pub const GuardFn = *const fn (ctx: ?*const anyopaque, path: []const u8) bool;

pub const Options = struct {
    roots: []const []const u8,
    /// Where main checkouts are looked for; empty is `~/work`.
    main_roots: []const []const u8 = &.{},
    older_s: i64 = default_older_s,
    threads: u32 = 0,
    git_exe: []const u8 = "git",
    /// Seconds since the epoch ages are measured from; null is now.
    now: ?i64 = null,
    trash_fn: TrashFn = trash_mod.moveToTrash,
    guard_fn: GuardFn = protectedByCore,
    guard_ctx: ?*const anyopaque = null,
};

/// protect.zig, with the real home folder from the user database.
pub fn protectedByCore(_: ?*const anyopaque, path: []const u8) bool {
    const home = if (session.userHome()) |h| filters.trimSep(h) else null;
    const guard: protect.Protection = .{ .home = home };
    return guard.guardsFolder(path);
}

// ===========================================================================
// Scanning
// ===========================================================================

const Candidate = struct { path: []const u8, rule: Rule };

/// Find, measure, compare and judge. Moves nothing.
pub fn scan(gpa: Allocator, io: Io, opts: Options) !Report {
    var report: Report = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer report.deinit();
    const a = report.arena.allocator();
    report.generated_at = opts.now orelse realtimeSeconds();
    report.older_s = opts.older_s;

    report.roots = try resolveRoots(a, opts.roots);
    report.main_roots = try mainRoots(a, opts.main_roots);

    // --- find -------------------------------------------------------------
    var markers: std.StringHashMapUnmanaged(u64) = .empty;
    var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
    {
        var fw = fast_walker.FastWalker.init(gpa);
        defer fw.deinit();
        fw.setIncludeHidden(true);
        fw.setOneFilesystem(true);
        fw.setSkipAppLibraries(true);
        fw.setFollowSymlinks(false);
        fw.enableTreeRecording();
        fw.setSizeFilter(0, 0);
        fw.disableHardLinkDetection();
        fw.setNoMaterialize(true);
        fw.setExcludeCacheDirs(true);
        fw.setExcludes(&walk_excludes);
        fw.setThreads(opts.threads);
        for (report.roots) |*root| {
            if (root.err != null) continue;
            fw.walk(root.path) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => root.err = @errorName(err),
            };
        }
        try fw.finish();

        for (fw.files.items) |f| {
            const bit = manifestBit(filters.baseName(f.path)) orelse continue;
            const parent = filters.parentDir(f.path) orelse continue;
            try markDir(a, &markers, parent, bit);
        }
        for (fw.skips.items) |s| {
            const root = rootOf(report.roots, s.path) orelse continue;
            switch (s.reason) {
                .excluded => {
                    const name = filters.baseName(s.path);
                    if (isVcsName(name)) {
                        try markDir(a, &markers, filters.parentDir(s.path) orelse continue, vcs_bit);
                    } else if (space.isBuildDirName(name)) {
                        try candidates.append(a, .{ .path = try a.dupe(u8, s.path), .rule = .name });
                    } else {
                        // No name the walk prunes: pruned for its CACHEDIR.TAG.
                        try candidates.append(a, .{ .path = try a.dupe(u8, s.path), .rule = .cachedir_tag });
                    }
                },
                .credentials, .other_volume, .app_library => report.roots[root].left_out += 1,
                .unreadable, .denied, .privacy, .partial => report.roots[root].unreadable += 1,
            }
        }
        for (fw.dirs.items) |d| {
            const manifests = space.buildDirManifests(filters.baseName(d.path)) orelse continue;
            const have = markers.get(filters.parentDir(d.path) orelse continue) orelse 0;
            for (manifests) |m| {
                if (have & manifestBit(m).? != 0) {
                    try candidates.append(a, .{ .path = try a.dupe(u8, d.path), .rule = .beside_manifest });
                    break;
                }
            }
        }
    }

    const found = try keepOutermost(a, report.roots, candidates.items);

    // --- whose -------------------------------------------------------------
    var projects: std.ArrayListUnmanaged(Project) = .empty;
    var project_of: std.StringHashMapUnmanaged(usize) = .empty;
    for (found.items) |*b| {
        const dir = nearestProject(&markers, b.path, report.roots[b.root].path) orelse continue;
        b.project = try projectIndex(a, &projects, &project_of, &markers, dir, b.root);
    }
    // Every checkout, and every outermost project: each copy of a project
    // under a root, whether or not it holds build output.
    var marker_it = markers.iterator();
    while (marker_it.next()) |kv| {
        const dir = kv.key_ptr.*;
        const root = rootOf(report.roots, dir) orelse continue;
        if (kv.value_ptr.* & vcs_bit == 0 and nearestProject(&markers, dir, report.roots[root].path) != null) continue;
        _ = try projectIndex(a, &projects, &project_of, &markers, dir, root);
    }

    // --- measure and compare -----------------------------------------------
    var sets: std.ArrayListUnmanaged(DuplicateSet) = .empty;
    if (found.items.len > 0) {
        var finder = dedupe.DupeFinder.init(gpa, .{
            .include_hidden = true,
            .excludes = &types.Config.credential_excludes,
            .one_filesystem = true,
            .skip_app_libraries = true,
            .analyze_dirs = true,
            .threads = opts.threads,
        });
        defer finder.deinit();
        const paths = try a.alloc([]const u8, found.items.len);
        for (found.items, paths) |b, *p| p.* = b.path;
        try finder.scan(paths);

        var by_path: std.StringHashMapUnmanaged(u32) = .empty;
        for (found.items, 0..) |b, i| try by_path.put(a, b.path, @intCast(i));
        var owners: Owners = .{ .by_path = &by_path };
        defer owners.memo.deinit(gpa);
        for (finder.files.items) |*f| {
            const i = try owners.of(gpa, f.path) orelse continue;
            const b = &found.items[i];
            if (f.link_of == null) {
                b.files += 1;
                b.bytes += f.allocated;
                b.logical_bytes += f.size;
                if (f.nlink > 1) b.hardlinked_bytes += f.allocated;
            }
            b.newest_mtime = if (b.newest_mtime) |n| @max(n, f.mtime) else f.mtime;
        }
        for (finder.getSkips()) |s| {
            switch (s.reason) {
                .excluded, .credentials => continue,
                else => {},
            }
            const i = by_path.get(s.path) orelse (try owners.of(gpa, s.path)) orelse continue;
            found.items[i].complete = false;
        }

        // Largest first; every index below is into this order.
        std.sort.pdq(BuildDir, found.items, {}, largerFirst);
        by_path.clearRetainingCapacity();
        for (found.items, 0..) |b, i| try by_path.put(a, b.path, @intCast(i));

        if (finder.getDirAnalysis()) |analysis| {
            for (analysis.identical_sets) |set| {
                var members: std.ArrayListUnmanaged(usize) = .empty;
                for (set.dirs) |d| {
                    if (by_path.get(d.path)) |i| try members.append(a, i);
                }
                if (members.items.len < 2) continue;
                std.sort.pdq(usize, members.items, found.items, byPath);
                try sets.append(a, setOf(found.items, members.items));
            }
        }
    }
    std.sort.pdq(DuplicateSet, sets.items, {}, moreReclaimable);
    for (sets.items, 0..) |set, k| {
        for (set.members) |i| found.items[i].duplicate_set = k;
    }

    // --- tally ---------------------------------------------------------------
    for (found.items) |b| {
        const root = &report.roots[b.root];
        root.build_dirs += 1;
        root.bytes += b.bytes;
        root.files += b.files;
    }
    // Projects were numbered as found; renumber by size and point folders at them.
    for (found.items) |b| {
        const p = &projects.items[b.project orelse continue];
        p.build_dirs += 1;
        p.build_bytes += b.bytes;
    }
    const order = try a.alloc(usize, projects.items.len);
    for (order, 0..) |*o, i| o.* = i;
    std.sort.pdq(usize, order, projects.items, projectLess);
    const renumber = try a.alloc(usize, projects.items.len);
    const sorted = try a.alloc(Project, projects.items.len);
    for (order, 0..) |old, new| {
        renumber[old] = new;
        sorted[new] = projects.items[old];
    }
    for (found.items) |*b| {
        if (b.project) |p| b.project = renumber[p];
    }

    // --- may it go -------------------------------------------------------------
    for (found.items) |*b| b.trash = checkFolder(gpa, opts, report.generated_at, b);

    // --- git -------------------------------------------------------------------
    const git = gitinfo.Git.init(gpa, io, a, opts.git_exe);
    report.git_version = git.version;
    if (git.available()) {
        const index = gitinfo.MainIndex.build(a, report.main_roots);
        var cache: std.StringHashMapUnmanaged(gitinfo.Checkout) = .empty;
        for (sorted) |*p| p.facts = gitinfo.inspect(&git, a, p.path, &index, &cache);
    }

    report.build_dirs = found.items;
    report.duplicate_sets = sets.items;
    report.projects = sorted;
    return report;
}

/// Scan, then move every eligible build folder to the Trash.
pub fn run(gpa: Allocator, io: Io, opts: Options, move: bool) !Report {
    var report = try scan(gpa, io, opts);
    errdefer report.deinit();
    if (move) try trashEligible(gpa, &report, opts);
    return report;
}

/// Move the eligible build folders to the Trash, largest first, each checked
/// again immediately before it goes. Every other build folder is listed as
/// skipped, with the reason.
pub fn trashEligible(gpa: Allocator, report: *Report, opts: Options) !void {
    const a = report.arena.allocator();
    var moved: std.ArrayListUnmanaged(Moved) = .empty;
    var skipped: std.ArrayListUnmanaged(Skipped) = .empty;
    var bytes_moved: u64 = 0;
    const now = opts.now orelse realtimeSeconds();
    for (report.build_dirs) |*b| {
        if (!b.trash.eligible) {
            try skipped.append(a, .{ .path = b.path, .bytes = b.bytes, .reason = b.trash.refusal orelse "not eligible" });
            continue;
        }
        if (stillBuildOutput(a, b)) |reason| {
            try skipped.append(a, .{ .path = b.path, .bytes = b.bytes, .reason = reason });
            continue;
        }
        const again = checkFolder(gpa, opts, now, b);
        if (!again.eligible) {
            try skipped.append(a, .{ .path = b.path, .bytes = b.bytes, .reason = again.refusal orelse "not eligible" });
            continue;
        }
        switch (opts.trash_fn(a, b.path, true)) {
            .moved => |where| {
                try moved.append(a, .{ .path = b.path, .bytes = b.bytes, .trashed_as = where });
                bytes_moved += b.bytes;
            },
            .failed => |why| try skipped.append(a, .{ .path = b.path, .bytes = b.bytes, .reason = why }),
        }
    }
    report.trash = .{ .moved = moved.items, .skipped = skipped.items, .bytes_moved = bytes_moved };
}

fn resolveRoots(a: Allocator, given: []const []const u8) ![]Root {
    const roots = try a.alloc(Root, given.len);
    for (given, roots) |g, *r| {
        r.* = .{ .given = g, .path = g };
        const real = gitinfo.realPath(a, g) orelse {
            r.err = "cannot be read";
            continue;
        };
        r.path = filters.trimSep(real);
        const z = try a.dupeSentinel(u8, r.path, 0);
        const st = pstat.lstat(z.ptr) catch {
            r.err = "cannot be read";
            continue;
        };
        if (!st.isDir()) r.err = "not a folder";
    }
    // A root inside another (or given twice) would be reported twice.
    for (roots, 0..) |*r, i| {
        if (r.err != null) continue;
        for (roots, 0..) |other, j| {
            if (i == j or other.err != null) continue;
            const same = std.mem.eql(u8, r.path, other.path);
            if ((same and j < i) or (!same and filters.isAtOrUnder(r.path, other.path))) {
                r.err = "inside another root";
                break;
            }
        }
    }
    return roots;
}

fn mainRoots(a: Allocator, given: []const []const u8) ![]const []const u8 {
    if (given.len > 0) return given;
    const home = session.userHome() orelse return &.{};
    const out = try a.alloc([]const u8, 1);
    out[0] = try std.fmt.allocPrint(a, "{s}/work", .{filters.trimSep(home)});
    return out;
}

fn manifestBit(name: []const u8) ?u64 {
    for (project_manifests, 0..) |m, i| {
        // zig-lens-ignore: EQL-FOR-SECRETS file names, not secrets
        if (std.mem.eql(u8, m, name)) return @as(u64, 1) << @intCast(i);
    }
    return null;
}

fn isVcsName(name: []const u8) bool {
    // zig-lens-ignore: EQL-FOR-SECRETS directory names, not secrets
    for (protect.component_names) |v| if (std.mem.eql(u8, v, name)) return true;
    return false;
}

fn markDir(a: Allocator, markers: *std.StringHashMapUnmanaged(u64), dir: []const u8, bit: u64) !void {
    const gop = try markers.getOrPut(a, dir);
    if (!gop.found_existing) {
        gop.key_ptr.* = try a.dupe(u8, dir);
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* |= bit;
}

fn rootOf(roots: []const Root, path: []const u8) ?usize {
    for (roots, 0..) |r, i| {
        if (r.err == null and filters.isAtOrUnder(path, r.path)) return i;
    }
    return null;
}

/// Candidates that are real folders below a root and inside no other
/// candidate, with their identity.
fn keepOutermost(a: Allocator, roots: []const Root, candidates: []Candidate) !std.ArrayListUnmanaged(BuildDir) {
    std.sort.pdq(Candidate, candidates, {}, struct {
        fn less(_: void, x: Candidate, y: Candidate) bool {
            return preorderLess(x.path, y.path);
        }
    }.less);
    var out: std.ArrayListUnmanaged(BuildDir) = .empty;
    var last: ?[]const u8 = null;
    for (candidates) |c| {
        // In preorder a folder's descendants follow it directly, so the last
        // folder kept is the only one that can hold this one.
        if (last) |l| if (filters.isAtOrUnder(c.path, l)) continue;
        const root = rootOf(roots, c.path) orelse continue;
        // A root is the scope, never a finding.
        if (std.mem.eql(u8, roots[root].path, c.path)) continue;
        const z = try a.dupeSentinel(u8, c.path, 0);
        const st = pstat.lstat(z.ptr) catch continue;
        if (!st.isDir()) continue;
        try out.append(a, .{
            .path = c.path,
            .kind = filters.baseName(c.path),
            .rule = c.rule,
            .root = root,
            .dev = st.dev,
            .ino = st.ino,
        });
        last = c.path;
    }
    return out;
}

/// Paths in preorder: `/` sorts below every other byte, so `/a/b/c` comes
/// between `/a/b` and `/a/b-c`.
fn preorderLess(x: []const u8, y: []const u8) bool {
    const n = @min(x.len, y.len);
    for (x[0..n], y[0..n]) |cx, cy| {
        if (cx == cy) continue;
        const rx: u16 = if (cx == '/') 0 else @as(u16, cx) + 1;
        const ry: u16 = if (cy == '/') 0 else @as(u16, cy) + 1;
        return rx < ry;
    }
    return x.len < y.len;
}

/// The nearest folder above `path`, up to `root`, holding a project marker.
fn nearestProject(markers: *const std.StringHashMapUnmanaged(u64), path: []const u8, root: []const u8) ?[]const u8 {
    var dir = filters.parentDir(path) orelse return null;
    while (true) {
        if (markers.get(dir)) |m| if (m != 0) return dir;
        if (std.mem.eql(u8, dir, root)) return null;
        dir = filters.parentDir(dir) orelse return null;
        if (!filters.isAtOrUnder(dir, root)) return null;
    }
}

fn projectIndex(
    a: Allocator,
    projects: *std.ArrayListUnmanaged(Project),
    index: *std.StringHashMapUnmanaged(usize),
    markers: *const std.StringHashMapUnmanaged(u64),
    dir: []const u8,
    root: usize,
) !usize {
    const gop = try index.getOrPut(a, dir);
    if (gop.found_existing) return gop.value_ptr.*;
    const path = try a.dupe(u8, dir);
    gop.key_ptr.* = path;
    gop.value_ptr.* = projects.items.len;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    const mask = markers.get(dir) orelse 0;
    if (mask & vcs_bit != 0) try names.append(a, ".git");
    for (project_manifests, 0..) |m, i| {
        if (mask & (@as(u64, 1) << @intCast(i)) != 0) try names.append(a, m);
    }
    try projects.append(a, .{ .path = path, .root = root, .markers = names.items });
    return gop.value_ptr.*;
}

/// Which build folder each scanned path is in, by its nearest known folder.
const Owners = struct {
    by_path: *const std.StringHashMapUnmanaged(u32),
    /// Folder -> build folder index, or `none`.
    memo: std.StringHashMapUnmanaged(u32) = .empty,

    const none = std.math.maxInt(u32);

    fn of(self: *Owners, gpa: Allocator, path: []const u8) !?u32 {
        var chain: [32][]const u8 = undefined;
        var depth: usize = 0;
        var dir = filters.parentDir(path);
        const found: u32 = while (dir) |d| {
            if (self.by_path.get(d)) |i| break i;
            if (self.memo.get(d)) |i| break i;
            if (depth < chain.len) {
                chain[depth] = d;
                depth += 1;
            }
            dir = filters.parentDir(d);
        } else none;
        for (chain[0..depth]) |d| try self.memo.put(gpa, d, found);
        return if (found == none) null else found;
    }
};

fn largerFirst(_: void, x: BuildDir, y: BuildDir) bool {
    if (x.bytes != y.bytes) return x.bytes > y.bytes;
    return std.mem.order(u8, x.path, y.path) == .lt;
}

fn byPath(dirs: []const BuildDir, x: usize, y: usize) bool {
    return std.mem.order(u8, dirs[x].path, dirs[y].path) == .lt;
}

fn moreReclaimable(_: void, x: DuplicateSet, y: DuplicateSet) bool {
    if (x.reclaimable != y.reclaimable) return x.reclaimable > y.reclaimable;
    return x.members[0] < y.members[0];
}

fn projectLess(projects: []const Project, x: usize, y: usize) bool {
    const px = projects[x];
    const py = projects[y];
    if (px.build_bytes != py.build_bytes) return px.build_bytes > py.build_bytes;
    return std.mem.order(u8, px.path, py.path) == .lt;
}

fn setOf(dirs: []const BuildDir, members: []const usize) DuplicateSet {
    var total: u64 = 0;
    var largest: u64 = 0;
    var files: u64 = 0;
    var kind = dirs[members[0]].kind;
    for (members) |i| {
        total += dirs[i].bytes;
        largest = @max(largest, dirs[i].bytes);
        files = @max(files, dirs[i].files);
        if (!std.mem.eql(u8, kind, dirs[i].kind)) kind = "mixed";
    }
    return .{ .kind = kind, .members = members, .bytes_each = largest, .files_each = files, .reclaimable = total - largest };
}

// ===========================================================================
// May it go
// ===========================================================================

fn checkFolder(gpa: Allocator, opts: Options, now: i64, b: *const BuildDir) Check {
    var check: Check = .{};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const age = newestChange(arena_state.allocator(), b.path, b.dev, b.ino);
    check.newest_change = age.newest;
    check.refusal = refusal: {
        if (opts.guard_fn(opts.guard_ctx, b.path)) break :refusal "is, or holds, a protected location";
        if (insideVcs(b.path)) break :refusal "is inside a version-control store";
        if (!b.complete) break :refusal "parts of it could not be read";
        if (age.problem) |p| break :refusal p;
        const newest = age.newest orelse break :refusal "its age is unknown";
        if (now - newest < opts.older_s) break :refusal "changed too recently (see newest_change)";
        break :refusal null;
    };
    check.eligible = check.refusal == null;
    return check;
}

/// Why `b` no longer passes its build-output rule, or null when it does.
fn stillBuildOutput(a: Allocator, b: *const BuildDir) ?[]const u8 {
    switch (b.rule) {
        .name => return null,
        .beside_manifest => {
            const parent = filters.parentDir(b.path) orelse return "has no parent folder";
            const manifests = space.buildDirManifests(b.kind) orelse return "is no longer build output";
            for (manifests) |m| {
                const z = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ parent, m }, 0) catch return "out of memory";
                const st = pstat.lstat(z.ptr) catch continue;
                if (st.isFile()) return null;
            }
            return "its manifest is gone, so it is no longer build output";
        },
        .cachedir_tag => {
            if (comptime builtin.os.tag == .windows) return "the Trash is not supported on this platform";
            const z = a.dupeSentinel(u8, b.path, 0) catch return "out of memory";
            const fd = libc.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(libc.mode_t, 0));
            if (fd < 0) return "cannot be opened";
            defer _ = libc.close(fd);
            if (!fast_walker.hasCacheDirTag(fd)) return "its CACHEDIR.TAG is gone, so it is no longer build output";
            return null;
        },
    }
}

fn insideVcs(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (isVcsName(part)) return true;
    return false;
}

const Age = struct {
    newest: ?i64 = null,
    problem: ?[]const u8 = null,
};

/// The newest modification or status change of the folder at `path` and of
/// everything in it, read through descriptors from the folder down (no path
/// is resolved twice, no link followed). The folder must still be the one
/// scanned (`dev`, `ino`), and everything in it on its filesystem and
/// readable; otherwise `problem` says what is wrong.
fn newestChange(a: Allocator, path: []const u8, dev: u64, ino: u64) Age {
    if (comptime builtin.os.tag == .windows) return .{ .problem = "the Trash is not supported on this platform" };
    var age: Age = .{};
    const z = a.dupeSentinel(u8, path, 0) catch return .{ .problem = "out of memory" };
    const top_fd = libc.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(libc.mode_t, 0));
    if (top_fd < 0) return .{ .problem = "is no longer a folder that can be opened (gone, or now a link)" };
    const top = pstat.fstat(top_fd) catch {
        _ = libc.close(top_fd);
        return .{ .problem = "cannot be read" };
    };
    if (top.dev != dev or top.ino != ino) {
        _ = libc.close(top_fd);
        return .{ .problem = "is not the folder that was scanned (it was replaced)" };
    }
    var newest = @max(top.mtime_sec, top.ctime_sec);

    // Each open folder with its descriptor, which the stream owns.
    const Open = struct { dir: *libc.DIR, fd: c_int };
    var stack: std.ArrayListUnmanaged(Open) = .empty;
    const first = libc.fdopendir(top_fd) orelse {
        _ = libc.close(top_fd);
        return .{ .problem = "cannot be read" };
    };
    stack.append(a, .{ .dir = first, .fd = top_fd }) catch {
        _ = libc.closedir(first);
        return .{ .problem = "out of memory" };
    };
    defer for (stack.items) |o| {
        _ = libc.closedir(o.dir);
    };
    while (stack.items.len > 0) {
        const top_open = stack.items[stack.items.len - 1];
        const entry = libc.readdir(top_open.dir) orelse {
            _ = libc.closedir(top_open.dir);
            stack.items.len -= 1;
            continue;
        };
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const fd = top_open.fd;
        const st = pstat.lstatAt(fd, name_ptr) catch {
            age.problem = "parts of it could not be read";
            break;
        };
        newest = @max(newest, @max(st.mtime_sec, st.ctime_sec));
        if (!st.isDir()) continue;
        if (st.dev != dev) {
            age.problem = "holds another volume's mount point";
            break;
        }
        const child_fd = libc.openat(fd, name_ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(libc.mode_t, 0));
        if (child_fd < 0) {
            age.problem = "parts of it could not be read";
            break;
        }
        const child = libc.fdopendir(child_fd) orelse {
            _ = libc.close(child_fd);
            age.problem = "parts of it could not be read";
            break;
        };
        stack.append(a, .{ .dir = child, .fd = child_fd }) catch {
            _ = libc.closedir(child);
            age.problem = "out of memory";
            break;
        };
    }
    age.newest = newest;
    return age;
}

fn realtimeSeconds() i64 {
    var ts: libc.timespec = undefined;
    _ = libc.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

// ===========================================================================
// Ages on the command line
// ===========================================================================

/// `90s`, `30m`, `24h`, `3d`, `2w`; a bare number is seconds.
pub fn parseAge(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    const unit: i64 = switch (text[text.len - 1]) {
        's' => 1,
        'm' => std.time.s_per_min,
        'h' => std.time.s_per_hour,
        'd' => std.time.s_per_day,
        'w' => std.time.s_per_week,
        '0'...'9' => return std.fmt.parseInt(i64, text, 10) catch null,
        else => return null,
    };
    const n = std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch return null;
    if (n < 0) return null;
    return std.math.mul(i64, n, unit) catch null;
}

/// `3d`, `5h`, `12m`, `40s`.
fn formatAge(buf: []u8, seconds: i64) []const u8 {
    const s = @max(seconds, 0);
    const out = if (s >= std.time.s_per_day)
        std.fmt.bufPrint(buf, "{d}d", .{@divFloor(s, std.time.s_per_day)})
    else if (s >= std.time.s_per_hour)
        std.fmt.bufPrint(buf, "{d}h", .{@divFloor(s, std.time.s_per_hour)})
    else if (s >= std.time.s_per_min)
        std.fmt.bufPrint(buf, "{d}m", .{@divFloor(s, std.time.s_per_min)})
    else
        std.fmt.bufPrint(buf, "{d}s", .{s});
    return out catch "?";
}

// ===========================================================================
// Output
// ===========================================================================

/// The JSON document; its schema is in the README ("zdedupe clean").
pub fn writeJson(gpa: Allocator, report: *const Report, out: *Io.Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var json: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    const S = struct {
        fn path(j: *std.json.Stringify, al: Allocator, p: []const u8) !void {
            try j.write(try session.lossy(al, p));
        }
        fn optPath(j: *std.json.Stringify, al: Allocator, p: ?[]const u8) !void {
            if (p) |v| try path(j, al, v) else try j.write(null);
        }
        fn field(j: *std.json.Stringify, name: []const u8, value: anytype) !void {
            try j.objectField(name);
            try j.write(value);
        }
    };
    try json.beginObject();
    try S.field(&json, "schema", schema_version);
    try S.field(&json, "generated_at", report.generated_at);
    try S.field(&json, "older_than_s", report.older_s);

    try json.objectField("git");
    try json.beginObject();
    try S.field(&json, "available", report.git_version != null);
    try S.field(&json, "version", report.git_version);
    try json.endObject();

    try json.objectField("main_roots");
    try json.beginArray();
    for (report.main_roots) |m| try S.path(&json, a, m);
    try json.endArray();

    try json.objectField("roots");
    try json.beginArray();
    for (report.roots) |r| {
        try json.beginObject();
        try json.objectField("path");
        try S.path(&json, a, r.path);
        try json.objectField("given");
        try S.path(&json, a, r.given);
        try S.field(&json, "error", r.err);
        try S.field(&json, "build_dirs", r.build_dirs);
        try S.field(&json, "bytes", r.bytes);
        try S.field(&json, "files", r.files);
        try S.field(&json, "unreadable", r.unreadable);
        try S.field(&json, "left_out", r.left_out);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("build_dirs");
    try json.beginArray();
    for (report.build_dirs) |b| {
        try json.beginObject();
        try json.objectField("path");
        try S.path(&json, a, b.path);
        try json.objectField("kind");
        try S.path(&json, a, b.kind);
        try S.field(&json, "rule", @tagName(b.rule));
        try json.objectField("root");
        try S.path(&json, a, report.roots[b.root].path);
        try json.objectField("project");
        try S.optPath(&json, a, if (b.project) |p| report.projects[p].path else null);
        try S.field(&json, "bytes", b.bytes);
        try S.field(&json, "logical_bytes", b.logical_bytes);
        try S.field(&json, "files", b.files);
        try S.field(&json, "hardlinked_bytes", b.hardlinked_bytes);
        try S.field(&json, "newest_mtime", b.newest_mtime);
        try S.field(&json, "complete", b.complete);
        try S.field(&json, "duplicate_set", b.duplicate_set);
        try json.objectField("trash");
        try json.beginObject();
        try S.field(&json, "eligible", b.trash.eligible);
        try S.field(&json, "refusal", b.trash.refusal);
        try S.field(&json, "newest_change", b.trash.newest_change);
        try json.endObject();
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("duplicate_sets");
    try json.beginArray();
    for (report.duplicate_sets) |set| {
        try json.beginObject();
        try json.objectField("kind");
        try S.path(&json, a, set.kind);
        try S.field(&json, "copies", set.members.len);
        try S.field(&json, "bytes_each", set.bytes_each);
        try S.field(&json, "files_each", set.files_each);
        try S.field(&json, "reclaimable", set.reclaimable);
        try json.objectField("paths");
        try json.beginArray();
        for (set.members) |i| try S.path(&json, a, report.build_dirs[i].path);
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("projects");
    try json.beginArray();
    for (report.projects) |p| {
        try json.beginObject();
        try json.objectField("path");
        try S.path(&json, a, p.path);
        try json.objectField("root");
        try S.path(&json, a, report.roots[p.root].path);
        try S.field(&json, "markers", p.markers);
        try S.field(&json, "build_dirs", p.build_dirs);
        try S.field(&json, "build_bytes", p.build_bytes);
        if (p.facts) |f| {
            try S.field(&json, "verdict", @tagName(f.verdict));
            try json.objectField("reasons");
            try json.beginArray();
            for (f.reasons) |r| try S.path(&json, a, r);
            try json.endArray();
            try json.objectField("ignored_by");
            try S.optPath(&json, a, f.ignored_by);
            try json.objectField("git");
            if (f.checkout) |c| {
                try json.beginObject();
                try json.objectField("toplevel");
                try S.path(&json, a, c.toplevel);
                try json.objectField("origin");
                try S.optPath(&json, a, c.origin);
                try json.objectField("origin_key");
                try S.optPath(&json, a, c.origin_key);
                try json.objectField("branch");
                try S.optPath(&json, a, c.branch);
                try S.field(&json, "head", c.head);
                try S.field(&json, "linked_worktree", c.linked_worktree);
                try json.objectField("main_repository");
                try S.optPath(&json, a, c.main_repository);
                try json.objectField("main_checkouts");
                try json.beginArray();
                for (c.main_checkouts) |m| try S.path(&json, a, m);
                try json.endArray();
                try S.field(&json, "is_main_checkout", c.is_main_checkout);
                try S.field(&json, "remotes", c.remotes);
                try S.field(&json, "uncommitted", c.uncommitted);
                try S.field(&json, "unpushed_commits", c.unpushed_commits);
                try S.field(&json, "stashes", c.stashes);
                try S.field(&json, "head_on_remote", c.head_on_remote);
                try S.field(&json, "head_in_main", c.head_in_main);
                try json.objectField("unique_branches");
                try json.beginArray();
                for (c.unique_tips) |t| {
                    try json.beginObject();
                    try json.objectField("name");
                    try S.path(&json, a, t.name);
                    try S.field(&json, "commits", t.commits);
                    try json.endObject();
                }
                try json.endArray();
                try json.endObject();
            } else {
                try json.write(null);
            }
        } else {
            try S.field(&json, "verdict", null);
            try json.objectField("reasons");
            try json.beginArray();
            try json.write("git is not available");
            try json.endArray();
            try S.field(&json, "ignored_by", null);
            try S.field(&json, "git", null);
        }
        try json.endObject();
    }
    try json.endArray();

    var total_bytes: u64 = 0;
    var total_files: u64 = 0;
    var reclaimable: u64 = 0;
    for (report.build_dirs) |b| {
        total_bytes += b.bytes;
        total_files += b.files;
    }
    for (report.duplicate_sets) |s| reclaimable += s.reclaimable;
    const eligible = report.eligibleBytes();
    try json.objectField("totals");
    try json.beginObject();
    try S.field(&json, "build_dirs", report.build_dirs.len);
    try S.field(&json, "bytes", total_bytes);
    try S.field(&json, "files", total_files);
    try S.field(&json, "duplicate_reclaimable", reclaimable);
    try S.field(&json, "eligible", eligible.count);
    try S.field(&json, "eligible_bytes", eligible.bytes);
    try json.endObject();

    try json.objectField("trash");
    if (report.trash) |t| {
        try json.beginObject();
        try json.objectField("moved");
        try json.beginArray();
        for (t.moved) |m| {
            try json.beginObject();
            try json.objectField("path");
            try S.path(&json, a, m.path);
            try S.field(&json, "bytes", m.bytes);
            try json.objectField("trashed_as");
            try S.path(&json, a, m.trashed_as);
            try json.endObject();
        }
        try json.endArray();
        try json.objectField("skipped");
        try json.beginArray();
        for (t.skipped) |s| {
            try json.beginObject();
            try json.objectField("path");
            try S.path(&json, a, s.path);
            try S.field(&json, "bytes", s.bytes);
            try json.objectField("reason");
            try S.path(&json, a, s.reason);
            try json.endObject();
        }
        try json.endArray();
        try S.field(&json, "bytes_moved", t.bytes_moved);
        try json.endObject();
    } else {
        try json.write(null);
    }
    try json.endObject();
    try out.writeByte('\n');
}

/// The readable report: per root, largest first; duplicate sets; projects
/// with their verdicts; what the Trash would take (or took).
pub fn writeText(report: *const Report, out: *Io.Writer) !void {
    var size_buf: [32]u8 = undefined;
    var size_buf2: [32]u8 = undefined;
    var age_buf: [16]u8 = undefined;
    const now = report.generated_at;

    var total_bytes: u64 = 0;
    for (report.build_dirs) |b| total_bytes += b.bytes;
    var reclaimable: u64 = 0;
    for (report.duplicate_sets) |s| reclaimable += s.reclaimable;
    try out.print("Build output under {d} root{s}: {s} in {d} folder{s}", .{
        report.roots.len,                          plural(report.roots.len),
        types.formatBytes(total_bytes, &size_buf), report.build_dirs.len,
        plural(report.build_dirs.len),
    });
    if (report.duplicate_sets.len > 0) {
        try out.print(", {s} of it in identical copies", .{types.formatBytes(reclaimable, &size_buf)});
    }
    try out.writeAll("\n");

    for (report.roots, 0..) |r, ri| {
        try out.print("\n{s}", .{r.path});
        if (r.err) |e| {
            try out.print(": not scanned ({s})\n", .{e});
            continue;
        }
        try out.print(": {s} in {d} build folder{s}", .{ types.formatBytes(r.bytes, &size_buf), r.build_dirs, plural(r.build_dirs) });
        if (r.unreadable > 0) try out.print(", {d} unreadable entr{s}", .{ r.unreadable, if (r.unreadable == 1) "y" else "ies" });
        try out.writeAll("\n");
        if (r.build_dirs == 0) continue;
        try out.print("  {s:>10}  {s:>8}  {s:>6}  {s:<14}  {s}\n", .{ "on disk", "files", "newest", "kind", "path" });
        var listed: usize = 0;
        var rest_count: u64 = 0;
        var rest_bytes: u64 = 0;
        for (report.build_dirs) |b| {
            if (b.root != ri) continue;
            if (listed == text_rows_per_root) {
                rest_count += 1;
                rest_bytes += b.bytes;
                continue;
            }
            listed += 1;
            const newest = if (b.newest_mtime) |m| formatAge(&age_buf, now - m) else "-";
            try out.print("  {s:>10}  {d:>8}  {s:>6}  {s:<14}  {s}", .{ types.formatBytes(b.bytes, &size_buf), b.files, newest, b.kind, b.path });
            if (b.rule == .cachedir_tag) try out.writeAll("  [CACHEDIR.TAG]");
            if (b.duplicate_set) |d| try out.print("  [copy, set {d}]", .{d + 1});
            if (!b.complete) try out.writeAll("  [partly unreadable]");
            try out.writeAll("\n");
        }
        if (rest_count > 0) try out.print("  {s:>10}  in {d} smaller folder{s} (all of them are in --json)\n", .{ types.formatBytes(rest_bytes, &size_buf), rest_count, plural(rest_count) });
    }

    if (report.duplicate_sets.len > 0) {
        try out.writeAll("\nIdentical build folders (same content)\n");
        for (report.duplicate_sets, 0..) |s, k| {
            try out.print("  set {d}: {d} copies of {s}, {s} each; keeping one frees {s}\n", .{
                k + 1,                                        s.members.len,
                s.kind,                                       types.formatBytes(s.bytes_each, &size_buf),
                types.formatBytes(s.reclaimable, &size_buf2),
            });
            for (s.members) |i| try out.print("      {s}\n", .{report.build_dirs[i].path});
        }
    }

    if (report.projects.len > 0) try writeProjects(report, out);

    try out.writeAll("\n");
    if (report.trash) |t| {
        try out.print("Moved to the Trash: {s} in {d} folder{s}\n", .{ types.formatBytes(t.bytes_moved, &size_buf), t.moved.len, plural(t.moved.len) });
        for (t.moved) |m| try out.print("  {s:>10}  {s}\n              now {s}\n", .{ types.formatBytes(m.bytes, &size_buf), m.path, m.trashed_as });
        if (t.skipped.len > 0) {
            try out.print("Left in place: {d} folder{s}\n", .{ t.skipped.len, plural(t.skipped.len) });
            for (t.skipped) |s| try out.print("  {s:>10}  {s}\n              {s}\n", .{ types.formatBytes(s.bytes, &size_buf), s.path, s.reason });
        }
    } else {
        const eligible = report.eligibleBytes();
        var older_buf: [16]u8 = undefined;
        try out.print("With --trash: {s} in {d} folder{s} would go to the Trash (nothing in them changed for {s})\n", .{
            types.formatBytes(eligible.bytes, &size_buf), eligible.count, plural(eligible.count), formatAge(&older_buf, report.older_s),
        });
        try writeRefusals(report, out);
    }
}

const ProjectGroup = enum { unique_in_git, not_vouched, held_elsewhere, no_git };

fn groupOf(p: *const Project) ProjectGroup {
    const f = p.facts orelse return .no_git;
    if (f.verdict == .main_has_everything) return .held_elsewhere;
    if (f.checkout == null and f.err == null) return .not_vouched;
    return .unique_in_git;
}

/// Projects in three groups: unique work git can see (in full), copies
/// nothing vouches for (a line each), copies held elsewhere (a line each).
fn writeProjects(report: *const Report, out: *Io.Writer) !void {
    var size_buf: [32]u8 = undefined;
    var counts: [std.meta.fieldNames(ProjectGroup).len]usize = @splat(0);
    for (report.projects) |*p| counts[@backingInt(groupOf(p))] += 1;
    const unique = counts[@backingInt(ProjectGroup.unique_in_git)] + counts[@backingInt(ProjectGroup.not_vouched)];
    try out.print("\nProjects: {d}, {d} with work found nowhere else\n", .{ report.projects.len, unique });

    const titles = [_][]const u8{
        "has_unique_work: git sees work on no remote and in no main checkout, or cannot tell",
        "has_unique_work: nothing vouches for them (not in a git repository)",
        "main_has_everything: committed, pushed or in a main checkout",
        "no verdict: git is not available",
    };
    for (titles, 0..) |title, g| {
        if (counts[g] == 0) continue;
        try out.print("\n  {s} ({d})\n", .{ title, counts[g] });
        for (report.projects) |*p| {
            if (@backingInt(groupOf(p)) != g) continue;
            try out.print("    {s}", .{p.path});
            if (p.build_dirs > 0) try out.print("  (build output {s})", .{types.formatBytes(p.build_bytes, &size_buf)});
            try out.writeAll("\n");
            const f = p.facts orelse continue;
            if (f.checkout) |c| {
                try out.print("        {s}", .{c.origin orelse "no origin"});
                if (c.branch) |br| try out.print(", branch {s}", .{br}) else try out.writeAll(", detached");
                if (c.head) |h| try out.print(" @ {s}", .{h[0..@min(h.len, 12)]});
                if (!std.mem.eql(u8, c.toplevel, p.path)) try out.print(", checkout {s}", .{c.toplevel});
                if (c.is_main_checkout) try out.writeAll(" (a main checkout)");
                try out.writeAll("\n");
                if (c.linked_worktree) try out.print("        worktree of {s}\n", .{c.main_repository orelse "?"});
                for (c.main_checkouts) |m| try out.print("        main checkout {s}\n", .{m});
            }
            if (g == @backingInt(ProjectGroup.not_vouched)) {
                if (f.ignored_by) |by| try out.print("        ignored by the repository at {s}\n", .{by});
                continue;
            }
            for (f.reasons) |r| try out.print("        why: {s}\n", .{r});
        }
    }
}

/// Why the other build folders would stay, grouped by reason.
fn writeRefusals(report: *const Report, out: *Io.Writer) !void {
    var size_buf: [32]u8 = undefined;
    var seen: [32][]const u8 = undefined;
    var n_seen: usize = 0;
    for (report.build_dirs) |b| {
        const reason = b.trash.refusal orelse continue;
        const known = for (seen[0..n_seen]) |s| {
            if (std.mem.eql(u8, s, reason)) break true;
        } else false;
        if (known) continue;
        if (n_seen < seen.len) {
            seen[n_seen] = reason;
            n_seen += 1;
        }
        var count: u64 = 0;
        var bytes: u64 = 0;
        for (report.build_dirs) |o| if (o.trash.refusal) |r| if (std.mem.eql(u8, r, reason)) {
            count += 1;
            bytes += o.bytes;
        };
        try out.print("  stays: {s} in {d} folder{s}: {s}\n", .{ types.formatBytes(bytes, &size_buf), count, plural(count), reason });
    }
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Scratch = @import("testing_scratch.zig").Scratch;

test "ages on the command line" {
    try testing.expectEqual(@as(?i64, 86400), parseAge("24h"));
    try testing.expectEqual(@as(?i64, 90), parseAge("90s"));
    try testing.expectEqual(@as(?i64, 1800), parseAge("30m"));
    try testing.expectEqual(@as(?i64, 3 * 86400), parseAge("3d"));
    try testing.expectEqual(@as(?i64, 14 * 86400), parseAge("2w"));
    try testing.expectEqual(@as(?i64, 600), parseAge("600"));
    try testing.expect(parseAge("") == null);
    try testing.expect(parseAge("h") == null);
    try testing.expect(parseAge("-1h") == null);
    try testing.expect(parseAge("1y") == null);
}

test "preorder puts a folder's contents directly after it" {
    try testing.expect(preorderLess("/a/b", "/a/b/c"));
    try testing.expect(preorderLess("/a/b/c", "/a/b-c"));
    try testing.expect(!preorderLess("/a/b-c", "/a/b/c"));
}

test "the core's protection refuses macOS temp areas by their real path" {
    try testing.expect(protectedByCore(null, "/private/tmp/claude-502/x/node_modules"));
    try testing.expect(protectedByCore(null, "/usr/local/lib/node_modules"));
    try testing.expect(protectedByCore(null, "/srv/a/.git/x/node_modules"));
    try testing.expect(!protectedByCore(null, "/srv/scratch/app/node_modules"));
}

/// A tree of scratch copies with every kind of build output, built under
/// `scratch`. Protection for the fixture: only `<fixture>/protected` and
/// version-control stores, through protect.zig with the fixture standing in
/// for a folder outside every system root.
const Fixture = struct {
    scratch: Scratch,
    real: []const u8,

    fn init(arena: Allocator, label: []const u8) !Fixture {
        const scratch = try Scratch.init(testing.allocator, label);
        return .{ .scratch = scratch, .real = gitinfo.realPath(arena, scratch.path).? };
    }

    fn deinit(self: *Fixture) void {
        self.scratch.deinit();
    }

    fn path(self: *const Fixture, arena: Allocator, rel: []const u8) []const u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ self.real, rel }) catch unreachable;
    }

    fn guard(ctx: ?*const anyopaque, p: []const u8) bool {
        const self: *const Fixture = @ptrCast(@alignCast(ctx.?));
        if (!filters.isAtOrUnder(p, self.real)) return true;
        var buf: [4096]u8 = undefined;
        const moved = std.fmt.bufPrint(&buf, "/srv/fixture{s}", .{p[self.real.len..]}) catch return true;
        const user = [_][]const u8{"/srv/fixture/protected"};
        const protection: protect.Protection = .{ .user = &user };
        return protection.guardsFolder(moved);
    }

    /// Set every timestamp in the fixture to `seconds` ago... as far as the
    /// modification time goes; the status change time is the system's.
    fn ageTree(self: *const Fixture, arena: Allocator, rel: []const u8, mtime: i64) !void {
        const full = try arena.dupeSentinel(u8, self.path(arena, rel), 0);
        var times = [2]libc.timeval{ .{ .sec = mtime, .usec = 0 }, .{ .sec = mtime, .usec = 0 } };
        try testing.expectEqual(@as(c_int, 0), libc.utimes(full.ptr, &times));
    }
};

fn fakeTrash(arena: Allocator, path: []const u8, is_dir: bool) trash_mod.Outcome {
    _ = is_dir;
    // Into a sibling folder named like the Trash, on the same filesystem.
    const parent = filters.parentDir(path) orelse return .{ .failed = "no parent" };
    const dest = std.fmt.allocPrintSentinel(arena, "{s}/.fake-trash-{s}", .{ parent, filters.baseName(path) }, 0) catch return .{ .failed = "oom" };
    const src = arena.dupeSentinel(u8, path, 0) catch return .{ .failed = "oom" };
    if (libc.rename(src.ptr, dest.ptr) != 0) return .{ .failed = "rename failed" };
    return .{ .moved = dest[0..dest.len] };
}

fn buildFixture(f: *Fixture) !void {
    const s = &f.scratch;
    // Two scratch copies of one app with the same node_modules, and a third
    // whose node_modules differs by one byte.
    for ([_][]const u8{ "copy-a", "copy-b", "copy-c" }) |copy| {
        var buf: [256]u8 = undefined;
        try s.makeDir(copy);
        try s.writeFile(try std.fmt.bufPrint(&buf, "{s}/package.json", .{copy}), "{\"name\":\"app\"}");
        try s.makeDir(try std.fmt.bufPrint(&buf, "{s}/node_modules", .{copy}));
        try s.makeDir(try std.fmt.bufPrint(&buf, "{s}/node_modules/left-pad", .{copy}));
        const body = if (std.mem.eql(u8, copy, "copy-c")) "module.exports = 2;\n" else "module.exports = 1;\n";
        try s.writeFile(try std.fmt.bufPrint(&buf, "{s}/node_modules/left-pad/index.js", .{copy}), body);
        try s.writeFile(try std.fmt.bufPrint(&buf, "{s}/node_modules/left-pad/package.json", .{copy}), "{\"name\":\"left-pad\"}");
        // Build output inside build output is not a finding of its own.
        try s.makeDir(try std.fmt.bufPrint(&buf, "{s}/node_modules/left-pad/node_modules", .{copy}));
        try s.writeFile(try std.fmt.bufPrint(&buf, "{s}/node_modules/left-pad/node_modules/x.js", .{copy}), "x");
    }
    // `target` counts beside Cargo.toml, and not beside nothing.
    try s.makeDir("rusty");
    try s.writeFile("rusty/Cargo.toml", "[package]\nname = \"r\"\n");
    try s.makeDir("rusty/target");
    try s.writeFile("rusty/target/out.rlib", "rlib bytes");
    try s.makeDir("rusty/target/zig-out");
    try s.writeFile("rusty/target/zig-out/inner", "inside target");
    try s.makeDir("photos");
    try s.makeDir("photos/target");
    try s.writeFile("photos/target/shot.jpg", "jpeg");
    // A tagged cache folder by any name; a file merely named CACHEDIR.TAG is not a tag.
    try s.makeDir("tool");
    try s.makeDir("tool/scratchpad-cache");
    try s.writeFile("tool/scratchpad-cache/CACHEDIR.TAG", fast_walker.cache_dir_signature ++ "\n");
    try s.writeFile("tool/scratchpad-cache/blob", "cached");
    try s.makeDir("tool/swapped-cache");
    try s.writeFile("tool/swapped-cache/CACHEDIR.TAG", fast_walker.cache_dir_signature ++ "\n");
    try s.writeFile("tool/swapped-cache/blob", "cached too");
    try s.makeDir("tool/notes");
    try s.writeFile("tool/notes/CACHEDIR.TAG", "");
    try s.writeFile("tool/notes/todo.txt", "keep me");
    // Protected, and a link that only looks like build output.
    try s.makeDir("protected");
    try s.makeDir("protected/zig-out");
    try s.writeFile("protected/zig-out/bin", "built");
    try s.makeDir("linked");
    try s.symLink("../copy-a/node_modules", "linked/node_modules");
}

fn find(report: *const Report, f: *const Fixture, arena: Allocator, rel: []const u8) ?*const BuildDir {
    const want = f.path(arena, rel);
    for (report.build_dirs) |*b| if (std.mem.eql(u8, b.path, want)) return b;
    return null;
}

test "clean finds build output by the core's rule, and copies of it by content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Fixture.init(a, "clean-find");
    defer f.deinit();
    try buildFixture(&f);

    var report = try scan(testing.allocator, testing.io, .{
        .roots = &.{f.real},
        .main_roots = &.{f.path(a, "no-main-roots")},
        .guard_fn = Fixture.guard,
        .guard_ctx = &f,
        .git_exe = "/nonexistent/zdedupe/git",
    });
    defer report.deinit();

    try testing.expect(find(&report, &f, a, "copy-a/node_modules") != null);
    try testing.expect(find(&report, &f, a, "copy-b/node_modules") != null);
    try testing.expect(find(&report, &f, a, "copy-c/node_modules") != null);
    try testing.expect(find(&report, &f, a, "copy-a/node_modules/left-pad/node_modules") == null);
    const target = find(&report, &f, a, "rusty/target").?;
    try testing.expectEqual(Rule.beside_manifest, target.rule);
    try testing.expect(find(&report, &f, a, "rusty/target/zig-out") == null);
    try testing.expectEqual(@as(u64, 2), target.files);
    try testing.expect(find(&report, &f, a, "photos/target") == null);
    const tagged = find(&report, &f, a, "tool/scratchpad-cache").?;
    try testing.expectEqual(Rule.cachedir_tag, tagged.rule);
    try testing.expect(find(&report, &f, a, "tool/notes") == null);
    try testing.expect(find(&report, &f, a, "linked/node_modules") == null);
    try testing.expect(find(&report, &f, a, "protected/zig-out") != null);
    try testing.expectEqual(@as(usize, 7), report.build_dirs.len);

    // Measured: the nested node_modules counts toward its outer folder.
    const nm = find(&report, &f, a, "copy-a/node_modules").?;
    try testing.expectEqual(@as(u64, 3), nm.files);
    try testing.expect(nm.bytes > 0 and nm.complete);
    try testing.expect(nm.newest_mtime != null);
    try testing.expectEqualStrings(f.path(a, "copy-a"), report.projects[nm.project.?].path);
    try testing.expectEqualStrings(f.path(a, "rusty"), report.projects[target.project.?].path);
    try testing.expect(tagged.project == null);

    // a and b are one set; c differs by a byte and is in none.
    try testing.expectEqual(@as(usize, 1), report.duplicate_sets.len);
    const set = report.duplicate_sets[0];
    try testing.expectEqual(@as(usize, 2), set.members.len);
    try testing.expectEqualStrings(f.path(a, "copy-a/node_modules"), report.build_dirs[set.members[0]].path);
    try testing.expectEqualStrings(f.path(a, "copy-b/node_modules"), report.build_dirs[set.members[1]].path);
    try testing.expectEqualStrings("node_modules", set.kind);
    try testing.expect(find(&report, &f, a, "copy-c/node_modules").?.duplicate_set == null);

    // No git: projects carry no verdict, and say so.
    try testing.expect(report.git_version == null);
    for (report.projects) |p| try testing.expect(p.facts == null);

    // Both outputs render; the JSON parses and says what it is.
    var text: Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try writeText(&report, &text.writer);
    try testing.expect(std.mem.indexOf(u8, text.writer.buffered(), "Identical build folders") != null);
    var json: Io.Writer.Allocating = .init(testing.allocator);
    defer json.deinit();
    try writeJson(testing.allocator, &report, &json.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json.writer.buffered(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(schema_version, parsed.value.object.get("schema").?.string);
    try testing.expectEqual(@as(usize, 7), parsed.value.object.get("build_dirs").?.array.items.len);
}

test "clean --trash moves only old, unprotected build output under a root, rechecked just before" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Fixture.init(a, "clean-trash");
    defer f.deinit();
    try buildFixture(&f);
    try f.scratch.makeDir(".git");
    try f.scratch.makeDir(".git/node_modules");
    try f.scratch.writeFile(".git/node_modules/x", "in the store");

    const day = std.time.s_per_day;
    // The status-change time is the system's: "now", as the fixture was
    // just written. Measure from a day and a minute ahead so all of it is old...
    const now = realtimeSeconds() + day + 60;
    const opts: Options = .{
        .roots = &.{f.real},
        .main_roots = &.{f.path(a, "no-main-roots")},
        .guard_fn = Fixture.guard,
        .guard_ctx = &f,
        .git_exe = "/nonexistent/zdedupe/git",
        .trash_fn = fakeTrash,
        .now = now,
    };
    var report = try scan(testing.allocator, testing.io, opts);
    defer report.deinit();

    // ...except one folder, touched to look fresh: a modification time in
    // the future of `now` stands for a build that just wrote.
    try f.ageTree(a, "copy-c/node_modules/left-pad/index.js", now);
    // Between the scan and the move, one folder becomes a link and one
    // loses its manifest.
    const b_nm = try a.dupeSentinel(u8, f.path(a, "copy-b/node_modules"), 0);
    const b_moved = try a.dupeSentinel(u8, f.path(a, "copy-b/elsewhere"), 0);
    try testing.expectEqual(@as(c_int, 0), libc.rename(b_nm.ptr, b_moved.ptr));
    try f.scratch.symLink("elsewhere", "copy-b/node_modules");
    const cargo = try a.dupeSentinel(u8, f.path(a, "rusty/Cargo.toml"), 0);
    try testing.expectEqual(@as(c_int, 0), libc.unlink(cargo.ptr));
    // And one is replaced by another folder of the same name and rule.
    const swapped = try a.dupeSentinel(u8, f.path(a, "tool/swapped-cache"), 0);
    const swapped_away = try a.dupeSentinel(u8, f.path(a, "tool/swapped-away"), 0);
    try testing.expectEqual(@as(c_int, 0), libc.rename(swapped.ptr, swapped_away.ptr));
    try f.scratch.makeDir("tool/swapped-cache");
    try f.scratch.writeFile("tool/swapped-cache/CACHEDIR.TAG", fast_walker.cache_dir_signature ++ "\n");

    try trashEligible(testing.allocator, &report, opts);
    const t = report.trash.?;

    var moved: std.StringHashMapUnmanaged(void) = .empty;
    for (t.moved) |m| try moved.put(a, m.path, {});
    try testing.expect(moved.contains(f.path(a, "copy-a/node_modules")));
    try testing.expect(moved.contains(f.path(a, "tool/scratchpad-cache")));
    try testing.expectEqual(@as(usize, 2), t.moved.len);
    try testing.expect(!try f.scratch.exists("copy-a/node_modules"));
    try testing.expect(try f.scratch.exists("copy-a/.fake-trash-node_modules/left-pad/index.js"));

    var skipped: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (t.skipped) |s| try skipped.put(a, s.path, s.reason);
    try testing.expect(std.mem.indexOf(u8, skipped.get(f.path(a, "protected/zig-out")).?, "protected") != null);
    try testing.expect(std.mem.indexOf(u8, skipped.get(f.path(a, "copy-b/node_modules")).?, "link") != null);
    try testing.expect(std.mem.indexOf(u8, skipped.get(f.path(a, "rusty/target")).?, "manifest") != null);
    try testing.expect(std.mem.indexOf(u8, skipped.get(f.path(a, "copy-c/node_modules")).?, "recently") != null);
    try testing.expect(std.mem.indexOf(u8, skipped.get(f.path(a, "tool/swapped-cache")).?, "replaced") != null);
    try testing.expect(try f.scratch.exists("tool/swapped-cache/CACHEDIR.TAG"));
    try testing.expect(try f.scratch.exists("tool/swapped-away/blob"));
    // Never a store, never a link, never anything that is not build output.
    try testing.expect(try f.scratch.exists(".git/node_modules/x"));
    try testing.expect(try f.scratch.exists("copy-b/elsewhere/left-pad/index.js"));
    try testing.expect(try f.scratch.exists("photos/target/shot.jpg"));
    try testing.expect(try f.scratch.exists("tool/notes/todo.txt"));
    try testing.expect(try f.scratch.exists("copy-a/package.json"));
}

test "clean --older: a just-built folder stays, measured by status changes too" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Fixture.init(a, "clean-older");
    defer f.deinit();
    // Three build folders whose files all carry modification times ten years
    // old, as an unpacker that restores them leaves them.
    const ten_years_ago = realtimeSeconds() - 10 * 365 * std.time.s_per_day;
    for ([_][]const u8{ "inner", "outer", "still" }) |name| {
        var buf: [128]u8 = undefined;
        try f.scratch.makeDir(name);
        try f.scratch.writeFile(try std.fmt.bufPrint(&buf, "{s}/build.zig", .{name}), "");
        try f.scratch.makeDir(try std.fmt.bufPrint(&buf, "{s}/zig-out", .{name}));
        try f.scratch.makeDir(try std.fmt.bufPrint(&buf, "{s}/zig-out/bin", .{name}));
        try f.scratch.writeFile(try std.fmt.bufPrint(&buf, "{s}/zig-out/bin/app", .{name}), "built");
        try f.ageTree(a, try std.fmt.bufPrint(&buf, "{s}/zig-out/bin/app", .{name}), ten_years_ago);
        try f.ageTree(a, try std.fmt.bufPrint(&buf, "{s}/zig-out/bin", .{name}), ten_years_ago);
        try f.ageTree(a, try std.fmt.bufPrint(&buf, "{s}/zig-out", .{name}), ten_years_ago);
    }
    // Three seconds on, one folder has a file whose status just changed, and
    // one has only its own status changed; their modification times stay old.
    const pause: libc.timespec = .{ .sec = 3, .nsec = 0 };
    _ = libc.nanosleep(&pause, null);
    try f.ageTree(a, "inner/zig-out/bin/app", ten_years_ago);
    try f.ageTree(a, "outer/zig-out", ten_years_ago);

    var report = try run(testing.allocator, testing.io, .{
        .roots = &.{f.real},
        .main_roots = &.{f.path(a, "none")},
        .guard_fn = Fixture.guard,
        .guard_ctx = &f,
        .git_exe = "/nonexistent/zdedupe/git",
        .trash_fn = fakeTrash,
        .older_s = 2,
    }, true);
    defer report.deinit();
    for ([_][]const u8{ "inner/zig-out", "outer/zig-out" }) |rel| {
        const b = find(&report, &f, a, rel).?;
        try testing.expectEqual(ten_years_ago, b.newest_mtime.?);
        try testing.expect(!b.trash.eligible);
        try testing.expect(b.trash.newest_change.? > ten_years_ago);
    }
    try testing.expect(try f.scratch.exists("inner/zig-out/bin/app"));
    try testing.expect(try f.scratch.exists("outer/zig-out/bin/app"));
    // The untouched one is old by every measure, and goes.
    try testing.expect(find(&report, &f, a, "still/zig-out").?.trash.eligible);
    try testing.expectEqual(@as(usize, 1), report.trash.?.moved.len);
    try testing.expect(!try f.scratch.exists("still/zig-out"));
}

test "clean leaves a build folder it could not read completely" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    if (libc.geteuid() == 0) return error.SkipZigTest; // root reads everything
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Fixture.init(a, "clean-unreadable");
    defer f.deinit();
    try f.scratch.makeDir("app");
    try f.scratch.writeFile("app/package.json", "{}");
    try f.scratch.makeDir("app/node_modules");
    try f.scratch.makeDir("app/node_modules/locked");
    try f.scratch.writeFile("app/node_modules/locked/x.js", "x");
    const locked = try a.dupeSentinel(u8, f.path(a, "app/node_modules/locked"), 0);
    try testing.expectEqual(@as(c_int, 0), libc.chmod(locked.ptr, 0));
    defer _ = libc.chmod(locked.ptr, 0o700);

    var report = try run(testing.allocator, testing.io, .{
        .roots = &.{f.real},
        .main_roots = &.{f.path(a, "none")},
        .guard_fn = Fixture.guard,
        .guard_ctx = &f,
        .git_exe = "/nonexistent/zdedupe/git",
        .trash_fn = fakeTrash,
        .now = realtimeSeconds() + 2 * std.time.s_per_day,
    }, true);
    defer report.deinit();
    const b = find(&report, &f, a, "app/node_modules").?;
    try testing.expect(!b.complete);
    try testing.expect(!b.trash.eligible);
    try testing.expectEqual(@as(usize, 0), report.trash.?.moved.len);
    try testing.expect(try f.scratch.exists("app/node_modules"));
}

test "clean never takes a root, and reports a root inside another once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Fixture.init(a, "clean-roots");
    defer f.deinit();
    try f.scratch.makeDir("node_modules");
    try f.scratch.makeDir("node_modules/zig-out");
    try f.scratch.writeFile("node_modules/zig-out/x", "1");
    try f.scratch.makeDir("crate");
    try f.scratch.writeFile("crate/Cargo.toml", "");
    try f.scratch.makeDir("crate/target");
    try f.scratch.writeFile("crate/target/y", "2");

    var report = try run(testing.allocator, testing.io, .{
        .roots = &.{ f.path(a, "node_modules"), f.path(a, "node_modules/zig-out"), "/nonexistent/zdedupe/root", f.path(a, "crate/target") },
        .main_roots = &.{f.path(a, "none")},
        .guard_fn = Fixture.guard,
        .guard_ctx = &f,
        .git_exe = "/nonexistent/zdedupe/git",
        .trash_fn = fakeTrash,
        .now = realtimeSeconds() + 2 * std.time.s_per_day,
    }, true);
    defer report.deinit();
    // The root named node_modules is the scope; zig-out inside it is a finding.
    try testing.expectEqual(@as(usize, 1), report.build_dirs.len);
    try testing.expectEqualStrings(f.path(a, "node_modules/zig-out"), report.build_dirs[0].path);
    try testing.expectEqualStrings("inside another root", report.roots[1].err.?);
    try testing.expectEqualStrings("cannot be read", report.roots[2].err.?);
    try testing.expect(try f.scratch.exists("node_modules"));
    try testing.expectEqual(@as(u64, 0), report.roots[3].build_dirs);
    try testing.expect(try f.scratch.exists("crate/target/y"));
}

test "clean with git: verdicts for each checkout and the project of each build folder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const git = gitinfo.Git.init(testing.allocator, testing.io, a, "git");
    if (!git.available()) return error.SkipZigTest;
    var f = try Fixture.init(a, "clean-git");
    defer f.deinit();

    const run_git = struct {
        fn call(al: Allocator, dir: []const u8, args: []const []const u8) !void {
            var argv: std.ArrayListUnmanaged([]const u8) = .empty;
            try argv.appendSlice(al, &.{
                "git", "-c",                       "user.name=t", "-c",                      "user.email=t@example.com", "-c", "commit.gpgsign=false",
                "-c",  "core.hooksPath=/dev/null", "-c",          "init.defaultBranch=main", "-C",                       dir,
            });
            try argv.appendSlice(al, args);
            const r = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items });
            testing.allocator.free(r.stdout);
            testing.allocator.free(r.stderr);
            if (!r.term.success()) return error.GitFixtureFailed;
        }
    }.call;
    try f.scratch.makeDir("scratch");
    try f.scratch.makeDir("scratch/repo");
    try run_git(a, f.path(a, "scratch/repo"), &.{ "init", "-q" });
    try f.scratch.writeFile("scratch/repo/.gitignore", "node_modules/\n.svelte-kit/\n");
    try f.scratch.writeFile("scratch/repo/package.json", "{}");
    try f.scratch.makeDir("scratch/repo/web");
    try f.scratch.writeFile("scratch/repo/web/package.json", "{}");
    try run_git(a, f.path(a, "scratch/repo"), &.{ "add", "." });
    try run_git(a, f.path(a, "scratch/repo"), &.{ "commit", "-q", "-m", "one" });
    try f.scratch.makeDir("scratch/repo/node_modules");
    try f.scratch.writeFile("scratch/repo/node_modules/a.js", "a");
    try f.scratch.makeDir("scratch/repo/web/.svelte-kit");
    try f.scratch.writeFile("scratch/repo/web/.svelte-kit/b.js", "b");

    var report = try scan(testing.allocator, testing.io, .{
        .roots = &.{f.path(a, "scratch")},
        .main_roots = &.{f.path(a, "none")},
        .guard_fn = Fixture.guard,
        .guard_ctx = &f,
    });
    defer report.deinit();
    try testing.expect(report.git_version != null);
    // The checkout, and the subproject that owns .svelte-kit.
    try testing.expectEqual(@as(usize, 2), report.projects.len);
    for (report.projects) |p| {
        const facts = p.facts.?;
        try testing.expectEqualStrings(f.path(a, "scratch/repo"), facts.checkout.?.toplevel);
        // Committed, but on no remote and in no main checkout.
        try testing.expectEqual(gitinfo.Verdict.has_unique_work, facts.verdict);
        try testing.expectEqual(@as(u64, 1), facts.checkout.?.unpushed_commits);
        try testing.expectEqual(@as(u64, 0), facts.checkout.?.uncommitted);
    }
    const kit = find(&report, &f, a, "scratch/repo/web/.svelte-kit").?;
    try testing.expectEqualStrings(f.path(a, "scratch/repo/web"), report.projects[kit.project.?].path);
}
