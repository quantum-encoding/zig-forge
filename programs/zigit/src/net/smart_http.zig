// Smart-HTTP protocol v2 client.
//
// Three calls cover a fresh clone:
//
//   1. discoverV2(url)    GET /info/refs?service=git-upload-pack
//                         with header `Git-Protocol: version=2`.
//                         Server replies with pkt-lines starting with
//                         "version 2" + capability list.
//
//   2. lsRefs(url)        POST /git-upload-pack body:
//                           command=ls-refs
//                           agent=zigit/0.1
//                           [delim]
//                           peel
//                           symrefs
//                           ref-prefix HEAD
//                           ref-prefix refs/
//                           [flush]
//                         Server replies one pkt-line per ref:
//                           <40-hex> <name> [symref-target:<x>] [peeled:<x>]
//
//   3. fetch(url, wants)  POST /git-upload-pack body:
//                           command=fetch
//                           agent=zigit/0.1
//                           [delim]
//                           ofs-delta
//                           thin-pack
//                           want <oid>            (one per want)
//                           done
//                           [flush]
//                         Server reply has sections:
//                           acknowledgments  (skipped for fresh clone)
//                           packfile         (pkt-lines with sideband:
//                                              0x01 = pack data,
//                                              0x02 = progress (stderr),
//                                              0x03 = fatal error)
//                         We concatenate the 0x01-band bytes into the
//                         returned pack buffer.
//
// We don't bother with v1 fallback — GitHub, GitLab, Forgejo, and
// every modern server speak v2. If a server doesn't, the discovery
// step returns error.UnsupportedProtocol.

const std = @import("std");
const Io = std.Io;
const pkt_line = @import("pkt_line.zig");

pub const agent = "zigit/0.1";

pub const Ref = struct {
    /// 40-char hex; owned by caller (we copy at parse time).
    oid_hex: [40]u8,
    /// Full ref name like "HEAD" or "refs/heads/main"; owned.
    name: []u8,
    /// For symbolic refs (HEAD with symref-target: …); owned, may be empty.
    symref_target: []u8,

    pub fn deinit(self: *Ref, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.symref_target);
        self.* = undefined;
    }
};

pub fn freeRefs(allocator: std.mem.Allocator, refs: []Ref) void {
    for (refs) |*r| r.deinit(allocator);
    allocator.free(refs);
}

/// Run the v2 capability advertisement. We don't actually parse the
/// capability list yet — we just confirm the server is speaking v2.
/// Useful as a connection sanity check before posting commands.
pub fn discoverV2(
    allocator: std.mem.Allocator,
    io: Io,
    base_url: []const u8,
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/info/refs?service=git-upload-pack", .{base_url});
    defer allocator.free(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = &.{
            .{ .name = "Git-Protocol", .value = "version=2" },
        },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) return error.HttpError;

    const bytes = body.written();
    var cursor: usize = 0;

    // Many servers (GitHub, GitLab, …) prefix the v2 advertisement
    // with the historical "# service=git-upload-pack\n" packet + a
    // flush, even when the client asked for protocol v2. Skip past
    // that prelude before checking for "version 2".
    const first = try pkt_line.read(bytes, cursor);
    cursor += first.advance;
    if (first.packet == .data and std.mem.startsWith(u8, first.packet.data, "# service=")) {
        const flush = try pkt_line.read(bytes, cursor);
        cursor += flush.advance;
        if (flush.packet != .flush) return error.UnsupportedProtocol;
    } else {
        // Re-process the first packet below.
        cursor = 0;
    }

    const advert = try pkt_line.read(bytes, cursor);
    if (advert.packet != .data) return error.UnsupportedProtocol;
    const trimmed = std.mem.trimEnd(u8, advert.packet.data, " \r\n");
    if (!std.mem.eql(u8, trimmed, "version 2")) return error.UnsupportedProtocol;
}

/// Run command=ls-refs and return all advertised refs.
pub fn lsRefs(
    allocator: std.mem.Allocator,
    io: Io,
    base_url: []const u8,
) ![]Ref {
    const url = try std.fmt.allocPrint(allocator, "{s}/git-upload-pack", .{base_url});
    defer allocator.free(url);

    // Build the request body in a small buffer.
    var req_body: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer req_body.deinit();
    const w = &req_body.writer;
    try pkt_line.writeData(w, "command=ls-refs\n");
    try pkt_line.writeData(w, "agent=" ++ agent ++ "\n");
    try pkt_line.writeDelim(w);
    try pkt_line.writeData(w, "peel\n");
    try pkt_line.writeData(w, "symrefs\n");
    try pkt_line.writeData(w, "ref-prefix HEAD\n");
    try pkt_line.writeData(w, "ref-prefix refs/heads/\n");
    try pkt_line.writeData(w, "ref-prefix refs/tags/\n");
    try pkt_line.writeFlush(w);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var resp: std.Io.Writer.Allocating = try .initCapacity(allocator, 64 * 1024);
    defer resp.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = req_body.written(),
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-git-upload-pack-request" },
            .{ .name = "Accept", .value = "application/x-git-upload-pack-result" },
            .{ .name = "Git-Protocol", .value = "version=2" },
        },
        .response_writer = &resp.writer,
    });
    if (result.status != .ok) return error.HttpError;

    return try parseRefList(allocator, resp.written());
}

fn parseRefList(allocator: std.mem.Allocator, bytes: []const u8) ![]Ref {
    var refs: std.ArrayListUnmanaged(Ref) = .empty;
    errdefer {
        for (refs.items) |*r| r.deinit(allocator);
        refs.deinit(allocator);
    }

    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const got = try pkt_line.read(bytes, cursor);
        cursor += got.advance;
        switch (got.packet) {
            .flush, .delim, .response_end => continue,
            .data => |line| {
                const trimmed = std.mem.trimEnd(u8, line, " \r\n");
                if (trimmed.len < 41 or trimmed[40] != ' ') continue;
                var ref: Ref = .{
                    .oid_hex = undefined,
                    .name = undefined,
                    .symref_target = try allocator.dupe(u8, ""),
                };
                @memcpy(&ref.oid_hex, trimmed[0..40]);
                // After the oid+space comes the ref name, then optional
                // attributes separated by spaces (symref-target:..., peeled:...).
                const rest = trimmed[41..];
                var name_end = rest.len;
                if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| name_end = sp;
                ref.name = try allocator.dupe(u8, rest[0..name_end]);
                // Walk remaining attrs.
                var attrs = rest[@min(name_end + 1, rest.len)..];
                while (attrs.len > 0) {
                    var next_end = attrs.len;
                    if (std.mem.indexOfScalar(u8, attrs, ' ')) |sp| next_end = sp;
                    const attr = attrs[0..next_end];
                    if (std.mem.startsWith(u8, attr, "symref-target:")) {
                        allocator.free(ref.symref_target);
                        ref.symref_target = try allocator.dupe(u8, attr[14..]);
                    }
                    attrs = if (next_end < attrs.len) attrs[next_end + 1 ..] else "";
                }
                try refs.append(allocator, ref);
            },
        }
    }

    return try refs.toOwnedSlice(allocator);
}

/// Run command=fetch with `wants` and return the raw pack bytes
/// (concatenation of all 0x01-banded payloads in the packfile section).
/// Caller owns the returned slice.
pub fn fetch(
    allocator: std.mem.Allocator,
    io: Io,
    base_url: []const u8,
    wants: []const [40]u8,
) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}/git-upload-pack", .{base_url});
    defer allocator.free(url);

    var req_body: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    defer req_body.deinit();
    const w = &req_body.writer;
    try pkt_line.writeData(w, "command=fetch\n");
    try pkt_line.writeData(w, "agent=" ++ agent ++ "\n");
    try pkt_line.writeDelim(w);
    try pkt_line.writeData(w, "ofs-delta\n");
    try pkt_line.writeData(w, "thin-pack\n");

    var line_buf: [64]u8 = undefined;
    for (wants) |oid_hex| {
        const line = try std.fmt.bufPrint(&line_buf, "want {s}\n", .{oid_hex});
        try pkt_line.writeData(w, line);
    }
    try pkt_line.writeData(w, "done\n");
    try pkt_line.writeFlush(w);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Fetched bytes — the raw HTTP body, banded pkt-lines included.
    var resp: std.Io.Writer.Allocating = try .initCapacity(allocator, 256 * 1024);
    defer resp.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = req_body.written(),
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-git-upload-pack-request" },
            .{ .name = "Accept", .value = "application/x-git-upload-pack-result" },
            .{ .name = "Git-Protocol", .value = "version=2" },
        },
        .response_writer = &resp.writer,
    });
    if (result.status != .ok) return error.HttpError;

    return try extractPackBytes(allocator, resp.written());
}

/// Walk the fetch response, locate the "packfile" section, and
/// concatenate every 0x01-band pkt-line payload.
fn extractPackBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var pack_buf: std.Io.Writer.Allocating = try .initCapacity(allocator, 64 * 1024);
    defer pack_buf.deinit();

    var in_packfile_section = false;
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const got = try pkt_line.read(bytes, cursor);
        cursor += got.advance;
        switch (got.packet) {
            .flush => break,
            .delim => continue,
            .response_end => break,
            .data => |line| {
                if (!in_packfile_section) {
                    const trimmed = std.mem.trimEnd(u8, line, " \r\n");
                    if (std.mem.eql(u8, trimmed, "packfile")) {
                        in_packfile_section = true;
                    }
                    // Otherwise it's a section header (acknowledgments,
                    // shallow-info, …) we don't care about for a fresh
                    // clone.
                    continue;
                }
                if (line.len == 0) continue;
                switch (line[0]) {
                    1 => try pack_buf.writer.writeAll(line[1..]),
                    2 => {}, // progress text — discard
                    3 => return error.RemoteFatalError,
                    else => return error.UnknownSidebandChannel,
                }
            },
        }
    }

    return try pack_buf.toOwnedSlice();
}

const testing = std.testing;

test "parseRefList parses a tiny ls-refs response" {
    // Hand-crafted: one HEAD + one branch ref, no peeled.
    var buf: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 256);
    defer buf.deinit();
    const w = &buf.writer;
    try pkt_line.writeData(w, "0123456789abcdef0123456789abcdef01234567 HEAD symref-target:refs/heads/main\n");
    try pkt_line.writeData(w, "0123456789abcdef0123456789abcdef01234567 refs/heads/main\n");
    try pkt_line.writeFlush(w);

    const refs = try parseRefList(testing.allocator, buf.written());
    defer freeRefs(testing.allocator, refs);

    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("HEAD", refs[0].name);
    try testing.expectEqualStrings("refs/heads/main", refs[0].symref_target);
    try testing.expectEqualStrings("refs/heads/main", refs[1].name);
    try testing.expectEqualStrings("", refs[1].symref_target);
}

test "extractPackBytes joins sideband-banded pack data" {
    var buf: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 256);
    defer buf.deinit();
    const w = &buf.writer;
    try pkt_line.writeData(w, "packfile\n");
    try pkt_line.writeData(w, "\x01PACK"); // first chunk
    try pkt_line.writeData(w, "\x01\x00\x00\x00\x02"); // version 2
    try pkt_line.writeData(w, "\x02progress noise"); // band 2 ignored
    try pkt_line.writeData(w, "\x01\x00\x00\x00\x05"); // count 5
    try pkt_line.writeFlush(w);

    const pack_bytes = try extractPackBytes(testing.allocator, buf.written());
    defer testing.allocator.free(pack_bytes);
    try testing.expectEqualStrings("PACK\x00\x00\x00\x02\x00\x00\x00\x05", pack_bytes);
}
