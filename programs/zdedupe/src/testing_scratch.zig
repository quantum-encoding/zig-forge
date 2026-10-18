//! Scratch-directory helper for tests that need real files on disk.
//!
//! Deliberately NOT `std.testing.tmpDir`: that roots its fixtures at
//! `.zig-cache/tmp` inside the source tree, and zdedupe's tests create hostile
//! filenames (embedded quotes, backslashes, `<script>`), symlink cycles and
//! hard links — none of which belong anywhere under the repo. Everything here
//! lands outside the repo, where nothing the core protects lies (see
//! `Scratch.init`), and is removed on `deinit`.
//!
//! Built on libc rather than `std.Io.Dir` to match the rest of zdedupe (which
//! is libc-based end to end) and to keep the fixtures usable from tests that
//! feed raw NUL-terminated paths straight into the walkers.

const std = @import("std");
const libc = @import("sys.zig").c;
const builtin = @import("builtin");
const pstat = @import("pstat.zig");

pub const Scratch = struct {
    allocator: std.mem.Allocator,
    /// Absolute real path to the scratch root (NUL-terminated for libc calls).
    path: [:0]const u8,

    /// Create a uniquely-named scratch directory. `label` is only for humans
    /// reading a leftover directory after a crash.
    ///
    /// The core resolves scan roots to their real paths and protects the
    /// operating system's trees by them, so fixtures live where nothing
    /// protects them: `ZDEDUPE_TEST_TMP` when set; on Windows C:/zdedupe-tests
    /// (%TEMP% is inside the protected AppData); on macOS
    /// ~/.cache/zdedupe-tests ($TMPDIR is really /private/var/folders, inside
    /// the protected /private); elsewhere $TMPDIR or /tmp.
    pub fn init(allocator: std.mem.Allocator, label: []const u8) !Scratch {
        var base_buf: [1024]u8 = undefined;
        return initAt(allocator, label, try fixtureBase(&base_buf));
    }

    /// In the operating system's own temporary folder ($TMPDIR or /tmp), by
    /// its real path: for tests of what the core does in temp areas.
    pub fn initTemp(allocator: std.mem.Allocator, label: []const u8) !Scratch {
        const base: []const u8 = if (libc.getenv("TMPDIR")) |tmpdir| std.mem.span(tmpdir) else "/tmp";
        return initAt(allocator, label, base);
    }

    fn initAt(allocator: std.mem.Allocator, label: []const u8, base: []const u8) !Scratch {
        const trimmed = std.mem.trimEnd(u8, base, "/");

        var rand_bytes: [8]u8 = undefined;
        libc.arc4random_buf(&rand_bytes, rand_bytes.len);
        const rand_hex = std.fmt.bytesToHex(rand_bytes, .lower);

        const spelled = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/zdedupe-test-{s}-{s}",
            .{ trimmed, label, rand_hex },
            0,
        );
        defer allocator.free(spelled);

        if (libc.mkdir(spelled.ptr, 0o700) != 0) return error.MakeDirFailed;

        // The real path: what the core reports, whatever the base's spelling.
        var real_buf: [libc.PATH_MAX]u8 = undefined;
        const real = libc.realpath(spelled.ptr, &real_buf) orelse {
            _ = libc.rmdir(spelled.ptr);
            return error.MakeDirFailed;
        };
        const path = try allocator.dupeSentinel(u8, std.mem.span(real), 0);
        return .{ .allocator = allocator, .path = path };
    }
    pub fn deinit(self: *Scratch) void {
        deleteTree(self.allocator, self.path) catch {};
        self.allocator.free(self.path);
    }

    /// Absolute path of `sub_path` inside the scratch dir. Caller frees.
    pub fn join(self: *const Scratch, sub_path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.path, sub_path });
    }

    /// Absolute, NUL-terminated path of `sub_path`. Caller frees.
    pub fn joinZ(self: *const Scratch, sub_path: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ self.path, sub_path }, 0);
    }

    pub fn makeDir(self: *const Scratch, sub_path: []const u8) !void {
        const full = try self.joinZ(sub_path);
        defer self.allocator.free(full);
        if (libc.mkdir(full.ptr, 0o700) != 0) return error.MakeDirFailed;
    }

    pub fn writeFile(self: *const Scratch, sub_path: []const u8, data: []const u8) !void {
        const full = try self.joinZ(sub_path);
        defer self.allocator.free(full);

        const fd = libc.open(full.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(libc.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        defer _ = libc.close(fd);

        var written: usize = 0;
        while (written < data.len) {
            const n = libc.write(fd, data.ptr + written, data.len - written);
            if (n <= 0) return error.WriteFailed;
            written += @intCast(n);
        }
    }

    pub const Extent = struct { offset: u64, data: []const u8 };

    /// A file of `size` bytes holding `extents` and nothing else: written
    /// with ftruncate + pwrite, so on APFS and ext4 the rest is holes.
    pub fn writeSparse(self: *const Scratch, sub_path: []const u8, size: u64, extents: []const Extent) !void {
        const full = try self.joinZ(sub_path);
        defer self.allocator.free(full);
        const fd = libc.open(full.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(libc.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        defer _ = libc.close(fd);
        if (libc.ftruncate(fd, @intCast(size)) != 0) return error.WriteFailed;
        for (extents) |e| {
            var written: usize = 0;
            while (written < e.data.len) {
                const n = libc.pwrite(fd, e.data.ptr + written, e.data.len - written, @intCast(e.offset + written));
                if (n <= 0) return error.WriteFailed;
                written += @intCast(n);
            }
        }
    }

    /// `target` is interpreted relative to the link's own directory, as with
    /// `ln -s target link`.
    pub fn symLink(self: *const Scratch, target: []const u8, link_sub_path: []const u8) !void {
        const target_z = try self.allocator.dupeSentinel(u8, target, 0);
        defer self.allocator.free(target_z);
        const link = try self.joinZ(link_sub_path);
        defer self.allocator.free(link);
        if (libc.symlink(target_z.ptr, link.ptr) != 0) return error.SymlinkFailed;
    }

    pub fn hardLink(self: *const Scratch, existing_sub_path: []const u8, new_sub_path: []const u8) !void {
        const existing = try self.joinZ(existing_sub_path);
        defer self.allocator.free(existing);
        const new = try self.joinZ(new_sub_path);
        defer self.allocator.free(new);
        if (libc.link(existing.ptr, new.ptr) != 0) return error.LinkFailed;
    }

    /// True if `sub_path` still exists (used to assert cleanup).
    pub fn exists(self: *const Scratch, sub_path: []const u8) !bool {
        const full = try self.joinZ(sub_path);
        defer self.allocator.free(full);
        _ = pstat.lstat(full.ptr) catch return false;
        return true;
    }
};

/// Where `init` makes fixtures; see there. Creates it when missing.
fn fixtureBase(buf: *[1024]u8) ![]const u8 {
    if (libc.getenv("ZDEDUPE_TEST_TMP")) |dir| return makeBase(buf, std.mem.span(dir), "");
    if (builtin.os.tag == .windows) return makeBase(buf, "C:/zdedupe-tests", "");
    if (builtin.os.tag.isDarwin()) {
        // The account's home from the user database: a test may change $HOME.
        const pw = libc.getpwuid(libc.getuid()) orelse return error.MakeDirFailed;
        const home = std.mem.span(pw.dir orelse return error.MakeDirFailed);
        _ = try makeBase(buf, home, "/.cache");
        return makeBase(buf, home, "/.cache/zdedupe-tests");
    }
    return if (libc.getenv("TMPDIR")) |tmpdir| std.mem.span(tmpdir) else "/tmp";
}

/// `head ++ tail` in `buf`, created as a folder when missing.
fn makeBase(buf: *[1024]u8, head: []const u8, tail: []const u8) ![]const u8 {
    const z = std.fmt.bufPrintSentinel(buf, "{s}{s}", .{ head, tail }, 0) catch return error.MakeDirFailed;
    _ = libc.mkdir(z.ptr, 0o700);
    return z;
}

/// Remove `path` and everything below it, never following a link; for
/// fixtures a test moved out of its scratch directory.
pub fn removeTree(allocator: std.mem.Allocator, path: []const u8) void {
    const z = allocator.dupeSentinel(u8, path, 0) catch return;
    defer allocator.free(z);
    deleteTree(allocator, z) catch {};
}

/// Recursive delete. Uses lstat (never stat), so a symlink to a directory is
/// unlinked rather than followed — otherwise cleaning up the symlink-cycle
/// fixture would delete whatever the link pointed at.
fn deleteTree(allocator: std.mem.Allocator, path: [:0]const u8) !void {
    const st = pstat.lstat(path.ptr) catch return;

    if (!st.isDir()) {
        _ = libc.unlink(path.ptr);
        return;
    }

    const dir = libc.opendir(path.ptr) orelse return;
    var entries: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }

    while (libc.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ path, name }, 0);
        try entries.append(allocator, child);
    }
    _ = libc.closedir(dir);

    for (entries.items) |child| {
        try deleteTree(allocator, child);
    }

    _ = libc.rmdir(path.ptr);
}

test "scratch dir is created outside the repo and cleaned up" {
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "selftest");

    try std.testing.expect(std.mem.indexOf(u8, scratch.path, "zig-forge") == null);
    try scratch.makeDir("nested");
    try scratch.writeFile("nested/hello.txt", "hi");
    try std.testing.expect(try scratch.exists("nested/hello.txt"));

    const path = try allocator.dupeSentinel(u8, scratch.path, 0);
    defer allocator.free(path);

    scratch.deinit();

    try std.testing.expectError(error.StatFailed, pstat.lstat(path.ptr));
}

test "hostile filenames survive the scratch helper" {
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "hostile");
    defer scratch.deinit();

    // Characters that need escaping in the reports; Windows forbids `"`, `\\`,
    // `<` and `>` in names, so there the hostile set is what NTFS allows.
    const name = if (builtin.os.tag == .windows) "quote' amp& pct% tag[script] {x}.txt" else "quote\" backslash\\ tag<script>.txt";
    try scratch.writeFile(name, "payload");
    try std.testing.expect(try scratch.exists(name));
}
