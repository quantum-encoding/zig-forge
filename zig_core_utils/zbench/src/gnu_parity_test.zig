// External-anchor tests for zbench.
//
// `bench` is NOT a GNU coreutil — no such reference binary exists (see the
// audit's gnu_gaps). zbench is a hyperfine-style benchmarking clone, so these
// tests anchor to two external sources the library author did not author:
//
//   1. hyperfine's DOCUMENTED behavior for process exit codes:
//      "If any of the commands failed, hyperfine will return a non-zero exit
//       code" (hyperfine README / --ignore-failure docs, sharkdp/hyperfine).
//      https://github.com/sharkdp/hyperfine#exit-codes
//
//   2. RFC 8259 (The JavaScript Object Notation Data Interchange Format) §7,
//      which mandates that `"` and `\` inside a string be escaped as `\"` and
//      `\\`. The expected escaped bytes are written literally below, and the
//      exported file is round-tripped through std.json — an INDEPENDENT parser
//      the export code did not construct — so a valid parse recovering the
//      original command is an external witness, not a self-consistency check.
//
// These shell out to the compiled zbench binary (path injected by build.zig via
// the `build_options` module) and compare its real observable behavior to the
// anchors above. They run under `zig build test`.

const std = @import("std");
const build_options = @import("build_options");

const exe_path: []const u8 = build_options.zbench_exe;

// The global single-threaded I/O instance ships a `.failing` allocator, which is
// fine for the file reads below (they take an explicit gpa) but not for
// processSpawn, which allocates the argv vector via the I/O allocator. File ops
// use this; process spawning builds its own Threaded io over the test allocator.
const io = std.Io.Threaded.global_single_threaded.io();

const Run = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn free(self: *Run, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn runZbench(gpa: std.mem.Allocator, extra: []const []const u8) !Run {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, exe_path);
    for (extra) |a| try argv.append(gpa, a);

    // A real allocator is required to back processSpawn (the .failing global
    // allocator can't). The child zbench is spawned by absolute path and the
    // commands it forks are shell builtins (true/false/echo), so an empty child
    // environment is sufficient.
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const spawn_io = threaded.io();

    const r = try std.process.run(gpa, spawn_io, .{ .argv = argv.items });
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

// ANCHOR 1a: hyperfine returns non-zero when a benchmarked command fails.
// `false` exits 1 every run, so zbench must exit non-zero (and cleanly — a
// clean `.exited` term, never a signal).
test "exit code: failing command yields non-zero exit (hyperfine parity)" {
    const gpa = std.testing.allocator;
    var r = try runZbench(gpa, &.{ "-w", "0", "-r", "1", "false" });
    defer r.free(gpa);

    try std.testing.expect(r.term == .exited);
    try std.testing.expect(r.term.exited != 0);
}

// ANCHOR 1b: a successful command yields exit 0.
test "exit code: successful command yields zero exit (hyperfine parity)" {
    const gpa = std.testing.allocator;
    var r = try runZbench(gpa, &.{ "-w", "0", "-r", "1", "true" });
    defer r.free(gpa);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
}

// ANCHOR: invalid `-r 0` must be rejected with a CLEAN non-zero exit, not a
// division-by-zero panic. A Zig panic aborts the process with a signal, so
// asserting the term is `.exited` (not `.signal`) is what proves the bug is
// fixed. Before the fix this run aborted with SIGABRT/SIGILL.
test "invalid --runs 0 rejected cleanly, not a panic" {
    const gpa = std.testing.allocator;
    var r = try runZbench(gpa, &.{ "-r", "0", "echo hi" });
    defer r.free(gpa);

    try std.testing.expect(r.term == .exited); // no signal => no panic/abort
    try std.testing.expect(r.term.exited != 0); // rejected, not accepted
}

// ANCHOR 2: JSON export escapes the caller-controlled command per RFC 8259 §7.
// The command bytes are:  echo "a\b   (a double-quote before `a`, a backslash
// before `b`). RFC 8259 requires `"`->`\"` and `\`->`\\`, so the emitted JSON
// string must be exactly  "echo \"a\\b"  — written literally below. We also
// parse the whole file with std.json (independent parser) and confirm it both
// parses AND recovers the original command byte-for-byte. Before the fix the
// raw `{s}` interpolation produced  "command": "echo "a\b"  which no parser
// accepts.
test "JSON export escapes command per RFC 8259 and parses back" {
    const gpa = std.testing.allocator;

    const out_name = "zbench_parity_export.json";
    const command = "echo \"a\\b"; // bytes: echo "a\b

    var r = try runZbench(gpa, &.{ "-w", "0", "-r", "1", command, "--export-json", out_name });
    defer r.free(gpa);
    defer std.Io.Dir.cwd().deleteFile(io, out_name) catch {};

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, out_name, gpa, .limited(1 << 20));
    defer gpa.free(bytes);

    // Literal RFC-8259-escaped form must appear verbatim.
    const expected_field = "\"command\": \"echo \\\"a\\\\b\"";
    try std.testing.expect(std.mem.indexOf(u8, bytes, expected_field) != null);

    // Independent parser must accept the whole document and recover the command.
    const Parsed = struct {
        results: []struct {
            command: []const u8,
            runs: u32,
        },
    };
    const parsed = try std.json.parseFromSlice(Parsed, gpa, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.results.len == 1);
    try std.testing.expectEqualStrings(command, parsed.value.results[0].command);
}

// ANCHOR: a command longer than the internal 4 KiB exec buffer makes every run
// error, leaving an EMPTY results set. Markdown export used to index results[0]
// unconditionally and panic (index-out-of-bounds). It must instead exit cleanly.
test "markdown export with all-failed benchmarks does not panic" {
    const gpa = std.testing.allocator;

    const big = "echo " ++ ("x" ** 5000);
    const out_name = "zbench_parity_export.md";

    var r = try runZbench(gpa, &.{ "-w", "0", "-r", "1", big, "--export-markdown", out_name });
    defer r.free(gpa);
    defer std.Io.Dir.cwd().deleteFile(io, out_name) catch {};

    // A panic would surface as a signal term; require a clean exit.
    try std.testing.expect(r.term == .exited);
}
