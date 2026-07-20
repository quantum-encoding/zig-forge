//! Externally-anchored unit tests for zpinky's pure formatting/parsing helpers.
//!
//! These do NOT roundtrip against zpinky itself. Each expected value is taken
//! from an external authority:
//!   - GNU coreutils 9.10 `pinky` idle_string() behavior (src/pinky.c), and the
//!     byte-exact output observed from /opt/homebrew/bin/gpinky on this host.
//!   - The passwd(5) colon-separated record format.
//!
//! The end-to-end byte-for-byte comparison against the real GNU `pinky` binary
//! lives in test/gnu_diff.sh, which `zig build test` also runs.

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

// ---------------------------------------------------------------------------
// formatIdle — anchored to GNU pinky idle_string():
//   < 60s          -> "" (blank; pinky prints spaces for "just now")
//   < 24h          -> "%02d:%02d"  (e.g. "01:44")
//   >= 24h         -> "<days>d"    (e.g. "18372d")
// Reference: coreutils src/pinky.c idle_string(), and observed gpinky output
// columns ("18372d", "01:46").
// ---------------------------------------------------------------------------

test "formatIdle: under a minute is blank" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("", main.formatIdle(0, &buf));
    try testing.expectEqualStrings("", main.formatIdle(59, &buf));
}

test "formatIdle: minutes and hours zero-padded HH:MM" {
    var buf: [16]u8 = undefined;
    // 1h44m = 6240s
    try testing.expectEqualStrings("01:44", main.formatIdle(6240, &buf));
    // exactly one minute
    try testing.expectEqualStrings("00:01", main.formatIdle(60, &buf));
    // 23:59 = 86340s (largest sub-day value)
    try testing.expectEqualStrings("23:59", main.formatIdle(86340, &buf));
    // 10h05m to exercise both digit positions
    try testing.expectEqualStrings("10:05", main.formatIdle(10 * 3600 + 5 * 60, &buf));
}

test "formatIdle: whole days rendered as <n>d" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("1d", main.formatIdle(86400, &buf));
    // 18372 days — the exact "console" idle value observed from gpinky
    try testing.expectEqualStrings("18372d", main.formatIdle(18372 * 86400, &buf));
}

// ---------------------------------------------------------------------------
// parsePasswdLine — anchored to passwd(5): 7 colon-separated fields
//   name:passwd:uid:gid:gecos:home:shell
// Full name is the GECOS field up to the first comma.
// The exact bytes below are the macOS system 'nobody' record.
// ---------------------------------------------------------------------------

test "parsePasswdLine: extracts name/gecos/home/shell (nobody record)" {
    var buf: [1024]u8 = undefined;
    const line = "nobody:*:-2:-2:Unprivileged User:/var/empty:/usr/bin/false";
    const info = main.parsePasswdLine(line, &buf) orelse return error.ParseFailed;
    try testing.expectEqualStrings("nobody", info.username);
    try testing.expectEqualStrings("Unprivileged User", info.fullname);
    try testing.expectEqualStrings("/var/empty", info.home);
    try testing.expectEqualStrings("/usr/bin/false", info.shell);
}

test "parsePasswdLine: GECOS truncated at first comma" {
    var buf: [1024]u8 = undefined;
    // Classic finger-style GECOS: "Full Name,Room,WorkPhone,HomePhone"
    const line = "jdoe:x:1000:1000:John Doe,Room 1,555-1234:/home/jdoe:/bin/bash";
    const info = main.parsePasswdLine(line, &buf) orelse return error.ParseFailed;
    try testing.expectEqualStrings("jdoe", info.username);
    try testing.expectEqualStrings("John Doe", info.fullname);
    try testing.expectEqualStrings("/home/jdoe", info.home);
    try testing.expectEqualStrings("/bin/bash", info.shell);
}

test "parsePasswdLine: empty GECOS yields empty full name" {
    var buf: [1024]u8 = undefined;
    const line = "svc:x:2:2::/var/svc:/usr/sbin/nologin";
    const info = main.parsePasswdLine(line, &buf) orelse return error.ParseFailed;
    try testing.expectEqualStrings("svc", info.username);
    try testing.expectEqualStrings("", info.fullname);
    try testing.expectEqualStrings("/var/svc", info.home);
    try testing.expectEqualStrings("/usr/sbin/nologin", info.shell);
}

test "parsePasswdLine: blank line rejected" {
    var buf: [1024]u8 = undefined;
    try testing.expect(main.parsePasswdLine("", &buf) == null);
}
