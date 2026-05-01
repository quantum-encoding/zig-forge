// Strip user:pass out of an HTTPS URL and return a Basic-auth
// header value if present.
//
// Input examples:
//   https://github.com/foo/bar
//     → clean = "https://github.com/foo/bar", auth = null
//   https://octocat:hunter2@github.com/foo/bar
//     → clean = "https://github.com/foo/bar"
//       auth  = "Basic b2N0b2NhdDpodW50ZXIy"
//   https://x-access-token:ghp_xxx@github.com/foo/bar
//     → same shape; works for GitHub PATs (user is anything, token is the password)
//
// We don't (yet) read .git/config or .netrc — explicit URL is the
// only credential source for now.

const std = @import("std");

pub const Result = struct {
    /// Cleaned URL (no userinfo); allocated when different from input.
    /// Caller frees with `allocator.free(clean)` only if `owns_clean`.
    clean_url: []const u8,
    owns_clean: bool,
    /// "Basic <base64(user:pass)>" or null. Owned when present.
    authorization: ?[]u8,
};

pub fn deinit(allocator: std.mem.Allocator, r: *Result) void {
    if (r.owns_clean) allocator.free(r.clean_url);
    if (r.authorization) |a| allocator.free(a);
    r.* = undefined;
}

pub fn split(allocator: std.mem.Allocator, url: []const u8) !Result {
    // We only handle http(s):// URLs; bail with the input untouched
    // for anything else.
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return .{
        .clean_url = url, .owns_clean = false, .authorization = null,
    };
    const scheme = url[0..scheme_end];
    const after_scheme = url[scheme_end + 3 ..];

    // Userinfo is everything before the first '@', and only if that
    // '@' comes before the next '/' (otherwise the '@' belongs to a
    // path component, not the authority).
    const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
    const at = std.mem.indexOfScalar(u8, after_scheme[0..slash], '@') orelse return .{
        .clean_url = url, .owns_clean = false, .authorization = null,
    };

    const userinfo = after_scheme[0..at];
    const host_and_path = after_scheme[at + 1 ..];

    // Build "<scheme>://<host_and_path>" without the userinfo.
    const clean = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ scheme, host_and_path });
    errdefer allocator.free(clean);

    // Build "Basic <base64(userinfo)>".
    const enc = std.base64.standard.Encoder;
    const enc_len = enc.calcSize(userinfo.len);
    const header = try allocator.alloc(u8, "Basic ".len + enc_len);
    errdefer allocator.free(header);
    @memcpy(header[0..6], "Basic ");
    _ = enc.encode(header[6..], userinfo);

    return .{ .clean_url = clean, .owns_clean = true, .authorization = header };
}

const testing = std.testing;

test "no userinfo: passes through unchanged" {
    var r = try split(testing.allocator, "https://github.com/foo/bar");
    defer deinit(testing.allocator, &r);
    try testing.expectEqualStrings("https://github.com/foo/bar", r.clean_url);
    try testing.expect(!r.owns_clean);
    try testing.expect(r.authorization == null);
}

test "userinfo split into clean URL + Basic header" {
    var r = try split(testing.allocator, "https://octocat:hunter2@github.com/foo/bar");
    defer deinit(testing.allocator, &r);
    try testing.expectEqualStrings("https://github.com/foo/bar", r.clean_url);
    try testing.expect(r.authorization != null);
    // base64("octocat:hunter2") = b2N0b2NhdDpodW50ZXIy
    try testing.expectEqualStrings("Basic b2N0b2NhdDpodW50ZXIy", r.authorization.?);
}

test "@ inside path is not userinfo" {
    var r = try split(testing.allocator, "https://example.com/foo@bar");
    defer deinit(testing.allocator, &r);
    try testing.expectEqualStrings("https://example.com/foo@bar", r.clean_url);
    try testing.expect(r.authorization == null);
}
