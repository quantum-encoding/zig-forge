// URL classification + parsing for the four shapes git accepts:
//
//   https://host/path[.git]
//   http://host/path[.git]
//   ssh://[user@]host[:port]/path[.git]
//   [user@]host:path[.git]                 (SCP-like)
//   git://host/path[.git]                  (legacy, not yet handled)
//
// Each higher-level command (clone / push / fetch) calls `classify`
// to pick which transport (smart_http vs. ssh) to dispatch to, and
// `parseSsh` when it's an ssh form to pull out (user, host, port, path).

const std = @import("std");

pub const Kind = enum { https, http, ssh, scp_like, git, unknown };

pub fn classify(url: []const u8) Kind {
    if (std.mem.startsWith(u8, url, "https://")) return .https;
    if (std.mem.startsWith(u8, url, "http://")) return .http;
    if (std.mem.startsWith(u8, url, "ssh://")) return .ssh;
    if (std.mem.startsWith(u8, url, "git://")) return .git;
    if (isScpLike(url)) return .scp_like;
    return .unknown;
}

/// SCP-like form is `[user@]host:path` where the colon comes BEFORE
/// the first slash and the host has no slashes/dots-only-tokens that
/// look like a Windows drive (e.g. C:/foo).
fn isScpLike(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    if (colon == 0) return false;
    const slash = std.mem.indexOfScalar(u8, url, '/');
    // Colon must come before any slash, otherwise it's a path or
    // already-handled scheme.
    if (slash) |s| if (s < colon) return false;
    // Reject "C:..." Windows drive letters: a single-letter host with
    // no '@' isn't a real ssh target.
    if (colon == 1 and std.ascii.isAlphabetic(url[0])) return false;
    // Need a non-empty path after the colon; SCP-form `host:` with
    // nothing after isn't a clone target.
    if (colon + 1 >= url.len) return false;
    return true;
}

pub const SshTarget = struct {
    /// Optional user (the bit before `@`, if any). Borrowed slice into the original URL
    /// for `ssh://` form, or owned for SCP-like form (we copy on parse). `parseSsh`
    /// returns owned strings either way for uniformity.
    user: ?[]const u8,
    host: []const u8,
    port: ?u16,
    /// Repository path on the remote.
    path: []const u8,

    pub fn deinit(self: *SshTarget, allocator: std.mem.Allocator) void {
        if (self.user) |u| allocator.free(u);
        allocator.free(self.host);
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// Parse either `ssh://[user@]host[:port]/path` or `[user@]host:path`.
/// Returned strings are owned by the caller (call `deinit`).
pub fn parseSsh(allocator: std.mem.Allocator, url: []const u8) !SshTarget {
    if (std.mem.startsWith(u8, url, "ssh://")) {
        return parseSshScheme(allocator, url[6..]);
    }
    return parseScpLike(allocator, url);
}

fn parseSshScheme(allocator: std.mem.Allocator, rest: []const u8) !SshTarget {
    // rest = "[user@]host[:port]/path"
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.MissingPath;
    const authority = rest[0..slash];
    const path = rest[slash + 1 ..];
    if (path.len == 0) return error.MissingPath;

    const at = std.mem.indexOfScalar(u8, authority, '@');
    const user_raw: ?[]const u8 = if (at) |i| authority[0..i] else null;
    const host_port = if (at) |i| authority[i + 1 ..] else authority;

    const colon = std.mem.indexOfScalar(u8, host_port, ':');
    const host_raw = if (colon) |c| host_port[0..c] else host_port;
    const port: ?u16 = if (colon) |c| try std.fmt.parseInt(u16, host_port[c + 1 ..], 10) else null;

    if (host_raw.len == 0) return error.MissingHost;

    return .{
        .user = if (user_raw) |u| try allocator.dupe(u8, u) else null,
        .host = try allocator.dupe(u8, host_raw),
        .port = port,
        .path = try allocator.dupe(u8, path),
    };
}

fn parseScpLike(allocator: std.mem.Allocator, url: []const u8) !SshTarget {
    // url = "[user@]host:path"
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return error.NotScpForm;
    const before = url[0..colon];
    const path = url[colon + 1 ..];
    if (path.len == 0) return error.MissingPath;

    const at = std.mem.indexOfScalar(u8, before, '@');
    const user_raw: ?[]const u8 = if (at) |i| before[0..i] else null;
    const host_raw = if (at) |i| before[i + 1 ..] else before;

    if (host_raw.len == 0) return error.MissingHost;

    return .{
        .user = if (user_raw) |u| try allocator.dupe(u8, u) else null,
        .host = try allocator.dupe(u8, host_raw),
        .port = null,
        .path = try allocator.dupe(u8, path),
    };
}

const testing = std.testing;

test "classify: https" {
    try testing.expectEqual(Kind.https, classify("https://github.com/foo/bar.git"));
}

test "classify: http" {
    try testing.expectEqual(Kind.http, classify("http://example.com/r"));
}

test "classify: ssh://" {
    try testing.expectEqual(Kind.ssh, classify("ssh://git@github.com:22/foo/bar.git"));
}

test "classify: scp-like" {
    try testing.expectEqual(Kind.scp_like, classify("git@github.com:foo/bar.git"));
}

test "classify: scp-like without user" {
    try testing.expectEqual(Kind.scp_like, classify("github.com:foo/bar.git"));
}

test "classify: unknown for raw filesystem path" {
    try testing.expectEqual(Kind.unknown, classify("/home/me/repo"));
}

test "classify: unknown for relative path with slash before colon" {
    try testing.expectEqual(Kind.unknown, classify("./repo:bare"));
}

test "parseSsh: scheme form with port + user" {
    var t = try parseSsh(testing.allocator, "ssh://git@example.com:2222/foo/bar.git");
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("git", t.user.?);
    try testing.expectEqualStrings("example.com", t.host);
    try testing.expectEqual(@as(u16, 2222), t.port.?);
    try testing.expectEqualStrings("foo/bar.git", t.path);
}

test "parseSsh: scheme form without user/port" {
    var t = try parseSsh(testing.allocator, "ssh://example.com/foo/bar.git");
    defer t.deinit(testing.allocator);
    try testing.expect(t.user == null);
    try testing.expectEqualStrings("example.com", t.host);
    try testing.expect(t.port == null);
    try testing.expectEqualStrings("foo/bar.git", t.path);
}

test "parseSsh: scp-like with user" {
    var t = try parseSsh(testing.allocator, "git@github.com:foo/bar.git");
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("git", t.user.?);
    try testing.expectEqualStrings("github.com", t.host);
    try testing.expect(t.port == null);
    try testing.expectEqualStrings("foo/bar.git", t.path);
}

test "parseSsh: scp-like without user" {
    var t = try parseSsh(testing.allocator, "host.example:repo");
    defer t.deinit(testing.allocator);
    try testing.expect(t.user == null);
    try testing.expectEqualStrings("host.example", t.host);
    try testing.expectEqualStrings("repo", t.path);
}
