//! Build output: the one rule for what a project's tooling recreates
//!
//! Disk Space suggestions (space.zig), `zdedupe clean` (clean.zig) and the
//! temp-area exception to protection (protect.zig) all ask this module, so a
//! folder is build output to every one of them or to none. A folder is build
//! output when
//!
//!   * its name is one of `names`, wherever it is;
//!   * its name is one of `beside` and its parent holds one of that entry's
//!     manifests as a regular file (`target` is build output beside
//!     Cargo.toml, somebody's folder anywhere else);
//!   * it is laid out like one of `shapes`, whatever it is called: a Zig
//!     cache (`--cache-dir` anywhere) or an Xcode derived-data folder
//!     (`-derivedDataPath` anywhere). A shape asks for several children of
//!     the right kind at once, among them names no project uses (`tmp`
//!     beside `h`, `o` and `z`; an `.noindex` folder), and is judged from the
//!     folder's own listing: a few stats, nothing read;
//!   * it holds a valid CACHEDIR.TAG (`fast_walker.hasCacheDirTag`).
//!
//! The rule is asked of three kinds of evidence: the disk itself (`onDisk`,
//! `DiskRule`), a disk-space store (space.zig), and a walk's own records
//! (clean.zig). Each gathers a folder's children into a `Seen` (or probes
//! for them) and asks `shapeOf`, so the layouts are written down once.

const std = @import("std");
const libc = @import("sys.zig").c;
const pstat = @import("pstat.zig");
const filters = @import("filters.zig");
const fast_walker = @import("fast_walker.zig");
const protect = @import("protect.zig");

const Allocator = std.mem.Allocator;

/// Build output and dependency stores, by name.
pub const names = [_][]const u8{
    "node_modules", "bower_components", ".zig-cache", "zig-cache",   "zig-out",
    "DerivedData",  "__pycache__",      ".next",      ".nuxt",       ".svelte-kit",
    ".turbo",       ".parcel-cache",    ".tox",       ".mypy_cache", ".pytest_cache",
    ".ruff_cache",
};

/// Build folders whose name is too common to trust alone: each counts only
/// beside a manifest of the tool that writes it.
pub const beside = [_]struct { name: []const u8, manifests: []const []const u8 }{
    .{ .name = "target", .manifests = &.{ "Cargo.toml", "pom.xml" } },
    .{ .name = ".build", .manifests = &.{"Package.swift"} },
};

/// Which part of the rule recognised a folder. The names are part of the
/// `zdedupe clean` JSON.
pub const Rule = enum { name, beside_manifest, cachedir_tag, zig_cache, xcode_derived_data };

/// A layout that makes a folder build output whatever it is called: every
/// one of `dirs` is a folder in it, every one of `files` a regular file, and
/// at least one of `any_dirs` (when there are any) a folder.
pub const Shape = struct {
    rule: Rule,
    dirs: []const []const u8,
    files: []const []const u8 = &.{},
    any_dirs: []const []const u8 = &.{},
};

pub const shapes = [_]Shape{
    // What Zig writes into a cache directory, local or global: manifests,
    // outputs, sources, and its scratch space.
    .{ .rule = .zig_cache, .dirs = &.{ "h", "o", "tmp", "z" } },
    // What Xcode writes into a derived-data folder, its default per-project
    // one or a `-derivedDataPath`. The `.noindex` folders are Xcode's own
    // convention; a project's Info.plist, build/ and logs/ do not make one.
    .{
        .rule = .xcode_derived_data,
        .dirs = &.{ "Build", "Logs" },
        .files = &.{"info.plist"},
        .any_dirs = &.{ "Index.noindex", "ModuleCache.noindex" },
    },
};

/// Every name some shape looks for, so a listing can be gathered in one pass.
pub const shape_names = blk: {
    var list: []const []const u8 = &.{};
    for (shapes) |shape| {
        for ([_][]const []const u8{ shape.dirs, shape.files, shape.any_dirs }) |group| {
            for (group) |n| {
                const known = for (list) |have| {
                    if (std.mem.eql(u8, have, n)) break true;
                } else false;
                if (!known) list = list ++ .{n};
            }
        }
    }
    if (list.len > 32) @compileError("Seen holds 32 names");
    break :blk list;
};

pub fn isName(name: []const u8) bool {
    // zig-lens-ignore: EQL-FOR-SECRETS directory names, not secrets
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// The manifests one of which must sit beside a folder called `name` for it
/// to be build output, or null when the name is not one of those.
pub fn manifestsFor(name: []const u8) ?[]const []const u8 {
    for (beside) |b| {
        // zig-lens-ignore: EQL-FOR-SECRETS directory names, not secrets
        if (std.mem.eql(u8, name, b.name)) return b.manifests;
    }
    return null;
}

/// The shape `probe` describes, if any. `probe` answers `hasDir(name)` and
/// `hasFile(name)` for the folder's direct children.
pub fn shapeOf(probe: anytype) ?Rule {
    for (shapes) |shape| {
        if (matches(shape, probe)) return shape.rule;
    }
    return null;
}

fn matches(shape: Shape, probe: anytype) bool {
    for (shape.dirs) |d| if (!probe.hasDir(d)) return false;
    for (shape.files) |f| if (!probe.hasFile(f)) return false;
    if (shape.any_dirs.len == 0) return true;
    for (shape.any_dirs) |d| if (probe.hasDir(d)) return true;
    return false;
}

/// The shape names among a folder's children, gathered from a listing.
pub const Seen = struct {
    dirs: u32 = 0,
    files: u32 = 0,

    fn bit(name: []const u8) ?u32 {
        inline for (shape_names, 0..) |n, i| {
            if (std.mem.eql(u8, name, n)) return @as(u32, 1) << i;
        }
        return null;
    }

    /// True when `name` is one some shape looks for.
    pub fn wants(name: []const u8) bool {
        return bit(name) != null;
    }

    pub fn note(self: *Seen, name: []const u8, is_dir: bool) void {
        const b = bit(name) orelse return;
        if (is_dir) self.dirs |= b else self.files |= b;
    }

    pub fn hasDir(self: *const Seen, name: []const u8) bool {
        return self.dirs & (bit(name) orelse return false) != 0;
    }

    pub fn hasFile(self: *const Seen, name: []const u8) bool {
        return self.files & (bit(name) orelse return false) != 0;
    }
};

// ===========================================================================
// On disk
// ===========================================================================

/// Children of a folder, by stat: a link is neither a folder nor a file.
const DiskProbe = struct {
    dir: []const u8,

    fn child(self: DiskProbe, name: []const u8) ?pstat.Stat {
        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ self.dir, name }, 0) catch return null;
        return pstat.lstat(z.ptr) catch null;
    }

    pub fn hasDir(self: DiskProbe, name: []const u8) bool {
        return if (self.child(name)) |st| st.isDir() else false;
    }

    pub fn hasFile(self: DiskProbe, name: []const u8) bool {
        return if (self.child(name)) |st| st.isFile() else false;
    }
};

/// Which part of the rule makes the folder at `path` build output now, or
/// null when none does (or it is not a folder: a link never is).
pub fn onDisk(path: []const u8) ?Rule {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return null;
    const st = pstat.lstat(z.ptr) catch return null;
    if (!st.isDir()) return null;
    return ruleOfFolder(path, z);
}

/// `onDisk` for a path already known to be a real folder.
fn ruleOfFolder(path: []const u8, z: [:0]const u8) ?Rule {
    const name = filters.baseName(path);
    if (isName(name)) return .name;
    if (manifestsFor(name)) |manifests| {
        if (filters.parentDir(path)) |parent| {
            const up: DiskProbe = .{ .dir = parent };
            for (manifests) |m| if (up.hasFile(m)) return .beside_manifest;
        }
    }
    if (shapeOf(DiskProbe{ .dir = path })) |rule| return rule;
    // Nearly every folder has no tag: one stat says so before anything is opened.
    if (!(DiskProbe{ .dir = path }).hasFile("CACHEDIR.TAG")) return null;
    const fd = libc.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(libc.mode_t, 0));
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    if (fast_walker.hasCacheDirTag(fd)) return .cachedir_tag;
    return null;
}

/// What `path` is now, for protect.zig's temp-area exception; with `rule`
/// false only whether it is a real folder.
pub fn placeOf(path: []const u8, rule: bool) protect.Place {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return .other;
    const st = pstat.lstat(z.ptr) catch return .other;
    if (!st.isDir()) return .other;
    if (!rule) return .folder;
    return if (ruleOfFolder(path, z) != null) .build_output else .folder;
}

/// The rule on disk as protect.zig asks it, remembering each answer until
/// `reset` so a call that checks thousands of paths under one folder stats
/// that folder's children once. One thread at a time.
pub const DiskRule = struct {
    /// Null: nothing is remembered.
    arena: ?std.heap.ArenaAllocator = null,
    memo: std.StringHashMapUnmanaged(Known) = .empty,

    /// An answer, and whether the build-output rule was asked for it.
    const Known = struct { place: protect.Place, ruled: bool };

    pub fn init(gpa: Allocator) DiskRule {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *DiskRule) void {
        if (self.arena) |*a| a.deinit();
        self.* = .{};
    }

    /// Forget every answer: the disk may have changed.
    pub fn reset(self: *DiskRule) void {
        self.memo = .empty;
        if (self.arena) |*a| _ = a.reset(.retain_capacity);
    }

    pub fn hook(self: *DiskRule) protect.BuildOutput {
        return .{ .ctx = self, .classify = classify };
    }

    fn classify(ctx: ?*anyopaque, path: []const u8, rule: bool) protect.Place {
        const self: *DiskRule = @ptrCast(@alignCast(ctx orelse return placeOf(path, rule)));
        const arena = if (self.arena) |*a| a.allocator() else return placeOf(path, rule);
        const gop = self.memo.getOrPut(arena, path) catch return placeOf(path, rule);
        if (gop.found_existing) {
            const known = gop.value_ptr.*;
            if (known.ruled or !rule or known.place == .other) return known.place;
        } else {
            gop.key_ptr.* = arena.dupe(u8, path) catch {
                _ = self.memo.remove(path);
                return placeOf(path, rule);
            };
        }
        const place = placeOf(path, rule);
        gop.value_ptr.* = .{ .place = place, .ruled = rule };
        return place;
    }
};

/// The rule on disk with nothing remembered.
pub const on_disk: protect.BuildOutput = .{ .classify = struct {
    fn f(_: ?*anyopaque, path: []const u8, rule: bool) protect.Place {
        return placeOf(path, rule);
    }
}.f };

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Scratch = @import("testing_scratch.zig").Scratch;

fn mk(s: *const Scratch, dirs: []const []const u8, files: []const []const u8) !void {
    for (dirs) |d| try s.makeDir(d);
    for (files) |f| try s.writeFile(f, "x");
}

fn ruleAt(s: *const Scratch, rel: []const u8) !?Rule {
    const full = try s.join(rel);
    defer testing.allocator.free(full);
    return onDisk(full);
}

test "names, and target only beside its manifest" {
    var s = try Scratch.init(testing.allocator, "buildrule-names");
    defer s.deinit();
    try mk(&s, &.{ "a", "a/node_modules", "rs", "rs/target", "notes", "notes/target", "sw", "sw/.build" }, &.{ "rs/Cargo.toml", "sw/Package.swift" });
    try testing.expectEqual(@as(?Rule, .name), try ruleAt(&s, "a/node_modules"));
    try testing.expectEqual(@as(?Rule, .beside_manifest), try ruleAt(&s, "rs/target"));
    try testing.expectEqual(@as(?Rule, .beside_manifest), try ruleAt(&s, "sw/.build"));
    try testing.expectEqual(@as(?Rule, null), try ruleAt(&s, "notes/target"));
    try testing.expectEqual(@as(?Rule, null), try ruleAt(&s, "a"));
}

test "a Zig cache by its layout, under any name; near misses are not" {
    var s = try Scratch.init(testing.allocator, "buildrule-zig");
    defer s.deinit();
    try mk(&s, &.{ "zcache7", "zcache7/h", "zcache7/o", "zcache7/tmp", "zcache7/z", "zcache7/c" }, &.{"zcache7/h/0123abcd.txt"});
    try testing.expectEqual(@as(?Rule, .zig_cache), try ruleAt(&s, "zcache7"));
    // A project with h/, o/ and z/ folders but no tmp/.
    try mk(&s, &.{ "letters", "letters/h", "letters/o", "letters/z" }, &.{"letters/README"});
    try testing.expectEqual(@as(?Rule, null), try ruleAt(&s, "letters"));
    // tmp as a file, not a folder.
    try mk(&s, &.{ "filetmp", "filetmp/h", "filetmp/o", "filetmp/z" }, &.{"filetmp/tmp"});
    try testing.expectEqual(@as(?Rule, null), try ruleAt(&s, "filetmp"));
    // A folder called tmp reached through a link does not count either.
    try mk(&s, &.{ "linked", "linked/h", "linked/o", "linked/z", "elsewhere" }, &.{});
    try s.symLink("../elsewhere", "linked/tmp");
    try testing.expectEqual(@as(?Rule, null), try ruleAt(&s, "linked"));
    // The cache itself through a link is not a folder.
    try s.symLink("zcache7", "cache-link");
    try testing.expectEqual(@as(?Rule, null), try ruleAt(&s, "cache-link"));
}

test "Xcode derived data by its layout; a project with Info.plist, build and logs is not" {
    var s = try Scratch.init(testing.allocator, "buildrule-xcode");
    defer s.deinit();
    // -derivedDataPath dd, as xcodebuild leaves it.
    try mk(&s, &.{ "dd", "dd/Build", "dd/Logs", "dd/Index.noindex", "dd/ModuleCache.noindex", "dd/SourcePackages" }, &.{"dd/info.plist"});
    try testing.expectEqual(@as(?Rule, .xcode_derived_data), try ruleAt(&s, "dd"));
    // The default per-project folder: no ModuleCache.noindex of its own.
    try mk(&s, &.{ "App-abcdef", "App-abcdef/Build", "App-abcdef/Logs", "App-abcdef/Index.noindex" }, &.{"App-abcdef/info.plist"});
    try testing.expectEqual(@as(?Rule, .xcode_derived_data), try ruleAt(&s, "App-abcdef"));
    // A project folder: Info.plist, Build/, Logs/, no .noindex folder.
    try mk(&s, &.{ "MyApp", "MyApp/Build", "MyApp/Logs", "MyApp/Sources" }, &.{"MyApp/Info.plist"});
    try testing.expectEqual(@as(?Rule, null), try ruleAt(&s, "MyApp"));
    // The .noindex entries as files, not folders.
    try mk(&s, &.{ "fake", "fake/Build", "fake/Logs" }, &.{ "fake/info.plist", "fake/Index.noindex", "fake/ModuleCache.noindex" });
    try testing.expectEqual(@as(?Rule, null), try ruleAt(&s, "fake"));
    // No info.plist.
    try mk(&s, &.{ "noplist", "noplist/Build", "noplist/Logs", "noplist/Index.noindex" }, &.{});
    try testing.expectEqual(@as(?Rule, null), try ruleAt(&s, "noplist"));
}

test "a tagged folder by any name; an empty tag file is not a tag" {
    var s = try Scratch.init(testing.allocator, "buildrule-tag");
    defer s.deinit();
    try mk(&s, &.{ "cache", "notes" }, &.{"notes/CACHEDIR.TAG"});
    try s.writeFile("cache/CACHEDIR.TAG", fast_walker.cache_dir_signature ++ "\n");
    try testing.expectEqual(@as(?Rule, .cachedir_tag), try ruleAt(&s, "cache"));
    try testing.expectEqual(@as(?Rule, null), try ruleAt(&s, "notes"));
}

test "a listing gathered once answers the same as the disk" {
    var seen: Seen = .{};
    for ([_][]const u8{ "h", "o", "tmp", "z", "README" }) |n| seen.note(n, true);
    try testing.expectEqual(@as(?Rule, .zig_cache), shapeOf(&seen));
    var xcode: Seen = .{};
    for ([_][]const u8{ "Build", "Logs", "Index.noindex" }) |n| xcode.note(n, true);
    try testing.expectEqual(@as(?Rule, null), shapeOf(&xcode));
    xcode.note("info.plist", false);
    try testing.expectEqual(@as(?Rule, .xcode_derived_data), shapeOf(&xcode));
    try testing.expect(Seen.wants("tmp") and !Seen.wants("src"));
}

test "places for the temp-area exception, remembered until reset" {
    var s = try Scratch.init(testing.allocator, "buildrule-place");
    defer s.deinit();
    try mk(&s, &.{ "p", "p/node_modules" }, &.{"p/file.txt"});
    const nm = try s.join("p/node_modules");
    defer testing.allocator.free(nm);
    const p = try s.join("p");
    defer testing.allocator.free(p);
    const f = try s.join("p/file.txt");
    defer testing.allocator.free(f);
    var rule = DiskRule.init(testing.allocator);
    defer rule.deinit();
    const hook = rule.hook();
    try testing.expectEqual(protect.Place.build_output, hook.classify(hook.ctx, nm, true));
    try testing.expectEqual(protect.Place.folder, hook.classify(hook.ctx, p, true));
    try testing.expectEqual(protect.Place.other, hook.classify(hook.ctx, f, true));
    // Remembered: renaming it away does not change the answer until reset.
    const nm_z = try s.joinZ("p/node_modules");
    defer testing.allocator.free(nm_z);
    const moved_z = try s.joinZ("p/moved");
    defer testing.allocator.free(moved_z);
    try testing.expectEqual(@as(c_int, 0), libc.rename(nm_z.ptr, moved_z.ptr));
    try testing.expectEqual(protect.Place.build_output, hook.classify(hook.ctx, nm, true));
    rule.reset();
    try testing.expectEqual(protect.Place.other, hook.classify(hook.ctx, nm, true));
    try testing.expectEqual(protect.Place.other, on_disk.classify(null, nm, true));
}

test "on disk in $TMPDIR: build output may go, a path through a link may not" {
    if (comptime !@import("builtin").os.tag.isDarwin()) return error.SkipZigTest;
    var s = try Scratch.initTemp(testing.allocator, "buildrule-temp");
    defer s.deinit();
    try mk(&s, &.{ "x", "y", "y/node_modules", "app", "app/node_modules" }, &.{ "y/node_modules/a.js", "app/node_modules/b.js", "app/main.js" });
    try s.symLink("../y", "x/lnk");
    var real_buf: [libc.PATH_MAX]u8 = undefined;
    const real = std.mem.span(libc.realpath(s.path.ptr, &real_buf) orelse return error.TestUnexpectedResult);
    try testing.expect(protect.tempAreaOf(null, real) != null);
    var rule = DiskRule.init(testing.allocator);
    defer rule.deinit();
    const guard: protect.Protection = .{ .build_output = rule.hook() };
    var buf: [4096]u8 = undefined;
    const at = struct {
        fn f(b: []u8, base: []const u8, rel: []const u8) []const u8 {
            return std.fmt.bufPrint(b, "{s}/{s}", .{ base, rel }) catch unreachable;
        }
    }.f;
    try testing.expect(!guard.guardsFolder(at(&buf, real, "app/node_modules")));
    try testing.expect(!guard.protects(at(&buf, real, "app/node_modules/b.js")));
    try testing.expect(guard.protects(at(&buf, real, "app/main.js")));
    try testing.expect(guard.guardsFolder(at(&buf, real, "app")));
    // x/lnk/node_modules is y/node_modules on disk, reached through a link.
    try testing.expect(guard.guardsFolder(at(&buf, real, "x/lnk/node_modules")));
    try testing.expect(guard.protects(at(&buf, real, "x/lnk/node_modules/a.js")));
}
