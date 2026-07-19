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

    // open() on a directory succeeds on both Darwin and Linux, but read()
    // returns -1/EISDIR — the exact `n < 0` case that used to be treated as
    // EOF. Two such paths previously hashed to BLAKE3("") and were therefore
    // reported as duplicates of each other.
    try scratch.makeDir("dir_a");
    try scratch.makeDir("dir_b");

    const a = try scratch.join("dir_a");
    defer allocator.free(a);
    const b = try scratch.join("dir_b");
    defer allocator.free(b);

    try testing.expectError(error.ReadFailed, hasher.hashFileBlake3(a, null));
    try testing.expectError(error.ReadFailed, hasher.hashFileSha256(a, null));
    try testing.expectError(error.ReadFailed, hasher.hashFileBlake3(b, null));

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
