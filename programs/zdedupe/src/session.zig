//! Results session — everything that happens *after* a scan, next to the store.
//!
//! A scan writes the binary result store (`store.zig`); a session maps it and
//! answers the questions a frontend asks of it: page the groups with a sort and
//! filters, summarise the "select all duplicates" rule as three numbers, delete
//! verified copies with progress and cancellation, remember what went so a
//! delete does not force a rescan, and export the lot. Before this existed each
//! frontend wrote that layer itself — ~4,000 lines of Rust and ~1,100 of Swift
//! that drifted apart and grew the same bugs twice.
//!
//! **The JSON boundary.** Queries in and answers out are JSON, so the C surface
//! is ten small functions instead of dozens of struct layouts, and adding a
//! field does not break a host's ABI. Answers are owned by an arena that is
//! reset at the start of every session call, so a caller never frees anything
//! and a page costs nothing once the next one is asked for.
//!
//! **Lossy in, exact out.** Paths inside JSON are the lossy UTF-8 spelling of
//! the stored bytes — the only thing a UI can display — and paths sent back in
//! (unticked, hand-picked) are matched against that same spelling. Everything
//! that touches the disk uses the store's exact bytes. Two different names can
//! share one lossy spelling, so a hand-pick can select more than was meant;
//! nothing is deleted on that basis alone, because a group only loses copies
//! while a verified copy outside the targets survives.
//!
//! **The Trash is the host's.** There is no portable API for it, so a permanent
//! delete happens here and the Trash is a callback (`TrashFn`) the host
//! supplies — `trash::delete_all` on the Rust side, `NSWorkspace.recycle` on
//! the Swift side. It is the only platform-specific piece left in a frontend.
//!
//! **Verification.** Results describe the disk as it was, which may be hours
//! ago, and a rule deletes files nobody looked at one by one. Nothing goes on
//! the strength of a stale hash: to the Trash (recoverable) a target and a
//! surviving copy must each still be a regular file of the recorded size and
//! modification time; permanently, both are re-hashed now and must equal the
//! group's hash.

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

const store = @import("store.zig");
const hasher = @import("hasher.zig");
const pstat = @import("pstat.zig");
const compare = @import("compare.zig");
const report_mod = @import("report.zig");
const filters_mod = @import("filters.zig");
const removed_mod = @import("removed.zig");
const keep_mod = @import("keep.zig");
const protect_mod = @import("protect.zig");

const Allocator = std.mem.Allocator;
const Filters = filters_mod.Filters;
const Matcher = filters_mod.Matcher;

/// Largest page a caller may ask for, whatever it sends. Bounds the work and
/// the JSON of any paged request.
pub const max_page: usize = 200;
/// Files listed in a group row. A group can have thousands of copies; the row
/// carries the oldest ones and `count` says how many there are in all. A bulk
/// rule covers the unlisted ones too — it works on the store, not on rows.
pub const group_files_in_row: usize = 50;
/// Member folders carried in an identical set's row. A set can have hundreds
/// of copies (879 in one real scan); the row carries the first few and the
/// rest come from `setMembers`.
pub const set_members_in_row: usize = 8;
/// Most facets one request may return, however many a caller asks for.
pub const max_facets: usize = 100;
/// Files handed to the Trash in one call, to amortise its per-call cost.
/// Progress and cancel are per group, not per batch.
pub const trash_batch: usize = 200;
/// Failures reported back in detail. The count is always exact.
pub const max_reported_failures: usize = 20;

/// Host-provided Trash. Called with a batch of exact path bytes, each
/// NUL-terminated. Returns 0 when every path went; any other value and the
/// session retries the batch one path at a time so a failure can be attributed
/// to a file. `err_out` receives a NUL-terminated message for a single-path
/// failure.
///
/// It runs inside the delete that called it, so the only session entry points
/// it may use are the two that touch nothing but atomics: `deleteProgress` and
/// `cancelDelete`. A nested `delete` is refused rather than allowed to disturb
/// the one in flight.
pub const TrashFn = *const fn (
    user: ?*anyopaque,
    paths: [*]const [*:0]const u8,
    count: usize,
    err_out: [*]u8,
    err_cap: usize,
) callconv(.c) c_int;

/// Mirrors `zdedupe_delete_progress` in the C header.
pub const DeleteProgress = extern struct {
    running: bool,
    done: u64,
    total: u64,
};

pub const GroupSort = enum { savings, size, count };

// ===========================================================================
// Queries and answers
// ===========================================================================

const GroupQuery = struct {
    offset: usize = 0,
    limit: usize = 50,
    sort: GroupSort = .savings,
    filters: Filters = .{},
    /// The "select all duplicates" rule in force, if any: rows it covers come
    /// back marked, so a UI can show them selected without ever holding the
    /// selection as a list.
    bulk: ?Filters = null,
    /// Which copy each row keeps, and so which it marks as targets.
    keep: keep_mod.Spec = .{},
};

/// Identical sets and overlap pairs page the same way: no sort, because the
/// store already holds them largest-first.
const FolderQuery = struct {
    offset: usize = 0,
    limit: usize = 50,
    filters: Filters = .{},
    /// Identical sets only; overlaps keep the store's largest-shared-first order.
    sort: SetSort = .reclaim,
};

/// How identical folder sets are ordered: by what deleting all but one copy
/// frees (the store's own order), by the size of one copy, or by copies.
const SetSort = enum { reclaim, size, count };

const FindingKind = enum { groups, sets, overlaps };
const FacetBy = enum { location, name, type };

const FacetQuery = struct {
    kind: FindingKind = .groups,
    by: FacetBy = .location,
    filters: Filters = .{},
    limit: usize = 50,
};

const Selection = struct {
    rule: ?Rule = null,
    extra: []const []const u8 = &.{},

    const Rule = struct {
        filters: Filters = .{},
        /// Files the user unticked, in their lossy spelling.
        excluded: []const []const u8 = &.{},
        /// Which copy of each group stays. The default keeps the oldest.
        keep: keep_mod.Spec = .{},
    };
};

/// Request to `bulkPlan`: the rule a delete would carry, answered with what
/// it would do and where the deleted copies are.
const PlanQuery = struct {
    /// Required, so a bare `Filters` sent by mistake fails to parse instead
    /// of reading as "every group".
    filters: Filters,
    excluded: []const []const u8 = &.{},
    keep: keep_mod.Spec = .{},
    /// Where to break the deleted copies down by location from; null starts
    /// at the scan root (or the roots, when there are several).
    under: ?[]const u8 = null,
    limit: usize = 20,
};

/// One folder a caller asks to have removed, with the copies it says will
/// survive it.
const FolderItem = struct {
    path: []const u8 = "",
    /// Folders holding the same content that are NOT being deleted. A
    /// permanent delete is verified against these; nothing else vouches.
    keepers: []const []const u8 = &.{},
    /// Size shown in the results, for the report's `freed_bytes`.
    bytes: u64 = 0,
};

/// How a file is proven to still be the duplicate the scan found.
const Verify = union(enum) {
    /// Same size and modification time as scanned. Enough when the delete can
    /// be undone from the Trash.
    metadata,
    /// Content re-hashed now and equal to the group's hash. Required when the
    /// delete cannot be undone.
    content: struct { sha256: bool },
};

const Report = struct {
    deleted: u64 = 0,
    freed_bytes: u64 = 0,
    /// Not deleted because the file, or every copy that would have been kept,
    /// no longer matches what the scan saw.
    skipped_changed: u64 = 0,
    failed_count: u64 = 0,
    failed: std.ArrayListUnmanaged(Failure) = .empty,
    cancelled: bool = false,
    /// The results could not be corrected for this delete; they must be
    /// rescanned to be trusted.
    needs_rescan: bool = false,
    /// What was removed, for the overlay to leave out from now on. Exact bytes.
    removed_paths: std.ArrayListUnmanaged([]const u8) = .empty,

    const Failure = struct { path: []const u8, reason: []const u8 };

    fn removed(self: *Report, arena: Allocator, path: []const u8, bytes: u64) void {
        self.deleted += 1;
        self.freed_bytes +|= bytes;
        // Borrowed from the mapping, which outlives the call.
        self.removed_paths.append(arena, path) catch {};
    }

    fn fail(self: *Report, arena: Allocator, path: []const u8, reason: []const u8) void {
        self.failed_count += 1;
        if (self.failed.items.len >= max_reported_failures) return;
        const shown = lossy(arena, path) catch return;
        self.failed.append(arena, .{ .path = shown, .reason = reason }) catch {};
    }
};

// ===========================================================================
// Lossy paths
// ===========================================================================

/// The lossy UTF-8 spelling of `bytes`: what a UI can show, and what comes back
/// in an unticked or hand-picked path. Each maximal invalid subpart becomes one
/// U+FFFD, which is what Rust's `String::from_utf8_lossy` and Swift's
/// `String(decoding:as: UTF8.self)` both produce — so all three frontends spell
/// a path the same way and a path sent back in still matches.
///
/// Valid UTF-8 (all but a handful of real filenames) is returned borrowed.
pub fn lossy(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(arena, bytes.len + 8);
    var i: usize = 0;
    while (i < bytes.len) {
        switch (stepUtf8(bytes[i..])) {
            .valid => |n| {
                try out.appendSlice(arena, bytes[i..][0..n]);
                i += n;
            },
            .invalid => |n| {
                try out.appendSlice(arena, &std.unicode.replacement_character_utf8);
                i += n;
            },
        }
    }
    return out.items;
}

const Step = union(enum) {
    valid: usize,
    /// Bytes to skip: the maximal subpart of a well-formed sequence found.
    invalid: usize,
};

/// One step of UTF-8 decoding with the maximal-subpart rule (Unicode 15.0
/// §3.9, "U+FFFD Substitution of Maximal Subparts").
fn stepUtf8(s: []const u8) Step {
    const b0 = s[0];
    if (b0 < 0x80) return .{ .valid = 1 };

    const Shape = struct { width: usize, lo: u8, hi: u8 };
    const shape: Shape = switch (b0) {
        0xC2...0xDF => .{ .width = 2, .lo = 0x80, .hi = 0xBF },
        // An overlong three-byte form and the surrogate block are not
        // characters, so their second byte is restricted.
        0xE0 => .{ .width = 3, .lo = 0xA0, .hi = 0xBF },
        0xE1...0xEC => .{ .width = 3, .lo = 0x80, .hi = 0xBF },
        0xED => .{ .width = 3, .lo = 0x80, .hi = 0x9F },
        0xEE...0xEF => .{ .width = 3, .lo = 0x80, .hi = 0xBF },
        0xF0 => .{ .width = 4, .lo = 0x90, .hi = 0xBF },
        0xF1...0xF3 => .{ .width = 4, .lo = 0x80, .hi = 0xBF },
        0xF4 => .{ .width = 4, .lo = 0x80, .hi = 0x8F },
        // A continuation byte on its own, or a lead byte no encoding uses.
        else => return .{ .invalid = 1 },
    };

    if (s.len < 2 or s[1] < shape.lo or s[1] > shape.hi) return .{ .invalid = 1 };
    var i: usize = 2;
    while (i < shape.width) : (i += 1) {
        if (i >= s.len or s[i] < 0x80 or s[i] > 0xBF) return .{ .invalid = i };
    }
    return .{ .valid = shape.width };
}

/// The exact path bytes, NUL-terminated for libc. Null when the path cannot
/// fit — no syscall would accept it either.
fn pathZ(buf: *[4096]u8, path: []const u8) ?[*:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

/// The user's real home directory, for the protected `~/Library` and the like.
/// From the user database first: inside the macOS App Sandbox `$HOME` is the
/// app's container, and protecting the container's `Library` would leave the
/// real one unprotected. `$HOME` is the fallback where the database has none.
fn userHome() ?[]const u8 {
    if (libc.getpwuid(libc.getuid())) |pw| {
        if (pw.dir) |dir| {
            const home = std.mem.span(dir);
            if (home.len > 0) return home;
        }
    }
    const env = libc.getenv("HOME") orelse return null;
    return std.mem.span(env);
}

// ===========================================================================
// Session
// ===========================================================================

/// One file of a group that still exists as far as the overlay knows.
const AliveFile = struct {
    /// Index within the group, which is what a delete plan holds.
    index: u32,
    path: []const u8,
    mtime: i64,
};

/// One member folder of an identical set that still exists as far as the
/// overlay knows. `Matcher.matches` reads the `path` field off these.
const AliveDir = struct {
    path: []const u8,
    newest_mtime: i64,
    skipped_entries: u64,
};

const CachedOrder = struct {
    sort: GroupSort,
    /// Owned; the query's arena is gone by the time this is compared.
    filters: Filters,
    /// The overlay generation the order was computed under.
    generation: u64,
    /// Four bytes per matching group.
    rows: []u32,
};

const DeleteState = struct {
    running: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
};

pub const Session = struct {
    gpa: Allocator,
    /// Owns every string a call returns. Reset at the start of every call, so
    /// an answer is valid exactly until the next one.
    arena: std.heap.ArenaAllocator,
    /// The mapped store file, and the validated view over it.
    map: []align(std.heap.page_size_min) const u8,
    reader: store.Reader,
    store_path: []u8,
    /// The scanned folders, from the sidecar or derived; owned.
    roots: [][]u8,
    removed: removed_mod.Removed,
    order: ?CachedOrder = null,
    /// Survives an arena reset, because it is read by a later call.
    last_error: ?[:0]u8 = null,
    /// Atomics only: reachable from another thread while a delete runs.
    del: DeleteState = .{},
    /// Reused across groups so paging a million of them does not churn.
    alive: std.ArrayListUnmanaged(AliveFile) = .empty,
    /// The same, for the member folders of an identical set.
    alive_dirs: std.ArrayListUnmanaged(AliveDir) = .empty,
    /// The user's home directory, owned; null when HOME is unset.
    home: ?[]u8 = null,
    /// Protected roots the host added, owned.
    user_protected: [][]u8 = &.{},
    /// Reused by `planGroup`, one entry per surviving copy.
    plan_members: std.ArrayListUnmanaged(keep_mod.Member) = .empty,
    plan_kept: std.ArrayListUnmanaged(bool) = .empty,
    plan_targets: std.ArrayListUnmanaged(bool) = .empty,

    pub const OpenError = error{
        CannotOpenStore,
        StoreIsInvalid,
        BadRootsJson,
        OutOfMemory,
    };

    /// Map a finished store. `roots_json`, when given, is a JSON array of the
    /// scan's root paths: it is written to the roots sidecar and the removed
    /// sidecar is discarded, because a fresh scan has nothing to leave out.
    /// When null, both sidecars are loaded.
    pub fn open(gpa: Allocator, store_path: []const u8, roots_json: ?[]const u8) OpenError!*Session {
        var path_buf: [4096]u8 = undefined;
        const path_z = pathZ(&path_buf, store_path) orelse return error.CannotOpenStore;

        const fd = libc.open(path_z, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) return error.CannotOpenStore;
        defer _ = libc.close(fd);

        const st = pstat.fstat(fd) catch return error.CannotOpenStore;
        // mmap refuses a zero length, and anything below a header is not a
        // store; either way the reader would reject it.
        if (!st.isFile() or st.size < store.header_size) return error.StoreIsInvalid;
        const length = std.math.cast(usize, st.size) orelse return error.StoreIsInvalid;

        // Read-only and private: the engine writes a new file and renames it
        // over the path, so the mapped inode never changes under us.
        const map = std.posix.mmap(
            null,
            length,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        ) catch return error.CannotOpenStore;
        errdefer std.posix.munmap(map);

        const reader = store.Reader.init(map, null) catch return error.StoreIsInvalid;

        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .map = map,
            .reader = reader,
            .store_path = try gpa.dupe(u8, store_path),
            .roots = &.{},
            .removed = .init(gpa),
        };
        errdefer {
            self.arena.deinit();
            gpa.free(self.store_path);
            self.removed.deinit();
        }

        const fresh = roots_json != null;
        if (roots_json) |json| {
            self.roots = parseRoots(gpa, json) catch return error.BadRootsJson;
            self.writeRootsSidecar(json);
        } else {
            self.roots = self.loadRootsSidecar() catch &.{};
            if (self.roots.len == 0) self.roots = try self.deriveRoots();
        }
        self.removed.attach(self.store_path, fresh) catch {};
        if (userHome()) |home| {
            const trimmed = std.mem.trimEnd(u8, home, "/");
            if (trimmed.len > 0) self.home = gpa.dupe(u8, trimmed) catch null;
        }
        return self;
    }

    pub fn close(self: *Session) void {
        const gpa = self.gpa;
        self.clearOrder();
        self.alive.deinit(gpa);
        self.alive_dirs.deinit(gpa);
        self.plan_members.deinit(gpa);
        self.plan_kept.deinit(gpa);
        self.plan_targets.deinit(gpa);
        if (self.home) |home| gpa.free(home);
        self.freeUserProtected();
        self.removed.deinit();
        for (self.roots) |root| gpa.free(root);
        gpa.free(self.roots);
        gpa.free(self.store_path);
        if (self.last_error) |e| gpa.free(e);
        self.arena.deinit();
        std.posix.munmap(self.map);
        gpa.destroy(self);
    }

    // --- errors -----------------------------------------------------------

    pub fn lastError(self: *const Session) ?[:0]const u8 {
        return self.last_error;
    }

    fn fail(self: *Session, comptime fmt: []const u8, args: anytype) void {
        if (self.last_error) |e| self.gpa.free(e);
        self.last_error = std.fmt.allocPrintSentinel(self.gpa, fmt, args, 0) catch null;
    }

    /// Turn a store read failure into something a user can act on. A store is
    /// ours, written 0600 and renamed into place, so this means the file was
    /// truncated or replaced underneath us.
    fn failRead(self: *Session, err: store.ReadError) void {
        switch (err) {
            error.Invalid => self.fail("scan results file is invalid", .{}),
            error.OutOfRange => self.fail("scan results file is corrupted", .{}),
        }
    }

    /// Every call begins here: the previous answer's memory goes, and a fresh
    /// arena backs this one.
    fn beginCall(self: *Session) Allocator {
        _ = self.arena.reset(.retain_capacity);
        return self.arena.allocator();
    }

    // --- roots ------------------------------------------------------------

    fn rootsSidecar(self: *const Session) ![:0]u8 {
        return removed_mod.sidecarPath(self.gpa, self.store_path, "roots.json");
    }

    /// Best effort: without it, results reopened later fall back to deriving
    /// the roots from the paths in the store.
    fn writeRootsSidecar(self: *Session, json: []const u8) void {
        const sidecar = self.rootsSidecar() catch return;
        defer self.gpa.free(sidecar);

        const fd = libc.open(sidecar.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(libc.mode_t, 0o600));
        if (fd < 0) return;
        defer _ = libc.close(fd);
        var written: usize = 0;
        while (written < json.len) {
            const n = libc.write(fd, json.ptr + written, json.len - written);
            if (n < 0) {
                if (libc.errno(n) == .INTR) continue;
                return;
            }
            if (n == 0) return;
            written += @intCast(n);
        }
    }

    fn loadRootsSidecar(self: *Session) ![][]u8 {
        const sidecar = try self.rootsSidecar();
        defer self.gpa.free(sidecar);
        const bytes = try removed_mod.readWholeFile(self.gpa, sidecar.ptr, 4 * 1024 * 1024);
        defer self.gpa.free(bytes);
        return parseRoots(self.gpa, bytes);
    }

    /// The scan roots with any trailing slash trimmed, and an empty one read
    /// as "/". Location facets compare and emit these as keys, so `/mnt/` and
    /// `/mnt` must not become two different places. `overview` reports the
    /// roots as recorded instead, unaltered.
    fn normalizedRoots(self: *Session, arena: Allocator) ![]const []const u8 {
        const out = try arena.alloc([]const u8, self.roots.len);
        for (self.roots, out) |root, *slot| {
            const trimmed = std.mem.trimEnd(u8, root, "/");
            slot.* = if (trimmed.len == 0) "/" else trimmed;
        }
        return out;
    }

    /// The deepest directory containing every path in the results — the stand-in
    /// when nothing recorded what was scanned.
    fn deriveRoots(self: *Session) ![][]u8 {
        var common: ?[]const u8 = null;
        for (0..self.reader.groupCount()) |i| {
            const group = self.reader.group(i) catch return &.{};
            for (0..group.file_count) |f| {
                const file = self.reader.groupFile(&group, f) catch return &.{};
                narrowToCommonDir(&common, file.path);
            }
        }
        for (0..self.reader.setCount()) |i| {
            const set = self.reader.set(i) catch return &.{};
            for (0..set.dir_count) |d| {
                const dir = self.reader.setDir(&set, d) catch return &.{};
                narrowToCommonDir(&common, dir.path);
            }
        }
        const root = common orelse return &.{};
        const list = try self.gpa.alloc([]u8, 1);
        errdefer self.gpa.free(list);
        list[0] = try self.gpa.dupe(u8, root);
        return list;
    }

    // --- protection -------------------------------------------------------

    fn protection(self: *const Session) protect_mod.Protection {
        return .{ .home = self.home, .user = self.user_protected };
    }

    fn freeUserProtected(self: *Session) void {
        for (self.user_protected) |root| self.gpa.free(root);
        self.gpa.free(self.user_protected);
        self.user_protected = &.{};
    }

    /// Replace the roots the host added to the built-in protected locations.
    /// `json` is an array of absolute paths. The built-in list stays whatever
    /// this is given.
    pub fn setProtected(self: *Session, json: []const u8) bool {
        const arena = self.beginCall();
        const paths = std.json.parseFromSliceLeaky([]const []const u8, arena, json, .{}) catch {
            self.fail("protected locations are not a JSON array of paths", .{});
            return false;
        };
        for (paths) |path| {
            if (path.len == 0 or path[0] != '/') {
                self.fail("protected location \"{s}\" is not an absolute path", .{path});
                return false;
            }
        }
        const owned = self.gpa.alloc([]u8, paths.len) catch {
            self.fail("out of memory", .{});
            return false;
        };
        var filled: usize = 0;
        for (paths, owned) |path, *slot| {
            const trimmed = std.mem.trimEnd(u8, path, "/");
            slot.* = self.gpa.dupe(u8, if (trimmed.len == 0) "/" else trimmed) catch {
                for (owned[0..filled]) |p| self.gpa.free(p);
                self.gpa.free(owned);
                self.fail("out of memory", .{});
                return false;
            };
            filled += 1;
        }
        self.freeUserProtected();
        self.user_protected = owned;
        return true;
    }

    /// Point the home-relative protected roots (`~/Library` and the like) at
    /// `path` instead of the user database's home. For a host that knows
    /// better — a test harness running inside a sandbox container, whose own
    /// temporary files sit in the real `~/Library` — never a way to switch
    /// protection off: the system roots, stores and packages stay in force.
    pub fn setHome(self: *Session, path: []const u8) bool {
        _ = self.beginCall();
        const trimmed = std.mem.trimEnd(u8, path, "/");
        if (trimmed.len == 0 or trimmed[0] != '/') {
            self.fail("home \"{s}\" is not an absolute path", .{path});
            return false;
        }
        const owned = self.gpa.dupe(u8, trimmed) catch {
            self.fail("out of memory", .{});
            return false;
        };
        if (self.home) |old| self.gpa.free(old);
        self.home = owned;
        return true;
    }

    /// Every protected location in force, for a UI to show: the built-in
    /// roots, the home directory's, the component rules, and the host's own.
    pub fn protectedJson(self: *Session) ?[:0]const u8 {
        const arena = self.beginCall();
        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        self.writeProtected(&json, arena) catch return self.outOfMemory();
        return self.finishJson(&out);
    }

    fn writeProtected(self: *Session, json: *std.json.Stringify, arena: Allocator) !void {
        try json.beginObject();
        try json.objectField("system");
        try json.write(protect_mod.system_roots);
        try json.objectField("home");
        try json.beginArray();
        if (self.home) |home| {
            for (protect_mod.home_roots) |rel| {
                try json.write(try std.fmt.allocPrint(arena, "{s}/{s}", .{ try lossy(arena, home), rel }));
            }
        }
        try json.endArray();
        try json.objectField("stores");
        try json.write(protect_mod.component_names);
        try json.objectField("packages");
        try json.write(protect_mod.package_suffixes);
        try json.objectField("user");
        try json.beginArray();
        for (self.user_protected) |root| try json.write(try lossy(arena, root));
        try json.endArray();
        try json.endObject();
    }

    /// How `spec` decides one group. The slices are reused buffers, valid
    /// until the next call; indices are into `alive`.
    const GroupPlan = struct {
        primary: ?usize,
        /// Per copy: its path and whether it is protected.
        members: []const keep_mod.Member,
        kept: []const bool,
        targets: []const bool,
    };

    fn planGroup(
        self: *Session,
        arena: Allocator,
        spec: *const keep_mod.Spec,
        group: *const store.Group,
        alive: []const AliveFile,
    ) !GroupPlan {
        const guard = self.protection();
        self.plan_members.clearRetainingCapacity();
        try self.plan_members.ensureTotalCapacity(self.gpa, alive.len);
        for (alive) |file| self.plan_members.appendAssumeCapacity(.{
            .path = file.path,
            .mtime = file.mtime,
            .protected = guard.protects(file.path),
        });
        try self.plan_kept.resize(self.gpa, alive.len);
        try self.plan_targets.resize(self.gpa, alive.len);

        const pinned = try pinnedIndex(arena, spec, group, alive);
        const primary = keep_mod.plan(spec, self.plan_members.items, pinned, self.plan_kept.items, self.plan_targets.items);
        return .{
            .primary = primary,
            .members = self.plan_members.items,
            .kept = self.plan_kept.items,
            .targets = self.plan_targets.items,
        };
    }

    /// The pinned copy of this group, if the spec pins one that still exists.
    fn pinnedIndex(
        arena: Allocator,
        spec: *const keep_mod.Spec,
        group: *const store.Group,
        alive: []const AliveFile,
    ) !?usize {
        if (spec.pins.len == 0) return null;
        var hex: [64]u8 = undefined;
        const hash = hasher.hashToHex(&group.hash, &hex);
        for (spec.pins) |pin| {
            if (!std.ascii.eqlIgnoreCase(pin.hash, hash)) continue;
            for (alive, 0..) |file, i| {
                if (std.mem.eql(u8, try lossy(arena, file.path), pin.path)) return i;
            }
        }
        return null;
    }

    // --- group order ------------------------------------------------------

    fn clearOrder(self: *Session) void {
        const cached = self.order orelse return;
        cached.filters.deinit(self.gpa);
        self.gpa.free(cached.rows);
        self.order = null;
    }

    /// The files of `group` that still exist as far as the overlay knows, with
    /// their index in the group. Fewer than two means it is no longer a
    /// duplicate group. Refills a reused buffer: valid until the next call.
    fn aliveFiles(self: *Session, group: *const store.Group) ![]const AliveFile {
        self.alive.clearRetainingCapacity();
        for (0..group.file_count) |f| {
            const file = try self.reader.groupFile(group, f);
            if (self.removed.covers(file.path)) continue;
            try self.alive.append(self.gpa, .{
                .index = @intCast(f),
                .path = file.path,
                .mtime = file.mtime,
            });
        }
        return self.alive.items;
    }

    /// The member folders of `set` that still exist as far as the overlay
    /// knows. Fewer than two and it is not a set of identical folders any
    /// more. Refills a reused buffer: valid until the next call.
    fn aliveDirs(self: *Session, set: *const store.Set) ![]const AliveDir {
        self.alive_dirs.clearRetainingCapacity();
        for (0..set.dir_count) |d| {
            const dir = try self.reader.setDir(set, d);
            if (self.removed.covers(dir.path)) continue;
            try self.alive_dirs.append(self.gpa, .{
                .path = dir.path,
                .newest_mtime = dir.newest_mtime,
                .skipped_entries = dir.skipped_entries,
            });
        }
        return self.alive_dirs.items;
    }

    fn liveSavings(size: u64, copies: usize) u64 {
        return size *| (@as(u64, copies) -| 1);
    }

    /// What "size" means for an overlap: the content the two folders share.
    fn overlapBytes(o: *const store.Overlap) u64 {
        return @max(o.a.shared_bytes, o.b.shared_bytes);
    }

    /// A pair says something about two folders; with either gone it says
    /// nothing at all, so it stops being a finding.
    fn overlapMatches(self: *Session, matcher: *const Matcher, o: *const store.Overlap) !bool {
        const a = try self.reader.sidePath(&o.a);
        const b = try self.reader.sidePath(&o.b);
        if (self.removed.covers(a) or self.removed.covers(b)) return false;
        if (matcher.redundant_only and store.Reader.relationOfRecord(o) == .overlap) return false;
        return matcher.matches(overlapBytes(o), &[_][]const u8{ a, b });
    }

    /// Group indices in the requested order, restricted to groups passing
    /// `filters`. Owned by the caller.
    fn orderedGroups(self: *Session, sort: GroupSort, filters: Filters) ![]u32 {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const matcher = try Matcher.init(scratch.allocator(), filters);

        const Row = struct { index: u32, key: u64 };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(self.gpa);

        for (0..self.reader.groupCount()) |i| {
            const group = try self.reader.group(i);
            const alive = try self.aliveFiles(&group);
            if (alive.len < 2) continue;
            // A file group's size is the size of one file.
            if (!matcher.matches(group.size, alive)) continue;
            const key: u64 = switch (sort) {
                // The store is already in savings order; a delete changes a
                // group's savings, so once anything is removed the live value
                // is the key.
                .savings => if (self.removed.isEmpty()) 0 else liveSavings(group.size, alive.len),
                .size => group.size,
                .count => alive.len,
            };
            try rows.append(self.gpa, .{ .index = @intCast(i), .key = key });
        }

        if (sort != .savings or !self.removed.isEmpty()) {
            // Stable, so ties keep the store's largest-savings-first order.
            std.mem.sort(Row, rows.items, {}, struct {
                fn desc(_: void, a: Row, b: Row) bool {
                    return a.key > b.key;
                }
            }.desc);
        }

        const out = try self.gpa.alloc(u32, rows.items.len);
        for (rows.items, out) |row, *slot| slot.* = row.index;
        return out;
    }

    /// The order for this (sort, filters, overlay generation), computed once.
    fn cachedGroupOrder(self: *Session, sort: GroupSort, filters: Filters) ![]const u32 {
        if (self.order) |cached| {
            if (cached.sort == sort and
                cached.generation == self.removed.generation and
                cached.filters.eql(filters))
            {
                return cached.rows;
            }
        }
        const rows = try self.orderedGroups(sort, filters);
        errdefer self.gpa.free(rows);
        const owned = try filters.clone(self.gpa);
        errdefer owned.deinit(self.gpa);

        self.clearOrder();
        self.order = .{
            .sort = sort,
            .filters = owned,
            .generation = self.removed.generation,
            .rows = rows,
        };
        return rows;
    }

    // --- overview ---------------------------------------------------------

    /// The scan's own counters, plus what the folder sections add up to. These
    /// do not change with deletes; the UIs say so beside them.
    pub fn overview(self: *Session) ?[:0]const u8 {
        const arena = self.beginCall();

        var reclaimable: u64 = 0;
        for (0..self.reader.setCount()) |i| {
            const set = self.reader.set(i) catch |err| return self.readFailed(err);
            reclaimable +|= set.bytes *| (@as(u64, set.dir_count) -| 1);
        }
        var redundant_pairs: usize = 0;
        for (0..self.reader.overlapCount()) |i| {
            const pair = self.reader.overlap(i) catch |err| return self.readFailed(err);
            // Anything but a two-way overlap means one side adds nothing.
            if (pair.relation != @intFromEnum(store.Relation.overlap)) redundant_pairs += 1;
        }

        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        self.writeOverview(&json, arena, reclaimable, redundant_pairs) catch return self.outOfMemory();
        return self.finishJson(&out);
    }

    fn writeOverview(
        self: *Session,
        json: *std.json.Stringify,
        arena: Allocator,
        reclaimable: u64,
        redundant_pairs: usize,
    ) !void {
        const header = &self.reader.header;
        try json.beginObject();
        try json.objectField("roots");
        try json.beginArray();
        for (self.roots) |root| try json.write(try lossy(arena, root));
        try json.endArray();
        try json.objectField("generated_at");
        try json.write(millis(header.generated_at));
        inline for (.{
            .{ "files_scanned", header.files_scanned },
            .{ "bytes_scanned", header.bytes_scanned },
            .{ "duplicate_groups", header.duplicate_groups },
            .{ "duplicate_files", header.duplicate_files },
            .{ "space_savings", header.space_savings },
            .{ "scan_time_ns", header.scan_time_ns },
            .{ "excluded_entries", header.excluded_entries },
            .{ "overlapping_roots", header.overlapping_roots },
            .{ "failed_paths", header.failed_paths },
        }) |field| {
            try json.objectField(field[0]);
            try json.write(field[1]);
        }
        try json.objectField("has_directories");
        try json.write(self.reader.hasDirectories());
        try json.objectField("dirs_analyzed");
        try json.write(header.dirs_analyzed);
        try json.objectField("dirs_incomplete");
        try json.write(header.dirs_incomplete);
        try json.objectField("identical_sets");
        try json.write(self.reader.setCount());
        try json.objectField("overlaps");
        try json.write(self.reader.overlapCount());
        try json.objectField("redundant_pairs");
        try json.write(redundant_pairs);
        try json.objectField("reclaimable");
        try json.write(reclaimable);
        try json.endObject();
    }

    // --- groups -----------------------------------------------------------

    pub fn groups(self: *Session, query_json: []const u8) ?[:0]const u8 {
        const arena = self.beginCall();
        const query = std.json.parseFromSliceLeaky(GroupQuery, arena, query_json, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.fail("group query is not valid JSON", .{});
            return null;
        };

        const order = self.cachedGroupOrder(query.sort, query.filters) catch |err|
            return self.callFailed(err);
        const bulk: ?Matcher = if (query.bulk) |f|
            Matcher.init(arena, f) catch return self.outOfMemory()
        else
            null;

        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        self.writeGroupPage(&json, arena, order, query, bulk) catch |err|
            return self.callFailed(err);
        return self.finishJson(&out);
    }

    fn writeGroupPage(
        self: *Session,
        json: *std.json.Stringify,
        arena: Allocator,
        order: []const u32,
        query: GroupQuery,
        bulk: ?Matcher,
    ) !void {
        const limit = @min(query.limit, max_page);
        const first = @min(query.offset, order.len);
        const last = @min(first +| limit, order.len);

        try json.beginObject();
        try json.objectField("rows");
        try json.beginArray();
        for (order[first..last]) |index| {
            const group = try self.reader.group(index);
            const alive = try self.aliveFiles(&group);
            const covered = if (bulk) |*matcher|
                alive.len >= 2 and matcher.matches(group.size, alive)
            else
                false;
            const decided = try self.planGroup(arena, &query.keep, &group, alive);

            try json.beginObject();
            var hex: [64]u8 = undefined;
            try json.objectField("hash");
            try json.write(hasher.hashToHex(&group.hash, &hex));
            try json.objectField("count");
            try json.write(alive.len);
            try json.objectField("size");
            try json.write(group.size);
            try json.objectField("savings");
            try json.write(liveSavings(group.size, alive.len));

            const listed = alive[0..@min(alive.len, group_files_in_row)];
            try json.objectField("files");
            try json.beginArray();
            for (listed) |file| try json.write(try lossy(arena, file.path));
            try json.endArray();
            try json.objectField("mtimes");
            try json.beginArray();
            for (listed) |file| try json.write(millis(file.mtime));
            try json.endArray();
            // The copy `keep` leaves in place, which may be past the listed
            // ones; `locked` and `targets` run parallel to `files`.
            try json.objectField("keeper");
            if (decided.primary) |p| try json.write(try lossy(arena, alive[p].path)) else try json.write(null);
            try json.objectField("locked");
            try json.beginArray();
            for (decided.members[0..listed.len]) |member| try json.write(member.protected);
            try json.endArray();
            try json.objectField("targets");
            try json.beginArray();
            for (decided.targets[0..listed.len]) |target| try json.write(target);
            try json.endArray();
            try json.objectField("bulk");
            try json.write(covered);
            try json.endObject();
        }
        try json.endArray();
        try json.objectField("total");
        try json.write(order.len);
        try json.objectField("offset");
        try json.write(query.offset);
        try json.endObject();
    }

    // --- bulk summary -----------------------------------------------------

    /// Every copy but the oldest in the matching groups, as three numbers,
    /// protected copies left out. Never sees the unticked list; the UI
    /// subtracts it. `bulkPlan` answers the same for any keep rule.
    pub fn bulkSummary(self: *Session, filters_json: []const u8) ?[:0]const u8 {
        const arena = self.beginCall();
        const filters = std.json.parseFromSliceLeaky(Filters, arena, filters_json, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.fail("filters are not valid JSON", .{});
            return null;
        };

        const order = self.cachedGroupOrder(.savings, filters) catch |err|
            return self.callFailed(err);

        const spec: keep_mod.Spec = .{};
        var files: u64 = 0;
        var bytes: u64 = 0;
        for (order) |index| {
            const group = self.reader.group(index) catch |err| return self.readFailed(err);
            const alive = self.aliveFiles(&group) catch |err| return self.callFailed(err);
            const decided = self.planGroup(arena, &spec, &group, alive) catch |err| return self.callFailed(err);
            var extra: u64 = 0;
            for (decided.targets) |t| extra += @intFromBool(t);
            files +|= extra;
            bytes +|= group.size *| extra;
        }

        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        writeSummary(&json, order.len, files, bytes) catch return self.outOfMemory();
        return self.finishJson(&out);
    }

    /// What a delete carrying this rule would do: how many copies go, how
    /// many protected copies stay regardless, how many matching groups lose
    /// nothing, and where the deleted copies are, by location. This is what a
    /// UI shows for review before it deletes anything.
    pub fn bulkPlan(self: *Session, query_json: []const u8) ?[:0]const u8 {
        const arena = self.beginCall();
        const query = std.json.parseFromSliceLeaky(PlanQuery, arena, query_json, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.fail("plan query is not valid JSON (it needs \"filters\")", .{});
            return null;
        };
        const order = self.cachedGroupOrder(.savings, query.filters) catch |err|
            return self.callFailed(err);
        const roots = self.normalizedRoots(arena) catch return self.outOfMemory();
        const base: ?[]const u8 = query.under orelse (if (roots.len == 1) roots[0] else null);

        var unticked: std.StringHashMapUnmanaged(void) = .empty;
        for (query.excluded) |path| unticked.put(arena, path, {}) catch return self.outOfMemory();

        var tally: PlanTally = .{};
        var counter: FacetCounter = .init(arena);
        for (order) |index| {
            self.tallyGroup(arena, &tally, &counter, &query.keep, &unticked, index, base, roots) catch |err|
                return self.callFailed(err);
        }

        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        writePlan(&json, arena, &tally, &counter, base, @min(query.limit, max_facets)) catch |err|
            return self.callFailed(err);
        return self.finishJson(&out);
    }

    const PlanTally = struct {
        groups: usize = 0,
        files: u64 = 0,
        bytes: u64 = 0,
        /// Protected copies in the matching groups, all of which stay.
        locked: u64 = 0,
        /// Matching groups the rule deletes nothing from.
        untouched: usize = 0,
    };

    fn tallyGroup(
        self: *Session,
        arena: Allocator,
        tally: *PlanTally,
        counter: *FacetCounter,
        spec: *const keep_mod.Spec,
        unticked: *const std.StringHashMapUnmanaged(void),
        index: u32,
        base: ?[]const u8,
        roots: []const []const u8,
    ) !void {
        const group = try self.reader.group(index);
        const alive = try self.aliveFiles(&group);
        const decided = try self.planGroup(arena, spec, &group, alive);
        var taken: u64 = 0;
        for (decided.members, decided.targets) |member, target| {
            tally.locked += @intFromBool(member.protected);
            if (!target) continue;
            if (unticked.count() > 0 and unticked.contains(try lossy(arena, member.path))) continue;
            taken += 1;
            // A file is somewhere by its folder: one directly in `base` counts
            // as "here", never as a location of its own.
            const key = try facetKey(arena, .location, parentOf(member.path), base, roots) orelse continue;
            try counter.add(arena, group.size, &.{key});
        }
        if (taken == 0) {
            tally.untouched += 1;
            return;
        }
        tally.groups += 1;
        tally.files +|= taken;
        tally.bytes +|= group.size *| taken;
    }

    fn writePlan(
        json: *std.json.Stringify,
        arena: Allocator,
        tally: *const PlanTally,
        counter: *FacetCounter,
        base: ?[]const u8,
        limit: usize,
    ) !void {
        try json.beginObject();
        try json.objectField("groups");
        try json.write(tally.groups);
        try json.objectField("files");
        try json.write(tally.files);
        try json.objectField("bytes");
        try json.write(tally.bytes);
        try json.objectField("locked");
        try json.write(tally.locked);
        try json.objectField("untouched");
        try json.write(tally.untouched);
        try json.objectField("from");
        try counter.write(json, arena, base, limit);
        try json.endObject();
    }

    fn writeSummary(json: *std.json.Stringify, group_count: usize, files: u64, bytes: u64) !void {
        try json.beginObject();
        try json.objectField("groups");
        try json.write(group_count);
        try json.objectField("files");
        try json.write(files);
        try json.objectField("bytes");
        try json.write(bytes);
        try json.endObject();
    }

    // --- removed status ---------------------------------------------------

    pub fn removedStatus(self: *Session) ?[:0]const u8 {
        const arena = self.beginCall();
        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        blk: {
            json.beginObject() catch break :blk;
            json.objectField("count") catch break :blk;
            json.write(self.removed.len()) catch break :blk;
            json.objectField("needs_rescan") catch break :blk;
            json.write(self.removed.needsRescan()) catch break :blk;
            json.endObject() catch break :blk;
            return self.finishJson(&out);
        }
        return self.outOfMemory();
    }

    // --- folders: identical sets ------------------------------------------

    /// The indices of the findings that fall inside the requested page, and
    /// how many match in all.
    ///
    /// `match` is the cheap half of a row — the overlay and the filters — and
    /// is asked about every finding, because `total` is the count a UI pages
    /// against. Only the indices it keeps are built into rows afterwards, so
    /// findings before the page are never materialised.
    const Window = struct { indices: []const usize, total: usize };

    fn windowOf(
        arena: Allocator,
        count: usize,
        query: FolderQuery,
        ctx: anytype,
        comptime match: fn (@TypeOf(ctx), usize) anyerror!bool,
    ) !Window {
        const limit = @min(query.limit, max_page);
        var indices: std.ArrayListUnmanaged(usize) = .empty;
        var total: usize = 0;
        for (0..count) |i| {
            if (!try match(ctx, i)) continue;
            if (total >= query.offset and indices.items.len < limit) {
                try indices.append(arena, i);
            }
            total += 1;
        }
        return .{ .indices = indices.items, .total = total };
    }

    /// The matching sets in `query.sort` order, largest first; ties keep the
    /// store's order. Every matching set is visited, as a sort must.
    fn sortedSetWindow(self: *Session, arena: Allocator, query: FolderQuery, cursor: Cursor) !Window {
        const Row = struct { index: usize, key: u64 };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        for (0..self.reader.setCount()) |i| {
            if (!try cursor.set(i)) continue;
            const s = try self.reader.set(i);
            const alive = (try self.aliveDirs(&s)).len;
            try rows.append(arena, .{ .index = i, .key = switch (query.sort) {
                .reclaim => liveSavings(s.bytes, alive),
                .size => s.bytes,
                .count => alive,
            } });
        }
        std.mem.sort(Row, rows.items, {}, struct {
            fn desc(_: void, a: Row, b: Row) bool {
                return a.key > b.key;
            }
        }.desc);
        const limit = @min(query.limit, max_page);
        const first = @min(query.offset, rows.items.len);
        const last = @min(first +| limit, rows.items.len);
        const indices = try arena.alloc(usize, last - first);
        for (rows.items[first..last], indices) |row, *slot| slot.* = row.index;
        return .{ .indices = indices, .total = rows.items.len };
    }

    /// What `windowOf` asks about each finding, for the two folder lists.
    const Cursor = struct {
        session: *Session,
        matcher: *const Matcher,

        fn set(self: Cursor, index: usize) anyerror!bool {
            const s = try self.session.reader.set(index);
            const dirs = try self.session.aliveDirs(&s);
            // One copy left is not a set of identical folders any more.
            return dirs.len >= 2 and self.matcher.matches(s.bytes, dirs);
        }

        fn overlap(self: Cursor, index: usize) anyerror!bool {
            const pair = try self.session.reader.overlap(index);
            return self.session.overlapMatches(self.matcher, &pair);
        }
    };

    pub fn identicalSets(self: *Session, query_json: []const u8) ?[:0]const u8 {
        const arena = self.beginCall();
        const query = std.json.parseFromSliceLeaky(FolderQuery, arena, query_json, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.fail("set query is not valid JSON", .{});
            return null;
        };
        const matcher = Matcher.init(arena, query.filters) catch return self.outOfMemory();
        const cursor: Cursor = .{ .session = self, .matcher = &matcher };

        // The store holds sets largest-reclaim-first as scanned; any other
        // order, or reclaim once a delete has changed what sets free, is sorted.
        const window = (if (query.sort == .reclaim and self.removed.isEmpty())
            windowOf(arena, self.reader.setCount(), query, cursor, Cursor.set)
        else
            self.sortedSetWindow(arena, query, cursor)) catch |err| return self.callFailed(err);

        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        self.writeSetPage(&json, arena, window, query) catch |err| return self.callFailed(err);
        return self.finishJson(&out);
    }

    fn writeSetPage(
        self: *Session,
        json: *std.json.Stringify,
        arena: Allocator,
        window: Window,
        query: FolderQuery,
    ) !void {
        try json.beginObject();
        try json.objectField("rows");
        try json.beginArray();
        for (window.indices) |index| {
            const set = try self.reader.set(index);
            const dirs = try self.aliveDirs(&set);

            var common: ?[]const u8 = null;
            for (dirs) |dir| narrowToCommonDir(&common, dir.path);

            try json.beginObject();
            try json.objectField("index");
            try json.write(index);
            var hex: [64]u8 = undefined;
            try json.objectField("digest");
            try json.write(hasher.hashToHex(&set.digest, &hex));
            try json.objectField("count");
            try json.write(dirs.len);
            try json.objectField("common_parent");
            try json.write(try lossy(arena, common orelse ""));
            try json.objectField("file_count");
            try json.write(set.file_count);
            try json.objectField("bytes");
            try json.write(set.bytes);
            try json.objectField("reclaimable");
            try json.write(liveSavings(set.bytes, dirs.len));
            try json.objectField("dirs");
            try writeDirRows(json, arena, dirs[0..@min(dirs.len, set_members_in_row)], self.protection());
            try json.endObject();
        }
        try json.endArray();
        try json.objectField("total");
        try json.write(window.total);
        try json.objectField("offset");
        try json.write(query.offset);
        try json.endObject();
    }

    /// `locked` is what a folder delete would say of the folder: it is, or
    /// holds, a protected location, so it is never deleted.
    fn writeDirRows(
        json: *std.json.Stringify,
        arena: Allocator,
        dirs: []const AliveDir,
        guard: protect_mod.Protection,
    ) !void {
        try json.beginArray();
        for (dirs) |dir| {
            try json.beginObject();
            try json.objectField("path");
            try json.write(try lossy(arena, dir.path));
            try json.objectField("newest_mtime");
            try json.write(millis(dir.newest_mtime));
            try json.objectField("skipped_entries");
            try json.write(dir.skipped_entries);
            try json.objectField("locked");
            try json.write(guard.guardsFolder(dir.path));
            try json.endObject();
        }
        try json.endArray();
    }

    /// Every member folder of one set — rows carry only the first few. The one
    /// unpaged call, and bounded by a single set.
    pub fn setMembers(self: *Session, index: usize) ?[:0]const u8 {
        const arena = self.beginCall();
        const set = self.reader.set(index) catch |err| return self.readFailed(err);
        const dirs = self.aliveDirs(&set) catch |err| return self.callFailed(err);

        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        writeDirRows(&json, arena, dirs, self.protection()) catch |err| return self.callFailed(err);
        return self.finishJson(&out);
    }

    // --- folders: overlaps ------------------------------------------------

    pub fn overlaps(self: *Session, query_json: []const u8) ?[:0]const u8 {
        const arena = self.beginCall();
        const query = std.json.parseFromSliceLeaky(FolderQuery, arena, query_json, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.fail("overlap query is not valid JSON", .{});
            return null;
        };
        const matcher = Matcher.init(arena, query.filters) catch return self.outOfMemory();
        const cursor: Cursor = .{ .session = self, .matcher = &matcher };

        const window = windowOf(arena, self.reader.overlapCount(), query, cursor, Cursor.overlap) catch |err|
            return self.callFailed(err);

        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        self.writeOverlapPage(&json, arena, window, query) catch |err| return self.callFailed(err);
        return self.finishJson(&out);
    }

    fn writeOverlapPage(
        self: *Session,
        json: *std.json.Stringify,
        arena: Allocator,
        window: Window,
        query: FolderQuery,
    ) !void {
        try json.beginObject();
        try json.objectField("rows");
        try json.beginArray();
        for (window.indices) |index| {
            const pair = try self.reader.overlap(index);
            try json.beginObject();
            try json.objectField("relation");
            try json.write(@tagName(store.Reader.relationOfRecord(&pair)));
            try json.objectField("a");
            try self.writeSideRow(json, arena, &pair.a);
            try json.objectField("b");
            try self.writeSideRow(json, arena, &pair.b);
            try json.endObject();
        }
        try json.endArray();
        try json.objectField("total");
        try json.write(window.total);
        try json.objectField("offset");
        try json.write(query.offset);
        try json.endObject();
    }

    fn writeSideRow(
        self: *Session,
        json: *std.json.Stringify,
        arena: Allocator,
        side: *const store.Side,
    ) !void {
        const path = try self.reader.sidePath(side);
        try json.beginObject();
        try json.objectField("path");
        try json.write(try lossy(arena, path));
        try json.objectField("locked");
        try json.write(self.protection().guardsFolder(path));
        inline for (.{
            .{ "files", side.files },
            .{ "bytes", side.bytes },
        }) |f| {
            try json.objectField(f[0]);
            try json.write(f[1]);
        }
        try json.objectField("newest_mtime");
        try json.write(millis(side.newest_mtime));
        try json.objectField("skipped_entries");
        try json.write(side.skipped_entries);
        try json.objectField("complete");
        try json.write(side.complete == 1);
        inline for (.{
            .{ "identical_copies", side.identical_copies },
            .{ "shared_files", side.shared_files },
            .{ "shared_bytes", side.shared_bytes },
            .{ "only_count", side.only_count },
        }) |f| {
            try json.objectField(f[0]);
            try json.write(f[1]);
        }
        // `only_count` is exact; `only` lists what the scan kept (<= 100).
        try json.objectField("only");
        try json.beginArray();
        for (0..side.only_listed) |i| {
            try json.write(try lossy(arena, try self.reader.onlyPath(side, i)));
        }
        try json.endArray();
        try json.endObject();
    }

    // --- folders: facets --------------------------------------------------

    /// Findings counted by where they are, what they are called, or what type
    /// they are — the "group by" of the UI.
    pub fn facets(self: *Session, query_json: []const u8) ?[:0]const u8 {
        const arena = self.beginCall();
        const query = std.json.parseFromSliceLeaky(FacetQuery, arena, query_json, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.fail("facet query is not valid JSON", .{});
            return null;
        };
        const matcher = Matcher.init(arena, query.filters) catch return self.outOfMemory();
        const roots = self.normalizedRoots(arena) catch return self.outOfMemory();

        // Locations drill down from `filters.under`. With nothing chosen yet
        // and a single scan root, start inside that root rather than offer it
        // as the one and only facet.
        const base: ?[]const u8 = switch (query.by) {
            .location => query.filters.under orelse
                (if (roots.len == 1) roots[0] else null),
            else => null,
        };

        var counter: FacetCounter = .init(arena);
        self.countFacets(arena, &counter, query, &matcher, base, roots) catch |err|
            return self.callFailed(err);

        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        counter.write(&json, arena, base, @min(query.limit, max_facets)) catch |err|
            return self.callFailed(err);
        return self.finishJson(&out);
    }

    fn countFacets(
        self: *Session,
        arena: Allocator,
        counter: *FacetCounter,
        query: FacetQuery,
        matcher: *const Matcher,
        base: ?[]const u8,
        roots: []const []const u8,
    ) !void {
        // Only the members that satisfy the chosen facets say where a finding
        // "is": under ~/work, a set spanning ~/work and /mnt is listed by its
        // ~/work member, not pulled apart by the other one.
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;

        switch (query.kind) {
            .groups => for (0..self.reader.groupCount()) |i| {
                const group = try self.reader.group(i);
                const alive = try self.aliveFiles(&group);
                if (alive.len < 2 or !matcher.matches(group.size, alive)) continue;
                paths.clearRetainingCapacity();
                for (alive) |file| try paths.append(arena, file.path);
                try collectKeys(arena, &keys, paths.items, query.by, matcher, base, roots, .files);
                try counter.add(arena, liveSavings(group.size, alive.len), keys.items);
            },
            .sets => for (0..self.reader.setCount()) |i| {
                const set = try self.reader.set(i);
                const dirs = try self.aliveDirs(&set);
                if (dirs.len < 2 or !matcher.matches(set.bytes, dirs)) continue;
                paths.clearRetainingCapacity();
                for (dirs) |dir| try paths.append(arena, dir.path);
                try collectKeys(arena, &keys, paths.items, query.by, matcher, base, roots, .folders);
                try counter.add(arena, liveSavings(set.bytes, dirs.len), keys.items);
            },
            .overlaps => for (0..self.reader.overlapCount()) |i| {
                const pair = try self.reader.overlap(i);
                if (!try self.overlapMatches(matcher, &pair)) continue;
                const sides = [_][]const u8{
                    try self.reader.sidePath(&pair.a),
                    try self.reader.sidePath(&pair.b),
                };
                try collectKeys(arena, &keys, &sides, query.by, matcher, base, roots, .folders);
                try counter.add(arena, overlapBytes(&pair), keys.items);
            },
        }
    }

    // --- folder deletes ---------------------------------------------------

    /// Remove whole folders: to the Trash, where the selection rules in the UI
    /// are the safeguard, or for good, where each one is compared with a
    /// surviving copy byte for byte immediately beforehand.
    pub fn deleteFolders(
        self: *Session,
        items_json: []const u8,
        use_trash: bool,
        trash_fn: ?TrashFn,
        user: ?*anyopaque,
    ) ?[:0]const u8 {
        // Claimed before `beginCall`, for the reason `delete` gives.
        if (self.del.running.swap(true, .acq_rel)) {
            self.fail("A delete is already running", .{});
            return null;
        }
        defer self.del.running.store(false, .release);
        defer self.del.cancel.store(false, .release);
        self.del.done.store(0, .release);
        self.del.total.store(0, .release);

        const arena = self.beginCall();
        const items = std.json.parseFromSliceLeaky([]const FolderItem, arena, items_json, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.fail("folder list is not valid JSON", .{});
            return null;
        };
        if (use_trash and trash_fn == null) {
            self.fail("no Trash callback was provided", .{});
            return null;
        }

        var report: Report = .{};
        self.runFolderDelete(arena, &report, items, use_trash, trash_fn, user);

        if (report.removed_paths.items.len > 0) {
            report.needs_rescan = !self.removed.record(report.removed_paths.items);
            self.clearOrder();
        } else {
            report.needs_rescan = self.removed.needsRescan();
        }

        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        writeReport(&json, &report) catch return self.outOfMemory();
        return self.finishJson(&out);
    }

    fn runFolderDelete(
        self: *Session,
        arena: Allocator,
        report: *Report,
        items: []const FolderItem,
        use_trash: bool,
        trash_fn: ?TrashFn,
        user: ?*anyopaque,
    ) void {
        self.del.total.store(items.len, .release);
        const guard = self.protection();

        for (items) |item| {
            if (self.del.cancel.load(.acquire)) {
                report.cancelled = true;
                break;
            }
            _ = self.del.done.fetchAdd(1, .release);

            var path_buf: [4096]u8 = undefined;
            const path_z = pathZ(&path_buf, item.path) orelse {
                report.fail(arena, item.path, "path is too long");
                continue;
            };
            if (guard.guardsFolder(item.path)) {
                report.fail(arena, item.path, "is, or holds, a protected location");
                continue;
            }

            if (use_trash) {
                // Recoverable, so the UI's selection rules are the safeguard.
                // But never follow a link, and never trash a non-folder.
                if (folderKind(path_z)) |reason| {
                    report.fail(arena, item.path, reason);
                    continue;
                }
                var err_buf: [512]u8 = undefined;
                err_buf[0] = 0;
                const paths = [_][*:0]const u8{path_z};
                if (trash_fn.?(user, &paths, 1, &err_buf, err_buf.len) == 0) {
                    report.removed(arena, item.path, item.bytes);
                } else {
                    report.fail(arena, item.path, trashReason(arena, &err_buf));
                }
                continue;
            }

            if (folderRefusal(item, path_z)) |reason| {
                report.fail(arena, item.path, reason);
                continue;
            }
            // Compared right now, in full: same relative paths, same bytes,
            // and nothing extra on either side, hidden files included. A
            // keeper that is itself being removed vouches for nothing.
            const verified = for (item.keepers) |keeper| {
                if (touchedByAny(keeper, items)) continue;
                if (foldersIdentical(self.gpa, item.path, keeper)) break true;
            } else false;
            if (!verified) {
                report.skipped_changed += 1;
                report.fail(arena, item.path, "no longer identical to a surviving copy " ++
                    "(or it differs in files the scan ignored, such as dependency folders). " ++
                    "Use the Trash instead.");
                continue;
            }
            if (removeTree(path_z)) |errno| {
                report.fail(arena, item.path, unlinkReason(errno));
            } else {
                // The overlay records the caller's spelling, which is the only
                // one it had; a folder whose real name is not UTF-8 would have
                // been refused above, because that spelling does not open.
                report.removed(arena, item.path, item.bytes);
            }
        }
    }

    // --- delete -----------------------------------------------------------

    pub fn deleteProgress(self: *const Session) DeleteProgress {
        return .{
            .running = self.del.running.load(.acquire),
            .done = self.del.done.load(.acquire),
            .total = self.del.total.load(.acquire),
        };
    }

    pub fn cancelDelete(self: *Session) void {
        self.del.cancel.store(true, .release);
    }

    /// Blocks until done. `use_trash` false deletes permanently and verifies by
    /// content; true calls `trash_fn` and verifies by metadata.
    pub fn delete(
        self: *Session,
        selection_json: []const u8,
        use_trash: bool,
        trash_fn: ?TrashFn,
        user: ?*anyopaque,
    ) ?[:0]const u8 {
        // Claimed before anything else, because `beginCall` frees the arena the
        // delete in flight is working out of. Only this refusal is safe to
        // reach from inside a running delete — a Trash callback that calls
        // anything else on the session pulls the ground out from under it.
        if (self.del.running.swap(true, .acq_rel)) {
            self.fail("A delete is already running", .{});
            return null;
        }
        defer self.del.running.store(false, .release);
        // Whatever happens, the next delete on this session starts uncancelled;
        // a cancel asked for before this one began still counts, as it does for
        // a scan (`zdedupe_cancel`).
        defer self.del.cancel.store(false, .release);
        self.del.done.store(0, .release);
        self.del.total.store(0, .release);

        const arena = self.beginCall();
        const selection = std.json.parseFromSliceLeaky(Selection, arena, selection_json, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.fail("selection is not valid JSON", .{});
            return null;
        };
        if (use_trash and trash_fn == null) {
            self.fail("no Trash callback was provided", .{});
            return null;
        }

        const order: ?[]const u32 = if (selection.rule) |rule|
            self.cachedGroupOrder(.savings, rule.filters) catch |err| return self.callFailed(err)
        else
            null;

        var report: Report = .{};
        self.runDelete(arena, &report, selection, order, use_trash, trash_fn, user) catch |err|
            return self.callFailed(err);

        // Hand what went to the overlay, so the results stop listing it.
        if (report.removed_paths.items.len > 0) {
            report.needs_rescan = !self.removed.record(report.removed_paths.items);
            self.clearOrder();
        } else {
            report.needs_rescan = self.removed.needsRescan();
        }

        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        writeReport(&json, &report) catch return self.outOfMemory();
        return self.finishJson(&out);
    }

    fn runDelete(
        self: *Session,
        arena: Allocator,
        report: *Report,
        selection: Selection,
        order: ?[]const u32,
        use_trash: bool,
        trash_fn: ?TrashFn,
        user: ?*anyopaque,
    ) !void {
        const verify: Verify = if (use_trash)
            .metadata
        else
            .{ .content = .{ .sha256 = self.reader.isSha256() } };

        // Which group, and which file in it, each hand-ticked path is.
        var by_hand: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
        var located: usize = 0;
        try self.locate(arena, selection.extra, &by_hand, &located);

        // Targets per group: the rule's (every alive copy its keep spec does not
        // keep, minus what was unticked) merged with the hand-ticked ones, so
        // "keep at least one copy" is judged once per group over everything
        // that is about to go.
        const Entry = struct { group: u32, targets: []const u32 };
        var plan: std.ArrayListUnmanaged(Entry) = .empty;
        var planned: std.AutoHashMapUnmanaged(u32, void) = .empty;

        if (order) |rows| {
            const rule = &selection.rule.?;
            var unticked: std.StringHashMapUnmanaged(void) = .empty;
            for (rule.excluded) |path| try unticked.put(arena, path, {});

            for (rows) |g| {
                const group = try self.reader.group(g);
                var targets: std.ArrayListUnmanaged(u32) = .empty;
                // Decided over the copies that still exist: an earlier delete
                // may already have taken the group's original keeper.
                const alive = try self.aliveFiles(&group);
                const decided = try self.planGroup(arena, &rule.keep, &group, alive);
                for (alive, decided.targets) |file, target| {
                    if (!target) continue;
                    if (unticked.count() > 0) {
                        // The UI only ever saw the lossy spelling of a path, so
                        // that is what comes back unticked.
                        if (unticked.contains(try lossy(arena, file.path))) continue;
                    }
                    try targets.append(arena, file.index);
                }
                if (by_hand.get(g)) |picks| {
                    for (picks.items) |f| {
                        if (std.mem.indexOfScalar(u32, targets.items, f) == null) {
                            try targets.append(arena, f);
                        }
                    }
                }
                try planned.put(arena, g, {});
                try plan.append(arena, .{ .group = g, .targets = targets.items });
            }
        }
        // Hand-picks in groups the rule did not cover, in group order so a
        // report reads the same way twice. A protected one among them is
        // refused by `deletable`, like any protected target.
        {
            var leftovers: std.ArrayListUnmanaged(u32) = .empty;
            var it = by_hand.iterator();
            while (it.next()) |entry| {
                if (!planned.contains(entry.key_ptr.*)) try leftovers.append(arena, entry.key_ptr.*);
            }
            std.mem.sort(u32, leftovers.items, {}, std.sort.asc(u32));
            for (leftovers.items) |g| {
                try plan.append(arena, .{ .group = g, .targets = by_hand.get(g).?.items });
            }
        }

        // Hand-ticked paths that are in no group of these results: we know
        // nothing about them, so we do not delete them.
        if (located < selection.extra.len) {
            for (selection.extra) |path| {
                if (!try self.isKnownPath(arena, &by_hand, path)) {
                    report.fail(arena, path, "not a duplicate in the current results");
                }
            }
        }

        var total: u64 = 0;
        for (plan.items) |entry| total +|= entry.targets.len;
        self.del.total.store(total, .release);

        var batch: std.ArrayListUnmanaged(Target) = .empty;
        try batch.ensureTotalCapacity(arena, trash_batch);
        for (plan.items) |entry| {
            if (self.del.cancel.load(.acquire)) {
                report.cancelled = true;
                break;
            }
            const group = try self.reader.group(entry.group);
            var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
            try self.deletable(arena, &group, entry.targets, verify, report, &doomed);
            for (doomed.items) |path| {
                batch.appendAssumeCapacity(.{ .path = path, .size = group.size });
                if (batch.items.len == trash_batch) {
                    self.removeBatch(arena, batch.items, use_trash, trash_fn, user, report);
                    batch.clearRetainingCapacity();
                }
            }
            _ = self.del.done.fetchAdd(entry.targets.len, .release);
        }
        self.removeBatch(arena, batch.items, use_trash, trash_fn, user, report);
    }

    /// Locate each hand-picked path in the store, by the lossy spelling a UI
    /// can have sent. Two names can share one spelling, so a pick may land on
    /// more than one file; the survivor rule still applies to all of them.
    fn locate(
        self: *Session,
        arena: Allocator,
        extra: []const []const u8,
        out: *std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)),
        located: *usize,
    ) !void {
        if (extra.len == 0) return;
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        for (extra) |path| try wanted.put(arena, path, {});

        for (0..self.reader.groupCount()) |g| {
            const group = try self.reader.group(g);
            for (0..group.file_count) |f| {
                const file = try self.reader.groupFile(&group, f);
                if (!wanted.contains(try lossy(arena, file.path))) continue;
                const entry = try out.getOrPut(arena, @intCast(g));
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(arena, @intCast(f));
                located.* += 1;
            }
        }
    }

    fn isKnownPath(
        self: *Session,
        arena: Allocator,
        by_hand: *const std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)),
        path: []const u8,
    ) !bool {
        var it = by_hand.iterator();
        while (it.next()) |entry| {
            const group = try self.reader.group(entry.key_ptr.*);
            for (entry.value_ptr.items) |f| {
                const file = try self.reader.groupFile(&group, f);
                if (std.mem.eql(u8, try lossy(arena, file.path), path)) return true;
            }
        }
        return false;
    }

    /// From `group`, the targets that may be deleted: only if some copy outside
    /// `targets` verifies — so the group keeps at least one — and only those
    /// targets that verify themselves.
    fn deletable(
        self: *Session,
        arena: Allocator,
        group: *const store.Group,
        targets: []const u32,
        verify: Verify,
        report: *Report,
        out: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        if (targets.len == 0) return;
        const guard = self.protection();

        var has_survivor = false;
        for (0..group.file_count) |f| {
            if (std.mem.indexOfScalar(u32, targets, @intCast(f)) != null) continue;
            const file = try self.reader.groupFile(group, f);
            if (stillACopy(file.path, group.size, file.mtime, &group.hash, verify)) {
                has_survivor = true;
                break;
            }
        }
        if (!has_survivor) {
            report.skipped_changed +|= targets.len;
            return;
        }

        for (targets) |f| {
            const file = try self.reader.groupFile(group, f);
            // Whatever put it here — a hand-ticked file, a rule — a protected
            // copy is never deleted.
            if (guard.protects(file.path)) {
                report.fail(arena, file.path, "is in a protected location");
                continue;
            }
            if (stillACopy(file.path, group.size, file.mtime, &group.hash, verify)) {
                try out.append(arena, file.path);
            } else {
                report.skipped_changed += 1;
            }
        }
    }

    const Target = struct { path: []const u8, size: u64 };

    /// Delete a batch, as one Trash call when that can be attributed on
    /// failure, otherwise one file at a time.
    fn removeBatch(
        self: *Session,
        arena: Allocator,
        batch: []const Target,
        use_trash: bool,
        trash_fn: ?TrashFn,
        user: ?*anyopaque,
        report: *Report,
    ) void {
        if (batch.len == 0) return;
        var err_buf: [512]u8 = undefined;

        if (use_trash and batch.len > 1) {
            if (self.trashBatch(arena, batch, trash_fn.?, user, &err_buf)) {
                for (batch) |target| report.removed(arena, target.path, target.size);
                return;
            }
        }

        // One at a time: a single file, a permanent delete, or a failed batch
        // where we need to know which file was the problem.
        for (batch) |target| {
            var path_buf: [4096]u8 = undefined;
            const path_z = pathZ(&path_buf, target.path) orelse {
                report.fail(arena, target.path, "path is too long");
                continue;
            };
            if (use_trash) {
                // A failed batch may have moved some files already.
                _ = pstat.lstat(path_z) catch {
                    report.removed(arena, target.path, target.size);
                    continue;
                };
                err_buf[0] = 0;
                const paths = [_][*:0]const u8{path_z};
                if (trash_fn.?(user, &paths, 1, &err_buf, err_buf.len) == 0) {
                    report.removed(arena, target.path, target.size);
                } else {
                    report.fail(arena, target.path, trashReason(arena, &err_buf));
                }
            } else if (libc.unlink(path_z) == 0) {
                report.removed(arena, target.path, target.size);
            } else {
                report.fail(arena, target.path, unlinkReason(libc.errno(@as(c_int, -1))));
            }
        }
    }

    fn trashBatch(
        self: *Session,
        arena: Allocator,
        batch: []const Target,
        trash_fn: TrashFn,
        user: ?*anyopaque,
        err_buf: *[512]u8,
    ) bool {
        _ = self;
        const paths = arena.alloc([*:0]const u8, batch.len) catch return false;
        for (batch, paths) |target, *slot| {
            const owned = arena.dupeZ(u8, target.path) catch return false;
            slot.* = owned.ptr;
        }
        err_buf[0] = 0;
        return trash_fn(user, paths.ptr, paths.len, err_buf, err_buf.len) == 0;
    }

    // --- export -----------------------------------------------------------

    pub const Format = enum { json, csv, html };

    /// Streams every alive group in store order, so a scan with millions of
    /// duplicates never exists as one document in memory.
    pub fn exportTo(self: *Session, format_name: []const u8, path: []const u8) bool {
        _ = self.beginCall();

        const format = std.meta.stringToEnum(Format, format_name) orelse {
            self.fail("unknown export format \"{s}\"; expected json, csv or html", .{format_name});
            return false;
        };

        var path_buf: [4096]u8 = undefined;
        const path_z = pathZ(&path_buf, path) orelse {
            self.fail("export path is too long", .{});
            return false;
        };
        const fd = libc.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(libc.mode_t, 0o600));
        if (fd < 0) {
            self.fail("cannot write {s}", .{path});
            return false;
        }
        defer _ = libc.close(fd);

        var buffer: [64 * 1024]u8 = undefined;
        var sink: FdSink = .init(fd, &buffer);
        self.writeExport(format, &sink.interface) catch |err| {
            switch (err) {
                error.WriteFailed => self.fail("cannot write {s}", .{path}),
                error.OutOfMemory => self.fail("out of memory", .{}),
                else => self.failRead(@errorCast(err)),
            }
            return false;
        };
        sink.interface.flush() catch {
            self.fail("cannot write {s}", .{path});
            return false;
        };
        return true;
    }

    /// The three documents are written by hand rather than through
    /// `std.json.Stringify`, so a group can be emitted and forgotten instead
    /// of held. Everything interpolated is therefore either a fixed-alphabet
    /// token (hex digest, ISO timestamp, integer) or goes through
    /// `encodeJsonString` / `writeCsvField` / `writeEscapedHtml` — a path is
    /// never written raw into any of them.
    fn writeExport(self: *Session, format: Format, writer: *std.Io.Writer) !void {
        const arena = self.arena.allocator();
        const header = &self.reader.header;
        var iso: [24]u8 = undefined;
        const generated = report_mod.formatIso8601(header.generated_at, &iso);

        switch (format) {
            .csv => try writer.writeAll("Group Hash,File Path,File Size (bytes),Group Savings (bytes),Modified\n"),
            .json => try writer.print(
                \\{{
                \\  "report_type": "duplicates",
                \\  "generated_at": "{s}",
                \\  "summary": {{
                \\    "files_scanned": {d},
                \\    "bytes_scanned": {d},
                \\    "duplicate_groups": {d},
                \\    "duplicate_files": {d},
                \\    "space_savings": {d}
                \\  }},
                \\  "groups": [
                \\
            , .{
                generated,
                header.files_scanned,
                header.bytes_scanned,
                header.duplicate_groups,
                header.duplicate_files,
                header.space_savings,
            }),
            .html => try self.writeHtmlHeader(writer, generated),
        }

        var first_group = true;
        for (0..self.reader.groupCount()) |i| {
            const group = try self.reader.group(i);
            const alive = try self.aliveFiles(&group);
            if (alive.len < 2) continue;
            const savings = liveSavings(group.size, alive.len);

            var hex: [64]u8 = undefined;
            const hash = hasher.hashToHex(&group.hash, &hex);

            switch (format) {
                .csv => for (alive) |file| {
                    try writer.print("{s},", .{hash});
                    try writeCsvField(writer, try lossy(arena, file.path));
                    try writer.print(",{d},{d},{s}\n", .{
                        group.size,
                        savings,
                        report_mod.formatIso8601(file.mtime, &iso),
                    });
                },
                .json => {
                    if (!first_group) try writer.writeAll(",\n");
                    try writer.print(
                        "    {{\n      \"hash\": \"{s}\",\n      \"size\": {d},\n      \"count\": {d},\n      \"savings\": {d},\n      \"files\": [\n",
                        .{ hash, group.size, alive.len, savings },
                    );
                    for (alive, 0..) |file, f| {
                        try writer.writeAll("        { \"path\": ");
                        try std.json.Stringify.encodeJsonString(try lossy(arena, file.path), .{}, writer);
                        try writer.print(", \"mtime\": \"{s}\" }}", .{report_mod.formatIso8601(file.mtime, &iso)});
                        if (f + 1 < alive.len) try writer.writeAll(",");
                        try writer.writeAll("\n");
                    }
                    try writer.writeAll("      ]\n    }");
                },
                .html => for (alive, 0..) |file, f| {
                    var size_buf: [64]u8 = undefined;
                    const header_row = f == 0;
                    try writer.print("<tr{s}><td>", .{if (header_row) " class=\"group-header\"" else ""});
                    if (header_row) try writer.print("{d} copies", .{alive.len});
                    try writer.writeAll("</td><td>");
                    try writeEscapedHtml(writer, try lossy(arena, file.path));
                    try writer.print("</td><td>{s}</td><td>", .{@import("types.zig").formatBytes(group.size, &size_buf)});
                    if (header_row) try writer.writeAll(@import("types.zig").formatBytes(savings, &size_buf));
                    try writer.writeAll("</td></tr>\n");
                },
            }
            first_group = false;
        }

        switch (format) {
            .csv => {},
            .json => try writer.writeAll("\n  ]\n}\n"),
            .html => try writer.writeAll("</table>\n</body></html>\n"),
        }
    }

    fn writeHtmlHeader(self: *Session, writer: *std.Io.Writer, generated: []const u8) !void {
        const header = &self.reader.header;
        var savings_buf: [64]u8 = undefined;
        try writer.print(
            \\<!DOCTYPE html>
            \\<html><head><meta charset="utf-8"><title>zdedupe — Duplicate Files</title>
            \\<style>
            \\body {{ font-family: -apple-system, system-ui, sans-serif; margin: 2rem; color: #222; }}
            \\table {{ border-collapse: collapse; width: 100%; }}
            \\th, td {{ text-align: left; padding: 6px 10px; border-bottom: 1px solid #e5e5e5; font-size: 13px; }}
            \\tr.group-header td {{ border-top: 2px solid #999; font-weight: 600; }}
            \\.summary {{ color: #555; margin-bottom: 1.5rem; }}
            \\</style></head><body>
            \\<h1>Duplicate Files</h1>
            \\<div class="summary">{d} groups · {d} duplicate files · {s} reclaimable · scanned {s}</div>
            \\<table>
            \\<tr><th>Group</th><th>File</th><th>Size</th><th>Savings</th></tr>
            \\
        , .{
            header.duplicate_groups,
            header.duplicate_files,
            @import("types.zig").formatBytes(header.space_savings, &savings_buf),
            generated,
        });
    }

    // --- shared plumbing --------------------------------------------------

    /// NUL-terminate the built JSON in place. The sentinel is inside the
    /// arena's buffer, so nothing is copied.
    fn finishJson(self: *Session, out: *std.Io.Writer.Allocating) ?[:0]const u8 {
        out.writer.writeByte(0) catch return self.outOfMemory();
        const written = out.writer.buffered();
        return written[0 .. written.len - 1 :0];
    }

    fn outOfMemory(self: *Session) ?[:0]const u8 {
        self.fail("out of memory", .{});
        return null;
    }

    fn readFailed(self: *Session, err: store.ReadError) ?[:0]const u8 {
        self.failRead(err);
        return null;
    }

    fn callFailed(self: *Session, err: anyerror) ?[:0]const u8 {
        return switch (err) {
            error.OutOfMemory => self.outOfMemory(),
            error.Invalid, error.OutOfRange => self.readFailed(@errorCast(err)),
            else => blk: {
                self.fail("{s}", .{@errorName(err)});
                break :blk null;
            },
        };
    }
};

fn writeReport(json: *std.json.Stringify, report: *const Report) !void {
    try json.beginObject();
    try json.objectField("deleted");
    try json.write(report.deleted);
    try json.objectField("freed_bytes");
    try json.write(report.freed_bytes);
    try json.objectField("skipped_changed");
    try json.write(report.skipped_changed);
    try json.objectField("failed_count");
    try json.write(report.failed_count);
    try json.objectField("failed");
    try json.beginArray();
    for (report.failed.items) |failure| {
        try json.beginArray();
        try json.write(failure.path);
        try json.write(failure.reason);
        try json.endArray();
    }
    try json.endArray();
    try json.objectField("cancelled");
    try json.write(report.cancelled);
    try json.objectField("needs_rescan");
    try json.write(report.needs_rescan);
    try json.endObject();
}

// ===========================================================================
// Facets
// ===========================================================================

/// The facet key one member contributes, or null when it contributes none —
/// a path under no scan root has no location to be counted in.
fn facetKey(
    arena: Allocator,
    by: FacetBy,
    path: []const u8,
    base: ?[]const u8,
    roots: []const []const u8,
) !?[]const u8 {
    return switch (by) {
        .name => filters_mod.baseName(path),
        .type => try filters_mod.extensionLower(arena, path),
        .location => if (base) |b|
            filters_mod.areaUnder(path, b)
        else for (roots) |root| {
            // At the top level the scan roots themselves are the areas.
            if (filters_mod.isAtOrUnder(path, root)) break root;
        } else null,
    };
}

/// The distinct keys a finding's members contribute. Only members that
/// satisfy the chosen facets count, so a finding spanning two places is
/// listed under the one the query asked about rather than pulled apart.
fn collectKeys(
    arena: Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
    members: []const []const u8,
    by: FacetBy,
    matcher: *const Matcher,
    base: ?[]const u8,
    roots: []const []const u8,
    kind: MemberKind,
) !void {
    out.clearRetainingCapacity();
    for (members) |path| {
        if (!matcher.memberSelected(path)) continue;
        // A file's location is its folder, so a file directly in `base` counts
        // as "here" rather than showing up as a location of its own.
        const where = if (by == .location and kind == .files) parentOf(path) else path;
        const key = try facetKey(arena, by, where, base, roots) orelse continue;
        try out.append(arena, key);
    }
}

/// What a finding's members are: files are located by their folder.
const MemberKind = enum { files, folders };

/// The folder holding `path`: everything before its last slash ("/" for a
/// file at the top).
fn parentOf(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return if (i == 0) "/" else path[0..i];
}

/// Counts findings per facet. A finding contributes once to each distinct
/// facet it touches, however many of its members share that facet — so a set
/// with two copies in one folder counts once there, not twice.
const FacetCounter = struct {
    totals: std.StringHashMapUnmanaged(Tally) = .empty,
    /// Keys already credited for the finding in hand.
    seen: std.ArrayListUnmanaged([]const u8) = .empty,

    const Tally = struct { count: usize, bytes: u64 };
    const Facet = struct { key: []const u8, count: usize, bytes: u64 };

    fn init(arena: Allocator) FacetCounter {
        _ = arena;
        return .{};
    }

    fn add(self: *FacetCounter, arena: Allocator, bytes: u64, keys: []const []const u8) !void {
        self.seen.clearRetainingCapacity();
        for (keys) |key| {
            const already = for (self.seen.items) |k| {
                if (std.mem.eql(u8, k, key)) break true;
            } else false;
            if (already) continue;
            try self.seen.append(arena, key);

            const entry = try self.totals.getOrPut(arena, key);
            if (!entry.found_existing) entry.value_ptr.* = .{ .count = 0, .bytes = 0 };
            entry.value_ptr.count += 1;
            entry.value_ptr.bytes +|= bytes;
        }
    }

    fn write(
        self: *FacetCounter,
        json: *std.json.Stringify,
        arena: Allocator,
        base: ?[]const u8,
        limit: usize,
    ) !void {
        var all: std.ArrayListUnmanaged(Facet) = .empty;
        var it = self.totals.iterator();
        while (it.next()) |entry| {
            try all.append(arena, .{
                .key = entry.key_ptr.*,
                .count = entry.value_ptr.count,
                .bytes = entry.value_ptr.bytes,
            });
        }
        // Bytes first; count and key make the order total, so the same scan
        // always lists its facets the same way.
        std.mem.sort(Facet, all.items, {}, struct {
            fn before(_: void, a: Facet, b: Facet) bool {
                if (a.bytes != b.bytes) return a.bytes > b.bytes;
                if (a.count != b.count) return a.count > b.count;
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.before);

        try json.beginObject();
        try json.objectField("base");
        if (base) |b| try json.write(try lossy(arena, b)) else try json.write(null);
        try json.objectField("facets");
        try json.beginArray();
        for (all.items[0..@min(all.items.len, limit)]) |facet| {
            try json.beginObject();
            try json.objectField("key");
            try json.write(try lossy(arena, facet.key));
            try json.objectField("count");
            try json.write(facet.count);
            try json.objectField("bytes");
            try json.write(facet.bytes);
            try json.endObject();
        }
        try json.endArray();
        // Distinct facets before the cut, so a UI can say "showing 100 of N".
        try json.objectField("total");
        try json.write(all.items.len);
        try json.endObject();
    }
};

// ===========================================================================
// Folder removal
// ===========================================================================

/// Why `path` must not be trashed without even looking at it. Null means it
/// is a real directory.
fn folderKind(path: [*:0]const u8) ?[]const u8 {
    const st = pstat.lstat(path) catch return "cannot be read";
    if (!st.isDir()) return "not a real folder (a link or a file)";
    return null;
}

/// Why `item` must not be removed for good without even looking at its
/// content. Null means it may go on to be compared with its keepers.
fn folderRefusal(item: FolderItem, path: [*:0]const u8) ?[]const u8 {
    // An absolute path with a parent: never a relative path, and never "/".
    if (item.path.len == 0 or item.path[0] != '/') return "not an absolute folder path";
    if (std.mem.eql(u8, item.path, "/")) return "not an absolute folder path";
    // A symlink to a folder: removing "it" is not what was verified.
    if (folderKind(path)) |reason| return reason;
    if (item.keepers.len == 0) return "no surviving copy was named";
    return null;
}

/// True if `path` is, contains, or lies inside anything in `items`. Nothing
/// that is being deleted can vouch for anything else.
fn touchedByAny(path: []const u8, items: []const FolderItem) bool {
    for (items) |item| {
        if (filters_mod.isAtOrUnder(path, item.path)) return true;
        if (filters_mod.isAtOrUnder(item.path, path)) return true;
    }
    return false;
}

/// Are the two folders identical right now: the same regular files at the
/// same relative paths with the same content, hidden and empty files
/// included, nothing extra on either side? Any error counts as "no".
///
/// `min_size` is 0 deliberately. The scan's own size window may have skipped
/// small files, and a folder must never pass for a copy of another because
/// the file that differs was below it.
fn foldersIdentical(gpa: Allocator, a: []const u8, b: []const u8) bool {
    var comparator = compare.FolderComparator.init(gpa, .{
        .min_size = 0,
        .include_hidden = true,
    });
    var result = comparator.compare(a, b) catch return false;
    defer result.deinit();
    return result.isIdentical();
}

/// Remove a directory and everything beneath it. Returns the errno that
/// stopped it, or null on success.
///
/// Recursion is by directory descriptor (`openat` with NOFOLLOW, then
/// `fdopendir`), never by re-resolving a path: the tree is being deleted
/// precisely because it is a duplicate, and re-walking names would let a
/// symlink swapped in mid-delete redirect the removal somewhere else. Entries
/// are removed with `unlinkat`, so a symlink beneath is unlinked rather than
/// followed.
fn removeTree(path: [*:0]const u8) ?std.c.E {
    const fd = libc.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true }, @as(libc.mode_t, 0));
    if (fd < 0) return libc.errno(@as(c_int, -1));
    if (removeChildren(fd)) |errno| {
        _ = libc.close(fd);
        return errno;
    }
    _ = libc.close(fd);
    if (libc.rmdir(path) != 0) return libc.errno(@as(c_int, -1));
    return null;
}

/// Empty the directory `dir_fd` refers to. Takes ownership of nothing: the
/// caller still closes `dir_fd`.
fn removeChildren(dir_fd: c_int) ?std.c.E {
    // fdopendir takes ownership of the fd it is given, so it gets a copy.
    const dup_fd = libc.dup(dir_fd);
    if (dup_fd < 0) return libc.errno(@as(c_int, -1));
    const dir = libc.fdopendir(dup_fd) orelse {
        _ = libc.close(dup_fd);
        return libc.errno(@as(c_int, -1));
    };
    defer _ = libc.closedir(dir);

    while (libc.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const st = pstat.lstatAt(dir_fd, name_ptr) catch return libc.errno(@as(c_int, -1));
        if (st.isDir()) {
            const child = libc.openat(dir_fd, name_ptr, .{
                .ACCMODE = .RDONLY,
                .DIRECTORY = true,
                .NOFOLLOW = true,
            }, @as(libc.mode_t, 0));
            if (child < 0) return libc.errno(@as(c_int, -1));
            if (removeChildren(child)) |errno| {
                _ = libc.close(child);
                return errno;
            }
            _ = libc.close(child);
            if (libc.unlinkat(dir_fd, name_ptr, @intCast(libc.AT.REMOVEDIR)) != 0) {
                return libc.errno(@as(c_int, -1));
            }
        } else if (libc.unlinkat(dir_fd, name_ptr, 0) != 0) {
            return libc.errno(@as(c_int, -1));
        }
    }
    return null;
}

/// True if `path` is still the file the scan hashed.
fn stillACopy(path: []const u8, size: u64, mtime: i64, hash: *const [32]u8, verify: Verify) bool {
    var buf: [4096]u8 = undefined;
    const path_z = pathZ(&buf, path) orelse return false;

    // A regular file of the right size either way: a symlink standing where a
    // file was must never be "verified" through its target.
    const st = pstat.lstat(path_z) catch return false;
    if (!st.isFile() or st.size != size) return false;

    return switch (verify) {
        .metadata => st.mtime_sec == mtime,
        .content => |c| blk: {
            const file_hasher = hasher.FileHasher.init(if (c.sha256) .sha256 else .blake3);
            const digest = file_hasher.hashFile(path) catch break :blk false;
            // zig-lens-ignore: EQL-FOR-SECRETS content digest of the user's own
            // file against the scan's record of it — nothing is authenticated
            // here and there is no attacker to leak a timing signal to.
            break :blk std.mem.eql(u8, &digest, hash);
        },
    };
}

/// The host's message for a single failed Trash move, or a stand-in when it
/// did not leave one.
fn trashReason(arena: Allocator, err_buf: *const [512]u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, err_buf, 0) orelse err_buf.len;
    if (len == 0) return "could not be moved to the Trash";
    return arena.dupe(u8, err_buf[0..len]) catch "could not be moved to the Trash";
}

fn unlinkReason(err: std.c.E) []const u8 {
    return switch (err) {
        .NOENT => "no longer exists",
        .ACCES, .PERM => "permission denied",
        .ISDIR => "is a directory",
        .ROFS => "is on a read-only filesystem",
        .BUSY => "is in use",
        .IO => "an I/O error occurred",
        else => "could not be deleted",
    };
}

/// The store holds seconds; JSON carries epoch milliseconds.
fn millis(seconds: i64) i64 {
    return seconds *| 1000;
}

/// Shrink `common` until it contains the parent directory of `path`.
fn narrowToCommonDir(common: *?[]const u8, path: []const u8) void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    const dir = if (slash == 0) path[0..1] else path[0..slash];
    const current = common.* orelse {
        common.* = dir;
        return;
    };
    var narrowed = current;
    while (!filters_mod.isAtOrUnder(dir, narrowed)) {
        const cut = std.mem.lastIndexOfScalar(u8, narrowed, '/') orelse {
            narrowed = "/";
            break;
        };
        if (cut == 0) {
            narrowed = "/";
            break;
        }
        narrowed = narrowed[0..cut];
    }
    common.* = narrowed;
}

fn parseRoots(gpa: Allocator, json: []const u8) ![][]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky([]const []const u8, arena.allocator(), json, .{});

    const out = try gpa.alloc([]u8, parsed.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |root| gpa.free(root);
        gpa.free(out);
    }
    for (parsed, out) |root, *slot| {
        slot.* = try gpa.dupe(u8, root);
        filled += 1;
    }
    return out;
}

fn writeCsvField(writer: *std.Io.Writer, field: []const u8) !void {
    const needs_quoting = std.mem.indexOfAny(u8, field, ",\"\n") != null;
    if (!needs_quoting) return writer.writeAll(field);
    try writer.writeByte('"');
    for (field) |c| {
        if (c == '"') try writer.writeByte('"');
        try writer.writeByte(c);
    }
    try writer.writeByte('"');
}

/// Stream `s` with HTML metacharacters entity-escaped, so a filename such as
/// `<img onerror=...>` is shown rather than executed.
fn writeEscapedHtml(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(c),
    };
}

/// A buffered `std.Io.Writer` over a raw fd, so an export streams to disk
/// instead of being built in memory first.
const FdSink = struct {
    fd: c_int,
    interface: std.Io.Writer,

    fn init(fd: c_int, buffer: []u8) FdSink {
        return .{
            .fd = fd,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
        };
    }

    fn writeAllTo(fd: c_int, bytes: []const u8) std.Io.Writer.Error!void {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = libc.write(fd, bytes.ptr + written, bytes.len - written);
            if (n < 0) {
                if (libc.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            written += @intCast(n);
        }
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FdSink = @alignCast(@fieldParentPtr("interface", w));
        try writeAllTo(self.fd, w.buffer[0..w.end]);
        w.end = 0;

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            try writeAllTo(self.fd, chunk);
            consumed += chunk.len;
        }
        // The last slice is repeated `splat` times.
        const last = data[data.len - 1];
        for (0..splat) |_| try writeAllTo(self.fd, last);
        return consumed + last.len * splat;
    }
};

// ============================================================================
// Tests
// ============================================================================

// The end-to-end tests — the real engine into a real store, then the session
// over it — are their own module (`session_test.zig`, registered in build.zig).
// Pulling them in from here would also run them inside every module that
// reaches this one.

const testing = std.testing;

test "lossy keeps valid UTF-8 byte for byte, without copying" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ascii = "/home/u/file.txt";
    try testing.expectEqual(ascii.ptr, (try lossy(a, ascii)).ptr);
    const unicode = "/home/u/café/日本語.txt";
    try testing.expectEqualStrings(unicode, try lossy(a, unicode));
}

test "lossy replaces each maximal invalid subpart with one U+FFFD" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A lone high byte: one replacement character.
    try testing.expectEqualStrings("/caf\u{FFFD}.bin", try lossy(a, "/caf\xe9.bin"));
    // Two stray continuation bytes are two subparts, not one.
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}", try lossy(a, "\x80\x81"));
    // A truncated three-byte sequence at the end is one subpart.
    try testing.expectEqualStrings("x\u{FFFD}", try lossy(a, "x\xe2\x82"));
    // A surrogate encoding is not a character; ED A0 80 is three subparts
    // because A0 is out of range for a lead of ED.
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}\u{FFFD}", try lossy(a, "\xed\xa0\x80"));
    // An overlong encoding of '/' must not decode to '/'.
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}", try lossy(a, "\xc0\xaf"));
    // Valid four-byte sequences survive.
    try testing.expectEqualStrings("\u{1F600}", try lossy(a, "\xf0\x9f\x98\x80"));
}

test "the common directory shrinks to hold every path" {
    var common: ?[]const u8 = null;
    narrowToCommonDir(&common, "/home/u/work/a.txt");
    try testing.expectEqualStrings("/home/u/work", common.?);
    narrowToCommonDir(&common, "/home/u/backup/b.txt");
    try testing.expectEqualStrings("/home/u", common.?);
    // A sibling whose name merely starts the same does not widen it wrongly.
    narrowToCommonDir(&common, "/home/user2/c.txt");
    try testing.expectEqualStrings("/home", common.?);
    narrowToCommonDir(&common, "/etc/d.txt");
    try testing.expectEqualStrings("/", common.?);
}

test "CSV fields are quoted only when they have to be" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeCsvField(&writer, "/plain/path.txt");
    try writer.writeByte('|');
    try writeCsvField(&writer, "/has,comma.txt");
    try writer.writeByte('|');
    try writeCsvField(&writer, "/has\"quote.txt");
    try testing.expectEqualStrings(
        \\/plain/path.txt|"/has,comma.txt"|"/has""quote.txt"
    , writer.buffered());
}
