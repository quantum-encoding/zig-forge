//! Externally-anchored tests for zps.
//!
//! zps is Linux-only (it reads /proc), and this repo builds/tests on macOS where
//! neither /proc nor a procps `ps` binary is available, so we cannot diff live
//! output against the real GNU/procps tool here. Instead the anchor is the
//! DOCUMENTED /proc/PID/stat field layout from the Linux man page proc_pid_stat(5)
//! (https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html):
//!
//!   (1) pid  (2) comm  (3) state  (4) ppid  (5) pgrp  (6) session  (7) tty_nr
//!   (8) tpgid  (9) flags  (10) minflt  (11) cminflt  (12) majflt  (13) cmajflt
//!   (14) utime  (15) stime  (16) cutime  (17) cstime  (18) priority  (19) nice
//!   (20) num_threads  (21) itrealvalue  (22) starttime  (23) vsize  (24) rss
//!
//! The man page also states: "comm ... The filename ... is shown in parentheses.
//! This field is visible only if ... The name can contain ... a ')' character",
//! which is why the parser anchors on the LAST ')' — the cases below pin that.
//!
//! The stat sample strings are real-shaped captures (systemd-style pid 1, and a
//! synthetic comm-with-')' worst case). Expected field values are written out
//! literally per the man-page field numbering above — no roundtrip self-checks.

const std = @import("std");
const zps = @import("main.zig");

test "parseStat: real systemd-style /proc/1/stat, fields per proc_pid_stat(5)" {
    // pid=1 comm=(systemd) state=S ppid=0 pgrp=1 session=1 tty_nr=0 tpgid=-1
    // flags=4194560 minflt=53899 cminflt=113 majflt=250 cmajflt=223 utime=178
    // stime=456 cutime=1120 cstime=780 priority=20 nice=0 num_threads=1
    // itrealvalue=0 starttime=33 vsize=170512384 rss=3288
    const line = "1 (systemd) S 0 1 1 0 -1 4194560 53899 113 250 223 178 456 1120 780 20 0 1 0 33 170512384 3288 18446744073709551615 1 1 0 0 0 0 0 671173123 0";
    const f = zps.parseStat(line);
    try std.testing.expectEqual(@as(u8, 'S'), f.state);
    try std.testing.expectEqual(@as(i32, 0), f.ppid);
    try std.testing.expectEqual(@as(i32, 0), f.tty_nr);
    try std.testing.expectEqual(@as(u64, 178), f.utime);
    try std.testing.expectEqual(@as(u64, 456), f.stime);
    try std.testing.expectEqual(@as(u64, 33), f.start_time);
    try std.testing.expectEqual(@as(u64, 170512384), f.vsize);
    try std.testing.expectEqual(@as(u64, 3288), f.rss);
}

test "parseStat: comm containing spaces and ')' anchors on the LAST paren" {
    // comm = "weird ) name" — proc_pid_stat(5) permits ')' inside comm.
    // After the final ')': state=R ppid=100 pgrp=4242 session=4242 tty_nr=34816
    // tpgid=-1 flags=1077936128 minflt=100 cminflt=0 majflt=0 cmajflt=0
    // utime=5 stime=7 cutime=0 cstime=0 priority=20 nice=0 num_threads=2
    // itrealvalue=0 starttime=9999 vsize=123456 rss=42
    // tty_nr=34816 == (136<<8)|0 -> pts/0 in ps.
    const line = "4242 (weird ) name) R 100 4242 4242 34816 -1 1077936128 100 0 0 0 5 7 0 0 20 0 2 0 9999 123456 42";
    const f = zps.parseStat(line);
    try std.testing.expectEqual(@as(u8, 'R'), f.state);
    try std.testing.expectEqual(@as(i32, 100), f.ppid);
    try std.testing.expectEqual(@as(i32, 34816), f.tty_nr);
    try std.testing.expectEqual(@as(u64, 5), f.utime);
    try std.testing.expectEqual(@as(u64, 7), f.stime);
    try std.testing.expectEqual(@as(u64, 9999), f.start_time);
    try std.testing.expectEqual(@as(u64, 123456), f.vsize);
    try std.testing.expectEqual(@as(u64, 42), f.rss);
}

// ---- Security anchor: truncated /proc read must not read out of bounds ----
// /proc/PID/stat is not a regular file; a short read is legal and can leave the
// buffer ending exactly at the closing ')'. The pre-fix code sliced
// content[paren_pos+2..] with paren_pos == len-1, i.e. content[len+1..], which is
// a Zig safety panic (DoS) in Debug/ReleaseSafe and an OOB read in ReleaseFast.
// These tests pin the guard: truncated input yields defaults, never a panic.

test "parseStat: buffer truncated exactly at ')' returns defaults, no OOB" {
    const line = "1234 (someproc)"; // last byte is ')', paren_pos == len-1
    const f = zps.parseStat(line);
    try std.testing.expectEqual(@as(u8, '?'), f.state);
    try std.testing.expectEqual(@as(i32, 0), f.ppid);
    try std.testing.expectEqual(@as(u64, 0), f.utime);
    try std.testing.expectEqual(@as(u64, 0), f.rss);
}

test "parseStat: buffer truncated at ') ' (one trailing space) returns defaults" {
    const line = "1234 (someproc) "; // paren_pos == len-2, no state byte present
    const f = zps.parseStat(line);
    try std.testing.expectEqual(@as(u8, '?'), f.state);
    try std.testing.expectEqual(@as(u64, 0), f.utime);
}

test "parseStat: no closing paren at all returns defaults" {
    const f = zps.parseStat("garbage without paren");
    try std.testing.expectEqual(@as(u8, '?'), f.state);
    try std.testing.expectEqual(@as(i32, 0), f.ppid);
}

// ---- %CPU anchor: procps computes total_time/hertz over process lifetime ----
// ps(1)/procps %CPU = (utime+stime)/HZ / (uptime - starttime/HZ) * 100.
// utime+stime=200 ticks @ HZ=100 -> 2.0 CPU-seconds; starttime=100 ticks -> 1s;
// uptime=101s -> elapsed=100s; %CPU = 2/100*100 = 2.0.
test "cpuPercent: procps formula, 2 CPU-seconds over 100s elapsed = 2.0%" {
    const pct = zps.cpuPercent(100, 100, 100, 101.0, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), pct, 0.01);
}

test "cpuPercent: zero elapsed / zero uptime is guarded to 0.0 (no div-by-zero)" {
    try std.testing.expectEqual(@as(f32, 0.0), zps.cpuPercent(50, 50, 0, 0.0, 100));
    // starttime in the future vs uptime -> negative elapsed -> 0.0
    try std.testing.expectEqual(@as(f32, 0.0), zps.cpuPercent(50, 50, 100000, 10.0, 100));
}

// ---- %MEM anchor: rss vs MemTotal, must honour real page size ----
// rss is in PAGES (proc field 24). %MEM = rss_bytes / MemTotal * 100.
// 1000 pages @ 4096 B = 4,096,000 B = 4000 kB; MemTotal=8,192,000 kB ->
// 4000/8192000*100 = 0.048828%.
test "memPercent: 1000 pages of 4KiB vs 8GiB total = ~0.0488%" {
    const pct = zps.memPercent(1000, 4096, 8192000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.048828), pct, 0.0001);
}

// Page-size anchor: same page count on a 16KiB-page kernel (arm64/ppc64) must
// report 4x the memory — the pre-fix hardcoded /4096 & rss*4 baked in 4KiB.
test "memPercent: 16KiB pages report 4x the resident memory of 4KiB pages" {
    const p4 = zps.memPercent(1000, 4096, 8192000);
    const p16 = zps.memPercent(1000, 16384, 8192000);
    try std.testing.expectApproxEqAbs(p4 * 4.0, p16, 0.0001);
}

test "memPercent: zero MemTotal guarded to 0.0" {
    try std.testing.expectEqual(@as(f32, 0.0), zps.memPercent(1000, 4096, 0));
}
