//! Externally-anchored tests for zclip (zcopy / zpaste).
//!
//! `clip` is NOT a GNU coreutils utility, so there is no `gclip` binary to diff
//! against. Per zig-forge/CLAUDE.md the anchor is therefore:
//!
//!   1. The DOCUMENTED command-line syntax of the real backends this tool drives
//!      (xclip(1), xsel(1x), wl-copy/wl-paste(1), pbcopy/pbpaste(1)). The exact
//!      argv we hand to `spawn` is asserted byte-for-byte against those manuals.
//!   2. The REAL macOS system pasteboard: on a host that has Apple's pbcopy and
//!      pbpaste, we push bytes through pbcopy and pull them back through pbpaste
//!      (two independent Apple binaries, not our own code) and require the round
//!      to survive intact. This is a genuine external oracle, not a self-roundtrip
//!      of zclip's own encode/decode.
//!   3. A FAKE backend (a POSIX `sh`/`cat` pipeline whose output we inspect on
//!      disk) so the copy() write-path and paste() read/exit-status paths are
//!      exercised with literal expected bytes written into the test — including a
//!      >64 KiB payload that forces the partial-write loop, which is exactly the
//!      truncation bug the audit flagged (clipboard.zig:144).
//!   4. The tool's own documented CLI contract for --version / unknown-option
//!      exit codes, checked by running the built binaries.
//!
//! None of these are roundtrip-only against zclip itself; each compares zclip's
//! behaviour to bytes or exit codes that zclip did not author.

const std = @import("std");
const posix = std.posix;
const libc = std.c;
const clipboard = @import("clipboard");
const build_options = @import("build_options");

const testing = std.testing;

/// A Threaded Io backed by a real allocator, carrying the real process environ
/// so spawned children inherit PATH (the built zcopy/zpaste need it to locate
/// pbcopy/pbpaste). `global_single_threaded` uses a failing allocator, so spawn
/// OOMs there; tests need a working one.
fn testIo(threaded: *std.Io.Threaded) std.Io {
    var n: usize = 0;
    while (libc.environ[n] != null) : (n += 1) {}
    const slice: [:null]const ?[*:0]const u8 = @ptrCast(libc.environ[0..n :null]);
    const environ: std.process.Environ = .{ .block = .{ .slice = slice } };
    threaded.* = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = environ });
    return threaded.io();
}

fn fileExists(path: [*:0]const u8) bool {
    return libc.access(path, posix.F_OK) == 0;
}

// ===========================================================================
// (1) Command-table argv is exactly what the backend manuals document.
// ===========================================================================

test "copy argv matches documented backend syntax" {
    // xclip(1): `xclip -selection {clipboard|primary} -i` reads stdin.
    try expectArgv(clipboard.getCopyCommand(.x11_xclip, .clipboard), &.{ "xclip", "-selection", "clipboard", "-i" });
    try expectArgv(clipboard.getCopyCommand(.x11_xclip, .primary), &.{ "xclip", "-selection", "primary", "-i" });
    // xsel(1x): `xsel --clipboard --input` / `--primary --input`.
    try expectArgv(clipboard.getCopyCommand(.x11_xsel, .clipboard), &.{ "xsel", "--clipboard", "--input" });
    try expectArgv(clipboard.getCopyCommand(.x11_xsel, .primary), &.{ "xsel", "--primary", "--input" });
    // wl-copy(1): default selection is CLIPBOARD; `--primary` targets PRIMARY.
    // `--` terminates option parsing so payloads beginning with `-` are literal.
    try expectArgv(clipboard.getCopyCommand(.wayland, .clipboard), &.{ "wl-copy", "--" });
    try expectArgv(clipboard.getCopyCommand(.wayland, .primary), &.{ "wl-copy", "--primary", "--" });
    // pbcopy(1) reads stdin into the single macOS pasteboard.
    try expectArgv(clipboard.getCopyCommand(.macos_pb, .clipboard), &.{"pbcopy"});
    try expectArgv(clipboard.getCopyCommand(.macos_pb, .primary), &.{"pbcopy"});
    // No backend -> no command.
    try testing.expect(clipboard.getCopyCommand(.none, .clipboard) == null);
}

test "paste argv matches documented backend syntax" {
    // xclip(1): `-o` writes the selection to stdout.
    try expectArgv(clipboard.getPasteCommand(.x11_xclip, .clipboard), &.{ "xclip", "-selection", "clipboard", "-o" });
    try expectArgv(clipboard.getPasteCommand(.x11_xclip, .primary), &.{ "xclip", "-selection", "primary", "-o" });
    // xsel(1x): `--output`.
    try expectArgv(clipboard.getPasteCommand(.x11_xsel, .clipboard), &.{ "xsel", "--clipboard", "--output" });
    try expectArgv(clipboard.getPasteCommand(.x11_xsel, .primary), &.{ "xsel", "--primary", "--output" });
    // wl-paste(1).
    try expectArgv(clipboard.getPasteCommand(.wayland, .clipboard), &.{"wl-paste"});
    try expectArgv(clipboard.getPasteCommand(.wayland, .primary), &.{ "wl-paste", "--primary" });
    // pbpaste(1).
    try expectArgv(clipboard.getPasteCommand(.macos_pb, .clipboard), &.{"pbpaste"});
    try testing.expect(clipboard.getPasteCommand(.none, .clipboard) == null);
}

fn expectArgv(actual: ?[]const []const u8, expected: []const []const u8) !void {
    try testing.expect(actual != null);
    const a = actual.?;
    try testing.expectEqual(expected.len, a.len);
    for (expected, a) |e, g| try testing.expectEqualStrings(e, g);
}

// ===========================================================================
// (3) Fake-backend data path: write-loop, read-loop, exit-status.
// ===========================================================================

test "copyToCommand delivers the complete payload (no truncation)" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    // Unique temp path; the backend `cat > path` materialises whatever bytes our
    // write-path actually delivered. A THIRD process (/bin/cat) then reads that
    // file back, so the on-disk bytes are the external oracle.
    // pid is unique to this test process; there is a single copy-path test.
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "/tmp/zclip_copy_{d}.bin", .{libc.getpid()}, 0);
    defer testing.allocator.free(path);
    defer _ = libc.unlink(path.ptr);

    // Payload larger than a pipe's kernel buffer (~64 KiB) so a single write()
    // returns short and the partial-write loop must run. The pre-fix code that
    // ignored write()'s return value truncated exactly here.
    const N = 200_000;
    const payload = try testing.allocator.alloc(u8, N);
    defer testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i % 251); // non-trivial, non-newline pattern

    const script = try std.fmt.allocPrint(testing.allocator, "cat > '{s}'", .{path});
    defer testing.allocator.free(script);
    const copy_cmd = [_][]const u8{ "/bin/sh", "-c", script };
    try clipboard.copyToCommand(io, payload, &copy_cmd);

    const read_cmd = [_][]const u8{ "/bin/cat", path };
    const got = try clipboard.pasteFromCommand(io, testing.allocator, &read_cmd);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, N), got.len);
    try testing.expectEqualSlices(u8, payload, got);
}

test "pasteFromCommand returns the backend's exact stdout bytes" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    // The backend (`printf`, whose escape expansion we do not control) emits
    // these exact bytes; our read-loop must reproduce them verbatim.
    const expected = "Grillparzer\ttab\nand newline";
    const cmd = [_][]const u8{ "/bin/sh", "-c", "printf 'Grillparzer\\ttab\\nand newline'" };
    const got = try clipboard.pasteFromCommand(io, testing.allocator, &cmd);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "pasteFromCommand drains a large multi-read stream intact" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    // 200 KiB of NULs from dd/dev-zero: forces the read-loop to iterate many
    // 4 KiB reads. A read()<=0-means-EOF bug (the pre-fix clipboard.zig:175)
    // would truncate this; here we require the full length back.
    const N = 200_000;
    const cmd = [_][]const u8{ "/bin/dd", "if=/dev/zero", "bs=1000", "count=200", "status=none" };
    const got = try clipboard.pasteFromCommand(io, testing.allocator, &cmd);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, N), got.len);
    for (got) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "pasteFromCommand surfaces a non-zero backend exit as BackendFailed" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    // Mirrors `xclip -o` returning non-zero when the selection is unavailable:
    // an empty/partial read must NOT be reported as a successful paste.
    const cmd = [_][]const u8{ "/bin/sh", "-c", "exit 3" };
    try testing.expectError(error.BackendFailed, clipboard.pasteFromCommand(io, testing.allocator, &cmd));
}

test "copyToCommand surfaces a non-zero backend exit as BackendFailed" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    const cmd = [_][]const u8{ "/bin/sh", "-c", "cat >/dev/null; exit 4" };
    try testing.expectError(error.BackendFailed, clipboard.copyToCommand(io, "anything", &cmd));
}

// ===========================================================================
// (2) Real macOS pasteboard oracle: pbcopy in, pbpaste out.
// ===========================================================================

test "macOS pbcopy/pbpaste roundtrip preserves bytes" {
    if (!fileExists("/usr/bin/pbcopy") or !fileExists("/usr/bin/pbpaste")) {
        return error.SkipZigTest; // not macOS / no system pasteboard
    }
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    const payload = "zclip anchor \xE2\x9C\x93 unicode + binary \x00\x01\x02 end";
    const copy_cmd = [_][]const u8{"/usr/bin/pbcopy"};
    try clipboard.copyToCommand(io, payload, &copy_cmd);

    const paste_cmd = [_][]const u8{"/usr/bin/pbpaste"};
    const got = try clipboard.pasteFromCommand(io, testing.allocator, &paste_cmd);
    defer testing.allocator.free(got);
    // pbcopy/pbpaste is a faithful byte pipe for these bytes.
    try testing.expectEqualStrings(payload, got);
}

// ===========================================================================
// (4) CLI contract of the built binaries: version + exit codes + strip flag.
// ===========================================================================

fn binPath(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ build_options.bin_dir, name });
}

const RunResult = struct { stdout: []u8, term: std.process.Child.Term };

fn runBin(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8, stdin_data: ?[]const u8) !RunResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin_data != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    if (stdin_data) |d| {
        if (child.stdin) |s| {
            _ = std.c.write(s.handle, d.ptr, d.len);
            _ = std.c.close(s.handle);
            child.stdin = null;
        }
    }
    var out = std.ArrayListUnmanaged(u8).empty;
    if (child.stdout) |so| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(so.handle, &buf, buf.len);
            if (n <= 0) break;
            try out.appendSlice(alloc, buf[0..@intCast(n)]);
        }
        _ = std.c.close(so.handle);
        child.stdout = null;
    }
    const term = try child.wait(io);
    return .{ .stdout = try out.toOwnedSlice(alloc), .term = term };
}

test "zcopy --version prints documented string and exits 0" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    const path = try binPath(testing.allocator, "zcopy");
    defer testing.allocator.free(path);
    const r = try runBin(io, testing.allocator, &.{ path, "--version" }, null);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqualStrings("zcopy 1.0.0\n", r.stdout);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
}

test "zpaste --version prints documented string and exits 0" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    const path = try binPath(testing.allocator, "zpaste");
    defer testing.allocator.free(path);
    const r = try runBin(io, testing.allocator, &.{ path, "--version" }, null);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqualStrings("zpaste 1.0.0\n", r.stdout);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
}

test "zcopy rejects an unknown option with exit 1" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    const path = try binPath(testing.allocator, "zcopy");
    defer testing.allocator.free(path);
    const r = try runBin(io, testing.allocator, &.{ path, "--bogus" }, null);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, r.term);
}

test "zpaste rejects an unknown option with exit 1" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    const path = try binPath(testing.allocator, "zpaste");
    defer testing.allocator.free(path);
    const r = try runBin(io, testing.allocator, &.{ path, "--bogus" }, null);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, r.term);
}

test "zcopy | zpaste roundtrip through the real system clipboard" {
    if (!fileExists("/usr/bin/pbcopy")) return error.SkipZigTest;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    const zcopy = try binPath(testing.allocator, "zcopy");
    defer testing.allocator.free(zcopy);
    const zpaste = try binPath(testing.allocator, "zpaste");
    defer testing.allocator.free(zpaste);

    // -n strips the trailing newline on copy; zpaste re-adds one on output.
    const cp = try runBin(io, testing.allocator, &.{ zcopy, "-n" }, "the quick brown fox\n");
    defer testing.allocator.free(cp.stdout);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, cp.term);

    const ps = try runBin(io, testing.allocator, &.{zpaste}, null);
    defer testing.allocator.free(ps.stdout);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, ps.term);
    // Clipboard holds "the quick brown fox" (newline stripped); zpaste adds "\n".
    try testing.expectEqualStrings("the quick brown fox\n", ps.stdout);
}
