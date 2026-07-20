//! Externally-anchored parity tests for znproc.
//!
//! ANCHOR 1 (live, strongest): every "diff" test below runs znproc AND the real
//! GNU coreutils `nproc` binary with identical argv + environment and asserts
//! byte-identical stdout and identical exit status. The expected output is
//! produced by GNU's own binary at test time — an input the znproc author did
//! not write (repo golden rule §1). When no GNU binary is present (e.g. a Linux
//! box without coreutils under a discoverable name) the live diffs self-skip and
//! only the literal anchors below run.
//!
//! ANCHOR 2 (literal, deterministic): several behaviours are independent of the
//! host's CPU count and are asserted against bytes copied from the documented
//! GNU/gnulib contract, cited inline:
//!   - `nproc = nproc <= ignore ? 1 : nproc - ignore`  (coreutils src/nproc.c)
//!   - OMP_NUM_THREADS overrides, OMP_THREAD_LIMIT caps  (gnulib lib/nproc.c,
//!     num_processors NPROC_CURRENT_OVERRIDABLE)
//!   - unknown option / extra operand -> stderr diagnostic + exit 1
//! These hold on any machine with >= 2 logical CPUs (asserted first).
//!
//! No roundtrip-only tests: nothing here compares znproc against itself.

const std = @import("std");
const build_options = @import("build_options");

const ZNPROC = build_options.znproc_bin;

const io = std.testing.io;
const gpa = std.testing.allocator;

const EnvPair = struct { []const u8, []const u8 };

const Result = struct {
    stdout: []u8,
    stderr: []u8,
    code: ?u8, // exit code, or null if killed by a signal

    fn deinit(self: *Result) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Run `bin` with `args` and an environment consisting ONLY of `env` (so the
/// ambient shell's OMP_* variables can never perturb a case). argv[0] = bin.
fn run(bin: []const u8, args: []const []const u8, env: []const EnvPair) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, args);

    var map = std.process.Environ.Map.init(gpa);
    defer map.deinit();
    for (env) |kv| try map.put(kv[0], kv[1]);

    const rr = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = &map,
    });
    return .{
        .stdout = rr.stdout,
        .stderr = rr.stderr,
        .code = switch (rr.term) {
            .exited => |c| c,
            else => null,
        },
    };
}

var gnu_cache: ?[]const u8 = null;
var gnu_probed = false;

/// Locate a GNU coreutils nproc binary, or null if none is runnable.
fn findGnu() ?[]const u8 {
    if (gnu_probed) return gnu_cache;
    gnu_probed = true;
    const candidates = [_][]const u8{
        "/opt/homebrew/bin/gnproc",
        "/opt/homebrew/opt/coreutils/libexec/gnubin/nproc",
        "/usr/local/bin/gnproc",
        "/usr/bin/nproc",
        "/bin/nproc",
    };
    for (candidates) |cand| {
        var r = run(cand, &.{}, &.{}) catch continue;
        defer r.deinit();
        // A real nproc prints a positive integer + newline on exit 0.
        if (r.code == 0 and r.stdout.len >= 2 and r.stdout[0] >= '1' and r.stdout[0] <= '9') {
            gnu_cache = cand;
            return cand;
        }
    }
    return null;
}

/// Assert znproc and GNU nproc agree on stdout AND exit code for `args`/`env`.
fn expectSameAsGnu(args: []const []const u8, env: []const EnvPair) !void {
    const gnu = findGnu() orelse return; // self-skip when no external anchor present

    var zr = try run(ZNPROC, args, env);
    defer zr.deinit();
    var gr = try run(gnu, args, env);
    defer gr.deinit();

    std.testing.expectEqualStrings(gr.stdout, zr.stdout) catch |e| {
        std.debug.print("mismatch args={any} env={any}\n  gnu   stdout={s} code={?}\n  znproc stdout={s} code={?}\n", .{ args, env, gr.stdout, gr.code, zr.stdout, zr.code });
        return e;
    };
    try std.testing.expectEqual(gr.code, zr.code);
}

fn hostCpus() !usize {
    return std.Thread.getCpuCount();
}

// --- Live diffs against the real GNU binary (external anchor) -----------------

test "parity: default count matches GNU nproc" {
    try expectSameAsGnu(&.{}, &.{});
}

test "parity: --all matches GNU nproc" {
    try expectSameAsGnu(&.{"--all"}, &.{});
}

test "parity: --ignore=2 matches GNU nproc" {
    try expectSameAsGnu(&.{"--ignore=2"}, &.{});
}

test "parity: --ignore 2 (separate arg) matches GNU nproc" {
    try expectSameAsGnu(&.{ "--ignore", "2" }, &.{});
}

test "parity: --ignore=2 --all matches GNU nproc" {
    try expectSameAsGnu(&.{ "--ignore=2", "--all" }, &.{});
}

test "parity: abbreviated --ig=2 matches GNU nproc" {
    try expectSameAsGnu(&.{"--ig=2"}, &.{});
}

test "parity: '--' end-of-options matches GNU nproc" {
    try expectSameAsGnu(&.{"--"}, &.{});
}

test "parity: OMP_NUM_THREADS override matches GNU nproc" {
    try expectSameAsGnu(&.{}, &.{.{ "OMP_NUM_THREADS", "3" }});
}

test "parity: OMP_THREAD_LIMIT cap matches GNU nproc" {
    try expectSameAsGnu(&.{}, &.{.{ "OMP_THREAD_LIMIT", "2" }});
}

test "parity: OMP_NUM_THREADS + OMP_THREAD_LIMIT matches GNU nproc" {
    try expectSameAsGnu(&.{}, &.{ .{ "OMP_NUM_THREADS", "3" }, .{ "OMP_THREAD_LIMIT", "2" } });
}

test "parity: OMP_NUM_THREADS comma-list uses first field, matches GNU nproc" {
    try expectSameAsGnu(&.{}, &.{.{ "OMP_NUM_THREADS", "2,4,8" }});
}

test "parity: OMP_NUM_THREADS=0 treated as unset, matches GNU nproc" {
    try expectSameAsGnu(&.{}, &.{.{ "OMP_NUM_THREADS", "0" }});
}

test "parity: OMP does not affect --all, matches GNU nproc" {
    try expectSameAsGnu(&.{"--all"}, &.{.{ "OMP_NUM_THREADS", "3" }});
}

test "parity: unknown option exit status matches GNU nproc" {
    try expectSameAsGnu(&.{"--bogus"}, &.{});
}

test "parity: extra operand exit status matches GNU nproc" {
    try expectSameAsGnu(&.{"foo"}, &.{});
}

// --- Literal anchors: documented GNU behaviour, host-independent --------------

test "anchor: --ignore=1000 clamps to 1 (nproc.c: nproc <= ignore ? 1)" {
    // src/nproc.c: `nproc = nproc <= ignore ? 1 : nproc - ignore;`
    var r = try run(ZNPROC, &.{"--ignore=1000"}, &.{});
    defer r.deinit();
    try std.testing.expectEqual(@as(?u8, 0), r.code);
    try std.testing.expectEqualStrings("1\n", r.stdout);
}

test "anchor: OMP_NUM_THREADS=3 prints 3 (gnulib num_processors override)" {
    // gnulib lib/nproc.c: OMP_NUM_THREADS overrides the measured count.
    var r = try run(ZNPROC, &.{}, &.{.{ "OMP_NUM_THREADS", "3" }});
    defer r.deinit();
    try std.testing.expectEqual(@as(?u8, 0), r.code);
    try std.testing.expectEqualStrings("3\n", r.stdout);
}

test "anchor: OMP_NUM_THREADS=3 + OMP_THREAD_LIMIT=2 prints 2 (cap after override)" {
    var r = try run(ZNPROC, &.{}, &.{ .{ "OMP_NUM_THREADS", "3" }, .{ "OMP_THREAD_LIMIT", "2" } });
    defer r.deinit();
    try std.testing.expectEqual(@as(?u8, 0), r.code);
    try std.testing.expectEqualStrings("2\n", r.stdout);
}

test "anchor: OMP_NUM_THREADS=2,4,8 uses first field -> 2 (strtoul semantics)" {
    var r = try run(ZNPROC, &.{}, &.{.{ "OMP_NUM_THREADS", "2,4,8" }});
    defer r.deinit();
    try std.testing.expectEqual(@as(?u8, 0), r.code);
    try std.testing.expectEqualStrings("2\n", r.stdout);
}

test "anchor: OMP_THREAD_LIMIT=2 caps count to 2 (host has >= 2 cpus)" {
    if (try hostCpus() < 2) return error.SkipZigTest;
    var r = try run(ZNPROC, &.{}, &.{.{ "OMP_THREAD_LIMIT", "2" }});
    defer r.deinit();
    try std.testing.expectEqual(@as(?u8, 0), r.code);
    try std.testing.expectEqualStrings("2\n", r.stdout);
}

test "anchor: unknown option -> stderr diagnostic + exit 1, empty stdout" {
    // GNU: `nproc: unrecognized option '--bogus'` to stderr, exit 1.
    var r = try run(ZNPROC, &.{"--bogus"}, &.{});
    defer r.deinit();
    try std.testing.expectEqual(@as(?u8, 1), r.code);
    try std.testing.expectEqualStrings("", r.stdout);
    try std.testing.expect(r.stderr.len > 0);
}

test "anchor: extra operand -> stderr diagnostic + exit 1, empty stdout" {
    // GNU: `nproc: extra operand 'foo'` to stderr, exit 1.
    var r = try run(ZNPROC, &.{"foo"}, &.{});
    defer r.deinit();
    try std.testing.expectEqual(@as(?u8, 1), r.code);
    try std.testing.expectEqualStrings("", r.stdout);
    try std.testing.expect(r.stderr.len > 0);
}

test "anchor: short option -a -> exit 1 (GNU: invalid option -- 'a')" {
    var r = try run(ZNPROC, &.{"-a"}, &.{});
    defer r.deinit();
    try std.testing.expectEqual(@as(?u8, 1), r.code);
    try std.testing.expectEqualStrings("", r.stdout);
}

test "anchor: --help exits 0 with usage on stdout" {
    var r = try run(ZNPROC, &.{"--help"}, &.{});
    defer r.deinit();
    try std.testing.expectEqual(@as(?u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "Usage:") != null);
}

test "anchor: --version exits 0 with a banner on stdout" {
    var r = try run(ZNPROC, &.{"--version"}, &.{});
    defer r.deinit();
    try std.testing.expectEqual(@as(?u8, 0), r.code);
    try std.testing.expect(r.stdout.len > 0);
}

test "anchor: default output is a positive integer + newline, exit 0" {
    // Proves the SIGSYS/portability crash is gone: a crashed process exits via
    // signal (code == null) with empty stdout.
    var r = try run(ZNPROC, &.{}, &.{});
    defer r.deinit();
    try std.testing.expectEqual(@as(?u8, 0), r.code);
    try std.testing.expect(r.stdout.len >= 2);
    try std.testing.expect(r.stdout[0] >= '1' and r.stdout[0] <= '9');
    try std.testing.expectEqual(@as(u8, '\n'), r.stdout[r.stdout.len - 1]);
}
