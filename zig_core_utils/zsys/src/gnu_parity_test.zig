// gnu_parity_test.zig — externally-anchored tests for zsys.
//
// `sys` is NOT a GNU coreutils utility, so there is no reference binary to diff
// against (audit: gnu_reference = "documented-behavior"). zsys is a custom
// aggregation of free/uptime/nproc/uname/lscpu, each of which reads a documented
// kernel interface. These tests therefore anchor to the *documented byte format*
// of those interfaces, feeding the pure parsers fixed fixture strings taken from
// the Linux man pages and asserting the exact numeric outputs. Every expected
// value is written literally below and cited to its source — no roundtrip tests.
//
// Anchors:
//   - /proc/meminfo  : proc(5) / proc_meminfo(5) man page field format
//     https://man7.org/linux/man-pages/man5/proc_meminfo.5.html
//   - /proc/loadavg  : proc_loadavg(5) man page
//     https://man7.org/linux/man-pages/man5/proc_loadavg.5.html
//   - /proc/uptime   : proc_uptime(5) man page (two floats, seconds)
//   - /proc/cpuinfo  : proc_cpuinfo(5) — one "processor" block per logical CPU
//   - IEC binary prefixes (Ki/Mi/Gi = 1024^n): `free -h` / IEC 80000-13
//   - utsname field sizes: POSIX <sys/utsname.h>; Darwin uses 256-byte fields
//     (SYS_NAMELEN) vs Linux __NEW_UTS_LEN (65) — the OOB regression below.

const std = @import("std");
const zsys = @import("main.zig");

// ── /proc/meminfo ────────────────────────────────────────────────────────────
// Fixture in the exact "Key:   Value kB" column format the kernel emits
// (proc_meminfo(5)). Values are in kibibytes; zsys converts to bytes (×1024).
test "parseMemoryInfo: proc/meminfo documented format → exact byte values" {
    const fixture =
        \\MemTotal:       16333764 kB
        \\MemFree:         2097152 kB
        \\MemAvailable:    8388608 kB
        \\Buffers:          524288 kB
        \\Cached:          3145728 kB
        \\SwapCached:            0 kB
        \\SwapTotal:       2097152 kB
        \\SwapFree:        1048576 kB
        \\Shmem:            131072 kB
        \\
    ;
    const mem = zsys.parseMemoryInfoFromContents(fixture);

    try std.testing.expectEqual(@as(u64, 16333764) * 1024, mem.total);
    try std.testing.expectEqual(@as(u64, 2097152) * 1024, mem.free);
    try std.testing.expectEqual(@as(u64, 8388608) * 1024, mem.available);
    try std.testing.expectEqual(@as(u64, 524288) * 1024, mem.buffers);
    try std.testing.expectEqual(@as(u64, 3145728) * 1024, mem.cached);
    try std.testing.expectEqual(@as(u64, 2097152) * 1024, mem.swap_total);
    try std.testing.expectEqual(@as(u64, 1048576) * 1024, mem.swap_free);
    try std.testing.expectEqual(@as(u64, 131072) * 1024, mem.shared);

    // `free`'s "used" column = MemTotal − MemFree − Buffers − Cached.
    // = (16333764 − 2097152 − 524288 − 3145728) kB = 10566596 kB.
    try std.testing.expectEqual(@as(u64, 10566596) * 1024, zsys.computeUsedMemory(mem));
}

// Regression for the u64-underflow finding: a missing MemTotal (total == 0) or
// reclaimable > total must clamp used → 0, never wrap to ~2^64.
test "computeUsedMemory: underflow guard (total==0 and skew) → 0, not ~2^64" {
    // total == 0 (MemTotal line absent/unparsed)
    const skew_zero_total = zsys.parseMemoryInfoFromContents(
        \\MemFree:         2097152 kB
        \\Buffers:          524288 kB
        \\Cached:          3145728 kB
        \\
    );
    try std.testing.expectEqual(@as(u64, 0), skew_zero_total.total);
    try std.testing.expectEqual(@as(u64, 0), zsys.computeUsedMemory(skew_zero_total));

    // free+buffers+cached transiently exceeds total
    const skew_over = zsys.parseMemoryInfoFromContents(
        \\MemTotal:            100 kB
        \\MemFree:             200 kB
        \\Buffers:             200 kB
        \\Cached:              200 kB
        \\
    );
    try std.testing.expectEqual(@as(u64, 0), zsys.computeUsedMemory(skew_over));
}

// ── /proc/loadavg ────────────────────────────────────────────────────────────
// proc_loadavg(5): "load1 load5 load15 runnable/total lastpid".
test "parseLoadAvg: proc/loadavg documented five-field format" {
    const load = zsys.parseLoadAvgFromContents("0.45 0.30 0.15 2/345 12345\n");
    try std.testing.expectApproxEqAbs(@as(f64, 0.45), load.one_min, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), load.five_min, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), load.fifteen_min, 1e-9);
    try std.testing.expectEqual(@as(u32, 2), load.running_procs);
    try std.testing.expectEqual(@as(u32, 345), load.total_procs);
}

// ── /proc/uptime ─────────────────────────────────────────────────────────────
// proc_uptime(5): two floating-point seconds values (uptime, idle-sum).
test "parseUptime: proc/uptime documented two-float format" {
    const up = zsys.parseUptimeFromContents("12345.67 98765.43\n");
    try std.testing.expectApproxEqAbs(@as(f64, 12345.67), up.uptime_secs, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 98765.43), up.idle_secs, 1e-6);
}

// ── /proc/cpuinfo ────────────────────────────────────────────────────────────
// proc_cpuinfo(5): one block per logical CPU. Two-socket, 2-logical fixture:
// distinct "physical id" values → 2 physical packages; two "processor" lines →
// 2 logical CPUs; first "model name"/"vendor_id" wins.
test "parseCpuInfo: proc/cpuinfo two-socket block format → core counts + model" {
    const allocator = std.testing.allocator;
    // Authentic /proc/cpuinfo byte format: key, a run of tabs, then ": " value.
    const fixture =
        "processor\t: 0\n" ++
        "vendor_id\t: GenuineIntel\n" ++
        "model name\t: Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz\n" ++
        "cpu MHz\t\t: 2400.000\n" ++
        "cache size\t: 35840 KB\n" ++
        "physical id\t: 0\n" ++
        "\n" ++
        "processor\t: 1\n" ++
        "vendor_id\t: GenuineIntel\n" ++
        "model name\t: Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz\n" ++
        "cpu MHz\t\t: 2400.000\n" ++
        "cache size\t: 35840 KB\n" ++
        "physical id\t: 1\n" ++
        "\n";
    const cpu = try zsys.parseCpuInfoFromContents(allocator, fixture);
    try std.testing.expectEqual(@as(u32, 2), cpu.logical_cores);
    try std.testing.expectEqual(@as(u32, 2), cpu.physical_cores);
    try std.testing.expectEqualStrings("GenuineIntel", cpu.getVendorId());
    try std.testing.expectEqualStrings("Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz", cpu.getModelName());
    try std.testing.expectEqual(@as(u64, 35840), cpu.cache_size);
}

// ── formatBytes: IEC binary prefixes ─────────────────────────────────────────
// Anchor: IEC 80000-13 binary prefixes (Ki=2^10, Mi=2^20, Gi=2^30, Ti=2^40),
// the same base-1024 scaling `free -h` uses. Expected strings written literally.
test "formatBytes: IEC binary-prefix boundaries" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512.0 B", zsys.formatBytes(512, &buf));
    try std.testing.expectEqualStrings("1.0 Ki", zsys.formatBytes(1024, &buf));
    try std.testing.expectEqualStrings("1.5 Ki", zsys.formatBytes(1536, &buf));
    try std.testing.expectEqualStrings("1.0 Mi", zsys.formatBytes(1024 * 1024, &buf));
    try std.testing.expectEqualStrings("1.0 Gi", zsys.formatBytes(1024 * 1024 * 1024, &buf));
    try std.testing.expectEqualStrings("1.0 Ti", zsys.formatBytes(1024 * 1024 * 1024 * 1024, &buf));
}

// ── uname OOB regression (the critical finding) ──────────────────────────────
// POSIX <sys/utsname.h> fields are implementation-sized: Linux __NEW_UTS_LEN is
// 65 but Darwin/BSD use 256-byte fields, and a real macOS `version` string is
// ~107 bytes. zsys's SystemInfo buffers are [65]u8, so copying an unclamped
// utsname field overflowed the destination and panicked
// ("index out of bounds: index 107, len 65"). copyField must clamp to the
// destination length. This fixture feeds a >64-byte version through the real
// copy path; before the fix it panics, after the fix it clamps to 65.
test "fillSystemInfo: over-length utsname field is clamped, not overflowed" {
    var uts: std.c.utsname = std.mem.zeroes(std.c.utsname);

    const sysname = "Darwin";
    const nodename = "host.local";
    const release = "27.0.0";
    // Real Darwin-shaped version string, 107 bytes — longer than the 65-byte dest.
    const version = "Darwin Kernel Version 27.0.0: Wed Jan 01 00:00:00 PST 2026; root:xnu-11000.0.0~1/RELEASE_ARM64_T6000_XXXXX";
    const machine = "arm64";

    @memcpy(uts.sysname[0..sysname.len], sysname);
    @memcpy(uts.nodename[0..nodename.len], nodename);
    @memcpy(uts.release[0..release.len], release);
    @memcpy(uts.version[0..version.len], version);
    @memcpy(uts.machine[0..machine.len], machine);

    try std.testing.expect(version.len > 65); // precondition: would overflow [65]u8

    const sys = zsys.fillSystemInfo(&uts); // must NOT panic

    // Short fields copied verbatim.
    try std.testing.expectEqualStrings("Darwin", sys.getSysname());
    try std.testing.expectEqualStrings("host.local", sys.getNodename());
    try std.testing.expectEqualStrings("27.0.0", sys.getRelease());
    try std.testing.expectEqualStrings("arm64", sys.getMachine());

    // Over-length field clamped to the 65-byte destination and a prefix of input.
    try std.testing.expectEqual(@as(usize, 65), sys.getVersion().len);
    try std.testing.expectEqualStrings(version[0..65], sys.getVersion());
}

// copyField unit anchor: clamp semantics both under and over the destination.
test "copyField: clamps to destination length" {
    var dst: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), zsys.copyField(&dst, "abc"));
    try std.testing.expectEqualStrings("abc", dst[0..3]);
    // Over-length source truncates to dst.len (8), never overflows.
    try std.testing.expectEqual(@as(usize, 8), zsys.copyField(&dst, "0123456789"));
    try std.testing.expectEqualStrings("01234567", dst[0..8]);
}
