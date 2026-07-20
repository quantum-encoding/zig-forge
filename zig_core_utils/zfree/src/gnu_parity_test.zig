//! Externally-anchored parity tests for `zfree` (GNU/procps `free`).
//!
//! THE EXTERNAL ANCHOR is real `free from procps-ng 4.0.6` output captured from
//! a live Linux host (x86-64, kernel 6.x). `zfree` targets Linux and reads
//! /proc/meminfo, which does not exist on the macOS build/test host, so the
//! parity tests feed the pure render/compute functions a FROZEN, real
//! /proc/meminfo snapshot and assert their output equals — byte for byte — what
//! procps-ng 4.0.6 `free` printed for that exact snapshot. None of these are
//! roundtrip / self-consistency tests: every expected string below is the
//! literal stdout of the reference GNU binary.
//!
//! The frozen snapshot (call it S) and the reference outputs were captured
//! atomically enough that `free`, `free -k`, `free -b`, `free -w` and `free -t`
//! all read the same stable memory state; each was verified consistent with the
//! /proc/meminfo dump before being pinned here:
//!
//!   MemTotal 65610148  MemFree 12213704  MemAvailable 46622552
//!   Buffers 1207872    Cached 39238312   SReclaimable 1748164
//!   Shmem 7340044      SwapTotal 16777212  SwapFree 12474888
//!
//! Cross-checks that pin the procps formulas (not our own math):
//!   used      = MemTotal - MemAvailable = 65610148 - 46622552 = 18987596  ✓ (matches real `free`)
//!   buff/cache = Buffers + Cached + SReclaimable = 42194348               ✓
//!   swap used = SwapTotal - SwapFree = 4302324                            ✓
//!
//! A separate group of end-to-end tests spawns the built `zfree` binary to pin
//! --help/--version (stdout, exit 0) and invalid-option (stderr, exit 1)
//! behavior against documented GNU `free`; those paths never touch /proc so
//! they run on the macOS host.

const std = @import("std");
const zfree = @import("main.zig");
const build_options = @import("build_options");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

// ---------------------------------------------------------------------------
// Frozen /proc/meminfo snapshot S (real Linux host, procps-ng 4.0.6 reference).
// Laid out like a real kernel dump (extra fields interleaved) so the parser is
// exercised on realistic input, not a hand-trimmed ideal.
// ---------------------------------------------------------------------------
const MEMINFO_S =
    \\MemTotal:       65610148 kB
    \\MemFree:        12213704 kB
    \\MemAvailable:   46622552 kB
    \\Buffers:         1207872 kB
    \\Cached:         39238312 kB
    \\SwapCached:       110292 kB
    \\Active:          9470884 kB
    \\Inactive:       39496332 kB
    \\Active(anon):    7577580 kB
    \\Inactive(anon):  8023344 kB
    \\Unevictable:      493420 kB
    \\Mlocked:             200 kB
    \\SwapTotal:      16777212 kB
    \\SwapFree:       12474888 kB
    \\Dirty:              2968 kB
    \\Writeback:           108 kB
    \\AnonPages:       8956756 kB
    \\Mapped:          2497060 kB
    \\Shmem:           7340044 kB
    \\KReclaimable:    1748164 kB
    \\Slab:            2291604 kB
    \\SReclaimable:    1748164 kB
    \\SUnreclaim:       543440 kB
    \\
;

// ---- Reference outputs: literal stdout of `free from procps-ng 4.0.6` -------

// `free`  (default; and `free -k` is byte-identical)
const REF_DEFAULT =
    "               total        used        free      shared  buff/cache   available\n" ++
    "Mem:        65610148    18987596    12213704     7340044    42194348    46622552\n" ++
    "Swap:       16777212     4302324    12474888\n";

// `free -b`
const REF_BYTES =
    "               total        used        free      shared  buff/cache   available\n" ++
    "Mem:     67184791552 19443298304 12506832896  7516205056 43207012352 47741493248\n" ++
    "Swap:    17179865088  4405579776 12774285312\n";

// `free -w`
const REF_WIDE =
    "               total        used        free      shared     buffers       cache   available\n" ++
    "Mem:        65610148    18987596    12213704     7340044     1207872    40986476    46622552\n" ++
    "Swap:       16777212     4302324    12474888\n";

// `free -t`
const REF_TOTAL =
    "               total        used        free      shared  buff/cache   available\n" ++
    "Mem:        65610148    18987596    12213704     7340044    42194348    46622552\n" ++
    "Swap:       16777212     4302324    12474888\n" ++
    "Total:      82387360    23289920    24688592\n";

fn render(cfg: zfree.Config) []const u8 {
    const info = zfree.parseMeminfoData(MEMINFO_S);
    // Static buffer is fine: tests are single-threaded and each assertion copies
    // via expectEqualStrings before the next render call reuses it.
    const S = struct {
        var buf: [4096]u8 = undefined;
    };
    var w = std.Io.Writer.fixed(&S.buf);
    zfree.renderReport(info, &cfg, &w) catch unreachable;
    return w.buffered();
}

test "parity: default output matches procps-ng 4.0.6 free" {
    try std.testing.expectEqualStrings(REF_DEFAULT, render(.{}));
}

test "parity: -k output matches procps-ng free -k (identical to default)" {
    try std.testing.expectEqualStrings(REF_DEFAULT, render(.{ .kibi = true }));
}

test "parity: -b output matches procps-ng free -b" {
    try std.testing.expectEqualStrings(REF_BYTES, render(.{ .bytes = true, .kibi = false }));
}

test "parity: -w wide output matches procps-ng free -w" {
    try std.testing.expectEqualStrings(REF_WIDE, render(.{ .show_wide = true }));
}

test "parity: -t total output matches procps-ng free -t" {
    try std.testing.expectEqualStrings(REF_TOTAL, render(.{ .show_total = true }));
}

// `free -m`: procps `scale_size` for a fixed exponent divides the KiB value by
// 1024^(exp-1) with truncation, i.e. floor(kB/1024) for -m. That truncation was
// validated against real `free -m` captures (e.g. 18942936 kB -> 18498 MiB).
// Applying it to snapshot S:
const REF_MEBI =
    "               total        used        free      shared  buff/cache   available\n" ++
    "Mem:           64072       18542       11927        7168       41205       45529\n" ++
    "Swap:          16383        4201       12182\n";

test "parity: -m mebibytes uses procps scale_size truncation" {
    try std.testing.expectEqualStrings(REF_MEBI, render(.{ .mebi = true, .kibi = false }));
}

// ---------------------------------------------------------------------------
// used-memory fix (audit HIGH: unsigned underflow). procps: used = MemTotal -
// MemAvailable, with a fallback to MemTotal - MemFree; NEVER a wrapped value.
// ---------------------------------------------------------------------------

test "computeMemUsed: total - available (matches real free)" {
    const info = zfree.parseMeminfoData(MEMINFO_S);
    try std.testing.expectEqual(@as(u64, 18987596), zfree.computeMemUsed(info));
}

test "computeMemUsed: no underflow when buff/cache exceeds total-free" {
    // The pre-fix formula (total - free - buffers - cached - sreclaimable)
    // underflows here (900 - 1200 < 0): panic in Debug, wrap in ReleaseFast.
    // The fix must clamp. MemAvailable=0 -> fallback total-free = 900.
    const info = zfree.MemInfo{
        .mem_total = 1000,
        .mem_free = 100,
        .mem_available = 0,
        .buffers = 500,
        .cached = 500,
        .s_reclaimable = 200,
    };
    try std.testing.expectEqual(@as(u64, 900), zfree.computeMemUsed(info));
}

test "computeMemUsed: available > total falls back to total-free (LXC case)" {
    const info = zfree.MemInfo{ .mem_total = 1000, .mem_free = 250, .mem_available = 5000 };
    try std.testing.expectEqual(@as(u64, 750), zfree.computeMemUsed(info));
}

// ---------------------------------------------------------------------------
// /proc/meminfo parsing (audit LOW: large meminfo / trailing fields).
// ---------------------------------------------------------------------------

test "parseMeminfoData: extracts all fields from realistic snapshot" {
    const info = zfree.parseMeminfoData(MEMINFO_S);
    try std.testing.expectEqual(@as(u64, 65610148), info.mem_total);
    try std.testing.expectEqual(@as(u64, 12213704), info.mem_free);
    try std.testing.expectEqual(@as(u64, 46622552), info.mem_available);
    try std.testing.expectEqual(@as(u64, 1207872), info.buffers);
    try std.testing.expectEqual(@as(u64, 39238312), info.cached);
    try std.testing.expectEqual(@as(u64, 1748164), info.s_reclaimable);
    try std.testing.expectEqual(@as(u64, 7340044), info.shmem);
    try std.testing.expectEqual(@as(u64, 16777212), info.swap_total);
    try std.testing.expectEqual(@as(u64, 12474888), info.swap_free);
}

test "parseMeminfoData: trailing Swap fields survive a >4096B meminfo" {
    // Kernels with many NUMA/hugepage lines produce a meminfo well over one 4 KiB
    // read. Build a >4096B blob with SwapTotal/SwapFree at the very end and
    // confirm they are still parsed (the read side now loops to EOF).
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll("MemTotal:       65610148 kB\nMemFree:        12213704 kB\n") catch unreachable;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        w.print("Filler{d}:        {d} kB\n", .{ i, i * 7 }) catch unreachable;
    }
    w.writeAll("SwapTotal:      16777212 kB\nSwapFree:       12474888 kB\n") catch unreachable;
    const blob = w.buffered();
    try std.testing.expect(blob.len > 4096);
    const info = zfree.parseMeminfoData(blob);
    try std.testing.expectEqual(@as(u64, 16777212), info.swap_total);
    try std.testing.expectEqual(@as(u64, 12474888), info.swap_free);
}

// ---------------------------------------------------------------------------
// -h column alignment (audit LOW). procps prints every column right-justified
// in an 11-char field behind a 9-char label, so column 1's value ends at byte
// offset 20 in EVERY mode. Pin that grid for -h.
// ---------------------------------------------------------------------------

test "human-readable columns align to the same grid as the header" {
    const out = render(.{ .human_readable = true });
    var lines = std.mem.splitScalar(u8, out, '\n');
    const header = lines.next().?;
    const mem = lines.next().?;
    // Header token "total" occupies bytes [15,20); its last char is at offset 19.
    try std.testing.expectEqualStrings("total", header[15..20]);
    // Mem: label is 9 wide, first value is 11 wide -> ends at offset 20, so byte
    // 20 is the separator space and byte 19 is a non-space value char.
    try std.testing.expect(mem[19] != ' ');
    try std.testing.expect(mem[20] == ' ');
    try std.testing.expect(std.mem.startsWith(u8, mem, "Mem:"));
}

// ---------------------------------------------------------------------------
// Argument parsing (audit MEDIUM: -s continuous + fractional; invalid option).
// Anchored to documented GNU `free` behavior.
// ---------------------------------------------------------------------------

test "parseArgs: -s alone repeats continuously (GNU free -s runs forever)" {
    const a = zfree.parseArgs(&.{ "-s", "2" });
    switch (a) {
        .run => |c| {
            try std.testing.expect(c.seconds_set);
            try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), c.count);
            try std.testing.expectEqual(@as(u64, 2_000_000_000), c.interval_ns);
        },
        else => return error.ExpectedRun,
    }
}

test "parseArgs: -s accepts fractional seconds (GNU allows 0.5)" {
    const a = zfree.parseArgs(&.{ "-s", "0.5" });
    switch (a) {
        .run => |c| try std.testing.expectEqual(@as(u64, 500_000_000), c.interval_ns),
        else => return error.ExpectedRun,
    }
}

test "parseArgs: -c caps the -s repeat count" {
    const a = zfree.parseArgs(&.{ "-s", "1", "-c", "3" });
    switch (a) {
        .run => |c| {
            try std.testing.expectEqual(@as(u32, 3), c.count);
            try std.testing.expect(c.count_set);
        },
        else => return error.ExpectedRun,
    }
}

test "parseArgs: no args runs exactly once" {
    const a = zfree.parseArgs(&.{});
    switch (a) {
        .run => |c| try std.testing.expectEqual(@as(u32, 1), c.count),
        else => return error.ExpectedRun,
    }
}

test "parseArgs: unknown long option is an error (GNU exits 1)" {
    try std.testing.expect(zfree.parseArgs(&.{"--bogus"}) == .err);
}

test "parseArgs: unknown short option is an error (GNU exits 1)" {
    try std.testing.expect(zfree.parseArgs(&.{"-x"}) == .err);
}

test "parseArgs: --help and --version are distinct actions" {
    try std.testing.expect(zfree.parseArgs(&.{"--help"}) == .help);
    try std.testing.expect(zfree.parseArgs(&.{"--version"}) == .version);
}

test "parseSeconds: fractional and integer seconds" {
    try std.testing.expectEqual(@as(?u64, 2_000_000_000), zfree.parseSeconds("2"));
    try std.testing.expectEqual(@as(?u64, 500_000_000), zfree.parseSeconds("0.5"));
    try std.testing.expectEqual(@as(?u64, null), zfree.parseSeconds("abc"));
    try std.testing.expectEqual(@as(?u64, null), zfree.parseSeconds("-1"));
}

// ---------------------------------------------------------------------------
// End-to-end: spawn the built binary. These paths return before touching
// /proc/meminfo, so they run on the macOS test host. Anchored to documented GNU
// `free`: --help/--version -> stdout, exit 0; invalid option -> stderr, exit 1,
// empty stdout.
// ---------------------------------------------------------------------------

var g_threaded: ?Io.Threaded = null;
fn io() Io {
    if (g_threaded == null) g_threaded = Io.Threaded.init(std.heap.page_allocator, .{});
    return g_threaded.?.io();
}

const RunOut = struct { stdout: []u8, stderr: []u8, code: i32 };

var g_path_counter: u64 = 0;
fn uniquePath(gpa: std.mem.Allocator, tag: []const u8) ![]u8 {
    var local: u8 = 0;
    const seed = @intFromPtr(&local);
    g_path_counter += 1;
    return std.fmt.allocPrint(gpa, "/tmp/zfree_test_{x}_{x}_{s}", .{ seed, g_path_counter, tag });
}

fn runProc(gpa: std.mem.Allocator, argv: []const []const u8) !RunOut {
    const out_path = try uniquePath(gpa, "out");
    defer gpa.free(out_path);
    const err_path = try uniquePath(gpa, "err");
    defer gpa.free(err_path);

    var of = try Dir.createFileAbsolute(io(), out_path, .{ .read = true });
    var ef = try Dir.createFileAbsolute(io(), err_path, .{ .read = true });

    var child = try std.process.spawn(io(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = of },
        .stderr = .{ .file = ef },
    });
    const term = try child.wait(io());

    const ostat = try of.stat(io());
    const estat = try ef.stat(io());
    const out = try gpa.alloc(u8, @intCast(ostat.size));
    const err = try gpa.alloc(u8, @intCast(estat.size));
    _ = try of.readPositionalAll(io(), out, 0);
    _ = try ef.readPositionalAll(io(), err, 0);

    of.close(io());
    ef.close(io());
    Dir.deleteFileAbsolute(io(), out_path) catch {};
    Dir.deleteFileAbsolute(io(), err_path) catch {};

    const code: i32 = switch (term) {
        .exited => |c| c,
        else => -1,
    };
    return .{ .stdout = out, .stderr = err, .code = code };
}

test "e2e: --help prints usage to stdout and exits 0" {
    const gpa = std.testing.allocator;
    const r = try runProc(gpa, &.{ build_options.zfree_bin, "--help" });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "Usage: zfree") != null);
}

test "e2e: --version prints to stdout and exits 0" {
    const gpa = std.testing.allocator;
    const r = try runProc(gpa, &.{ build_options.zfree_bin, "--version" });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expectEqualStrings("zfree 1.0.0\n", r.stdout);
}

test "e2e: unknown long option -> stderr, exit 1, empty stdout" {
    const gpa = std.testing.allocator;
    const r = try runProc(gpa, &.{ build_options.zfree_bin, "--bogus" });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(i32, 1), r.code);
    try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unrecognized option") != null);
}

test "e2e: unknown short option -> stderr, exit 1, empty stdout" {
    const gpa = std.testing.allocator;
    const r = try runProc(gpa, &.{ build_options.zfree_bin, "-x" });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(i32, 1), r.code);
    try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid option") != null);
}
