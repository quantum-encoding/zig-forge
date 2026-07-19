//! Scratch-directory helper for tests that need real files on disk.
//!
//! Deliberately NOT `std.testing.tmpDir`: that roots its fixtures at
//! `.zig-cache/tmp` inside the source tree, and zdedupe's tests create hostile
//! filenames (embedded quotes, backslashes, `<script>`), symlink cycles and
//! hard links — none of which belong anywhere under the repo. Everything here
//! lands under `$TMPDIR` (or `/tmp`) and is removed on `deinit`.
//!
//! Built on libc rather than `std.Io.Dir` to match the rest of zdedupe (which
//! is libc-based end to end) and to keep the fixtures usable from tests that
//! feed raw NUL-terminated paths straight into the walkers.

const std = @import("std");
const libc = std.c;
const pstat = @import("pstat.zig");

pub const Scratch = struct {
    allocator: std.mem.Allocator,
    /// Absolute path to the scratch root (NUL-terminated for libc calls).
    path: [:0]const u8,

    /// Create a uniquely-named scratch directory. `label` is only for humans
    /// reading a leftover directory after a crash.
    pub fn init(allocator: std.mem.Allocator, label: []const u8) !Scratch {
        const base: []const u8 = if (libc.getenv("TMPDIR")) |tmpdir|
            std.mem.span(tmpdir)
        else
            "/tmp";

        const trimmed = std.mem.trimEnd(u8, base, "/");

        var rand_bytes: [8]u8 = undefined;
        libc.arc4random_buf(&rand_bytes, rand_bytes.len);
        const rand_hex = std.fmt.bytesToHex(rand_bytes, .lower);

        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/zdedupe-test-{s}-{s}",
            .{ trimmed, label, rand_hex },
            0,
        );
        errdefer allocator.free(path);

        if (libc.mkdir(path.ptr, 0o700) != 0) return error.MakeDirFailed;

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

    /// `target` is interpreted relative to the link's own directory, as with
    /// `ln -s target link`.
    pub fn symLink(self: *const Scratch, target: []const u8, link_sub_path: []const u8) !void {
        const target_z = try self.allocator.dupeZ(u8, target);
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

    const path = try allocator.dupeZ(u8, scratch.path);
    defer allocator.free(path);

    scratch.deinit();

    try std.testing.expectError(error.StatFailed, pstat.lstat(path.ptr));
}

test "hostile filenames survive the scratch helper" {
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "hostile");
    defer scratch.deinit();

    const name = "quote\" backslash\\ tag<script>.txt";
    try scratch.writeFile(name, "payload");
    try std.testing.expect(try scratch.exists(name));
}
