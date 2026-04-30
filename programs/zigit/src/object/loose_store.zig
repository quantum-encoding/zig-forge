// Loose-object store rooted at .git/objects/.
//
//   .git/objects/ab/cdef0123...    ← oid hex split: first 2 chars =
//                                     directory, remaining 38 = filename
//   contents = zlib(  "<kind> <size>\x00" || payload  )
//
// Read path: read file → zlib-inflate → split header at \x00 → parse
// "<kind> <size>" → return payload bytes (caller-owned).
//
// Write path: build header in front of payload → SHA-1 → zlib-deflate
// in memory → write to a temp file in the same directory and rename
// into place (atomic on every sane filesystem). Writing is a no-op
// if the file already exists — git is content-addressed, the bytes
// are the same.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const oid_mod = @import("oid.zig");
const kind_mod = @import("kind.zig");
const Oid = oid_mod.Oid;
const OidPrefix = oid_mod.OidPrefix;
const Kind = kind_mod.Kind;

pub const LoadedObject = struct {
    kind: Kind,
    payload: []u8,

    pub fn deinit(self: *LoadedObject, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const LooseStore = struct {
    /// Owned by the caller (Repository); we just borrow the handle.
    objects_dir: Dir,
    io: Io,

    pub fn init(objects_dir: Dir, io: Io) LooseStore {
        return .{ .objects_dir = objects_dir, .io = io };
    }

    pub fn write(self: *LooseStore, allocator: std.mem.Allocator, kind: Kind, payload: []const u8, oid: Oid) !void {
        var hex: [40]u8 = undefined;
        oid.toHex(&hex);

        // Make sure ab/ exists.
        try self.objects_dir.createDirPath(self.io, hex[0..2]);

        // Skip if it's already there — content-addressed, byte-identical.
        var path_buf: [50]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ hex[0..2], hex[2..] });

        if (self.objects_dir.access(self.io, path, .{})) {
            return; // already stored
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        // Build the framed header.
        var header_buf: [32]u8 = undefined;
        const header = try std.fmt.bufPrint(
            &header_buf,
            "{s} {d}\x00",
            .{ kind.name(), payload.len },
        );

        // zlib-deflate (header || payload) into memory. Compress requires
        // at least 8 bytes of buffer capacity at init time.
        var compressed: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
        defer compressed.deinit();

        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var compress = try std.compress.flate.Compress.init(
            &compressed.writer,
            &window,
            .zlib,
            .default,
        );
        try compress.writer.writeAll(header);
        try compress.writer.writeAll(payload);
        try compress.finish();

        const compressed_bytes = compressed.written();

        // Atomic rename: write into ab/.tmp.<rand>, then rename to final name.
        var rand_bytes: [8]u8 = undefined;
        self.io.random(&rand_bytes);
        const rand_suffix = std.mem.readInt(u64, &rand_bytes, .little);
        var tmp_name_buf: [64]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(
            &tmp_name_buf,
            "{s}/.tmp.{x}",
            .{ hex[0..2], rand_suffix },
        );

        try self.objects_dir.writeFile(self.io, .{ .sub_path = tmp_name, .data = compressed_bytes });
        try self.objects_dir.rename(tmp_name, self.objects_dir, path, self.io);
    }

    pub fn read(self: *LooseStore, allocator: std.mem.Allocator, oid: Oid) !LoadedObject {
        var hex: [40]u8 = undefined;
        oid.toHex(&hex);

        var path_buf: [50]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ hex[0..2], hex[2..] });

        // Read entire compressed file (loose objects are individually small).
        const compressed = self.objects_dir.readFileAlloc(
            self.io,
            path,
            allocator,
            .unlimited,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.ObjectNotFound,
            else => return err,
        };
        defer allocator.free(compressed);

        var src_reader: std.Io.Reader = .fixed(compressed);
        var inflate_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress = std.compress.flate.Decompress.init(&src_reader, .zlib, &inflate_buf);

        var inflated: std.Io.Writer.Allocating = .init(allocator);
        defer inflated.deinit();
        _ = try decompress.reader.streamRemaining(&inflated.writer);

        const bytes = inflated.written();

        // Split header at the NUL.
        const nul = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.MalformedObject;
        const header = bytes[0..nul];

        // Parse "<kind> <size>"
        const space = std.mem.indexOfScalar(u8, header, ' ') orelse return error.MalformedObject;
        const kind_str = header[0..space];
        const size_str = header[space + 1 ..];

        const kind = Kind.parse(kind_str) orelse return error.UnknownKind;
        const size = try std.fmt.parseInt(usize, size_str, 10);

        const payload_start = nul + 1;
        if (bytes.len - payload_start != size) return error.SizeMismatch;

        const payload = try allocator.dupe(u8, bytes[payload_start..]);
        return .{ .kind = kind, .payload = payload };
    }

    /// Resolve a 4-40 char hex prefix to a single Oid.
    /// Errors if zero or more than one object matches.
    pub fn resolvePrefix(self: *LooseStore, hex: []const u8) !Oid {
        const prefix = try OidPrefix.fromHex(hex);

        if (hex.len == 40) return Oid.fromHex(hex);

        var subdir_name: [2]u8 = undefined;
        std.mem.copyForwards(u8, &subdir_name, hex[0..2]);

        var subdir = self.objects_dir.openDir(self.io, &subdir_name, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return error.ObjectNotFound,
            else => return err,
        };
        defer subdir.close(self.io);

        var found: ?Oid = null;
        var it = subdir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len != 38) continue;

            var full_hex: [40]u8 = undefined;
            std.mem.copyForwards(u8, full_hex[0..2], &subdir_name);
            std.mem.copyForwards(u8, full_hex[2..], entry.name);

            const candidate = Oid.fromHex(&full_hex) catch continue;
            if (!prefix.matches(candidate)) continue;

            if (found != null) return error.AmbiguousOidPrefix;
            found = candidate;
        }

        return found orelse error.ObjectNotFound;
    }
};

const testing = std.testing;

test "round-trip a blob via tmp loose store" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = LooseStore.init(tmp.dir, io);

    const payload = "hello, zigit\n";
    const oid = computeOid(.blob, payload);
    try store.write(allocator, .blob, payload, oid);

    var loaded = try store.read(allocator, oid);
    defer loaded.deinit(allocator);

    try testing.expectEqual(Kind.blob, loaded.kind);
    try testing.expectEqualStrings(payload, loaded.payload);
}

test "write is a no-op on duplicate oid" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = LooseStore.init(tmp.dir, io);
    const payload = "double tap\n";
    const oid = computeOid(.blob, payload);

    try store.write(allocator, .blob, payload, oid);
    try store.write(allocator, .blob, payload, oid);

    var loaded = try store.read(allocator, oid);
    defer loaded.deinit(allocator);
    try testing.expectEqualStrings(payload, loaded.payload);
}

test "resolvePrefix unique hit" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = LooseStore.init(tmp.dir, io);
    const oid = computeOid(.blob, "abc");
    try store.write(allocator, .blob, "abc", oid);

    var hex: [40]u8 = undefined;
    oid.toHex(&hex);

    const resolved = try store.resolvePrefix(hex[0..6]);
    try testing.expect(resolved.eql(oid));
}

test "resolvePrefix miss returns ObjectNotFound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = LooseStore.init(tmp.dir, testing.io);
    try testing.expectError(
        error.ObjectNotFound,
        store.resolvePrefix("deadbeef"),
    );
}

// Re-defined locally to avoid a circular import with object/mod.zig.
fn computeOid(kind: Kind, payload: []const u8) Oid {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var header_buf: [32]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "{s} {d}\x00",
        .{ kind.name(), payload.len },
    ) catch unreachable;
    hasher.update(header);
    hasher.update(payload);
    var bytes: [20]u8 = undefined;
    hasher.final(&bytes);
    return .{ .bytes = bytes };
}
