// Resolve credentials for an HTTPS URL.
//
// Resolution order (matches git's documented precedence, narrowed
// to what we actually support):
//
//   1. Userinfo embedded in the URL ("https://user:pass@host/repo")
//      — caller already handles this via net/auth.zig before reaching
//      us, so we only see clean URLs here.
//   2. `~/.git-credentials` (the format the `store` helper writes:
//      one URL per line including the userinfo).
//   3. `GIT_ASKPASS` env var → spawn that program twice ("Username"
//      and "Password") and capture stdout. SSH_ASKPASS is honoured as
//      a fallback for parity with git's own behaviour.
//
// We don't (yet):
//   * Run arbitrary `credential.helper` programs from config.
//   * Parse `~/.netrc`.
//   * Cache credentials in memory across multiple operations.
//
// Returned result lifetimes: every returned slice is owned by the
// caller and freed via `Result.deinit`. Callers feed `authorization`
// to `extra_headers` on the next HTTPS request.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;

pub const Result = struct {
    /// `Basic <base64>` — feed straight into the `Authorization` header.
    authorization: []u8,
    /// Source the credentials came from, for diagnostic output.
    source: Source,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.authorization);
        self.* = undefined;
    }
};

pub const Source = enum { url, git_credentials, askpass };

/// Try every source in order, return the first match. Returns null
/// if no source produced credentials (caller may proceed unauth'd
/// and let the server respond 401 if it cares).
pub fn resolve(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    clean_url: []const u8,
) !?Result {
    if (try fromGitCredentials(allocator, io, environ, clean_url)) |r| return r;
    if (try fromAskpass(allocator, io, environ, clean_url)) |r| return r;
    return null;
}

/// Read `~/.git-credentials` and find the first line that matches
/// the (scheme, host, optional path-prefix) of the request URL.
pub fn fromGitCredentials(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    clean_url: []const u8,
) !?Result {
    const home = environ.getPosix("HOME") orelse return null;

    const path = try std.fs.path.join(allocator, &.{ home, ".git-credentials" });
    defer allocator.free(path);

    const bytes = Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const want = try splitUrl(clean_url);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Each line is `scheme://user:pass@host[/path]`. We split off
        // the userinfo and compare scheme/host (and prefix-match the
        // path) against the request.
        const at = std.mem.indexOfScalar(u8, line, '@') orelse continue;
        const proto_end = std.mem.indexOf(u8, line, "://") orelse continue;
        if (at < proto_end + 3) continue;
        const userinfo = line[proto_end + 3 .. at];

        // Build the line's URL without userinfo for comparison.
        const after_at = line[at + 1 ..];
        const have_url_prefix = line[0 .. proto_end + 3]; // "https://"
        const got_scheme = line[0..proto_end];
        if (!std.mem.eql(u8, got_scheme, want.scheme)) continue;

        // Slice off any path on the credentials line and compare.
        const got_slash = std.mem.indexOfScalar(u8, after_at, '/');
        const got_host = if (got_slash) |s| after_at[0..s] else after_at;
        if (!std.mem.eql(u8, got_host, want.host)) continue;

        _ = have_url_prefix;
        return try buildBasic(allocator, userinfo, .git_credentials);
    }

    return null;
}

/// Spawn the `GIT_ASKPASS` (or `SSH_ASKPASS`) helper twice with
/// "Username for '<url>': " and "Password for '<url>': " prompts on
/// argv, capturing the helper's stdout each time.
pub fn fromAskpass(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    clean_url: []const u8,
) !?Result {
    const helper_z = environ.getPosix("GIT_ASKPASS") orelse environ.getPosix("SSH_ASKPASS") orelse return null;
    const helper: []const u8 = helper_z;
    if (helper.len == 0) return null;

    const user_prompt = try std.fmt.allocPrint(allocator, "Username for '{s}': ", .{clean_url});
    defer allocator.free(user_prompt);
    const pass_prompt = try std.fmt.allocPrint(allocator, "Password for '{s}': ", .{clean_url});
    defer allocator.free(pass_prompt);

    const username = try runAskpass(allocator, io, helper, user_prompt);
    defer allocator.free(username);
    const password = try runAskpass(allocator, io, helper, pass_prompt);
    defer allocator.free(password);

    if (username.len == 0 and password.len == 0) return null;

    const userinfo = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
    defer allocator.free(userinfo);

    return try buildBasic(allocator, userinfo, .askpass);
}

fn runAskpass(allocator: std.mem.Allocator, io: Io, helper: []const u8, prompt: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ helper, prompt },
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    // Strip trailing whitespace/newlines that conventional askpass helpers append.
    const trimmed_len = std.mem.trimEnd(u8, result.stdout, " \r\n").len;
    return try allocator.realloc(result.stdout, trimmed_len);
}

fn buildBasic(allocator: std.mem.Allocator, userinfo: []const u8, src: Source) !Result {
    const enc = std.base64.standard.Encoder;
    const enc_len = enc.calcSize(userinfo.len);
    const header = try allocator.alloc(u8, "Basic ".len + enc_len);
    errdefer allocator.free(header);
    @memcpy(header[0..6], "Basic ");
    _ = enc.encode(header[6..], userinfo);
    return .{ .authorization = header, .source = src };
}

const SplitUrl = struct {
    scheme: []const u8,
    host: []const u8,
    path: []const u8,
};

fn splitUrl(url: []const u8) !SplitUrl {
    const proto_end = std.mem.indexOf(u8, url, "://") orelse return error.UrlMissingScheme;
    const after = url[proto_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    return .{
        .scheme = url[0..proto_end],
        .host = after[0..slash],
        .path = if (slash < after.len) after[slash..] else "",
    };
}

const testing = std.testing;

test "splitUrl pulls scheme/host/path" {
    const s = try splitUrl("https://github.com/foo/bar.git");
    try testing.expectEqualStrings("https", s.scheme);
    try testing.expectEqualStrings("github.com", s.host);
    try testing.expectEqualStrings("/foo/bar.git", s.path);
}

test "buildBasic encodes userinfo" {
    var r = try buildBasic(testing.allocator, "octocat:hunter2", .url);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("Basic b2N0b2NhdDpodW50ZXIy", r.authorization);
    try testing.expectEqual(Source.url, r.source);
}
