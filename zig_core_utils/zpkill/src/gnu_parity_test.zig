//! Externally-anchored tests for zpkill.
//!
//! ANCHORING (per zig-forge/CLAUDE.md golden rule — no roundtrip-only tests):
//! There is no GNU `pkill` binary on this (darwin) build host to diff against —
//! the `pkill` on PATH is macOS BSD pkill, whose signal numbering and flag set
//! differ from procps — and zpkill's process-scanning path requires a Linux
//! /proc filesystem that darwin does not provide. So the runtime process logic
//! cannot be exercised end-to-end here. Instead every expected value below is
//! taken from a source zpkill's author did not write:
//!
//!   * Signal numbers: signal(7) / `kill -l` on Linux (the kernel/glibc ABI).
//!   * /proc/<pid>/stat and /proc/<pid>/status field layout: proc(5).
//!   * `pkill -c` count/exit-code semantics: GNU procps pkill(1) documented
//!     behavior ("-c … Suppresses normal output; instead print a count of
//!     matching processes … exit status 1 if nothing matched").
//!
//! The expected bytes/numbers are written literally in each test and cited.

const std = @import("std");
const testing = std.testing;
const zpkill = @import("main.zig");

// ---------------------------------------------------------------------------
// parseSignal — anchored to signal(7) / `kill -l` on Linux (glibc).
// These numbers are the Linux kernel signal ABI, not chosen by this project.
// ---------------------------------------------------------------------------

test "parseSignal: classic names map to signal(7) numbers" {
    // Reference: signal(7), Standard signals table (x86/ARM/most arches).
    try testing.expectEqual(@as(?i32, 1), zpkill.parseSignal("HUP"));
    try testing.expectEqual(@as(?i32, 2), zpkill.parseSignal("INT"));
    try testing.expectEqual(@as(?i32, 3), zpkill.parseSignal("QUIT"));
    try testing.expectEqual(@as(?i32, 6), zpkill.parseSignal("ABRT"));
    try testing.expectEqual(@as(?i32, 9), zpkill.parseSignal("KILL"));
    try testing.expectEqual(@as(?i32, 11), zpkill.parseSignal("SEGV"));
    try testing.expectEqual(@as(?i32, 15), zpkill.parseSignal("TERM"));
    try testing.expectEqual(@as(?i32, 17), zpkill.parseSignal("CHLD"));
    try testing.expectEqual(@as(?i32, 19), zpkill.parseSignal("STOP"));
}

test "parseSignal: SIG prefix and case-insensitivity (pkill accepts both)" {
    try testing.expectEqual(@as(?i32, 9), zpkill.parseSignal("SIGKILL"));
    try testing.expectEqual(@as(?i32, 9), zpkill.parseSignal("sigkill"));
    try testing.expectEqual(@as(?i32, 9), zpkill.parseSignal("Kill"));
    try testing.expectEqual(@as(?i32, 15), zpkill.parseSignal("sigterm"));
}

test "parseSignal: numeric signals including the real-time range" {
    // `kill -l` on Linux/glibc: valid signal numbers run 1..64; 0 is the
    // null-signal (permission probe). Numbers >64 are not valid signals.
    try testing.expectEqual(@as(?i32, 0), zpkill.parseSignal("0"));
    try testing.expectEqual(@as(?i32, 9), zpkill.parseSignal("9"));
    try testing.expectEqual(@as(?i32, 15), zpkill.parseSignal("15"));
    try testing.expectEqual(@as(?i32, 34), zpkill.parseSignal("34")); // SIGRTMIN
    try testing.expectEqual(@as(?i32, 64), zpkill.parseSignal("64")); // SIGRTMAX
    try testing.expectEqual(@as(?i32, null), zpkill.parseSignal("65"));
    try testing.expectEqual(@as(?i32, null), zpkill.parseSignal("999"));
    try testing.expectEqual(@as(?i32, null), zpkill.parseSignal("-1"));
}

test "parseSignal: SIGRTMIN+n / SIGRTMAX-n (glibc real-time signals)" {
    // Reference: glibc `kill -l` — SIGRTMIN=34, SIGRTMAX=64 in user space.
    try testing.expectEqual(@as(?i32, 34), zpkill.parseSignal("RTMIN"));
    try testing.expectEqual(@as(?i32, 34), zpkill.parseSignal("SIGRTMIN"));
    try testing.expectEqual(@as(?i32, 36), zpkill.parseSignal("SIGRTMIN+2"));
    try testing.expectEqual(@as(?i32, 64), zpkill.parseSignal("RTMAX"));
    try testing.expectEqual(@as(?i32, 63), zpkill.parseSignal("SIGRTMAX-1"));
    // Out of the RT band -> rejected.
    try testing.expectEqual(@as(?i32, null), zpkill.parseSignal("SIGRTMIN+40"));
    try testing.expectEqual(@as(?i32, null), zpkill.parseSignal("SIGRTMAX-40"));
}

test "parseSignal: unknown names rejected" {
    try testing.expectEqual(@as(?i32, null), zpkill.parseSignal("NOTASIGNAL"));
    try testing.expectEqual(@as(?i32, null), zpkill.parseSignal("SIGBOGUS"));
    try testing.expectEqual(@as(?i32, null), zpkill.parseSignal(""));
}

// ---------------------------------------------------------------------------
// parseUidFromStatus — anchored to proc(5), /proc/<pid>/status "Uid:" line.
// Format: "Uid:\t<real>\t<effective>\t<saved>\t<fs>"
// ---------------------------------------------------------------------------

test "parseUidFromStatus: extracts real UID from a proc(5) status blob" {
    // Field layout per proc(5). procps matches the real UID (first field).
    const status =
        "Name:\tbash\n" ++
        "Umask:\t0022\n" ++
        "State:\tS (sleeping)\n" ++
        "Tgid:\t1234\n" ++
        "Pid:\t1234\n" ++
        "Uid:\t1000\t1000\t1000\t1000\n" ++
        "Gid:\t1000\t1000\t1000\t1000\n";
    try testing.expectEqual(@as(?u32, 1000), zpkill.parseUidFromStatus(status));
}

test "parseUidFromStatus: root (uid 0) and absent line" {
    const root_status = "Name:\tinit\nUid:\t0\t0\t0\t0\n";
    try testing.expectEqual(@as(?u32, 0), zpkill.parseUidFromStatus(root_status));

    const no_uid = "Name:\tfoo\nState:\tR (running)\n";
    try testing.expectEqual(@as(?u32, null), zpkill.parseUidFromStatus(no_uid));
}

// ---------------------------------------------------------------------------
// parseStarttime — anchored to proc(5), /proc/<pid>/stat.
// Fields: pid(1) comm(2) state(3) ppid(4) pgrp(5) session(6) tty_nr(7)
// tpgid(8) flags(9) minflt(10) cminflt(11) majflt(12) cmajflt(13) utime(14)
// stime(15) cutime(16) cstime(17) priority(18) nice(19) num_threads(20)
// itrealvalue(21) starttime(22) ...
// ---------------------------------------------------------------------------

test "parseStarttime: field 22 from a proc(5) stat line" {
    // Constructed so field 22 (starttime) == 987654321 and every preceding
    // field is distinct, per the proc(5) ordering above.
    //  pid comm  st ppid pgrp sess tty tpgid flags min cmin maj cmaj ut st cut cst prio nice nthr itreal START vsize rss
    const stat = "1234 (bash) S 1000 1234 1234 34816 -1 4194304 100 0 0 0 10 5 0 0 20 0 1 0 987654321 123456 456";
    try testing.expectEqual(@as(?u64, 987654321), zpkill.parseStarttime(stat));
}

test "parseStarttime: comm containing spaces and parens (scan from last ')')" {
    // procps handles comm values like "(sd-pam)" and names with spaces; the
    // parser must locate the LAST ')' so the field count stays correct.
    const stat = "42 ((sd pam)) S 1 42 42 0 -1 4194304 5 0 0 0 1 1 0 0 20 0 1 0 555000 111 22";
    try testing.expectEqual(@as(?u64, 555000), zpkill.parseStarttime(stat));
}

// ---------------------------------------------------------------------------
// countOutcome — anchored to GNU procps pkill(1) `-c` documented semantics.
// "Print a count of matching processes"; exit 1 when nothing matched.
// This is the regression guard for the fixed bug where zpkill emitted nothing
// and exited 1 on zero matches (a script's `n=$(zpkill -c foo)` got "").
// ---------------------------------------------------------------------------

test "countOutcome: zero matches prints 0 and exits 1 (GNU pkill -c)" {
    const zero = zpkill.countOutcome(0);
    try testing.expectEqual(@as(usize, 0), zero.count); // prints "0\n"
    try testing.expectEqual(@as(u8, 1), zero.exit_code); // nothing matched
}

test "countOutcome: N matches prints N and exits 0" {
    const some = zpkill.countOutcome(3);
    try testing.expectEqual(@as(usize, 3), some.count);
    try testing.expectEqual(@as(u8, 0), some.exit_code);

    const one = zpkill.countOutcome(1);
    try testing.expectEqual(@as(usize, 1), one.count);
    try testing.expectEqual(@as(u8, 0), one.exit_code);
}
