//! Where a project's code lives, and whether a copy of it holds anything
//! that exists nowhere else
//!
//! Everything here is read from `git` itself, run as a child process. A
//! repository is never written to: every call passes `--no-optional-locks`
//! (so `status` does not rewrite the index while another session works in the
//! same checkout) and `core.fsmonitor=false` (a repository's own config can
//! name an fsmonitor program, which `status` would otherwise run). Nothing
//! contacts a remote: "on a remote" means "on a remote-tracking ref", as of
//! the checkout's last fetch.
//!
//! **Main checkouts** are found by origin, not by name: the folders under the
//! main roots (`~/work` by default, searched `main_depth` levels deep) whose
//! `.git` is a directory, read straight from `.git/config`. Origins compare by
//! a key that ignores how they are spelled: `git@github.com:Acme/Widget.git`,
//! `ssh://git@github.com/acme/widget` and `https://github.com/acme/widget`
//! are one key, `github.com/acme/widget`. A local path origin is that folder.
//!
//! **The verdict** says whether removing the copy's folder could lose work:
//!
//!   * `main_has_everything`: nothing uncommitted (untracked files included),
//!     no stash (a linked worktree shares its stashes with its repository),
//!     and every commit its branches hold is on a remote-tracking ref or in
//!     a main checkout's current branch. A linked worktree is judged by its
//!     own HEAD only: its other branches live in the main repository.
//!   * `has_unique_work`, with the reasons. Also every folder git cannot
//!     vouch for: not in a repository, ignored by the repository around it,
//!     or unreadable to git.

const std = @import("std");
const builtin = @import("builtin");
const libc = @import("sys.zig").c;
const pstat = @import("pstat.zig");
const filters = @import("filters.zig");
const space = @import("space.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Levels below each main root searched for main checkouts.
pub const main_depth: usize = 4;
/// Largest output read from one git call.
const output_limit: usize = 64 << 20;

// ===========================================================================
// Running git
// ===========================================================================

pub const Git = struct {
    gpa: Allocator,
    io: Io,
    exe: []const u8,
    /// `git --version`, when git could be started at all.
    version: ?[]const u8 = null,

    pub const Run = struct {
        ok: bool,
        /// Exit status, null when it did not exit normally.
        code: ?u8,
        out: []const u8,
        err: []const u8,
    };

    /// Finds out whether `exe` runs; strings live in `arena`.
    pub fn init(gpa: Allocator, io: Io, arena: Allocator, exe: []const u8) Git {
        var git: Git = .{ .gpa = gpa, .io = io, .exe = exe };
        if (git.runRaw(arena, null, &.{"--version"})) |r| {
            if (r.ok) git.version = std.mem.trim(u8, r.out, " \n");
        }
        return git;
    }

    pub fn available(self: *const Git) bool {
        return self.version != null;
    }

    /// `git -C dir args...` with the read-only guards; null when git could
    /// not be started. Output is trimmed of its final newline.
    pub fn run(self: *const Git, arena: Allocator, dir: []const u8, args: []const []const u8) ?Run {
        return self.runRaw(arena, dir, args);
    }

    fn runRaw(self: *const Git, arena: Allocator, dir: ?[]const u8, args: []const []const u8) ?Run {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        argv.appendSlice(arena, &.{ self.exe, "--no-optional-locks", "-c", "core.fsmonitor=false" }) catch return null;
        if (dir) |d| argv.appendSlice(arena, &.{ "-C", d }) catch return null;
        argv.appendSlice(arena, args) catch return null;
        const result = std.process.run(self.gpa, self.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(output_limit),
            .stderr_limit = .limited(1 << 20),
        }) catch return null;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const code: ?u8 = switch (result.term) {
            .exited => |c| c,
            else => null,
        };
        return .{
            .ok = code == 0,
            .code = code,
            .out = arena.dupe(u8, std.mem.trimEnd(u8, result.stdout, "\n")) catch return null,
            .err = arena.dupe(u8, std.mem.trim(u8, result.stderr, " \n")) catch return null,
        };
    }
};

// ===========================================================================
// Origins
// ===========================================================================

/// The comparable form of an origin URL: `host/path`, lower case, without
/// user, port, scheme or `.git`; `file:<canonical path>` for a local one.
/// `base_dir` resolves a relative local origin. Null when it says nothing.
pub fn originKey(arena: Allocator, url_in: []const u8, base_dir: []const u8) ?[]const u8 {
    const url = std.mem.trim(u8, url_in, " \t\r\n");
    if (url.len == 0) return null;
    if (std.mem.startsWith(u8, url, "file://")) return localKey(arena, url["file://".len..], base_dir);
    if (url[0] == '/' or url[0] == '.' or url[0] == '~') return localKey(arena, url, base_dir);

    var host: []const u8 = undefined;
    var path: []const u8 = undefined;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        const rest = url[scheme_end + 3 ..];
        const auth_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const authority = rest[0..auth_end];
        host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;
        path = rest[auth_end..];
    } else if (scpColon(url)) |colon| {
        // user@host:path
        const authority = url[0..colon];
        host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;
        path = url[colon + 1 ..];
    } else {
        return localKey(arena, url, base_dir);
    }
    // Drop a port, but not the inside of an IPv6 literal.
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |c| {
        if (std.mem.indexOfScalar(u8, host, ']') == null or c > std.mem.indexOfScalar(u8, host, ']').?) host = host[0..c];
    }
    path = std.mem.trim(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    path = std.mem.trimEnd(u8, path, "/");
    if (host.len == 0 or path.len == 0) return null;
    const key = std.fmt.allocPrint(arena, "{s}/{s}", .{ host, path }) catch return null;
    for (key) |*c| c.* = std.ascii.toLower(c.*);
    return key;
}

/// Index of the colon in an scp-like `[user@]host:path`, where the colon
/// comes before any slash.
fn scpColon(url: []const u8) ?usize {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    if (colon == 0) return null;
    if (std.mem.indexOfScalar(u8, url, '/')) |slash| {
        if (slash < colon) return null;
    }
    return colon;
}

fn localKey(arena: Allocator, path: []const u8, base_dir: []const u8) ?[]const u8 {
    const canonical = localCheckout(arena, path, base_dir) orelse return null;
    return std.fmt.allocPrint(arena, "file:{s}", .{canonical}) catch null;
}

/// The canonical folder a local origin names, without a trailing `/.git`.
pub fn localCheckout(arena: Allocator, path_in: []const u8, base_dir: []const u8) ?[]const u8 {
    var path = path_in;
    if (std.mem.startsWith(u8, path, "file://")) path = path["file://".len..];
    const joined = if (path.len > 0 and path[0] == '/')
        path
    else if (path.len > 0 and path[0] == '~') blk: {
        const home = homeDir() orelse return null;
        break :blk std.fmt.allocPrint(arena, "{s}{s}", .{ home, path[1..] }) catch return null;
    } else std.fmt.allocPrint(arena, "{s}/{s}", .{ base_dir, path }) catch return null;
    var canonical = realPath(arena, joined) orelse joined;
    canonical = filters.trimSep(canonical);
    if (std.mem.endsWith(u8, canonical, "/.git")) canonical = canonical[0 .. canonical.len - 5];
    return canonical;
}

fn homeDir() ?[]const u8 {
    return @import("session.zig").userHome();
}

pub fn realPath(arena: Allocator, path: []const u8) ?[]const u8 {
    const z = arena.dupeSentinel(u8, path, 0) catch return null;
    var buf: [libc.PATH_MAX]u8 = undefined;
    const resolved = libc.realpath(z.ptr, &buf) orelse return null;
    return arena.dupe(u8, std.mem.span(resolved)) catch null;
}

/// `url` safe to print: an http(s) URL loses its user part entirely (a
/// token is often the user name), any other keeps the user but loses a
/// password.
pub fn redactUrl(arena: Allocator, url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const rest = url[scheme_end + 3 ..];
    const auth_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const at = std.mem.lastIndexOfScalar(u8, rest[0..auth_end], '@') orelse return url;
    const scheme = url[0..scheme_end];
    const userinfo = rest[0..at];
    const after = rest[at + 1 ..];
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
        return std.fmt.allocPrint(arena, "{s}://{s}", .{ scheme, after }) catch url;
    }
    const colon = std.mem.indexOfScalar(u8, userinfo, ':') orelse return url;
    return std.fmt.allocPrint(arena, "{s}://{s}:***@{s}", .{ scheme, userinfo[0..colon], after }) catch url;
}

/// The `url` of `[remote "origin"]` in a git config file's text.
pub fn originFromConfig(text: []const u8) ?[]const u8 {
    var in_origin = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            var header = std.mem.trim(u8, line[1..close], " \t");
            in_origin = false;
            if (!std.ascii.startsWithIgnoreCase(header, "remote")) continue;
            header = std.mem.trim(u8, header["remote".len..], " \t");
            in_origin = std.mem.eql(u8, header, "\"origin\"");
            continue;
        }
        if (!in_origin) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "url")) continue;
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        return value;
    }
    return null;
}

// ===========================================================================
// Main checkouts
// ===========================================================================

pub const MainIndex = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct { path: []const u8, key: []const u8 };

    /// Every folder whose `.git` is a directory, up to `main_depth` levels
    /// below each of `roots`, with its origin key. Hidden folders and build
    /// output are not searched.
    pub fn build(arena: Allocator, roots: []const []const u8) MainIndex {
        var found: std.ArrayListUnmanaged(Entry) = .empty;
        for (roots) |root| {
            const canonical = realPath(arena, root) orelse continue;
            visit(arena, &found, canonical, 0);
        }
        return .{ .entries = found.items };
    }

    fn visit(arena: Allocator, found: *std.ArrayListUnmanaged(Entry), dir: []const u8, depth: usize) void {
        if (repoKey(arena, dir)) |key| found.append(arena, .{ .path = dir, .key = key }) catch return;
        if (depth >= main_depth) return;
        const dir_z = arena.dupeSentinel(u8, dir, 0) catch return;
        const handle = libc.opendir(dir_z.ptr) orelse return;
        defer _ = libc.closedir(handle);
        while (libc.readdir(handle)) |entry| {
            const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
            const name = std.mem.span(name_ptr);
            if (name.len == 0 or name[0] == '.') continue;
            if (space.isBuildDirName(name)) continue;
            const child = if (filters.isRoot(dir))
                std.fmt.allocPrint(arena, "{s}{s}", .{ dir, name }) catch return
            else
                std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }) catch return;
            const child_z = arena.dupeSentinel(u8, child, 0) catch return;
            const st = pstat.lstat(child_z.ptr) catch continue;
            if (!st.isDir()) continue;
            visit(arena, found, child, depth + 1);
        }
    }

    /// The origin key of the checkout at `dir`, when its `.git` is a folder.
    fn repoKey(arena: Allocator, dir: []const u8) ?[]const u8 {
        const git_dir = std.fmt.allocPrintSentinel(arena, "{s}/.git", .{dir}, 0) catch return null;
        const st = pstat.lstat(git_dir.ptr) catch return null;
        if (!st.isDir()) return null;
        const config = std.fmt.allocPrintSentinel(arena, "{s}/.git/config", .{dir}, 0) catch return null;
        const text = readSmall(arena, config) orelse return "";
        const url = originFromConfig(text) orelse return "";
        return originKey(arena, url, dir) orelse "";
    }

    /// Checkouts with origin `key`, other than `self_path`.
    pub fn matching(self: *const MainIndex, arena: Allocator, key: []const u8, self_path: []const u8) []const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        if (key.len == 0) return out.items;
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key) and !std.mem.eql(u8, e.path, self_path)) out.append(arena, e.path) catch break;
        }
        return out.items;
    }

    pub fn contains(self: *const MainIndex, path: []const u8) bool {
        for (self.entries) |e| if (std.mem.eql(u8, e.path, path)) return true;
        return false;
    }
};

fn readSmall(arena: Allocator, path: [:0]const u8) ?[]const u8 {
    const fd = libc.open(path.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, @as(libc.mode_t, 0));
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [16384]u8 = undefined;
    while (out.items.len < 1 << 20) {
        const n = libc.read(fd, &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(arena, buf[0..@intCast(n)]) catch return null;
    }
    return out.items;
}

// ===========================================================================
// Facts and verdicts
// ===========================================================================

pub const Verdict = enum { main_has_everything, has_unique_work };

/// A branch (or a detached HEAD) holding commits found on no remote and in
/// no main checkout.
pub const Tip = struct { name: []const u8, commits: u64 };

pub const Checkout = struct {
    toplevel: []const u8,
    /// Printable (credentials removed).
    origin: ?[]const u8 = null,
    origin_key: ?[]const u8 = null,
    /// Null when HEAD is detached.
    branch: ?[]const u8 = null,
    /// Null in a repository with no commits.
    head: ?[]const u8 = null,
    /// Its `.git` is a file: a worktree of the repository at `main_repository`.
    linked_worktree: bool = false,
    main_repository: ?[]const u8 = null,
    /// Checkouts of the same origin under the main roots (itself excluded),
    /// and for a linked worktree its main repository.
    main_checkouts: []const []const u8 = &.{},
    /// It is one of the checkouts under the main roots.
    is_main_checkout: bool = false,
    remotes: u64 = 0,
    /// Modified, staged and untracked entries (`git status --porcelain`).
    uncommitted: u64 = 0,
    /// Commits on its branches (a linked worktree: on its HEAD) that no
    /// remote-tracking ref holds.
    unpushed_commits: u64 = 0,
    /// Null for a linked worktree, whose stashes are its repository's.
    stashes: ?u64 = null,
    head_on_remote: bool = false,
    /// Null when there is no main checkout to look in.
    head_in_main: ?bool = null,
    unique_tips: []const Tip = &.{},
};

pub const Facts = struct {
    checkout: ?Checkout = null,
    /// Not in a checkout because the repository around it ignores it.
    ignored_by: ?[]const u8 = null,
    /// What git said when it could not answer.
    err: ?[]const u8 = null,
    verdict: Verdict = .has_unique_work,
    reasons: []const []const u8 = &.{},
};

/// Reads the checkout around `project` and judges it. `cache` maps a
/// toplevel to its checkout, so a repository holding several projects is
/// read once.
pub fn inspect(
    git: *const Git,
    arena: Allocator,
    project: []const u8,
    index: *const MainIndex,
    cache: *std.StringHashMapUnmanaged(Checkout),
) Facts {
    var facts: Facts = .{};
    const top = git.run(arena, project, &.{ "rev-parse", "--show-toplevel" }) orelse {
        facts.err = "git could not be started";
        return judged(arena, facts);
    };
    if (!top.ok) {
        if (std.mem.indexOf(u8, top.err, "not a git repository") == null) {
            facts.err = firstLine(top.err);
        } else if (brokenLink(arena, project)) |why| {
            facts.err = why;
        }
        return judged(arena, facts);
    }
    const toplevel = realPath(arena, top.out) orelse top.out;
    if (!std.mem.eql(u8, toplevel, project)) {
        if (filters.isAtOrUnder(project, toplevel) and project.len > toplevel.len + 1) {
            const rel = project[filters.trimSep(toplevel).len + 1 ..];
            if (git.run(arena, toplevel, &.{ "check-ignore", "-q", "--", rel })) |ig| {
                if (ig.ok) {
                    facts.ignored_by = toplevel;
                    return judged(arena, facts);
                }
            }
        }
    }
    if (cache.get(toplevel)) |c| {
        facts.checkout = c;
        return judged(arena, facts);
    }
    const c = readCheckout(git, arena, toplevel, index) catch |err| {
        facts.err = @errorName(err);
        return judged(arena, facts);
    };
    cache.put(arena, toplevel, c) catch {};
    facts.checkout = c;
    return judged(arena, facts);
}

/// A `.git` file whose `gitdir:` names a folder that is gone: a worktree
/// whose repository moved or was deleted.
fn brokenLink(arena: Allocator, project: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrintSentinel(arena, "{s}/.git", .{project}, 0) catch return null;
    const st = pstat.lstat(path.ptr) catch return null;
    if (!st.isFile()) return null;
    const text = readSmall(arena, path) orelse return null;
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const target = std.mem.trim(u8, text[prefix.len..], " \t\r\n");
    const z = arena.dupeSentinel(u8, target, 0) catch return null;
    if (pstat.lstat(z.ptr)) |_| return null else |_| {}
    return std.fmt.allocPrint(arena, "its .git file points at {s}, which no longer exists (the repository moved or was deleted)", .{target}) catch null;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

fn readCheckout(git: *const Git, arena: Allocator, top: []const u8, index: *const MainIndex) !Checkout {
    var c: Checkout = .{ .toplevel = top };

    const dirs = try need(git.run(arena, top, &.{ "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir" }));
    var dir_lines = std.mem.splitScalar(u8, dirs, '\n');
    const git_dir = dir_lines.next() orelse return error.GitDirUnknown;
    const common_dir = dir_lines.next() orelse return error.GitDirUnknown;
    if (!std.mem.eql(u8, filters.trimSep(git_dir), filters.trimSep(common_dir))) {
        c.linked_worktree = true;
        const common = realPath(arena, common_dir) orelse common_dir;
        c.main_repository = if (std.mem.eql(u8, filters.baseName(common), ".git")) filters.parentDir(common) else common;
    }

    if (git.run(arena, top, &.{ "config", "--get", "remote.origin.url" })) |r| {
        if (r.ok and r.out.len > 0) {
            c.origin = redactUrl(arena, r.out);
            c.origin_key = originKey(arena, r.out, top);
        }
    }
    if (git.run(arena, top, &.{"remote"})) |r| {
        if (r.ok) c.remotes = countLines(r.out);
    }
    if (git.run(arena, top, &.{ "symbolic-ref", "-q", "--short", "HEAD" })) |r| {
        if (r.ok and r.out.len > 0) c.branch = r.out;
    }
    if (git.run(arena, top, &.{ "rev-parse", "-q", "--verify", "HEAD^{commit}" })) |r| {
        if (r.ok and r.out.len > 0) c.head = r.out;
    }
    const status = try need(git.run(arena, top, &.{ "status", "--porcelain=v1", "-z", "--untracked-files=normal" }));
    c.uncommitted = countPorcelain(status);
    if (!c.linked_worktree) {
        c.stashes = 0;
        if (git.run(arena, top, &.{ "rev-list", "--walk-reflogs", "--count", "refs/stash" })) |r| {
            if (r.ok) c.stashes = std.fmt.parseInt(u64, r.out, 10) catch 0;
        }
    }

    // Where else the code lives.
    var mains: std.ArrayListUnmanaged([]const u8) = .empty;
    if (c.origin_key) |key| {
        try mains.appendSlice(arena, index.matching(arena, key, top));
        if (std.mem.startsWith(u8, key, "file:")) {
            const local = key["file:".len..];
            if (!std.mem.eql(u8, local, top) and isCheckout(arena, local) and !containsPath(mains.items, local))
                try mains.append(arena, local);
        }
    }
    if (c.main_repository) |m| {
        if (!containsPath(mains.items, m) and !std.mem.eql(u8, m, top)) try mains.append(arena, m);
    }
    c.main_checkouts = mains.items;
    c.is_main_checkout = index.contains(top);

    // What this copy holds that might be nowhere else.
    var tips: std.ArrayListUnmanaged(Tip) = .empty;
    var tip_shas: std.ArrayListUnmanaged([]const u8) = .empty;
    if (c.linked_worktree) {
        if (c.head) |h| {
            try tips.append(arena, .{ .name = c.branch orelse "HEAD", .commits = 0 });
            try tip_shas.append(arena, h);
        }
    } else {
        if (git.run(arena, top, &.{ "for-each-ref", "--format=%(refname:short)%09%(objectname)", "refs/heads" })) |r| {
            if (r.ok) {
                var lines = std.mem.splitScalar(u8, r.out, '\n');
                while (lines.next()) |line| {
                    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
                    try tips.append(arena, .{ .name = line[0..tab], .commits = 0 });
                    try tip_shas.append(arena, line[tab + 1 ..]);
                }
            }
        }
        if (c.branch == null) {
            if (c.head) |h| {
                try tips.append(arena, .{ .name = "HEAD", .commits = 0 });
                try tip_shas.append(arena, h);
            }
        }
    }
    if (tip_shas.items.len > 0) {
        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        try args.appendSlice(arena, &.{ "rev-list", "--count" });
        try args.appendSlice(arena, tip_shas.items);
        try args.appendSlice(arena, &.{ "--not", "--remotes" });
        const count = try need(git.run(arena, top, args.items));
        c.unpushed_commits = std.fmt.parseInt(u64, count, 10) catch 0;
    }
    var unique: std.ArrayListUnmanaged(Tip) = .empty;
    if (c.unpushed_commits > 0) {
        for (tips.items, tip_shas.items) |tip, sha| {
            const r = try need(git.run(arena, top, &.{ "rev-list", "--count", sha, "--not", "--remotes" }));
            const n = std.fmt.parseInt(u64, r, 10) catch 0;
            if (n == 0) continue;
            if (inAnyMain(git, arena, c.main_checkouts, sha)) continue;
            try unique.append(arena, .{ .name = tip.name, .commits = n });
        }
    }
    c.unique_tips = unique.items;

    if (c.head) |h| {
        if (git.run(arena, top, &.{ "for-each-ref", "--count=1", "--contains", h, "--format=%(refname)", "refs/remotes" })) |r| {
            c.head_on_remote = r.ok and r.out.len > 0;
        }
        if (c.main_checkouts.len > 0) c.head_in_main = inAnyMain(git, arena, c.main_checkouts, h);
    }
    return c;
}

fn need(r: ?Git.Run) ![]const u8 {
    const run = r orelse return error.GitFailed;
    if (!run.ok) return error.GitFailed;
    return run.out;
}

/// Some main checkout's current branch already holds commit `sha`.
fn inAnyMain(git: *const Git, arena: Allocator, mains: []const []const u8, sha: []const u8) bool {
    for (mains) |m| {
        if (git.run(arena, m, &.{ "merge-base", "--is-ancestor", sha, "HEAD" })) |r| {
            if (r.ok) return true;
        }
    }
    return false;
}

fn isCheckout(arena: Allocator, dir: []const u8) bool {
    const z = std.fmt.allocPrintSentinel(arena, "{s}/.git", .{dir}, 0) catch return false;
    _ = pstat.lstat(z.ptr) catch return false;
    return true;
}

fn containsPath(list: []const []const u8, path: []const u8) bool {
    for (list) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

fn countLines(text: []const u8) u64 {
    if (text.len == 0) return 0;
    return std.mem.count(u8, text, "\n") + 1;
}

/// Entries in `git status --porcelain=v1 -z`: a rename or copy carries its
/// original path as one more field, which is not another entry.
pub fn countPorcelain(out: []const u8) u64 {
    var n: u64 = 0;
    var fields = std.mem.splitScalar(u8, out, 0);
    while (fields.next()) |field| {
        if (field.len < 3) continue;
        n += 1;
        if (field[0] == 'R' or field[0] == 'C' or field[1] == 'R' or field[1] == 'C') _ = fields.next();
    }
    return n;
}

fn judged(arena: Allocator, facts_in: Facts) Facts {
    var facts = facts_in;
    var reasons: std.ArrayListUnmanaged([]const u8) = .empty;
    const add = struct {
        fn f(a: Allocator, list: *std.ArrayListUnmanaged([]const u8), comptime fmt: []const u8, args: anytype) void {
            const text = std.fmt.allocPrint(a, fmt, args) catch return;
            list.append(a, text) catch {};
        }
    }.f;
    if (facts.err) |e| {
        add(arena, &reasons, "git could not read it: {s}", .{e});
    } else if (facts.ignored_by) |by| {
        add(arena, &reasons, "not in a git repository (the repository at {s} ignores it)", .{by});
    } else if (facts.checkout) |c| {
        if (c.uncommitted > 0) add(arena, &reasons, "{d} uncommitted change{s} (modified, staged or untracked)", .{ c.uncommitted, plural(c.uncommitted) });
        if (c.stashes) |s| if (s > 0) add(arena, &reasons, "{d} stash{s}", .{ s, if (s == 1) "" else "es" });
        var head_reported = false;
        for (c.unique_tips) |tip| {
            const holds_head = if (c.branch) |b| std.mem.eql(u8, b, tip.name) else std.mem.eql(u8, tip.name, "HEAD");
            if (holds_head) head_reported = true;
            if (std.mem.eql(u8, tip.name, "HEAD") and c.branch == null) {
                add(arena, &reasons, "detached HEAD: {d} commit{s} on no remote and in no main checkout", .{ tip.commits, plural(tip.commits) });
            } else {
                add(arena, &reasons, "branch {s}: {d} commit{s} on no remote and in no main checkout", .{ tip.name, tip.commits, plural(tip.commits) });
            }
        }
        if (c.head) |h| {
            if (!head_reported and !c.head_on_remote and c.head_in_main != true) {
                add(arena, &reasons, "HEAD {s} is on no remote and in no main checkout", .{h[0..@min(h.len, 12)]});
            }
        }
    } else {
        add(arena, &reasons, "not in a git repository", .{});
    }
    facts.reasons = reasons.items;
    facts.verdict = if (reasons.items.len == 0) .main_has_everything else .has_unique_work;
    return facts;
}

fn plural(n: u64) []const u8 {
    return if (n == 1) "" else "s";
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Scratch = @import("testing_scratch.zig").Scratch;

test "origin keys ignore how a URL is spelled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const want = "github.com/acme/widget";
    for ([_][]const u8{
        "git@github.com:Acme/Widget.git",
        "ssh://git@github.com/acme/widget",
        "ssh://git@github.com:22/acme/widget.git/",
        "https://github.com/acme/widget.git",
        "https://x-access-token:SECRET@github.com/Acme/widget",
        "git://github.com/acme/widget",
        "  github.com:acme/widget.git\n",
    }) |url| {
        try testing.expectEqualStrings(want, originKey(a, url, "/").?);
    }
    try testing.expect(!std.mem.eql(u8, want, originKey(a, "git@github.com:acme/widget-2.git", "/").?));
    try testing.expect(!std.mem.eql(u8, want, originKey(a, "git@gitlab.com:acme/widget.git", "/").?));
    try testing.expect(originKey(a, "", "/") == null);
    // A local origin is a folder, by its canonical path.
    const local = originKey(a, "/nonexistent/zdedupe/repo/.git", "/").?;
    try testing.expectEqualStrings("file:/nonexistent/zdedupe/repo", local);
}

test "printed origins never carry credentials" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("https://github.com/acme/w.git", redactUrl(a, "https://ghp_TOKEN@github.com/acme/w.git"));
    try testing.expectEqualStrings("https://github.com/acme/w", redactUrl(a, "https://user:pass@github.com/acme/w"));
    try testing.expectEqualStrings("ssh://git:***@host/acme/w", redactUrl(a, "ssh://git:pw@host/acme/w"));
    try testing.expectEqualStrings("git@github.com:acme/w.git", redactUrl(a, "git@github.com:acme/w.git"));
    try testing.expectEqualStrings("ssh://git@host/acme/w", redactUrl(a, "ssh://git@host/acme/w"));
}

test "origin url from a git config file" {
    const text = "[core]\n\tbare = false\n[remote \"upstream\"]\n\turl = git@github.com:other/repo.git\n" ++
        "[remote \"origin\"]\n\turl = \"https://github.com/acme/widget.git\"\n" ++
        "\tfetch = +refs/heads/*:refs/remotes/origin/*\n";
    try testing.expectEqualStrings("https://github.com/acme/widget.git", originFromConfig(text).?);
    try testing.expect(originFromConfig("[core]\n\tbare = false\n") == null);
}

test "porcelain entries count renames once" {
    try testing.expectEqual(@as(u64, 0), countPorcelain(""));
    try testing.expectEqual(@as(u64, 3), countPorcelain(" M a.txt\x00?? new/\x00R  b.txt\x00old b.txt\x00"));
}

/// git with an identity and no hooks, signing or system state, for fixtures.
fn sh(arena: Allocator, dir: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        "git",
        "-c",
        "user.name=zdedupe test",
        "-c",
        "user.email=test@example.com",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "init.defaultBranch=main",
        "-c",
        "protocol.file.allow=always",
        "-C",
        dir,
    });
    try argv.appendSlice(arena, args);
    const r = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items });
    defer testing.allocator.free(r.stdout);
    defer testing.allocator.free(r.stderr);
    if (!r.term.success()) {
        std.debug.print("git {s} failed: {s}\n", .{ args[0], r.stderr });
        return error.GitFixtureFailed;
    }
}

fn verdictOf(git: *const Git, arena: Allocator, dir: []const u8, index: *const MainIndex) Facts {
    var cache: std.StringHashMapUnmanaged(Checkout) = .empty;
    return inspect(git, arena, realPath(arena, dir).?, index, &cache);
}

test "verdicts: clean copies, local changes, unpushed commits, worktrees, non-repositories" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const git = Git.init(testing.allocator, testing.io, a, "git");
    if (!git.available()) return error.SkipZigTest;

    var scratch = try Scratch.init(testing.allocator, "gitinfo");
    defer scratch.deinit();
    const root = realPath(a, scratch.path).?;
    const p = struct {
        fn f(al: Allocator, base: []const u8, rel: []const u8) []const u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ base, rel }) catch unreachable;
        }
    }.f;

    // A bare "remote", a main checkout under work/ and a scratch clone.
    try scratch.makeDir("work");
    try scratch.makeDir("scratch");
    try sh(a, root, &.{ "init", "-q", "--bare", "remote.git" });
    try sh(a, root, &.{ "init", "-q", p(a, root, "work/widget") });
    try scratch.writeFile("work/widget/README", "hello\n");
    try sh(a, p(a, root, "work/widget"), &.{ "add", "README" });
    try sh(a, p(a, root, "work/widget"), &.{ "commit", "-q", "-m", "first" });
    try sh(a, p(a, root, "work/widget"), &.{ "remote", "add", "origin", p(a, root, "remote.git") });
    try sh(a, p(a, root, "work/widget"), &.{ "push", "-q", "origin", "main" });
    try sh(a, p(a, root, "work/widget"), &.{ "fetch", "-q", "origin" });
    try sh(a, root, &.{ "clone", "-q", p(a, root, "remote.git"), p(a, root, "scratch/copy") });
    // Both say the same origin, spelled two ways.
    try sh(a, p(a, root, "work/widget"), &.{ "remote", "set-url", "origin", "git@github.com:Acme/Widget.git" });
    try sh(a, p(a, root, "scratch/copy"), &.{ "remote", "set-url", "origin", "https://github.com/acme/widget" });

    const index = MainIndex.build(a, &.{p(a, root, "work")});
    try testing.expectEqual(@as(usize, 1), index.entries.len);

    const copy = p(a, root, "scratch/copy");
    {
        const f = verdictOf(&git, a, copy, &index);
        try testing.expectEqual(Verdict.main_has_everything, f.verdict);
        const c = f.checkout.?;
        try testing.expectEqualStrings("github.com/acme/widget", c.origin_key.?);
        try testing.expectEqual(@as(usize, 1), c.main_checkouts.len);
        try testing.expectEqualStrings(p(a, root, "work/widget"), c.main_checkouts[0]);
        try testing.expect(!c.linked_worktree);
        try testing.expect(c.head_on_remote);
        try testing.expectEqualStrings("main", c.branch.?);
    }

    // An untracked file is work nothing else holds.
    try scratch.writeFile("scratch/copy/notes.txt", "draft\n");
    {
        const f = verdictOf(&git, a, copy, &index);
        try testing.expectEqual(Verdict.has_unique_work, f.verdict);
        try testing.expectEqual(@as(u64, 1), f.checkout.?.uncommitted);
    }

    // Committed but not pushed: still unique...
    try sh(a, copy, &.{ "add", "notes.txt" });
    try sh(a, copy, &.{ "commit", "-q", "-m", "notes" });
    {
        const f = verdictOf(&git, a, copy, &index);
        try testing.expectEqual(Verdict.has_unique_work, f.verdict);
        const c = f.checkout.?;
        try testing.expectEqual(@as(u64, 0), c.uncommitted);
        try testing.expectEqual(@as(u64, 1), c.unpushed_commits);
        try testing.expectEqual(@as(usize, 1), c.unique_tips.len);
        try testing.expectEqualStrings("main", c.unique_tips[0].name);
        try testing.expect(!c.head_on_remote);
    }
    // ...until the main checkout's branch holds it.
    try sh(a, p(a, root, "work/widget"), &.{ "pull", "-q", "--ff-only", copy, "main" });
    {
        const f = verdictOf(&git, a, copy, &index);
        try testing.expectEqual(Verdict.main_has_everything, f.verdict);
        try testing.expectEqual(@as(u64, 1), f.checkout.?.unpushed_commits);
        try testing.expect(f.checkout.?.head_in_main.?);
    }

    // A stash is unique work in a standalone copy.
    try scratch.writeFile("scratch/copy/README", "changed\n");
    try sh(a, copy, &.{ "stash", "-q" });
    {
        const f = verdictOf(&git, a, copy, &index);
        try testing.expectEqual(Verdict.has_unique_work, f.verdict);
        try testing.expectEqual(@as(u64, 1), f.checkout.?.stashes.?);
    }

    // A linked worktree belongs to its main repository and is judged by its HEAD.
    const wt = p(a, root, "scratch/wt");
    try sh(a, p(a, root, "work/widget"), &.{ "worktree", "add", "-q", "-b", "feature", wt });
    {
        const f = verdictOf(&git, a, wt, &index);
        const c = f.checkout.?;
        try testing.expect(c.linked_worktree);
        try testing.expectEqualStrings(p(a, root, "work/widget"), c.main_repository.?);
        try testing.expect(c.stashes == null);
        try testing.expectEqual(Verdict.main_has_everything, f.verdict);
    }
    try scratch.writeFile("scratch/wt/feature.txt", "x\n");
    try sh(a, wt, &.{ "add", "feature.txt" });
    try sh(a, wt, &.{ "commit", "-q", "-m", "feature" });
    {
        const f = verdictOf(&git, a, wt, &index);
        try testing.expectEqual(Verdict.has_unique_work, f.verdict);
        try testing.expectEqualStrings("feature", f.checkout.?.unique_tips[0].name);
    }
    try sh(a, p(a, root, "work/widget"), &.{ "merge", "-q", "--ff-only", "feature" });
    try testing.expectEqual(Verdict.main_has_everything, verdictOf(&git, a, wt, &index).verdict);

    // A worktree whose repository is gone says so.
    try scratch.makeDir("scratch/orphan");
    try scratch.writeFile("scratch/orphan/.git", "gitdir: /nonexistent/zdedupe/repo/.git/worktrees/orphan\n");
    {
        const f = verdictOf(&git, a, p(a, root, "scratch/orphan"), &index);
        try testing.expectEqual(Verdict.has_unique_work, f.verdict);
        try testing.expect(std.mem.indexOf(u8, f.err.?, "no longer exists") != null);
    }

    // Not a repository, and a folder its enclosing repository ignores.
    try scratch.makeDir("scratch/loose");
    try scratch.writeFile("scratch/loose/package.json", "{}");
    {
        const f = verdictOf(&git, a, p(a, root, "scratch/loose"), &index);
        try testing.expect(f.checkout == null);
        try testing.expectEqual(Verdict.has_unique_work, f.verdict);
    }
    try scratch.writeFile("work/widget/.gitignore", "tmp/\n");
    try scratch.makeDir("work/widget/tmp");
    try scratch.makeDir("work/widget/tmp/exp");
    try scratch.writeFile("work/widget/tmp/exp/package.json", "{}");
    {
        const f = verdictOf(&git, a, p(a, root, "work/widget/tmp/exp"), &index);
        try testing.expect(f.checkout == null);
        try testing.expectEqualStrings(p(a, root, "work/widget"), f.ignored_by.?);
        try testing.expectEqual(Verdict.has_unique_work, f.verdict);
    }
}

test "a missing git is reported, not guessed around" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const git = Git.init(testing.allocator, testing.io, arena_state.allocator(), "/nonexistent/zdedupe/git");
    try testing.expect(!git.available());
}
