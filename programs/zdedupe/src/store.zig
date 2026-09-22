//! Binary result store — scan results as a file a host can page through
//!
//! The JSON report is one document: to show row 40,000 a host has to receive,
//! copy and parse rows 0–39,999 first, and a whole-disk scan makes that document
//! hundreds of megabytes (measured: 106 MB of JSON, plus 570 MB once parsed,
//! for 642k files). This format is the opposite trade: fixed-size records in
//! flat sections, so a host maps the file and reads exactly the rows it is
//! about to draw. Nothing is parsed, nothing is held in memory, and a finished
//! scan can be reopened later for free.
//!
//! The writer streams: it never builds the file in memory. Records only refer
//! to strings by offset, and offsets are plain running sums over a fixed
//! iteration order, so the record sections are written first with offsets
//! computed on the fly, and the string section is then written by walking the
//! same data in the same order (see `StringCursor`).
//!
//! Layout — little-endian, every section 8-byte aligned:
//!
//!     Header (256 bytes)           magic, version, summary, section table
//!     GROUPS       Group[]         duplicate groups, largest savings first
//!     GROUP_FILES  GroupFile[]     their files, oldest first within a group
//!     SETS         Set[]           identical-directory sets
//!     SET_DIRS     SetDir[]        their member directories
//!     OVERLAPS     Overlap[]       overlapping directory pairs
//!     ONLY_PATHS   OnlyPath[]      "exists only on this side" paths
//!     STRINGS      u8[]            path bytes, referenced as (offset, len)
//!
//! String offsets are relative to the start of STRINGS. Record layouts are
//! `extern struct`s with explicit padding and comptime-checked sizes, and are
//! mirrored field for field by the Rust reader in the desktop app
//! (`src-tauri/src/store.rs`) — an independent implementation, which is what
//! the app's tests use to anchor this writer. Readers must bounds-check every
//! offset: the file lives on disk and can be truncated or replaced.
//!
//! `Reader` is this file's own reader, over bytes the caller has mapped (see
//! `session.zig`). It validates the header and the whole section table up
//! front and bounds-checks every record and string reference, so a truncated
//! or corrupted store yields an error rather than a trap or a wild read.
//!
//! The file is written to `<path>.partial` and renamed into place, so a reader
//! never sees a half-written store.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const dirs = @import("dirs.zig");
const libc = std.c;

comptime {
    // Records are written as raw bytes. Every supported target is
    // little-endian; fail the build rather than emit a byte-swapped file.
    if (builtin.cpu.arch.endian() != .little) @compileError("zdedupe result store requires a little-endian target");
}

pub const magic = "ZDSTORE1".*;
pub const format_version: u32 = 1;
pub const header_size: usize = 256;

pub const flag_has_directories: u64 = 1 << 0;
pub const flag_sha256: u64 = 1 << 1;

pub const SectionId = enum(usize) {
    groups = 0,
    group_files = 1,
    sets = 2,
    set_dirs = 3,
    overlaps = 4,
    only_paths = 5,
    strings = 6,
};
pub const section_count = 7;

pub const Section = extern struct {
    /// Absolute file offset of the section's first byte.
    offset: u64 = 0,
    /// Number of records (bytes, for STRINGS).
    count: u64 = 0,
};

pub const Header = extern struct {
    magic: [8]u8 = magic,
    version: u32 = format_version,
    header_size: u32 = header_size,
    flags: u64 = 0,
    /// Total file size; a reader rejects a file whose length disagrees.
    file_size: u64 = 0,
    /// Seconds since the epoch, UTC.
    generated_at: i64 = 0,

    files_scanned: u64 = 0,
    bytes_scanned: u64 = 0,
    duplicate_groups: u64 = 0,
    duplicate_files: u64 = 0,
    space_savings: u64 = 0,
    scan_time_ns: u64 = 0,
    excluded_entries: u64 = 0,
    overlapping_roots: u64 = 0,
    /// Scan roots that could not be walked at all.
    failed_paths: u64 = 0,
    dirs_analyzed: u64 = 0,
    dirs_incomplete: u64 = 0,

    sections: [section_count]Section = @splat(.{}),
    reserved: [16]u8 = @splat(0),
};

pub const Group = extern struct {
    hash: [32]u8,
    /// Size of each file in the group.
    size: u64,
    /// Index of the group's first record in GROUP_FILES.
    first_file: u64,
    file_count: u32,
    _pad: u32 = 0,
};

pub const GroupFile = extern struct {
    path_offset: u64,
    /// Modification time, seconds since the epoch.
    mtime: i64,
    path_len: u32,
    _pad: u32 = 0,
};

pub const Set = extern struct {
    digest: [32]u8,
    /// Regular files in each copy (recursive).
    file_count: u64,
    /// Logical size of each copy.
    bytes: u64,
    /// Index of the set's first record in SET_DIRS.
    first_dir: u64,
    dir_count: u32,
    _pad: u32 = 0,
};

pub const SetDir = extern struct {
    path_offset: u64,
    newest_mtime: i64,
    skipped_entries: u64,
    path_len: u32,
    _pad: u32 = 0,
};

pub const Side = extern struct {
    path_offset: u64,
    files: u64,
    bytes: u64,
    newest_mtime: i64,
    skipped_entries: u64,
    identical_copies: u64,
    shared_files: u64,
    shared_bytes: u64,
    /// Exact count; `only_listed` of them are in ONLY_PATHS.
    only_count: u64,
    /// Index of the side's first record in ONLY_PATHS.
    first_only: u64,
    path_len: u32,
    only_listed: u32,
    /// 1 if everything beneath could be read.
    complete: u32,
    _pad: u32 = 0,
};

/// `relation` values; numbering is part of the format.
pub const Relation = enum(u32) { same_content = 0, a_in_b = 1, b_in_a = 2, overlap = 3 };

pub const Overlap = extern struct {
    relation: u32,
    _pad: u32 = 0,
    a: Side,
    b: Side,
};

pub const OnlyPath = extern struct {
    path_offset: u64,
    path_len: u32,
    _pad: u32 = 0,
};

comptime {
    // The Rust reader hard-codes these. If one changes, bump `format_version`.
    std.debug.assert(@sizeOf(Header) == header_size);
    std.debug.assert(@sizeOf(Section) == 16);
    std.debug.assert(@sizeOf(Group) == 56);
    std.debug.assert(@sizeOf(GroupFile) == 24);
    std.debug.assert(@sizeOf(Set) == 64);
    std.debug.assert(@sizeOf(SetDir) == 32);
    std.debug.assert(@sizeOf(Side) == 96);
    std.debug.assert(@sizeOf(Overlap) == 200);
    std.debug.assert(@sizeOf(OnlyPath) == 16);
}

/// Everything a store is written from; all borrowed.
pub const Source = struct {
    groups: []const types.DuplicateGroup,
    summary: *const types.DuplicateSummary,
    failed_paths: u64 = 0,
    analysis: ?*const dirs.Analysis = null,
    algorithm: types.Config.HashAlgorithm = .blake3,
};

pub const WriteError = error{
    PathTooLong,
    CannotCreateFile,
    WriteFailed,
    RenameFailed,
    /// A path is longer than a u32 can describe (it never is; this keeps the
    /// cast honest).
    StringTooLong,
};

/// Write `source` to `path`, atomically.
pub fn write(path: []const u8, source: Source) WriteError!void {
    var partial_buf: [4096 + 16]u8 = undefined;
    var final_buf: [4096]u8 = undefined;
    if (path.len >= final_buf.len) return error.PathTooLong;

    const final_z = std.fmt.bufPrintZ(&final_buf, "{s}", .{path}) catch return error.PathTooLong;
    const partial_z = std.fmt.bufPrintZ(&partial_buf, "{s}.partial", .{path}) catch return error.PathTooLong;

    // 0600: results list the user's files; nobody else needs to read them.
    const fd = libc.open(partial_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(libc.mode_t, 0o600));
    if (fd < 0) return error.CannotCreateFile;

    var out: FileWriter = .{ .fd = fd };
    writeAll(&out, source) catch |err| {
        _ = libc.close(fd);
        _ = libc.unlink(partial_z.ptr);
        return err;
    };
    if (libc.close(fd) != 0) {
        _ = libc.unlink(partial_z.ptr);
        return error.WriteFailed;
    }

    if (libc.rename(partial_z.ptr, final_z.ptr) != 0) {
        _ = libc.unlink(partial_z.ptr);
        return error.RenameFailed;
    }
}

fn writeAll(out: *FileWriter, source: Source) WriteError!void {
    const summary = source.summary;
    var header: Header = .{
        .flags = (if (source.analysis != null) flag_has_directories else 0) |
            (if (source.algorithm == .sha256) flag_sha256 else 0),
        .generated_at = nowSeconds(),
        .files_scanned = summary.files_scanned,
        .bytes_scanned = summary.bytes_scanned,
        .duplicate_groups = summary.duplicate_groups,
        .duplicate_files = summary.duplicate_files,
        .space_savings = summary.space_savings,
        .scan_time_ns = summary.scan_time_ns,
        .excluded_entries = summary.excluded_entries,
        .overlapping_roots = summary.overlapping_roots,
        .failed_paths = source.failed_paths,
    };
    if (source.analysis) |analysis| {
        header.dirs_analyzed = analysis.dirs_analyzed;
        header.dirs_incomplete = analysis.dirs_incomplete;
    }

    const identical_sets: []const dirs.IdenticalSet = if (source.analysis) |a| a.identical_sets else &.{};
    const overlaps: []const dirs.Overlap = if (source.analysis) |a| a.overlaps else &.{};

    // Placeholder; rewritten once the section table is known.
    try out.write(std.mem.asBytes(&header));

    // Hands out string offsets in the one fixed order that `writeStrings`
    // later reproduces: group files, set dirs, overlap side paths, only-paths.
    var strings: StringCursor = .{};

    // GROUPS
    try beginSection(out, &header, .groups);
    var next_file: u64 = 0;
    for (source.groups) |*group| {
        try out.write(std.mem.asBytes(&Group{
            .hash = group.hash,
            .size = group.size,
            .first_file = next_file,
            .file_count = @intCast(group.file_infos.items.len),
        }));
        next_file += group.file_infos.items.len;
    }
    endSection(out, &header, .groups, source.groups.len);

    // GROUP_FILES
    try beginSection(out, &header, .group_files);
    for (source.groups) |*group| {
        for (group.file_infos.items) |info| {
            const ref = try strings.take(info.path);
            try out.write(std.mem.asBytes(&GroupFile{
                .path_offset = ref.offset,
                .path_len = ref.len,
                .mtime = info.mtime,
            }));
        }
    }
    endSection(out, &header, .group_files, next_file);

    // SETS
    try beginSection(out, &header, .sets);
    var next_dir: u64 = 0;
    for (identical_sets) |*set| {
        try out.write(std.mem.asBytes(&Set{
            .digest = set.digest,
            .file_count = set.file_count,
            .bytes = set.bytes,
            .first_dir = next_dir,
            .dir_count = @intCast(set.dirs.len),
        }));
        next_dir += set.dirs.len;
    }
    endSection(out, &header, .sets, identical_sets.len);

    // SET_DIRS
    try beginSection(out, &header, .set_dirs);
    for (identical_sets) |*set| {
        for (set.dirs) |dir| {
            const ref = try strings.take(dir.path);
            try out.write(std.mem.asBytes(&SetDir{
                .path_offset = ref.offset,
                .path_len = ref.len,
                .newest_mtime = dir.newest_mtime,
                .skipped_entries = dir.skipped_entries,
            }));
        }
    }
    endSection(out, &header, .set_dirs, next_dir);

    // OVERLAPS. Side paths come before only-paths in string order, so the
    // only-path offsets are assigned in a second pass below; here each side
    // just reserves its run of ONLY_PATHS records.
    try beginSection(out, &header, .overlaps);
    var next_only: u64 = 0;
    for (overlaps) |*overlap| {
        var record: Overlap = .{
            .relation = @intFromEnum(relationOf(overlap.relation)),
            .a = undefined,
            .b = undefined,
        };
        record.a = try sideRecord(&overlap.a, &strings, &next_only);
        record.b = try sideRecord(&overlap.b, &strings, &next_only);
        try out.write(std.mem.asBytes(&record));
    }
    endSection(out, &header, .overlaps, overlaps.len);

    // ONLY_PATHS
    try beginSection(out, &header, .only_paths);
    for (overlaps) |*overlap| {
        for ([_]*const dirs.OverlapSide{ &overlap.a, &overlap.b }) |side| {
            for (side.only) |only_path| {
                const ref = try strings.take(only_path);
                try out.write(std.mem.asBytes(&OnlyPath{ .path_offset = ref.offset, .path_len = ref.len }));
            }
        }
    }
    endSection(out, &header, .only_paths, next_only);

    // STRINGS — same order as the `strings.take` calls above.
    try beginSection(out, &header, .strings);
    const strings_start = out.offset;
    for (source.groups) |*group| {
        for (group.file_infos.items) |info| try out.write(info.path);
    }
    for (identical_sets) |*set| {
        for (set.dirs) |dir| try out.write(dir.path);
    }
    for (overlaps) |*overlap| {
        try out.write(overlap.a.path);
        try out.write(overlap.b.path);
    }
    for (overlaps) |*overlap| {
        for ([_]*const dirs.OverlapSide{ &overlap.a, &overlap.b }) |side| {
            for (side.only) |only_path| try out.write(only_path);
        }
    }
    // The cursor predicted these offsets before a single string was written;
    // if the two orders ever drift apart every path in the file is wrong.
    if (out.offset - strings_start != strings.next) return error.WriteFailed;
    endSection(out, &header, .strings, strings.next);

    try out.flush();
    header.file_size = out.offset;
    try out.rewriteHeader(std.mem.asBytes(&header));
}

fn sideRecord(side: *const dirs.OverlapSide, strings: *StringCursor, next_only: *u64) WriteError!Side {
    const ref = try strings.take(side.path);
    const record: Side = .{
        .path_offset = ref.offset,
        .path_len = ref.len,
        .files = side.files,
        .bytes = side.bytes,
        .newest_mtime = side.newest_mtime,
        .skipped_entries = side.skipped_entries,
        .identical_copies = side.identical_copies,
        .shared_files = side.shared_files,
        .shared_bytes = side.shared_bytes,
        .only_count = side.only_count,
        .first_only = next_only.*,
        .only_listed = @intCast(side.only.len),
        .complete = @intFromBool(side.complete),
    };
    next_only.* += side.only.len;
    return record;
}

fn relationOf(relation: dirs.Relation) Relation {
    return switch (relation) {
        .same_content => .same_content,
        .a_in_b => .a_in_b,
        .b_in_a => .b_in_a,
        .overlap => .overlap,
    };
}

/// Assigns string offsets as running sums.
const StringCursor = struct {
    next: u64 = 0,

    const Ref = struct { offset: u64, len: u32 };

    fn take(self: *StringCursor, string: []const u8) WriteError!Ref {
        const len = std.math.cast(u32, string.len) orelse return error.StringTooLong;
        const ref: Ref = .{ .offset = self.next, .len = len };
        self.next += len;
        return ref;
    }
};

fn beginSection(out: *FileWriter, header: *Header, id: SectionId) WriteError!void {
    try out.alignTo(8);
    header.sections[@intFromEnum(id)].offset = out.offset;
}

fn endSection(out: *const FileWriter, header: *Header, id: SectionId, count: u64) void {
    _ = out;
    header.sections[@intFromEnum(id)].count = count;
}

fn nowSeconds() i64 {
    var tv: libc.timeval = undefined;
    _ = libc.gettimeofday(&tv, null);
    return tv.sec;
}

/// Buffered, offset-tracking writer over a raw fd.
const FileWriter = struct {
    fd: c_int,
    /// Logical offset: bytes accepted so far, buffered or not.
    offset: u64 = 0,
    used: usize = 0,
    buf: [64 * 1024]u8 = undefined,

    fn write(self: *FileWriter, bytes: []const u8) WriteError!void {
        var rest = bytes;
        while (rest.len > 0) {
            if (self.used == self.buf.len) try self.flush();
            const n = @min(rest.len, self.buf.len - self.used);
            @memcpy(self.buf[self.used..][0..n], rest[0..n]);
            self.used += n;
            rest = rest[n..];
        }
        self.offset += bytes.len;
    }

    fn alignTo(self: *FileWriter, comptime alignment: u64) WriteError!void {
        const zeros: [alignment]u8 = @splat(0);
        const remainder = self.offset % alignment;
        if (remainder != 0) try self.write(zeros[0..@intCast(alignment - remainder)]);
    }

    fn flush(self: *FileWriter) WriteError!void {
        var written: usize = 0;
        while (written < self.used) {
            const n = libc.write(self.fd, self.buf[written..].ptr, self.used - written);
            if (n < 0) {
                if (libc.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            written += @intCast(n);
        }
        self.used = 0;
    }

    /// Overwrite the header at offset 0. Call after `flush`.
    fn rewriteHeader(self: *FileWriter, bytes: []const u8) WriteError!void {
        std.debug.assert(self.used == 0);
        var written: usize = 0;
        while (written < bytes.len) {
            const n = libc.pwrite(self.fd, bytes[written..].ptr, bytes.len - written, @intCast(written));
            if (n < 0) {
                if (libc.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            written += @intCast(n);
        }
    }
};

// ============================================================================
// Reading
// ============================================================================

/// Bytes of one record section, per section. STRINGS counts bytes, so its
/// record is one byte; everything else is derived from the layout above rather
/// than restated as a number.
pub fn recordSize(id: SectionId) usize {
    return switch (id) {
        .groups => @sizeOf(Group),
        .group_files => @sizeOf(GroupFile),
        .sets => @sizeOf(Set),
        .set_dirs => @sizeOf(SetDir),
        .overlaps => @sizeOf(Overlap),
        .only_paths => @sizeOf(OnlyPath),
        .strings => 1,
    };
}

pub const ReadError = error{
    /// Not a store, from another format version, or its internal offsets do
    /// not fit inside it.
    Invalid,
    /// A record index or string reference points outside its section.
    OutOfRange,
};

/// One file of a duplicate group. `path` borrows the mapped bytes.
pub const FileRef = struct {
    path: []const u8,
    /// Modification time, seconds since the epoch.
    mtime: i64,
};

/// One member directory of an identical set. `path` borrows the mapped bytes.
pub const DirRef = struct {
    path: []const u8,
    /// Newest file modification time in the subtree, seconds since the epoch.
    newest_mtime: i64,
    /// Entries beneath it the scan deliberately ignored.
    skipped_entries: u64,
};

/// A read-only view over a mapped store. Holds no allocations: every accessor
/// returns values, or slices borrowed from `bytes`.
pub const Reader = struct {
    bytes: []const u8,
    header: Header,

    /// Why a file was rejected, for the message a host shows. Set alongside
    /// `error.Invalid`; `init` is the only producer.
    pub const Rejection = enum {
        shorter_than_a_header,
        not_a_zdedupe_result_store,
        unsupported_format_version,
        unexpected_header_size,
        file_size_disagrees_with_the_header,
        a_section_lies_outside_the_file,

        pub fn message(self: Rejection) []const u8 {
            return switch (self) {
                .shorter_than_a_header => "shorter than a header",
                .not_a_zdedupe_result_store => "not a zdedupe result store",
                .unsupported_format_version => "unsupported format version",
                .unexpected_header_size => "unexpected header size",
                .file_size_disagrees_with_the_header => "file size does not match its header (truncated?)",
                .a_section_lies_outside_the_file => "section lies outside the file",
            };
        }
    };

    /// Validate `bytes` as a store. `why`, when given, receives the reason for
    /// an `error.Invalid`.
    pub fn init(bytes: []const u8, why: ?*Rejection) ReadError!Reader {
        const reject = struct {
            fn set(out: ?*Rejection, reason: Rejection) ReadError {
                if (out) |o| o.* = reason;
                return error.Invalid;
            }
        }.set;

        if (bytes.len < header_size) return reject(why, .shorter_than_a_header);
        const header = std.mem.bytesToValue(Header, bytes[0..header_size]);
        if (!std.mem.eql(u8, &header.magic, &magic)) return reject(why, .not_a_zdedupe_result_store);
        if (header.version != format_version) return reject(why, .unsupported_format_version);
        if (header.header_size != header_size) return reject(why, .unexpected_header_size);
        if (header.file_size != bytes.len) return reject(why, .file_size_disagrees_with_the_header);

        // Every section must lie wholly inside the file, with no arithmetic
        // wrapping into range, before a single record is read.
        for (header.sections, 0..) |section, i| {
            const id: SectionId = @enumFromInt(i);
            const offset = std.math.cast(usize, section.offset) orelse
                return reject(why, .a_section_lies_outside_the_file);
            const records = std.math.cast(usize, section.count) orelse
                return reject(why, .a_section_lies_outside_the_file);
            const byte_len = std.math.mul(usize, records, recordSize(id)) catch
                return reject(why, .a_section_lies_outside_the_file);
            const end = std.math.add(usize, offset, byte_len) catch
                return reject(why, .a_section_lies_outside_the_file);
            if (offset < header_size or offset % 8 != 0 or end > bytes.len) {
                return reject(why, .a_section_lies_outside_the_file);
            }
        }
        return .{ .bytes = bytes, .header = header };
    }

    pub fn count(self: *const Reader, id: SectionId) usize {
        // Fits: `init` cast it to usize.
        return @intCast(self.header.sections[@intFromEnum(id)].count);
    }

    pub fn groupCount(self: *const Reader) usize {
        return self.count(.groups);
    }

    pub fn setCount(self: *const Reader) usize {
        return self.count(.sets);
    }

    pub fn overlapCount(self: *const Reader) usize {
        return self.count(.overlaps);
    }

    pub fn hasDirectories(self: *const Reader) bool {
        return self.header.flags & flag_has_directories != 0;
    }

    pub fn isSha256(self: *const Reader) bool {
        return self.header.flags & flag_sha256 != 0;
    }

    /// The bytes of record `i` in section `id`.
    fn record(self: *const Reader, id: SectionId, i: usize) ReadError![]const u8 {
        if (i >= self.count(id)) return error.OutOfRange;
        const size = recordSize(id);
        // In range by construction: `init` verified offset + count * size.
        const start: usize = @intCast(self.header.sections[@intFromEnum(id)].offset + i * size);
        return self.bytes[start .. start + size];
    }

    fn string(self: *const Reader, offset: u64, path_len: u32) ReadError![]const u8 {
        const section = self.header.sections[@intFromEnum(SectionId.strings)];
        const start = std.math.cast(usize, offset) orelse return error.OutOfRange;
        const end = std.math.add(usize, start, path_len) catch return error.OutOfRange;
        if (end > section.count) return error.OutOfRange;
        const base: usize = @intCast(section.offset);
        return self.bytes[base + start .. base + end];
    }

    /// A run of `run_count` records starting at `first` must fit in `id`.
    fn checkRun(self: *const Reader, id: SectionId, first: u64, run_count: u32) ReadError!void {
        const start = std.math.cast(usize, first) orelse return error.OutOfRange;
        const end = std.math.add(usize, start, run_count) catch return error.OutOfRange;
        if (end > self.count(id)) return error.OutOfRange;
    }

    pub fn group(self: *const Reader, i: usize) ReadError!Group {
        const g = std.mem.bytesToValue(Group, (try self.record(.groups, i))[0..@sizeOf(Group)]);
        try self.checkRun(.group_files, g.first_file, g.file_count);
        return g;
    }

    /// File `i` (0-based within the group) of `g`.
    pub fn groupFile(self: *const Reader, g: *const Group, i: usize) ReadError!FileRef {
        if (i >= g.file_count) return error.OutOfRange;
        const bytes = try self.record(.group_files, @as(usize, @intCast(g.first_file)) + i);
        const r = std.mem.bytesToValue(GroupFile, bytes[0..@sizeOf(GroupFile)]);
        return .{ .path = try self.string(r.path_offset, r.path_len), .mtime = r.mtime };
    }

    /// Savings over every copy the scan recorded. Live savings, once anything
    /// has been deleted, are the session's business (see `session.zig`).
    pub fn groupSavings(g: *const Group) u64 {
        return g.size *| (@as(u64, g.file_count) -| 1);
    }

    pub fn set(self: *const Reader, i: usize) ReadError!Set {
        const s = std.mem.bytesToValue(Set, (try self.record(.sets, i))[0..@sizeOf(Set)]);
        try self.checkRun(.set_dirs, s.first_dir, s.dir_count);
        return s;
    }

    pub fn setDir(self: *const Reader, s: *const Set, i: usize) ReadError!DirRef {
        if (i >= s.dir_count) return error.OutOfRange;
        const bytes = try self.record(.set_dirs, @as(usize, @intCast(s.first_dir)) + i);
        const r = std.mem.bytesToValue(SetDir, bytes[0..@sizeOf(SetDir)]);
        return .{
            .path = try self.string(r.path_offset, r.path_len),
            .newest_mtime = r.newest_mtime,
            .skipped_entries = r.skipped_entries,
        };
    }

    /// The path of one side of an overlap pair. Validated by `overlap`, so
    /// this cannot fail for a side that came from it.
    pub fn sidePath(self: *const Reader, side: *const Side) ReadError![]const u8 {
        return self.string(side.path_offset, side.path_len);
    }

    /// `relation` as the enum, once `overlap` has vouched for the value.
    pub fn relationOfRecord(o: *const Overlap) Relation {
        return @enumFromInt(o.relation);
    }

    pub fn overlap(self: *const Reader, i: usize) ReadError!Overlap {
        const bytes = try self.record(.overlaps, i);
        const o = std.mem.bytesToValue(Overlap, bytes[0..@sizeOf(Overlap)]);
        if (o.relation > @intFromEnum(Relation.overlap)) return error.Invalid;
        // The side paths and only-path runs are what a caller reads next.
        _ = try self.string(o.a.path_offset, o.a.path_len);
        _ = try self.string(o.b.path_offset, o.b.path_len);
        try self.checkRun(.only_paths, o.a.first_only, o.a.only_listed);
        try self.checkRun(.only_paths, o.b.first_only, o.b.only_listed);
        return o;
    }

    /// "Exists only on this side" path `i` of `side`.
    pub fn onlyPath(self: *const Reader, side: *const Side, i: usize) ReadError![]const u8 {
        if (i >= side.only_listed) return error.OutOfRange;
        const bytes = try self.record(.only_paths, @as(usize, @intCast(side.first_only)) + i);
        const r = std.mem.bytesToValue(OnlyPath, bytes[0..@sizeOf(OnlyPath)]);
        return self.string(r.path_offset, r.path_len);
    }
};

// ============================================================================
// Tests
// ============================================================================
//
// Layout and reader validation only, the latter on hand-built buffers. Round-
// tripping a real scan through the file — and checking it against the JSON
// report of the same scan — lives in tier1_anchors.zig; reading one back
// through the results session lives in session.zig.

test "record layouts are the sizes the format documents" {
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Group));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(GroupFile));
    try std.testing.expectEqual(@as(usize, 200), @sizeOf(Overlap));
    // Field offsets the Rust reader relies on.
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Group, "size"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(Group, "file_count"));
    try std.testing.expectEqual(@as(usize, 128), @offsetOf(Header, "sections"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Overlap, "a"));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(Overlap, "b"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(Side, "path_len"));
}

test "StringCursor hands out running offsets" {
    var cursor: StringCursor = .{};
    const a = try cursor.take("abc");
    const b = try cursor.take("");
    const c = try cursor.take("defgh");
    try std.testing.expectEqual(@as(u64, 0), a.offset);
    try std.testing.expectEqual(@as(u64, 3), b.offset);
    try std.testing.expectEqual(@as(u64, 3), c.offset);
    try std.testing.expectEqual(@as(u64, 8), cursor.next);
}

/// A header-only store: every section empty and placed at the header's end.
fn emptyStore(gpa: std.mem.Allocator) ![]u8 {
    const header: Header = .{
        .file_size = header_size,
        .sections = @splat(.{ .offset = header_size, .count = 0 }),
    };
    return gpa.dupe(u8, std.mem.asBytes(&header));
}

test "the reader accepts a minimal store and refuses a row it does not have" {
    const gpa = std.testing.allocator;
    const bytes = try emptyStore(gpa);
    defer gpa.free(bytes);

    const reader = try Reader.init(bytes, null);
    try std.testing.expectEqual(@as(usize, 0), reader.groupCount());
    try std.testing.expectEqual(@as(usize, 0), reader.setCount());
    try std.testing.expectError(error.OutOfRange, reader.group(0));
}

test "the reader refuses a wrong magic, version or length" {
    const gpa = std.testing.allocator;

    {
        const bytes = try emptyStore(gpa);
        defer gpa.free(bytes);
        bytes[0] = 'X';
        var why: Reader.Rejection = undefined;
        try std.testing.expectError(error.Invalid, Reader.init(bytes, &why));
        try std.testing.expectEqual(Reader.Rejection.not_a_zdedupe_result_store, why);
    }
    {
        const bytes = try emptyStore(gpa);
        defer gpa.free(bytes);
        bytes[8] = 9;
        var why: Reader.Rejection = undefined;
        try std.testing.expectError(error.Invalid, Reader.init(bytes, &why));
        try std.testing.expectEqual(Reader.Rejection.unsupported_format_version, why);
    }
    {
        // Longer than the header claims: the file was replaced or extended.
        const short = try emptyStore(gpa);
        defer gpa.free(short);
        const bytes = try std.mem.concat(gpa, u8, &.{ short, &[_]u8{0} ** 64 });
        defer gpa.free(bytes);
        var why: Reader.Rejection = undefined;
        try std.testing.expectError(error.Invalid, Reader.init(bytes, &why));
        try std.testing.expectEqual(Reader.Rejection.file_size_disagrees_with_the_header, why);
    }
    {
        var why: Reader.Rejection = undefined;
        try std.testing.expectError(error.Invalid, Reader.init(&[_]u8{0} ** 10, &why));
        try std.testing.expectEqual(Reader.Rejection.shorter_than_a_header, why);
    }
}

test "the reader refuses a section that runs past the file" {
    const gpa = std.testing.allocator;

    // A million groups in a header-only file.
    {
        const bytes = try emptyStore(gpa);
        defer gpa.free(bytes);
        var header = std.mem.bytesToValue(Header, bytes[0..header_size]);
        header.sections[@intFromEnum(SectionId.groups)].count = 1_000_000;
        @memcpy(bytes, std.mem.asBytes(&header));
        var why: Reader.Rejection = undefined;
        try std.testing.expectError(error.Invalid, Reader.init(bytes, &why));
        try std.testing.expectEqual(Reader.Rejection.a_section_lies_outside_the_file, why);
    }
    // A count whose byte size overflows usize must not wrap into range.
    {
        const bytes = try emptyStore(gpa);
        defer gpa.free(bytes);
        var header = std.mem.bytesToValue(Header, bytes[0..header_size]);
        header.sections[@intFromEnum(SectionId.groups)].count = std.math.maxInt(u64);
        @memcpy(bytes, std.mem.asBytes(&header));
        try std.testing.expectError(error.Invalid, Reader.init(bytes, null));
    }
}

test "a group pointing outside its files is an error, not a trap" {
    const gpa = std.testing.allocator;

    // One structurally valid group record claiming five files, with an empty
    // GROUP_FILES section behind it.
    const group: Group = .{ .hash = @splat(0), .size = 10, .first_file = 0, .file_count = 5 };
    const header_only = try emptyStore(gpa);
    defer gpa.free(header_only);
    const bytes = try std.mem.concat(gpa, u8, &.{ header_only, std.mem.asBytes(&group) });
    defer gpa.free(bytes);

    var header = std.mem.bytesToValue(Header, bytes[0..header_size]);
    header.file_size = bytes.len;
    header.sections[@intFromEnum(SectionId.groups)] = .{ .offset = header_size, .count = 1 };
    // Every other section starts after the group record, still empty.
    for (header.sections[1..]) |*section| section.* = .{ .offset = bytes.len, .count = 0 };
    @memcpy(bytes[0..header_size], std.mem.asBytes(&header));

    const reader = try Reader.init(bytes, null);
    try std.testing.expectEqual(@as(usize, 1), reader.groupCount());
    try std.testing.expectError(error.OutOfRange, reader.group(0));
}

test "savings is the size of every copy but one, and cannot overflow" {
    const one: Group = .{ .hash = @splat(0), .size = 1024, .first_file = 0, .file_count = 1 };
    try std.testing.expectEqual(@as(u64, 0), Reader.groupSavings(&one));

    const three: Group = .{ .hash = @splat(0), .size = 1024, .first_file = 0, .file_count = 3 };
    try std.testing.expectEqual(@as(u64, 2048), Reader.groupSavings(&three));

    const absurd: Group = .{ .hash = @splat(0), .size = std.math.maxInt(u64), .first_file = 0, .file_count = 9 };
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), Reader.groupSavings(&absurd));
}
