//! Tier-1 external anchors and end-to-end contract tests for zdedupe.
//!
//! Why this file exists (zig-forge CLAUDE.md, golden rule §1): the pre-existing
//! tests anchored the hash *primitives* against published digests, but nothing
//! anchored the parts that can destroy user data:
//!
//!   * the file-reading hash loop (a short/interrupted read used to be treated
//!     as EOF, so two unreadable files hashed identically → "duplicates" → the
//!     consumer app offers a non-duplicate for deletion), and
//!   * the JSON document, which is the real external contract — the Tauri app
//!     (`src-tauri/src/ffi.rs`, serde) and the native Swift app
//!     (`ZDedupeEngine.swift`, `JSONDecoder`) parse it to decide what to delete.
//!
//! Anchors used here, none of them produced by this library:
//!
//!   * BLAKE3 official test vectors — BLAKE3-team/BLAKE3
//!     `test_vectors/test_vectors.json`, whose inputs are the repeating byte
//!     sequence 0,1,…,250. Lengths 4096 and 102400 are used; 102400 is well
//!     past the 64 KiB read buffer, so it exercises the multi-`read()` loop.
//!   * SHA-256 digests of those same two inputs, produced by Apple's
//!     `/usr/bin/shasum -a 256` (a separate Perl implementation).
//!   * `std.json` as an independent parser for the emitted report.

const std = @import("std");
const hasher = @import("hasher.zig");
const types = @import("types.zig");
const dedupe = @import("dedupe.zig");
const report = @import("report.zig");
const compare = @import("compare.zig");
const walker = @import("walker.zig");
const Scratch = @import("testing_scratch.zig").Scratch;

const testing = std.testing;

/// The BLAKE3 test-vector input generator: byte i is `i % 251`.
fn vectorInput(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @intCast(i % 251);
}

/// BLAKE3 of the 102400-byte vector input (official test_vectors.json, first
/// 32 bytes of the extended output).
const B3_102400 = "bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085";
/// BLAKE3 of the 4096-byte vector input (official test_vectors.json).
const B3_4096 = "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969";
/// `shasum -a 256` of the 102400-byte vector input.
const SHA_102400 = "74588b7f0bcc354ac14d9cf199fa3a20c05f0c7293b9075b2f2e146e718de800";
/// `shasum -a 256` of the 4096-byte vector input.
const SHA_4096 = "d67c656e01756650d77717b0839985a056ec28ffe174601d690fc407a2ceffca";

// ===========================================================================
// Tier 1 — file hashing against externally-published digests
// ===========================================================================

test "anchor: hashFileBlake3 over a 100 KiB file matches the official BLAKE3 vector" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "anchor-b3");
    defer scratch.deinit();

    const data = try allocator.alloc(u8, 102400);
    defer allocator.free(data);
    vectorInput(data);
    try scratch.writeFile("vector.bin", data);

    const path = try scratch.join("vector.bin");
    defer allocator.free(path);

    // 102400 > BUFFER_SIZE (65536): this only matches if every read() in the
    // loop is accumulated, which is the property the read-error fix protects.
    const hash = try hasher.hashFileBlake3(path, null);
    var hex: [64]u8 = undefined;
    try testing.expectEqualStrings(B3_102400, hasher.hashToHex(&hash, &hex));
}

test "anchor: hashFileSha256 over the same file matches shasum -a 256" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "anchor-sha");
    defer scratch.deinit();

    const data = try allocator.alloc(u8, 102400);
    defer allocator.free(data);
    vectorInput(data);
    try scratch.writeFile("vector.bin", data);

    const path = try scratch.join("vector.bin");
    defer allocator.free(path);

    const hash = try hasher.hashFileSha256(path, null);
    var hex: [64]u8 = undefined;
    try testing.expectEqualStrings(SHA_102400, hasher.hashToHex(&hash, &hex));
}

test "anchor: quick hash (first 4 KiB) matches the published 4096-byte vectors" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "anchor-quick");
    defer scratch.deinit();

    const data = try allocator.alloc(u8, 102400);
    defer allocator.free(data);
    vectorInput(data);
    try scratch.writeFile("vector.bin", data);

    const path = try scratch.join("vector.bin");
    defer allocator.free(path);

    var hex: [64]u8 = undefined;

    const b3 = hasher.FileHasher.init(.blake3);
    const quick_b3 = try b3.hashFileQuick(path, 4096);
    try testing.expectEqualStrings(B3_4096, hasher.hashToHex(&quick_b3, &hex));

    const sha = hasher.FileHasher.init(.sha256);
    const quick_sha = try sha.hashFileQuick(path, 4096);
    try testing.expectEqualStrings(SHA_4096, hasher.hashToHex(&quick_sha, &hex));
}

// ===========================================================================
// Tier 2 — a failed read must never yield a hash
// ===========================================================================

test "read error propagates instead of hashing a partial prefix" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "readerr");
    defer scratch.deinit();

    // Historical shape of the bug: open() on a directory succeeds, read()
    // returns -1/EISDIR, and the old loop treated that as EOF — so two such
    // paths hashed to BLAKE3("") and were reported as duplicates of each
    // other. Since openRegularFile() gained the fstat S_ISREG guard, a
    // directory is rejected as NotRegularFile before read() is ever
    // attempted — an error strictly earlier than ReadFailed. The load-bearing
    // assertion is unchanged: a pathological path must produce an error,
    // never a digest. (The `n < 0` → ReadFailed branch remains in the read
    // loop for genuine mid-read I/O errors on regular files.)
    try scratch.makeDir("dir_a");
    try scratch.makeDir("dir_b");

    const a = try scratch.join("dir_a");
    defer allocator.free(a);
    const b = try scratch.join("dir_b");
    defer allocator.free(b);

    try testing.expectError(error.NotRegularFile, hasher.hashFileBlake3(a, null));
    try testing.expectError(error.NotRegularFile, hasher.hashFileSha256(a, null));
    try testing.expectError(error.NotRegularFile, hasher.hashFileBlake3(b, null));

    // And explicitly: the failure is not the empty-input digest sneaking
    // through some other path.
    const empty_b3 = hasher.hashBytesBlake3("");
    var hex: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
        hasher.hashToHex(&empty_b3, &hex),
    );
}

test "a file that cannot be opened is excluded, not grouped" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "unreadable");
    defer scratch.deinit();

    try testing.expectError(error.CannotOpenFile, hasher.hashFileBlake3("/no/such/zdedupe/file", null));

    // Quick-hash path too (the pipeline runs quick hash before full hash).
    const h = hasher.FileHasher.init(.blake3);
    try testing.expectError(error.CannotOpenFile, h.hashFileQuick("/no/such/zdedupe/file", 4096));
}

// ===========================================================================
// Tier 3 — end-to-end pipeline and the JSON the consumer apps parse
// ===========================================================================

/// Filename containing every character that breaks naive JSON emission, plus
/// an HTML payload. Both are legal on APFS and ext4.
const hostile_name = "evil\" ,\"injected\":1, \\ <script>alert(1)<x>.txt";

fn buildFixture(scratch: *Scratch) !void {
    // Two byte-identical files + one different, all above Config.min_size.
    try scratch.writeFile("alpha.txt", "duplicate payload for zdedupe\n");
    try scratch.makeDir("nested");
    try scratch.writeFile("nested/beta.txt", "duplicate payload for zdedupe\n");
    try scratch.writeFile("unique.txt", "a different payload entirely\n");
    // Same content again, under a hostile filename.
    try scratch.writeFile(hostile_name, "duplicate payload for zdedupe\n");
}

test "end-to-end: DupeFinder finds exactly one group across the fixture tree" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "e2e");
    defer scratch.deinit();
    try buildFixture(&scratch);

    var finder = dedupe.DupeFinder.init(allocator, .{});
    defer finder.deinit();
    try finder.scan(&.{scratch.path});

    const groups = finder.getGroups();
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqual(@as(usize, 3), groups[0].count());
    try testing.expectEqual(@as(u64, 30), groups[0].size);

    // The group's hash is the real content hash, anchored by hashing the same
    // bytes in memory.
    const expect = hasher.hashBytesBlake3("duplicate payload for zdedupe\n");
    try testing.expect(hasher.hashEqual(&expect, &groups[0].hash));

    // unique.txt must not appear anywhere in the group.
    for (groups[0].files.items) |p| {
        try testing.expect(std.mem.indexOf(u8, p, "unique.txt") == null);
    }
}

test "hard links are counted once, not reported as duplicates of themselves" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "hardlink");
    defer scratch.deinit();

    try scratch.writeFile("original.bin", "hard link payload payload payload\n");
    try scratch.hardLink("original.bin", "linked.bin");

    var finder = dedupe.DupeFinder.init(allocator, .{});
    defer finder.deinit();
    try finder.scan(&.{scratch.path});

    // Same inode → one entry → no duplicate group. Deleting a hard link
    // reclaims nothing, so reporting one would be a false saving.
    try testing.expectEqual(@as(usize, 0), finder.getGroups().len);
    try testing.expectEqual(@as(usize, 1), finder.getSummary().files_scanned);
}

test "external contract: the JSON report parses and preserves hostile paths byte-exactly" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "json");
    defer scratch.deinit();
    try buildFixture(&scratch);

    var finder = dedupe.DupeFinder.init(allocator, .{});
    defer finder.deinit();
    try finder.scan(&.{scratch.path});

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const writer = report.ReportWriter.init(allocator, .{ .format = .json });
    try writer.writeDuplicateReport(&out.writer, finder.getGroups(), finder.getSummary());
    const json = out.written();

    // 1. An independent parser accepts it.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // 2. The field names the Swift JSONDecoder / Tauri serde models expect are
    //    all present with the documented types (include/zdedupe.h). Renaming
    //    any of these silently breaks both consumer apps.
    try testing.expectEqualStrings("duplicates", root.get("report_type").?.string);
    _ = root.get("generated_at").?.string;
    _ = root.get("scan_duration_ms").?.integer;

    const summary = root.get("summary").?.object;
    for ([_][]const u8{
        "files_scanned",   "bytes_scanned", "duplicate_groups",
        "duplicate_files", "space_savings",
    }) |field| {
        _ = summary.get(field).?.integer;
    }
    _ = summary.get("bytes_scanned_human").?.string;
    _ = summary.get("space_savings_human").?.string;

    const groups = root.get("groups").?.array;
    try testing.expectEqual(@as(usize, 1), groups.items.len);
    const group = groups.items[0].object;
    _ = group.get("hash").?.string;
    _ = group.get("size").?.integer;
    _ = group.get("count").?.integer;
    _ = group.get("savings").?.integer;
    _ = group.get("size_human").?.string;
    _ = group.get("savings_human").?.string;

    // 3. The hostile filename survives encode → parse unchanged. This is what
    //    a no-op escaper cannot do: it either produced invalid JSON or split
    //    the path into extra fields.
    const files = group.get("files").?.array;
    try testing.expectEqual(@as(usize, 3), files.items.len);

    var found_hostile = false;
    for (files.items) |f| {
        const path = f.object.get("path").?.string;
        _ = f.object.get("mtime").?.string;
        if (std.mem.endsWith(u8, path, hostile_name)) found_hostile = true;
    }
    try testing.expect(found_hostile);

    // 4. No stray top-level key was injected by the filename.
    try testing.expect(root.get("injected") == null);
    try testing.expectEqual(@as(usize, 5), root.count());
}

test "external contract: the compare JSON report parses" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "cmp");
    defer scratch.deinit();

    try scratch.makeDir("a");
    try scratch.makeDir("b");
    try scratch.writeFile("a/same.txt", "identical content here\n");
    try scratch.writeFile("b/same.txt", "identical content here\n");
    try scratch.writeFile("a/only_a.txt", "left side only\n");
    try scratch.writeFile("b/" ++ "differs.txt", "right side only\n");

    const dir_a = try scratch.join("a");
    defer allocator.free(dir_a);
    const dir_b = try scratch.join("b");
    defer allocator.free(dir_b);

    var comparator = compare.FolderComparator.init(allocator, .{});
    var result = try comparator.compare(dir_a, dir_b);
    defer result.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const writer = report.ReportWriter.init(allocator, .{ .format = .json });
    try writer.writeCompareReport(&out.writer, &result);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings(dir_a, root.get("folder_a").?.string);
    try testing.expectEqualStrings(dir_b, root.get("folder_b").?.string);
    try testing.expectEqual(false, root.get("is_identical").?.bool);
}

test "the HTML report escapes a filename carrying a script tag" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "html");
    defer scratch.deinit();
    try buildFixture(&scratch);

    var finder = dedupe.DupeFinder.init(allocator, .{});
    defer finder.deinit();
    try finder.scan(&.{scratch.path});

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const writer = report.ReportWriter.init(allocator, .{ .format = .html });
    try writer.writeDuplicateReport(&out.writer, finder.getGroups(), finder.getSummary());
    const html = out.written();

    // The fixture's filename contains a literal <script> tag. If it reaches the
    // document unescaped, opening the report executes it.
    try testing.expect(std.mem.indexOf(u8, html, "<script>alert(1)") == null);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;") != null);
}

// ===========================================================================
// Tier 3 — symlink semantics (the -L flag)
// ===========================================================================

test "follow_symlinks reaches files behind a symlinked directory" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "symlink-follow");
    defer scratch.deinit();

    try scratch.makeDir("real");
    try scratch.makeDir("visible");
    try scratch.writeFile("real/target.txt", "behind a symlink payload\n");
    try scratch.writeFile("visible/plain.txt", "behind a symlink payload\n");
    try scratch.symLink("../real", "visible/link_to_real");

    const root = try scratch.join("visible");
    defer allocator.free(root);

    // Without -L the symlinked directory is not traversed: one file, no dupes.
    {
        var finder = dedupe.DupeFinder.init(allocator, .{ .follow_symlinks = false });
        defer finder.deinit();
        try finder.scan(&.{root});
        try testing.expectEqual(@as(usize, 0), finder.getGroups().len);
    }

    // With -L the target is reached and the pair is found. Before this fix
    // dedupe never passed follow_symlinks to the walker at all, so -L was a
    // silent no-op for the duplicate finder.
    {
        var finder = dedupe.DupeFinder.init(allocator, .{ .follow_symlinks = true });
        defer finder.deinit();
        try finder.scan(&.{root});
        try testing.expectEqual(@as(usize, 1), finder.getGroups().len);
        try testing.expectEqual(@as(usize, 2), finder.getGroups()[0].count());
    }
}

test "a symlink cycle terminates instead of recursing forever" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "symlink-cycle");
    defer scratch.deinit();

    // `sub/loop -> ..` is the classic cycle: walking sub/loop/sub/loop/... is
    // unbounded without a visited-directory guard.
    try scratch.makeDir("sub");
    try scratch.writeFile("sub/file.txt", "cycle fixture payload\n");
    try scratch.symLink("..", "sub/loop");

    const root = try scratch.join("sub");
    defer allocator.free(root);

    // FastWalker (dedupe path).
    {
        var finder = dedupe.DupeFinder.init(allocator, .{ .follow_symlinks = true });
        defer finder.deinit();
        try finder.scan(&.{root});
        // Terminates; the file is seen (inode-deduped) exactly once.
        try testing.expectEqual(@as(usize, 1), finder.getSummary().files_scanned);
    }

    // Walker (compare path).
    {
        var w = walker.Walker.init(allocator, .{ .follow_symlinks = true });
        defer w.deinit();
        var result = try w.walk(root);
        defer result.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), result.files.items.len);
    }
}

// ===========================================================================
// Directory analysis — what a user is told is safe to delete
// ===========================================================================
//
// Anchors, none produced by dirs.zig:
//   * `tools/dirdigest_reference.py`, an independent implementation of the
//     documented digest format (os + hashlib), supplies the expected digests.
//   * Every identity / containment expectation below is the verdict `diff -r`
//     gives for the same fixture; the fixtures are small enough to check by eye.

const dirs = @import("dirs.zig");

const readme_text = "zdedupe directory digest fixture\n";
const main_text = "int main(void) { return 0; }\n";
const util_text = "/* strings */\n";
const project_bytes = readme_text.len + main_text.len + util_text.len;

/// `python3 tools/dirdigest_reference.py T` for the tree built by
/// `buildGoldenProject`, and for its `src/` subdirectory.
const DIR_DIGEST_PROJECT = "7e75cf42667ab61c3a42c149b4f7fb7d5d4216ac4b4ec4c77bf5d97179ad8b0a";
const DIR_DIGEST_SRC = "ac80422eb3ec43a0afa16c807838f50c6e7128fa30f7e76b985c1e25b8659a43";

/// A three-file project tree: readme.txt, src/main.c, src/util/str.c.
fn buildProject(scratch: *Scratch, comptime root: []const u8) !void {
    try scratch.makeDir(root);
    try scratch.makeDir(root ++ "/src");
    try scratch.makeDir(root ++ "/src/util");
    try scratch.writeFile(root ++ "/readme.txt", readme_text);
    try scratch.writeFile(root ++ "/src/main.c", main_text);
    try scratch.writeFile(root ++ "/src/util/str.c", util_text);
}

/// `buildProject` plus an empty directory and a symlink — every entry kind the
/// digest covers. Must stay in step with the tree the reference digests were
/// computed from (see tools/dirdigest_reference.py).
fn buildGoldenProject(scratch: *Scratch, comptime root: []const u8) !void {
    try buildProject(scratch, root);
    try scratch.makeDir(root ++ "/empty");
    try scratch.symLink("src/main.c", root ++ "/link");
}

fn scanDirs(finder: *dedupe.DupeFinder, scratch: *const Scratch) !*const dirs.Analysis {
    try finder.scan(&.{scratch.path});
    return finder.getDirAnalysis() orelse error.NoDirectoryAnalysis;
}

fn pathIs(scratch: *const Scratch, path: []const u8, sub_path: []const u8) bool {
    return path.len == scratch.path.len + 1 + sub_path.len and
        std.mem.startsWith(u8, path, scratch.path) and
        path[scratch.path.len] == '/' and
        std.mem.endsWith(u8, path, sub_path);
}

/// The identical set that has `sub_path` as a member, if any.
fn setWith(analysis: *const dirs.Analysis, scratch: *const Scratch, sub_path: []const u8) ?*const dirs.IdenticalSet {
    for (analysis.identical_sets) |*set| {
        for (set.dirs) |dir| {
            if (pathIs(scratch, dir.path, sub_path)) return set;
        }
    }
    return null;
}

fn setHas(set: *const dirs.IdenticalSet, scratch: *const Scratch, sub_path: []const u8) bool {
    for (set.dirs) |dir| {
        if (pathIs(scratch, dir.path, sub_path)) return true;
    }
    return false;
}

fn overlapOf(analysis: *const dirs.Analysis, scratch: *const Scratch, a: []const u8, b: []const u8) ?*const dirs.Overlap {
    for (analysis.overlaps) |*overlap| {
        if (pathIs(scratch, overlap.a.path, a) and pathIs(scratch, overlap.b.path, b)) return overlap;
    }
    return null;
}

fn expectOnly(scratch: *const Scratch, side: *const dirs.OverlapSide, expected: []const []const u8) !void {
    try testing.expectEqual(@as(u64, expected.len), side.only_count);
    try testing.expectEqual(expected.len, side.only.len);
    for (expected, side.only) |want, got| {
        if (!pathIs(scratch, got, want)) {
            std.debug.print("expected only-path {s}, got {s}\n", .{ want, got });
            return error.TestExpectedEqual;
        }
    }
}

test "anchor: directory digests match the independent Python reference" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "dirs-golden");
    defer scratch.deinit();

    try buildGoldenProject(&scratch, "one");
    try buildGoldenProject(&scratch, "two");
    // A third copy of src/ alone, inside a parent that is no copy of the
    // others, so the src/ set is not implied by its parents and gets reported.
    try scratch.makeDir("three");
    try scratch.makeDir("three/src");
    try scratch.makeDir("three/src/util");
    try scratch.writeFile("three/src/main.c", main_text);
    try scratch.writeFile("three/src/util/str.c", util_text);
    try scratch.writeFile("three/notes.txt", "not part of the project\n");

    var finder = dedupe.DupeFinder.init(allocator, .{ .analyze_dirs = true, .hash_algorithm = .sha256 });
    defer finder.deinit();
    const analysis = try scanDirs(&finder, &scratch);

    var hex: [64]u8 = undefined;

    const project = setWith(analysis, &scratch, "one") orelse return error.ProjectSetMissing;
    try testing.expectEqual(@as(usize, 2), project.dirs.len);
    try testing.expect(setHas(project, &scratch, "two"));
    try testing.expectEqualStrings(DIR_DIGEST_PROJECT, hasher.hashToHex(&project.digest, &hex));
    try testing.expectEqual(@as(u64, 3), project.file_count);
    try testing.expectEqual(@as(u64, project_bytes), project.bytes);
    try testing.expectEqual(@as(u64, project_bytes), project.reclaimable);

    const src = setWith(analysis, &scratch, "three/src") orelse return error.SrcSetMissing;
    try testing.expectEqual(@as(usize, 3), src.dirs.len);
    try testing.expectEqualStrings(DIR_DIGEST_SRC, hasher.hashToHex(&src.digest, &hex));

    // one/src/util == two/src/util == three/src/util is implied by the src/
    // set and must not be reported again.
    try testing.expect(setWith(analysis, &scratch, "one/src/util") == null);
    try testing.expectEqual(@as(usize, 2), analysis.identical_sets.len);
}

test "a one-byte, same-size change breaks identity and is named on both sides" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "dirs-onebyte");
    defer scratch.deinit();

    try buildProject(&scratch, "p");
    try buildProject(&scratch, "q");
    // Same length as main_text, one byte different: size and name alone would
    // call these trees identical.
    try scratch.writeFile("q/src/main.c", "int main(void) { return 1; }\n");

    var finder = dedupe.DupeFinder.init(allocator, .{ .analyze_dirs = true });
    defer finder.deinit();
    const analysis = try scanDirs(&finder, &scratch);

    try testing.expect(setWith(analysis, &scratch, "p") == null);
    try testing.expect(setWith(analysis, &scratch, "p/src") == null);

    const overlap = overlapOf(analysis, &scratch, "p", "q") orelse return error.OverlapMissing;
    try testing.expectEqual(dirs.Relation.overlap, overlap.relation);
    try testing.expectEqual(@as(u64, 2), overlap.a.shared_files);
    try testing.expectEqual(@as(u64, 2), overlap.b.shared_files);
    try expectOnly(&scratch, &overlap.a, &.{"p/src/main.c"});
    try expectOnly(&scratch, &overlap.b, &.{"q/src/main.c"});
}

test "a stale backup is contained in the current tree, never the reverse" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "dirs-backup");
    defer scratch.deinit();

    try buildProject(&scratch, "backup");
    try buildProject(&scratch, "current");
    try scratch.writeFile("current/src/new.c", "work done after the backup\n");

    var finder = dedupe.DupeFinder.init(allocator, .{ .analyze_dirs = true });
    defer finder.deinit();
    const analysis = try scanDirs(&finder, &scratch);

    try testing.expect(setWith(analysis, &scratch, "backup") == null);

    const overlap = overlapOf(analysis, &scratch, "backup", "current") orelse return error.OverlapMissing;
    // Deleting `backup` loses nothing; deleting `current` loses new.c.
    try testing.expectEqual(dirs.Relation.a_in_b, overlap.relation);
    try expectOnly(&scratch, &overlap.a, &.{});
    try expectOnly(&scratch, &overlap.b, &.{"current/src/new.c"});
    try testing.expectEqual(@as(u64, 3), overlap.a.shared_files);
}

test "a rename alone, or an empty directory alone, is same content but not identical" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "dirs-rename");
    defer scratch.deinit();

    try buildProject(&scratch, "p");

    // renamed/: one file under a different name, nothing else changed.
    try scratch.makeDir("renamed");
    try scratch.makeDir("renamed/src");
    try scratch.makeDir("renamed/src/util");
    try scratch.writeFile("renamed/README.txt", readme_text);
    try scratch.writeFile("renamed/src/main.c", main_text);
    try scratch.writeFile("renamed/src/util/str.c", util_text);

    // with-empty/: the same tree plus one empty directory.
    try buildProject(&scratch, "with-empty");
    try scratch.makeDir("with-empty/logs");

    var finder = dedupe.DupeFinder.init(allocator, .{ .analyze_dirs = true });
    defer finder.deinit();
    const analysis = try scanDirs(&finder, &scratch);

    // Three trees, the same three files, and not one identical pair.
    try testing.expect(setWith(analysis, &scratch, "p") == null);
    try testing.expect(setWith(analysis, &scratch, "renamed") == null);
    try testing.expect(setWith(analysis, &scratch, "with-empty") == null);

    for ([_][2][]const u8{
        .{ "p", "renamed" },
        .{ "p", "with-empty" },
        .{ "renamed", "with-empty" },
    }) |pair| {
        const overlap = overlapOf(analysis, &scratch, pair[0], pair[1]) orelse return error.OverlapMissing;
        try testing.expectEqual(dirs.Relation.same_content, overlap.relation);
    }
}

test "symlink targets are part of directory identity" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "dirs-symlink");
    defer scratch.deinit();

    inline for (.{ "p", "q", "r" }) |root| try buildProject(&scratch, root);
    try scratch.symLink("src/main.c", "p/link");
    try scratch.symLink("src/main.c", "q/link");
    try scratch.symLink("readme.txt", "r/link");

    var finder = dedupe.DupeFinder.init(allocator, .{ .analyze_dirs = true });
    defer finder.deinit();
    const analysis = try scanDirs(&finder, &scratch);

    const set = setWith(analysis, &scratch, "p") orelse return error.SetMissing;
    try testing.expect(setHas(set, &scratch, "q"));
    try testing.expect(!setHas(set, &scratch, "r"));
}

test "hard-linked snapshot trees are identical yet hold no duplicate files" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "dirs-hardlink");
    defer scratch.deinit();

    // What `cp -al p q` / `rsync --link-dest` produce.
    try buildProject(&scratch, "p");
    try scratch.makeDir("q");
    try scratch.makeDir("q/src");
    try scratch.makeDir("q/src/util");
    try scratch.hardLink("p/readme.txt", "q/readme.txt");
    try scratch.hardLink("p/src/main.c", "q/src/main.c");
    try scratch.hardLink("p/src/util/str.c", "q/src/util/str.c");

    var finder = dedupe.DupeFinder.init(allocator, .{ .analyze_dirs = true });
    defer finder.deinit();
    const analysis = try scanDirs(&finder, &scratch);

    // Nothing to reclaim at file level: every "copy" is the same inode.
    try testing.expectEqual(@as(usize, 0), finder.getGroups().len);
    try testing.expectEqual(@as(u64, 3), finder.getSummary().files_scanned);

    const set = setWith(analysis, &scratch, "p") orelse return error.SetMissing;
    try testing.expect(setHas(set, &scratch, "q"));
    try testing.expectEqual(@as(u64, 3), set.file_count);
}

/// A minimal `.git` whose local and remote refs are byte-identical — true of
/// any freshly pushed branch.
fn addGitMetadata(scratch: *Scratch, comptime root: []const u8, comptime commit: []const u8) !void {
    inline for (.{ "/.git", "/.git/refs", "/.git/refs/heads", "/.git/refs/remotes", "/.git/refs/remotes/origin" }) |dir| {
        try scratch.makeDir(root ++ dir);
    }
    try scratch.writeFile(root ++ "/.git/HEAD", "ref: refs/heads/main\n");
    try scratch.writeFile(root ++ "/.git/refs/heads/main", commit ++ "\n");
    try scratch.writeFile(root ++ "/.git/refs/heads/feature", commit ++ "\n");
    try scratch.writeFile(root ++ "/.git/refs/remotes/origin/main", commit ++ "\n");
    try scratch.writeFile(root ++ "/.git/refs/remotes/origin/feature", commit ++ "\n");
}

test "no finding points inside .git, yet .git still decides project identity" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "dirs-vcs");
    defer scratch.deinit();

    inline for (.{ "p", "q", "r" }) |root| try buildProject(&scratch, root);
    try addGitMetadata(&scratch, "p", "1111111111111111111111111111111111111111");
    try addGitMetadata(&scratch, "q", "1111111111111111111111111111111111111111");
    // Same working tree, different history.
    try addGitMetadata(&scratch, "r", "2222222222222222222222222222222222222222");

    var finder = dedupe.DupeFinder.init(allocator, .{ .analyze_dirs = true });
    defer finder.deinit();
    const analysis = try scanDirs(&finder, &scratch);

    // refs/heads and refs/remotes/origin match byte for byte inside every
    // repo. "heads adds nothing" is true of the bytes and would delete the
    // local branches; nothing may be reported at or below a .git directory.
    for (analysis.identical_sets) |set| {
        for (set.dirs) |dir| try testing.expect(std.mem.indexOf(u8, dir.path, "/.git") == null);
    }
    for (analysis.overlaps) |overlap| {
        try testing.expect(std.mem.indexOf(u8, overlap.a.path, "/.git") == null);
        try testing.expect(std.mem.indexOf(u8, overlap.b.path, "/.git") == null);
    }

    // The metadata still counts: r's tree matches p's file for file, but its
    // history differs, so it is not a copy.
    const set = setWith(analysis, &scratch, "p") orelse return error.SetMissing;
    try testing.expect(setHas(set, &scratch, "q"));
    try testing.expect(!setHas(set, &scratch, "r"));

    // ...and r's unique history is what the pair with r reports as at stake.
    const overlap = overlapOf(analysis, &scratch, "p", "r") orelse return error.OverlapMissing;
    try testing.expectEqual(dirs.Relation.overlap, overlap.relation);
    try testing.expect(overlap.b.only_count > 0);
    for (overlap.b.only) |path| try testing.expect(std.mem.indexOf(u8, path, "/.git/") != null);
}

extern "c" fn geteuid() c_uint;

test "an unreadable subdirectory blocks every safety verdict" {
    // root reads through mode 000, so the fixture would not be unreadable.
    if (geteuid() == 0) return error.SkipZigTest;

    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "dirs-unreadable");
    defer scratch.deinit();

    try buildProject(&scratch, "p");
    try buildProject(&scratch, "q");

    const locked = try scratch.joinZ("q/src/util");
    defer allocator.free(locked);
    if (std.c.chmod(locked.ptr, 0) != 0) return error.SkipZigTest;
    // Restore before Scratch.deinit, or the tree cannot be cleaned up.
    defer _ = std.c.chmod(locked.ptr, 0o700);

    var finder = dedupe.DupeFinder.init(allocator, .{ .analyze_dirs = true });
    defer finder.deinit();
    const analysis = try scanDirs(&finder, &scratch);

    // q/src, q and the scan root all have something unknown beneath them.
    try testing.expectEqual(@as(u64, 3), analysis.dirs_incomplete);
    try testing.expect(setWith(analysis, &scratch, "q") == null);
    try testing.expect(setWith(analysis, &scratch, "q/src") == null);

    // Everything we *could* read of q exists in p — and that is exactly the
    // trap: "q is contained in p" would invite deleting a directory whose
    // contents were never seen.
    const overlap = overlapOf(analysis, &scratch, "p", "q") orelse return error.OverlapMissing;
    try testing.expect(!overlap.b.complete);
    try testing.expectEqual(@as(u64, 0), overlap.b.only_count);
    try testing.expectEqual(dirs.Relation.overlap, overlap.relation);
}

test "excluded names and tagged cache dirs are ignored, counted, and need a valid tag" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "dirs-excludes");
    defer scratch.deinit();

    inline for (.{ "p", "q", "r" }) |root| try buildProject(&scratch, root);

    try scratch.makeDir("p/node_modules");
    try scratch.writeFile("p/node_modules/dep.js", "module.exports = 1;\n");

    try scratch.makeDir("q/target");
    try scratch.writeFile("q/target/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n# cargo\n");
    try scratch.writeFile("q/target/artifact.o", "object code\n");

    // A file merely *named* CACHEDIR.TAG proves nothing: r/cache is real data
    // and must keep r out of the set.
    try scratch.makeDir("r/cache");
    try scratch.writeFile("r/cache/CACHEDIR.TAG", "");
    try scratch.writeFile("r/cache/data.bin", "user data\n");

    var finder = dedupe.DupeFinder.init(allocator, .{
        .analyze_dirs = true,
        .excludes = &types.Config.default_excludes,
        .exclude_cache_dirs = true,
    });
    defer finder.deinit();
    const analysis = try scanDirs(&finder, &scratch);

    try testing.expectEqual(@as(u64, 2), finder.getSummary().excluded_entries);

    const set = setWith(analysis, &scratch, "p") orelse return error.SetMissing;
    try testing.expectEqual(@as(usize, 2), set.dirs.len);
    try testing.expect(setHas(set, &scratch, "q"));
    try testing.expect(!setHas(set, &scratch, "r"));
    for (set.dirs) |dir| try testing.expectEqual(@as(u64, 1), dir.skipped_entries);
}

test "excludes prune the file-level scan too, but never a scan root" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "excludes-files");
    defer scratch.deinit();

    try scratch.makeDir("app");
    try scratch.makeDir("app/node_modules");
    try scratch.writeFile("app/index.js", "module.exports = 1;\n");
    try scratch.writeFile("app/node_modules/index.js", "module.exports = 1;\n");

    const config: types.Config = .{ .excludes = &.{"node_modules"} };

    {
        var finder = dedupe.DupeFinder.init(allocator, config);
        defer finder.deinit();
        try finder.scan(&.{scratch.path});
        try testing.expectEqual(@as(usize, 0), finder.getGroups().len);
        try testing.expectEqual(@as(u64, 1), finder.getSummary().files_scanned);
    }
    {
        // Asked for by name, an excluded directory is scanned like any other.
        const root = try scratch.join("app/node_modules");
        defer allocator.free(root);
        var finder = dedupe.DupeFinder.init(allocator, config);
        defer finder.deinit();
        try finder.scan(&.{root});
        try testing.expectEqual(@as(u64, 1), finder.getSummary().files_scanned);
    }
}

test "size filters narrow the file groups without blinding directory analysis" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "dirs-sizefilter");
    defer scratch.deinit();

    inline for (.{ "p", "q", "r" }) |root| try buildProject(&scratch, root);
    try scratch.writeFile("r/src/main.c", "int main(void) { return 1; }\n");

    // Every fixture file is far below the window.
    var finder = dedupe.DupeFinder.init(allocator, .{ .analyze_dirs = true, .min_size = 1024 * 1024 });
    defer finder.deinit();
    const analysis = try scanDirs(&finder, &scratch);

    try testing.expectEqual(@as(usize, 0), finder.getGroups().len);

    // Had the walk honoured min_size, p, q and r would all look empty — and
    // r, which differs, would pass for a copy.
    const set = setWith(analysis, &scratch, "p") orelse return error.SetMissing;
    try testing.expect(setHas(set, &scratch, "q"));
    try testing.expect(!setHas(set, &scratch, "r"));
}

test "overlapping scan roots never make a file its own duplicate" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "roots");
    defer scratch.deinit();

    try scratch.makeDir("sub");
    try scratch.writeFile("sub/precious.txt", "the only copy of this content\n");
    try scratch.symLink("sub", "alias");

    const sub = try scratch.join("sub");
    defer allocator.free(sub);
    const alias = try scratch.join("alias");
    defer allocator.free(alias);

    // Nested root, the same root twice, and a symlinked spelling of a root.
    // Before roots were reconciled each of these listed precious.txt twice and
    // reported it as a duplicate of itself — "keep one, delete the rest" then
    // deletes the only copy.
    const cases = [_][]const []const u8{
        &.{ scratch.path, sub },
        &.{ sub, scratch.path },
        &.{ sub, sub },
        &.{ sub, alias },
    };
    for (cases) |roots| {
        var finder = dedupe.DupeFinder.init(allocator, .{});
        defer finder.deinit();
        try finder.scan(roots);

        try testing.expectEqual(@as(usize, 0), finder.getGroups().len);
        try testing.expectEqual(@as(u64, 1), finder.getSummary().files_scanned);
        try testing.expectEqual(@as(u64, 1), finder.getSummary().overlapping_roots);
    }
}

test "external contract: the directories JSON section parses with the documented shape" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "dirs-json");
    defer scratch.deinit();

    const hostile_dir = "dir\" ,\"injected\":1, \\ <b>";
    try buildProject(&scratch, "p");
    try buildProject(&scratch, "q");
    try buildProject(&scratch, hostile_dir);
    try scratch.writeFile(hostile_dir ++ "/src/extra.c", "only in the hostile copy\n");

    var finder = dedupe.DupeFinder.init(allocator, .{ .analyze_dirs = true });
    defer finder.deinit();
    try finder.scan(&.{scratch.path});

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = report.ReportWriter.init(allocator, .{ .format = .json });
    try writer.writeScanReport(&out.writer, finder.getGroups(), finder.getSummary(), finder.getDirAnalysis());

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // The five original keys plus "directories"; nothing injected by the name.
    try testing.expectEqual(@as(usize, 6), root.count());
    try testing.expect(root.get("injected") == null);

    const summary = root.get("summary").?.object;
    _ = summary.get("excluded_entries").?.integer;
    _ = summary.get("overlapping_roots").?.integer;

    const directories = root.get("directories").?.object;
    _ = directories.get("analyzed").?.integer;
    _ = directories.get("incomplete").?.integer;

    // {p, q}, then the three src/util copies (the hostile tree's src/ differs,
    // so that smaller set is not implied by any parent). Largest first.
    const sets = directories.get("identical_sets").?.array;
    try testing.expectEqual(@as(usize, 2), sets.items.len);
    try testing.expectEqual(@as(i64, 3), sets.items[1].object.get("count").?.integer);
    const set = sets.items[0].object;
    try testing.expectEqual(@as(usize, 64), set.get("digest").?.string.len);
    try testing.expectEqual(@as(i64, 2), set.get("count").?.integer);
    for ([_][]const u8{ "file_count", "bytes", "reclaimable" }) |field| _ = set.get(field).?.integer;
    for ([_][]const u8{ "bytes_human", "reclaimable_human" }) |field| _ = set.get(field).?.string;
    for (set.get("dirs").?.array.items) |dir| {
        _ = dir.object.get("path").?.string;
        _ = dir.object.get("newest_mtime").?.string;
        _ = dir.object.get("skipped_entries").?.integer;
    }

    // p and q are identical, so the pair with the hostile copy is reported
    // once, against the set's first path.
    const overlaps = directories.get("overlaps").?.array;
    try testing.expectEqual(@as(usize, 1), overlaps.items.len);
    const overlap = overlaps.items[0].object;
    try testing.expectEqualStrings("b_in_a", overlap.get("relation").?.string);

    const side_a = overlap.get("a").?.object;
    const side_b = overlap.get("b").?.object;
    try testing.expect(std.mem.endsWith(u8, side_a.get("path").?.string, hostile_dir));
    try testing.expect(std.mem.endsWith(u8, side_b.get("path").?.string, "/p"));
    try testing.expectEqual(@as(i64, 2), side_b.get("identical_copies").?.integer);
    for ([_]std.json.ObjectMap{ side_a, side_b }) |side| {
        for ([_][]const u8{
            "files",        "bytes",        "skipped_entries", "identical_copies",
            "shared_files", "shared_bytes", "only_count",
        }) |field| _ = side.get(field).?.integer;
        _ = side.get("bytes_human").?.string;
        _ = side.get("newest_mtime").?.string;
        _ = side.get("complete").?.bool;
        _ = side.get("only").?.array;
    }
    try testing.expectEqual(@as(usize, 1), side_a.get("only").?.array.items.len);

    // Without an analysis the document is exactly the one consumers already
    // parse: no "directories" key appears.
    var plain: std.Io.Writer.Allocating = .init(allocator);
    defer plain.deinit();
    try writer.writeScanReport(&plain.writer, finder.getGroups(), finder.getSummary(), null);
    var parsed_plain = try std.json.parseFromSlice(std.json.Value, allocator, plain.written(), .{});
    defer parsed_plain.deinit();
    try testing.expect(parsed_plain.value.object.get("directories") == null);
}

// ===========================================================================
// Result store, progress and cancellation
// ===========================================================================
//
// The store is checked against the JSON report of the same scan: two emitters
// that share no code below `DupeFinder`, one of which (JSON) is already
// anchored above by an independent parser. The desktop app's Rust reader is
// the second, fully independent implementation of the format.

const store = @import("store.zig");
const lib = @import("lib.zig");

/// Bounds-checked view over a store file, for tests.
const StoreView = struct {
    bytes: []const u8,
    header: store.Header,

    fn open(bytes: []const u8) !StoreView {
        if (bytes.len < store.header_size) return error.Truncated;
        const header = std.mem.bytesToValue(store.Header, bytes[0..store.header_size]);
        if (!std.mem.eql(u8, &header.magic, &store.magic)) return error.BadMagic;
        if (header.version != store.format_version) return error.BadVersion;
        if (header.file_size != bytes.len) return error.SizeMismatch;
        return .{ .bytes = bytes, .header = header };
    }

    fn count(self: *const StoreView, id: store.SectionId) u64 {
        return self.header.sections[@intFromEnum(id)].count;
    }

    fn record(self: *const StoreView, comptime T: type, id: store.SectionId, index: u64) !T {
        const section = self.header.sections[@intFromEnum(id)];
        if (index >= section.count) return error.OutOfRange;
        const start = section.offset + index * @sizeOf(T);
        if (start + @sizeOf(T) > self.bytes.len) return error.Truncated;
        return std.mem.bytesToValue(T, self.bytes[@intCast(start)..][0..@sizeOf(T)]);
    }

    fn string(self: *const StoreView, offset: u64, len: u32) ![]const u8 {
        const section = self.header.sections[@intFromEnum(store.SectionId.strings)];
        if (offset + len > section.count) return error.OutOfRange;
        const start: usize = @intCast(section.offset + offset);
        return self.bytes[start..][0..len];
    }
};

fn readWholeFile(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return out.toOwnedSlice(allocator);
}

fn setMtime(scratch: *const Scratch, sub_path: []const u8, seconds: i64) !void {
    const full = try scratch.joinZ(sub_path);
    defer scratch.allocator.free(full);
    const times = [2]std.c.timespec{
        .{ .sec = seconds, .nsec = 0 },
        .{ .sec = seconds, .nsec = 0 },
    };
    if (std.c.utimensat(std.c.AT.FDCWD, full.ptr, &times, 0) != 0) return error.SetMtimeFailed;
}

test "duplicate groups list the oldest file first, whatever order the walk found them in" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "oldest-first");
    defer scratch.deinit();

    // Names chosen so neither creation order nor name order matches age order.
    try scratch.writeFile("b-newest.txt", "same payload, three ages\n");
    try scratch.writeFile("c-oldest.txt", "same payload, three ages\n");
    try scratch.writeFile("a-middle.txt", "same payload, three ages\n");
    try setMtime(&scratch, "b-newest.txt", 1_700_003_000);
    try setMtime(&scratch, "c-oldest.txt", 1_700_001_000);
    try setMtime(&scratch, "a-middle.txt", 1_700_002_000);

    var finder = dedupe.DupeFinder.init(allocator, .{});
    defer finder.deinit();
    try finder.scan(&.{scratch.path});

    const groups = finder.getGroups();
    try testing.expectEqual(@as(usize, 1), groups.len);
    const infos = groups[0].file_infos.items;
    try testing.expect(pathIs(&scratch, infos[0].path, "c-oldest.txt"));
    try testing.expect(pathIs(&scratch, infos[1].path, "a-middle.txt"));
    try testing.expect(pathIs(&scratch, infos[2].path, "b-newest.txt"));
    // The legacy path list must agree with it.
    try testing.expect(pathIs(&scratch, groups[0].files.items[0], "c-oldest.txt"));
}

test "the result store holds exactly what the JSON report of the same scan says" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "store");
    defer scratch.deinit();

    const hostile_dir = "dir\" ,\"injected\":1, \\ <b>";
    try buildProject(&scratch, "p");
    try buildProject(&scratch, "q");
    try buildProject(&scratch, hostile_dir);
    try scratch.writeFile(hostile_dir ++ "/src/extra.c", "only in the hostile copy\n");

    var finder = dedupe.DupeFinder.init(allocator, .{ .analyze_dirs = true });
    defer finder.deinit();
    try finder.scan(&.{scratch.path});

    // The store goes next to the fixture, not into it, and is read back whole.
    var store_scratch = try Scratch.init(allocator, "store-out");
    defer store_scratch.deinit();
    const store_path = try store_scratch.joinZ("result.zds");
    defer allocator.free(store_path);

    try store.write(store_path, .{
        .groups = finder.getGroups(),
        .summary = finder.getSummary(),
        .failed_paths = finder.getFailedPathCount(),
        .analysis = finder.getDirAnalysis(),
    });
    // Written via a temporary name and renamed: nothing half-done is left.
    try testing.expect(try store_scratch.exists("result.zds"));
    try testing.expect(!try store_scratch.exists("result.zds.partial"));

    const bytes = try readWholeFile(allocator, store_path);
    defer allocator.free(bytes);
    const view = try StoreView.open(bytes);

    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();
    const writer = report.ReportWriter.init(allocator, .{ .format = .json });
    try writer.writeScanReport(&json_out.writer, finder.getGroups(), finder.getSummary(), finder.getDirAnalysis());
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Summary
    const summary = root.get("summary").?.object;
    try testing.expectEqual(summary.get("files_scanned").?.integer, @as(i64, @intCast(view.header.files_scanned)));
    try testing.expectEqual(summary.get("bytes_scanned").?.integer, @as(i64, @intCast(view.header.bytes_scanned)));
    try testing.expectEqual(summary.get("duplicate_groups").?.integer, @as(i64, @intCast(view.header.duplicate_groups)));
    try testing.expectEqual(summary.get("duplicate_files").?.integer, @as(i64, @intCast(view.header.duplicate_files)));
    try testing.expectEqual(summary.get("space_savings").?.integer, @as(i64, @intCast(view.header.space_savings)));
    try testing.expect(view.header.flags & store.flag_has_directories != 0);

    // Groups, in order, file for file.
    const json_groups = root.get("groups").?.array.items;
    try testing.expectEqual(@as(u64, json_groups.len), view.count(.groups));
    try testing.expect(json_groups.len > 0);
    var hex: [64]u8 = undefined;
    for (json_groups, 0..) |json_group, gi| {
        const group = try view.record(store.Group, .groups, gi);
        try testing.expectEqualStrings(json_group.object.get("hash").?.string, hasher.hashToHex(&group.hash, &hex));
        try testing.expectEqual(json_group.object.get("size").?.integer, @as(i64, @intCast(group.size)));
        const json_files = json_group.object.get("files").?.array.items;
        try testing.expectEqual(@as(u32, @intCast(json_files.len)), group.file_count);
        for (json_files, 0..) |json_file, fi| {
            const file = try view.record(store.GroupFile, .group_files, group.first_file + fi);
            try testing.expectEqualStrings(json_file.object.get("path").?.string, try view.string(file.path_offset, file.path_len));
            try testing.expect(file.mtime > 0);
        }
    }

    // Identical sets.
    const directories = root.get("directories").?.object;
    const json_sets = directories.get("identical_sets").?.array.items;
    try testing.expectEqual(@as(u64, json_sets.len), view.count(.sets));
    for (json_sets, 0..) |json_set, si| {
        const set = try view.record(store.Set, .sets, si);
        try testing.expectEqualStrings(json_set.object.get("digest").?.string, hasher.hashToHex(&set.digest, &hex));
        try testing.expectEqual(json_set.object.get("file_count").?.integer, @as(i64, @intCast(set.file_count)));
        try testing.expectEqual(json_set.object.get("bytes").?.integer, @as(i64, @intCast(set.bytes)));
        const json_dirs = json_set.object.get("dirs").?.array.items;
        try testing.expectEqual(@as(u32, @intCast(json_dirs.len)), set.dir_count);
        for (json_dirs, 0..) |json_dir, di| {
            const dir = try view.record(store.SetDir, .set_dirs, set.first_dir + di);
            try testing.expectEqualStrings(json_dir.object.get("path").?.string, try view.string(dir.path_offset, dir.path_len));
            try testing.expectEqual(json_dir.object.get("skipped_entries").?.integer, @as(i64, @intCast(dir.skipped_entries)));
        }
    }

    // Overlaps, including the hostile directory name and the only-here lists.
    const json_overlaps = directories.get("overlaps").?.array.items;
    try testing.expectEqual(@as(u64, json_overlaps.len), view.count(.overlaps));
    try testing.expect(json_overlaps.len > 0);
    const relation_names = [_][]const u8{ "same_content", "a_in_b", "b_in_a", "overlap" };
    for (json_overlaps, 0..) |json_overlap, oi| {
        const overlap = try view.record(store.Overlap, .overlaps, oi);
        try testing.expectEqualStrings(json_overlap.object.get("relation").?.string, relation_names[overlap.relation]);
        for ([_]store.Side{ overlap.a, overlap.b }, [_][]const u8{ "a", "b" }) |side, key| {
            const json_side = json_overlap.object.get(key).?.object;
            try testing.expectEqualStrings(json_side.get("path").?.string, try view.string(side.path_offset, side.path_len));
            try testing.expectEqual(json_side.get("files").?.integer, @as(i64, @intCast(side.files)));
            try testing.expectEqual(json_side.get("shared_files").?.integer, @as(i64, @intCast(side.shared_files)));
            try testing.expectEqual(json_side.get("only_count").?.integer, @as(i64, @intCast(side.only_count)));
            try testing.expectEqual(json_side.get("identical_copies").?.integer, @as(i64, @intCast(side.identical_copies)));
            try testing.expectEqual(json_side.get("complete").?.bool, side.complete == 1);
            const json_only = json_side.get("only").?.array.items;
            try testing.expectEqual(@as(u32, @intCast(json_only.len)), side.only_listed);
            for (json_only, 0..) |json_path, pi| {
                const only = try view.record(store.OnlyPath, .only_paths, side.first_only + pi);
                try testing.expectEqualStrings(json_path.string, try view.string(only.path_offset, only.path_len));
            }
        }
    }
}

test "a store that cannot be created reports it and leaves nothing behind" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "store-fail");
    defer scratch.deinit();

    const summary = std.mem.zeroes(types.DuplicateSummary);
    const target = try scratch.join("no-such-dir/result.zds");
    defer allocator.free(target);

    try testing.expectError(error.CannotCreateFile, store.write(target, .{ .groups = &.{}, .summary = &summary }));
    try testing.expect(!try scratch.exists("no-such-dir"));
}

test "a cancelled scan yields no results, not partial ones" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "cancel");
    defer scratch.deinit();
    try buildFixture(&scratch);

    var monitor: types.Monitor = .{};
    monitor.cancel();

    var finder = dedupe.DupeFinder.init(allocator, .{ .monitor = &monitor });
    defer finder.deinit();

    // Files whose hashing was skipped look exactly like unique files. Building
    // groups from a stopped run would silently under-report duplicates.
    try testing.expectError(error.Cancelled, finder.scan(&.{scratch.path}));
    try testing.expectEqual(@as(usize, 0), finder.getGroups().len);
}

test "a hash in progress stops between reads once cancelled" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "cancel-hash");
    defer scratch.deinit();

    const data = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(data);
    @memset(data, 0x5a);
    try scratch.writeFile("big.bin", data);
    const path = try scratch.join("big.bin");
    defer allocator.free(path);

    var monitor: types.Monitor = .{};
    var file_hasher = hasher.FileHasher.init(.blake3);
    file_hasher.monitor = &monitor;

    _ = try file_hasher.hashFile(path);
    monitor.cancel();
    try testing.expectError(error.Cancelled, file_hasher.hashFile(path));
}

test "FFI: progress is readable, cancel stops a run, and the context recovers" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "ffi-run");
    defer scratch.deinit();
    try buildFixture(&scratch);

    var out_scratch = try Scratch.init(allocator, "ffi-out");
    defer out_scratch.deinit();
    const store_path = try out_scratch.joinZ("result.zds");
    defer allocator.free(store_path);

    const ctx = lib.zdedupe_init();
    defer lib.zdedupe_free(ctx);
    try testing.expectEqual(@as(c_int, 0), lib.zdedupe_add_path(ctx, scratch.path.ptr));

    // Cancel requested before the run starts: status 2, and no file appears.
    lib.zdedupe_cancel(ctx);
    try testing.expectEqual(@as(c_int, 2), lib.zdedupe_run_to_file(ctx, store_path.ptr));
    try testing.expect(!try out_scratch.exists("result.zds"));

    // The same context then runs normally: a cancel does not stick.
    try testing.expectEqual(@as(c_int, 0), lib.zdedupe_run_to_file(ctx, store_path.ptr));

    var progress: lib.ZDedupeProgress = undefined;
    lib.zdedupe_get_progress(ctx, &progress);
    try testing.expectEqual(@intFromEnum(types.Monitor.Phase.done), progress.phase);
    try testing.expectEqual(@as(u64, 4), progress.files_found);

    const bytes = try readWholeFile(allocator, store_path);
    defer allocator.free(bytes);
    const view = try StoreView.open(bytes);
    try testing.expectEqual(@as(u64, 1), view.count(.groups));
    try testing.expectEqual(@as(u64, 3), view.count(.group_files));
    try testing.expect(view.header.flags & store.flag_has_directories == 0);

    // Compare mode has no store representation.
    lib.zdedupe_set_mode(ctx, 1);
    try testing.expectEqual(@as(c_int, 3), lib.zdedupe_run_to_file(ctx, store_path.ptr));
}

/// Progress callbacks carry no context, so the test reaches its monitor here.
var cancel_at_full_hash: ?*types.Monitor = null;

fn cancelWhenFullHashingStarts(progress: *const types.Progress) void {
    if (progress.phase == .full_hashing) {
        if (cancel_at_full_hash) |monitor| monitor.cancel();
    }
}

test "cancelling during hashing is an error, never a clean 'no duplicates'" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "cancel-midway");
    defer scratch.deinit();
    try buildFixture(&scratch);

    var monitor: types.Monitor = .{};
    cancel_at_full_hash = &monitor;
    defer cancel_at_full_hash = null;

    var finder = dedupe.DupeFinder.init(allocator, .{ .monitor = &monitor });
    defer finder.deinit();
    finder.setProgressCallback(cancelWhenFullHashingStarts);

    // The walk and size grouping complete; the stop lands as full hashing
    // begins, so no file gets a hash. A file without a hash is indistinguishable
    // from a unique one — returning normally here would tell the user this
    // tree (which holds three identical files) has no duplicates at all.
    try testing.expectError(error.Cancelled, finder.scan(&.{scratch.path}));
    try testing.expectEqual(@as(usize, 0), finder.getGroups().len);
}

test "a failed write never touches the store that is already there" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "store-atomic");
    defer scratch.deinit();

    const previous = "a previous, complete result store";
    try scratch.writeFile("result.zds", previous);
    // Occupy the temporary name with a directory, so the new store cannot even
    // be started. A writer that goes straight at the final path would not
    // notice — and would have truncated the old store before failing later.
    try scratch.makeDir("result.zds.partial");

    const summary = std.mem.zeroes(types.DuplicateSummary);
    const target = try scratch.joinZ("result.zds");
    defer allocator.free(target);

    try testing.expectError(error.CannotCreateFile, store.write(target, .{ .groups = &.{}, .summary = &summary }));

    const after = try readWholeFile(allocator, target);
    defer allocator.free(after);
    try testing.expectEqualStrings(previous, after);
}

test "FFI: zdedupe_hash_file agrees with the scan and refuses what the scan refuses" {
    const allocator = testing.allocator;
    var scratch = try Scratch.init(allocator, "ffi-hash");
    defer scratch.deinit();
    try buildFixture(&scratch);

    var finder = dedupe.DupeFinder.init(allocator, .{});
    defer finder.deinit();
    try finder.scan(&.{scratch.path});
    const group = finder.getGroups()[0];

    // Every file of the group hashes, now, to the hash the scan recorded.
    for (group.file_infos.items) |info| {
        const path_z = try allocator.dupeZ(u8, info.path);
        defer allocator.free(path_z);
        var digest: [32]u8 = undefined;
        try testing.expectEqual(@as(c_int, 0), lib.zdedupe_hash_file(path_z.ptr, false, &digest));
        try testing.expect(hasher.hashEqual(&digest, &group.hash));
    }

    // The published BLAKE3 vector, through the FFI.
    const data = try allocator.alloc(u8, 4096);
    defer allocator.free(data);
    vectorInput(data);
    try scratch.writeFile("vector.bin", data);
    const vector_path = try scratch.joinZ("vector.bin");
    defer allocator.free(vector_path);
    var digest: [32]u8 = undefined;
    var hex: [64]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), lib.zdedupe_hash_file(vector_path.ptr, false, &digest));
    try testing.expectEqualStrings(B3_4096, hasher.hashToHex(&digest, &hex));
    try testing.expectEqual(@as(c_int, 0), lib.zdedupe_hash_file(vector_path.ptr, true, &digest));
    try testing.expectEqualStrings(SHA_4096, hasher.hashToHex(&digest, &hex));

    // A directory, a missing file and NULLs are failures, not digests.
    try testing.expectEqual(@as(c_int, -1), lib.zdedupe_hash_file(scratch.path.ptr, false, &digest));
    const missing = try scratch.joinZ("no-such-file");
    defer allocator.free(missing);
    try testing.expectEqual(@as(c_int, -1), lib.zdedupe_hash_file(missing.ptr, false, &digest));
    try testing.expectEqual(@as(c_int, -1), lib.zdedupe_hash_file(null, false, &digest));
    try testing.expectEqual(@as(c_int, -1), lib.zdedupe_hash_file(vector_path.ptr, false, null));
}
