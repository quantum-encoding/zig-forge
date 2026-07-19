//! Externally-anchored tests for zcp.
//!
//! Anchor: the real GNU coreutils `cp` binary (verified against GNU
//! coreutils 9.10 from Homebrew). Every test sets up two identical
//! sandboxes, runs `zcp ARGS` in one and GNU `cp ARGS` in the other, and
//! compares exit code, stdout, stderr (program-name-normalized), and — where
//! meaningful — a full manifest of the resulting file tree (names, kinds,
//! symlink targets, file contents). This is a true external anchor: none of
//! the expected outputs are produced by zcp itself.
//!
//! If no GNU cp is installed, the tests skip (error.SkipZigTest) rather than
//! silently passing.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;
const Dir = Io.Dir;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/cp",
    "/opt/homebrew/bin/gcp",
    "/usr/local/opt/coreutils/libexec/gnubin/cp",
    "/usr/local/bin/gcp",
    // On Linux, /usr/bin/cp and /bin/cp are GNU coreutils.
    if (builtin.os.tag == .linux) "/usr/bin/cp" else "",
    if (builtin.os.tag == .linux) "/bin/cp" else "",
};

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsize: usize) isize;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;

const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn utimensat(dirfd: c_int, pathname: [*:0]const u8, times: ?*const [2]Timespec, flags: c_int) c_int;
const AT_FDCWD: c_int = if (builtin.os.tag.isDarwin()) -2 else -100;

// Minimal cross-platform stat, mirroring src/main.zig.
const CStat = switch (builtin.os.tag) {
    .linux => extern struct {
        dev: u64, ino: u64, nlink: u64, mode: u32, uid: u32, gid: u32,
        __pad0: u32 = 0, rdev: u64, size: i64, blksize: i64, blocks: i64,
        atim: Timespec, mtim: Timespec, ctim: Timespec,
        __unused: [3]i64 = .{ 0, 0, 0 },
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32, mode: u16, nlink: u16, ino: u64, uid: u32, gid: u32, rdev: i32,
        atim: Timespec, mtim: Timespec, ctim: Timespec, birthtim: Timespec,
        size: i64, blocks: i64, blksize: i32, flags: u32, gen: u32, lspare: i32, qspare: [2]i64,
    },
    else => @compileError("unsupported platform for zcp tests"),
};
extern "c" fn stat(path: [*:0]const u8, buf: *CStat) c_int;

fn findGnuCp() ?[]const u8 {
    for (gnu_candidates) |cand| {
        if (cand.len == 0) continue;
        var buf: [256]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{cand}, 0) catch continue;
        if (access(z.ptr, 1) == 0) return cand; // X_OK
    }
    return null;
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    zcp: []const u8,
    gnu: []const u8,
    sandboxes: std.ArrayListUnmanaged([]const u8) = .empty,

    fn init(gpa: std.mem.Allocator, io: Io) !Ctx {
        const gnu = findGnuCp() orelse return error.SkipZigTest;
        // build_options.zcp_path may be relative to the build root (the cwd
        // the test runner starts in); children run with cwd set to a
        // sandbox, so resolve it to an absolute path up front.
        const zcp_rel = try std.fmt.allocPrintSentinel(gpa, "{s}", .{build_options.zcp_path}, 0);
        var resolved_buf: [4096]u8 = undefined;
        const zcp_abs = realpath(zcp_rel.ptr, &resolved_buf) orelse return error.ZcpBinaryNotFound;
        return .{
            .gpa = gpa,
            .io = io,
            .zcp = try gpa.dupe(u8, std.mem.span(zcp_abs)),
            .gnu = gnu,
        };
    }

    fn makeSandbox(ctx: *Ctx) ![]const u8 {
        const tmp: []const u8 = if (getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
        const sep: []const u8 = if (tmp.len > 0 and tmp[tmp.len - 1] == '/') "" else "/";
        const template = try std.fmt.allocPrintSentinel(ctx.gpa, "{s}{s}zcp_gnu_test.XXXXXX", .{ tmp, sep }, 0);
        const result = mkdtemp(template.ptr) orelse return error.MkdtempFailed;
        const dir = std.mem.span(result);
        try ctx.sandboxes.append(ctx.gpa, dir);
        return dir;
    }

    fn cleanup(ctx: *Ctx) void {
        for (ctx.sandboxes.items) |sb| {
            Dir.cwd().deleteTree(ctx.io, sb) catch {};
        }
        ctx.sandboxes.clearRetainingCapacity();
    }

    fn path(ctx: *Ctx, base: []const u8, rel: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(ctx.gpa, "{s}/{s}", .{ base, rel }, 0);
    }

    // ---- fixture helpers (absolute-path based) ----

    fn writeFile(ctx: *Ctx, base: []const u8, rel: []const u8, contents: []const u8) !void {
        const p = try ctx.path(base, rel);
        const f = try Dir.createFileAbsolute(ctx.io, p, .{});
        defer f.close(ctx.io);
        try f.writeStreamingAll(ctx.io, contents);
    }

    fn makeDir(ctx: *Ctx, base: []const u8, rel: []const u8) !void {
        const p = try ctx.path(base, rel);
        if (mkdir(p.ptr, 0o755) != 0) return error.MkdirFailed;
    }

    fn makeSymlink(ctx: *Ctx, base: []const u8, rel: []const u8, target: []const u8) !void {
        const p = try ctx.path(base, rel);
        const t = try std.fmt.allocPrintSentinel(ctx.gpa, "{s}", .{target}, 0);
        if (symlink(t.ptr, p.ptr) != 0) return error.SymlinkFailed;
    }

    fn setMode(ctx: *Ctx, base: []const u8, rel: []const u8, mode: c_uint) !void {
        const p = try ctx.path(base, rel);
        if (chmod(p.ptr, mode) != 0) return error.ChmodFailed;
    }

    fn setTimes(ctx: *Ctx, base: []const u8, rel: []const u8, sec: i64) !void {
        const p = try ctx.path(base, rel);
        const times: [2]Timespec = .{ .{ .sec = sec, .nsec = 0 }, .{ .sec = sec, .nsec = 0 } };
        if (utimensat(AT_FDCWD, p.ptr, &times, 0) != 0) return error.UtimensatFailed;
    }

    fn mtimeOf(ctx: *Ctx, base: []const u8, rel: []const u8) !Timespec {
        const p = try ctx.path(base, rel);
        var st: CStat = undefined;
        if (stat(p.ptr, &st) != 0) return error.StatFailed;
        return st.mtim;
    }

    // ---- run helpers ----

    const RunResult = struct {
        exit_code: u8,
        stdout: []const u8,
        stderr: []const u8,
    };

    fn runTool(ctx: *Ctx, tool: []const u8, args: []const []const u8, cwd: []const u8) !RunResult {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(ctx.gpa, tool);
        try argv.appendSlice(ctx.gpa, args);

        const result = try std.process.run(ctx.gpa, ctx.io, .{
            .argv = argv.items,
            .cwd = .{ .path = cwd },
        });
        return .{
            .exit_code = switch (result.term) {
                .exited => |code| code,
                else => 255,
            },
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }

    /// Normalize program identity in outputs so "zcp: ...", "gcp: ..." and
    /// "/path/to/gcp: ..." all become "cp: ...".
    fn normalize(ctx: *Ctx, s: []const u8) ![]const u8 {
        const a = try std.mem.replaceOwned(u8, ctx.gpa, s, ctx.gnu, "cp");
        const b = try std.mem.replaceOwned(u8, ctx.gpa, a, ctx.zcp, "cp");
        const c = try std.mem.replaceOwned(u8, ctx.gpa, b, "zcp", "cp");
        return std.mem.replaceOwned(u8, ctx.gpa, c, "gcp", "cp");
    }

    // ---- tree manifest ----

    fn manifest(ctx: *Ctx, base: []const u8) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try ctx.walk(base, "", &out);
        return out.items;
    }

    fn walk(ctx: *Ctx, abs: []const u8, rel: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
        var dir = try Dir.openDirAbsolute(ctx.io, abs, .{ .iterate = true });
        defer dir.close(ctx.io);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var kinds: std.ArrayListUnmanaged(Io.File.Kind) = .empty;
        var iter = dir.iterate();
        while (try iter.next(ctx.io)) |entry| {
            try names.append(ctx.gpa, try ctx.gpa.dupe(u8, entry.name));
            try kinds.append(ctx.gpa, entry.kind);
        }
        // sort by name for determinism (keep kinds aligned)
        var i: usize = 0;
        while (i < names.items.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < names.items.len) : (j += 1) {
                if (std.mem.lessThan(u8, names.items[j], names.items[i])) {
                    std.mem.swap([]const u8, &names.items[i], &names.items[j]);
                    std.mem.swap(Io.File.Kind, &kinds.items[i], &kinds.items[j]);
                }
            }
        }

        for (names.items, kinds.items) |name, kind| {
            const child_rel = if (rel.len == 0)
                try ctx.gpa.dupe(u8, name)
            else
                try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ rel, name });
            const child_abs = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ abs, name });

            switch (kind) {
                .directory => {
                    try out.appendSlice(ctx.gpa, "D ");
                    try out.appendSlice(ctx.gpa, child_rel);
                    try out.append(ctx.gpa, '\n');
                    try ctx.walk(child_abs, child_rel, out);
                },
                .sym_link => {
                    const child_abs_z = try std.fmt.allocPrintSentinel(ctx.gpa, "{s}", .{child_abs}, 0);
                    var buf: [4096]u8 = undefined;
                    const n = readlink(child_abs_z.ptr, &buf, buf.len);
                    const target = if (n >= 0) buf[0..@intCast(n)] else "<unreadable>";
                    try out.appendSlice(ctx.gpa, "L ");
                    try out.appendSlice(ctx.gpa, child_rel);
                    try out.appendSlice(ctx.gpa, " -> ");
                    try out.appendSlice(ctx.gpa, target);
                    try out.append(ctx.gpa, '\n');
                },
                else => {
                    try out.appendSlice(ctx.gpa, "F ");
                    try out.appendSlice(ctx.gpa, child_rel);
                    try out.appendSlice(ctx.gpa, " ");
                    if (Dir.openFileAbsolute(ctx.io, child_abs, .{})) |f| {
                        defer f.close(ctx.io);
                        var rbuf: [4096]u8 = undefined;
                        var reader = f.reader(ctx.io, &rbuf);
                        const contents = reader.interface.allocRemaining(ctx.gpa, .limited(1024 * 1024)) catch "<readerror>";
                        try out.appendSlice(ctx.gpa, contents);
                    } else |_| {
                        try out.appendSlice(ctx.gpa, "<unreadable>");
                    }
                    try out.append(ctx.gpa, '\n');
                },
            }
        }
    }
};

const CompareOptions = struct {
    /// Compare the resulting file trees of the two sandboxes.
    check_tree: bool = true,
};

/// Run `zcp args` and GNU `cp args` in identical sandboxes and require
/// identical exit code, stdout, stderr, and (optionally) resulting tree.
/// Returns the two sandbox roots for extra per-test assertions.
fn compareCase(
    ctx: *Ctx,
    setup: *const fn (ctx: *Ctx, base: []const u8) anyerror!void,
    args: []const []const u8,
    opts: CompareOptions,
) !struct { z: []const u8, g: []const u8 } {
    const sb_z = try ctx.makeSandbox();
    const sb_g = try ctx.makeSandbox();
    try setup(ctx, sb_z);
    try setup(ctx, sb_g);

    const rz = try ctx.runTool(ctx.zcp, args, sb_z);
    const rg = try ctx.runTool(ctx.gnu, args, sb_g);

    try std.testing.expectEqual(rg.exit_code, rz.exit_code);
    try std.testing.expectEqualStrings(try ctx.normalize(rg.stdout), try ctx.normalize(rz.stdout));
    try std.testing.expectEqualStrings(try ctx.normalize(rg.stderr), try ctx.normalize(rz.stderr));

    if (opts.check_tree) {
        try std.testing.expectEqualStrings(try ctx.manifest(sb_g), try ctx.manifest(sb_z));
    }
    return .{ .z = sb_z, .g = sb_g };
}

fn withCtx(body: *const fn (ctx: *Ctx) anyerror!void) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // global_single_threaded has a failing allocator and cannot spawn
    // processes; build a real Io.Threaded instance for the child spawns.
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    var ctx = try Ctx.init(arena_state.allocator(), threaded.io());
    defer ctx.cleanup();
    try body(&ctx);
}

// ---------------------------------------------------------------------------
// basic copies
// ---------------------------------------------------------------------------

fn setupOneFile(ctx: *Ctx, base: []const u8) !void {
    try ctx.writeFile(base, "a", "hello zcp\n");
}

test "basic file copy matches GNU (content, exit, silence)" {
    try withCtx(&struct {
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setupOneFile, &.{ "a", "b" }, .{});
        }
    }.body);
}

test "-v verbose output format matches GNU" {
    try withCtx(&struct {
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setupOneFile, &.{ "-v", "a", "b" }, .{});
        }
    }.body);
}

test "copy into existing directory matches GNU" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "into dir\n");
            try ctx.makeDir(base, "d");
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "a", "d" }, .{});
        }
    }.body);
}

// ---------------------------------------------------------------------------
// same-file protection (the audit's critical finding: `zcp a a` used to
// truncate the source to zero bytes)
// ---------------------------------------------------------------------------

test "cp a a refuses and does NOT truncate the source (GNU: same file, exit 1)" {
    try withCtx(&struct {
        fn body(ctx: *Ctx) !void {
            const r = try compareCase(ctx, &setupOneFile, &.{ "a", "a" }, .{});
            // Belt and braces: the source must still have its bytes.
            const m = try ctx.manifest(r.z);
            try std.testing.expectEqualStrings("F a hello zcp\n\n", m);
        }
    }.body);
}

test "cp onto a hardlink of the source refuses like GNU" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "linked\n");
            const pa = try ctx.path(base, "a");
            const ph = try ctx.path(base, "h");
            try std.testing.expectEqual(@as(c_int, 0), std.c.link(pa.ptr, ph.ptr));
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "a", "h" }, .{});
        }
    }.body);
}

test "cp onto a symlink to the source refuses like GNU" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "target\n");
            try ctx.makeSymlink(base, "la", "a");
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "a", "la" }, .{});
        }
    }.body);
}

test "-n with same file stays silent and exits 0 like GNU" {
    try withCtx(&struct {
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setupOneFile, &.{ "-n", "a", "a" }, .{});
        }
    }.body);
}

// ---------------------------------------------------------------------------
// dir-into-itself protection (audit high: used to recurse until
// ENAMETOOLONG, littering ~170 nested directories)
// ---------------------------------------------------------------------------

test "cp -r self self/copy refuses like GNU and does not run away" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.makeDir(base, "self");
            try ctx.writeFile(base, "self/f", "x\n");
        }
        fn body(ctx: *Ctx) !void {
            // Tree compare included: GNU copies one level then refuses when
            // it re-encounters the new directory; zcp matches that behavior.
            const r = try compareCase(ctx, &setup, &.{ "-r", "self", "self/copy" }, .{});
            // No runaway nesting: self/copy/copy must not exist.
            const p = try ctx.path(r.z, "self/copy/copy");
            try std.testing.expect(access(p.ptr, 0) != 0);
        }
    }.body);
}

test "cp -r a a (dest exists) refuses like GNU" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.makeDir(base, "aa");
            try ctx.writeFile(base, "aa/q", "q\n");
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "-r", "aa", "aa" }, .{});
        }
    }.body);
}

// ---------------------------------------------------------------------------
// symlink handling in recursive copies (audit high: symlinks were
// dereferenced; a symlink-to-dir produced a stray empty file + error)
// ---------------------------------------------------------------------------

fn setupSymlinkTree(ctx: *Ctx, base: []const u8) !void {
    try ctx.makeDir(base, "tree");
    try ctx.writeFile(base, "tree/file", "data\n");
    try ctx.makeSymlink(base, "tree/link", "file");
    try ctx.makeSymlink(base, "tree/dirlink", ".");
    try ctx.makeSymlink(base, "tree/dangling", "no-such-target");
}

test "-r copies symlinks as symlinks (file, dir, dangling) like GNU" {
    try withCtx(&struct {
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setupSymlinkTree, &.{ "-r", "tree", "out" }, .{});
        }
    }.body);
}

test "-a archive copy of symlink tree matches GNU" {
    try withCtx(&struct {
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setupSymlinkTree, &.{ "-a", "tree", "out" }, .{});
        }
    }.body);
}

test "top-level symlink to a directory without -r refuses like GNU" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.makeDir(base, "d");
            try ctx.writeFile(base, "d/f", "f\n");
            try ctx.makeSymlink(base, "dl", "d");
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "dl", "out" }, .{});
        }
    }.body);
}

test "top-level symlink: -r keeps it a symlink, plain cp dereferences (GNU)" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "pointed-at\n");
            try ctx.makeSymlink(base, "la", "a");
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "-r", "la", "out_r" }, .{});
            _ = try compareCase(ctx, &setup, &.{ "la", "out_plain" }, .{});
        }
    }.body);
}

// ---------------------------------------------------------------------------
// -f force semantics (audit medium: -f failed on a read-only destination)
// ---------------------------------------------------------------------------

test "-f removes an unwritable destination and succeeds like GNU" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "src", "new content\n");
            try ctx.writeFile(base, "ro", "old content\n");
            try ctx.setMode(base, "ro", 0o444);
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "-f", "src", "ro" }, .{});
        }
    }.body);
}

test "without -f an unwritable destination fails like GNU" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "src", "new content\n");
            try ctx.writeFile(base, "ro", "old content\n");
            try ctx.setMode(base, "ro", 0o444);
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "src", "ro" }, .{});
        }
    }.body);
}

// ---------------------------------------------------------------------------
// -i interactive (audit low: declined overwrite used to exit 0; GNU 9.10
// exits 1). stdin is /dev/null, which GNU treats as "no".
// ---------------------------------------------------------------------------

test "declined -i overwrite exits 1 and leaves destination intact (GNU)" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "new\n");
            try ctx.writeFile(base, "dst", "keep me\n");
        }
        fn body(ctx: *Ctx) !void {
            const r = try compareCase(ctx, &setup, &.{ "-i", "a", "dst" }, .{});
            const m = try ctx.manifest(r.z);
            try std.testing.expect(std.mem.indexOf(u8, m, "keep me") != null);
        }
    }.body);
}

test "-i combined with -f still prompts like GNU (both orders)" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "new\n");
            try ctx.writeFile(base, "dst", "keep me\n");
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "-i", "-f", "a", "dst" }, .{});
            _ = try compareCase(ctx, &setup, &.{ "-f", "-i", "a", "dst" }, .{});
        }
    }.body);
}

test "-n overrides an earlier -i (last one wins, GNU)" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "new\n");
            try ctx.writeFile(base, "dst", "keep me\n");
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "-i", "-n", "a", "dst" }, .{});
        }
    }.body);
}

// ---------------------------------------------------------------------------
// -p preservation (audit medium: timestamps silently not preserved on
// macOS because utimensat was called with the Linux AT_FDCWD)
// ---------------------------------------------------------------------------

const fixed_time_sec: i64 = 1577880000; // 2020-01-01T12:00:00Z

test "-p preserves file mtime (cross-checked against GNU cp -p)" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "timed\n");
            try ctx.setTimes(base, "a", fixed_time_sec);
        }
        fn body(ctx: *Ctx) !void {
            const r = try compareCase(ctx, &setup, &.{ "-p", "a", "b" }, .{});
            const mz = try ctx.mtimeOf(r.z, "b");
            const mg = try ctx.mtimeOf(r.g, "b");
            try std.testing.expectEqual(fixed_time_sec, mz.sec);
            try std.testing.expectEqual(mg.sec, mz.sec);
            try std.testing.expectEqual(mg.nsec, mz.nsec);
        }
    }.body);
}

test "-rp preserves directory mtimes like GNU" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.makeDir(base, "ptree");
            try ctx.makeDir(base, "ptree/sub");
            try ctx.writeFile(base, "ptree/sub/z", "z\n");
            try ctx.setTimes(base, "ptree/sub", fixed_time_sec);
            try ctx.setTimes(base, "ptree", fixed_time_sec);
        }
        fn body(ctx: *Ctx) !void {
            const r = try compareCase(ctx, &setup, &.{ "-rp", "ptree", "pdst" }, .{});
            const dz = try ctx.mtimeOf(r.z, "pdst");
            const sz = try ctx.mtimeOf(r.z, "pdst/sub");
            try std.testing.expectEqual(fixed_time_sec, dz.sec);
            try std.testing.expectEqual(fixed_time_sec, sz.sec);
        }
    }.body);
}

test "-p preserves mode like GNU" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "mode\n");
            try ctx.setMode(base, "a", 0o640);
        }
        fn body(ctx: *Ctx) !void {
            const r = try compareCase(ctx, &setup, &.{ "-p", "a", "b" }, .{});
            const pz = try ctx.path(r.z, "b");
            var st: CStat = undefined;
            try std.testing.expectEqual(@as(c_int, 0), stat(pz.ptr, &st));
            try std.testing.expectEqual(@as(u32, 0o640), @as(u32, st.mode) & 0o7777);
        }
    }.body);
}

// ---------------------------------------------------------------------------
// -u update
// ---------------------------------------------------------------------------

test "-u skips newer destination and copies over older one, like GNU" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "src", "source\n");
            try ctx.writeFile(base, "newer_dst", "newer\n");
            try ctx.writeFile(base, "older_dst", "older\n");
            try ctx.setTimes(base, "src", fixed_time_sec);
            try ctx.setTimes(base, "newer_dst", fixed_time_sec + 1000);
            try ctx.setTimes(base, "older_dst", fixed_time_sec - 1000);
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "-u", "src", "newer_dst" }, .{});
            _ = try compareCase(ctx, &setup, &.{ "-u", "src", "older_dst" }, .{});
        }
    }.body);
}

// ---------------------------------------------------------------------------
// target-directory handling and diagnostics
// ---------------------------------------------------------------------------

test "-t DIR and attached -tDIR both work like GNU" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "one\n");
            try ctx.writeFile(base, "b", "two\n");
            try ctx.makeDir(base, "dir");
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "-t", "dir", "a", "b" }, .{});
            _ = try compareCase(ctx, &setup, &.{ "-tdir", "a", "b" }, .{});
        }
    }.body);
}

test "-t with missing / non-directory target: GNU diagnostics and exit" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "one\n");
            try ctx.writeFile(base, "plainfile", "not a dir\n");
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "-t", "nonexist", "a" }, .{});
            _ = try compareCase(ctx, &setup, &.{ "-t", "plainfile", "a" }, .{});
        }
    }.body);
}

test "multiple sources to missing / non-directory target: GNU diagnostics" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.writeFile(base, "a", "one\n");
            try ctx.writeFile(base, "b", "two\n");
            try ctx.writeFile(base, "plainfile", "not a dir\n");
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "a", "b", "nonexist" }, .{});
            _ = try compareCase(ctx, &setup, &.{ "a", "b", "plainfile" }, .{});
        }
    }.body);
}

// ---------------------------------------------------------------------------
// diagnostics wording (audit low: Zig error names leaked into messages)
// ---------------------------------------------------------------------------

test "missing source: GNU wording and exit" {
    try withCtx(&struct {
        fn setup(_: *Ctx, _: []const u8) !void {}
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "nonexist", "z" }, .{});
        }
    }.body);
}

test "destination in missing directory: GNU wording and exit" {
    try withCtx(&struct {
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setupOneFile, &.{ "a", "nodir/z" }, .{});
        }
    }.body);
}

test "directory source without -r: GNU '-r not specified' wording" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.makeDir(base, "d");
            try ctx.writeFile(base, "d/f", "f\n");
        }
        fn body(ctx: *Ctx) !void {
            _ = try compareCase(ctx, &setup, &.{ "d", "z" }, .{});
        }
    }.body);
}

// ---------------------------------------------------------------------------
// recursive copy resilience
// ---------------------------------------------------------------------------

test "recursive copy continues past an unreadable file and exits 1 (GNU)" {
    try withCtx(&struct {
        fn setup(ctx: *Ctx, base: []const u8) !void {
            try ctx.makeDir(base, "rf");
            try ctx.writeFile(base, "rf/readable", "ok\n");
            try ctx.writeFile(base, "rf/locked", "secret\n");
            try ctx.setMode(base, "rf/locked", 0o000);
        }
        fn body(ctx: *Ctx) !void {
            if (std.c.geteuid() == 0) return error.SkipZigTest; // root can read anything
            _ = try compareCase(ctx, &setup, &.{ "-r", "rf", "out" }, .{});
        }
    }.body);
}
