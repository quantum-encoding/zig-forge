// `zigit log [-n N] [--oneline]`
//
// Walks the first-parent chain from HEAD. Two output modes:
//
//   default       commit <full-oid>
//                 Author: <name> <<email>>
//                 Date:   <unix> <tz>
//                 <blank>
//                     <indented message>
//                 <blank>
//
//   --oneline     <7-char-short-oid> <first-line-of-message>
//
// We intentionally don't follow merges or do topological ordering —
// `--first-parent` semantics. Once we ship merge-graph walks we can
// revisit.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const zigit = @import("zigit");

/// Git's default abbreviation width. Real git grows this dynamically
/// when the loose-object population exposes prefix collisions; we
/// always emit 7. The parity fixtures we ship don't have enough
/// commits to collide.
const short_oid_len: usize = 7;

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var max_count: ?usize = null;
    var oneline = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--max-count")) {
            i += 1;
            if (i >= args.len) return error.MissingCountArg;
            max_count = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--oneline")) {
            oneline = true;
        } else {
            return error.UnknownArgument;
        }
    }

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    var current_opt = try zigit.refs.tryResolve(allocator, io, repo.git_dir, zigit.refs.head_path);
    if (current_opt == null) return error.UnbornBranchNothingToShow;

    const out = File.stdout();
    var line_buf: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    defer line_buf.deinit();

    var shown: usize = 0;
    while (current_opt) |current| {
        if (max_count) |m| {
            if (shown >= m) break;
        }

        var loaded = try store.read(allocator, current);
        defer loaded.deinit(allocator);
        if (loaded.kind != .commit) return error.HeadNotACommit;

        var parsed = try zigit.object.commit.parse(allocator, loaded.payload);
        defer parsed.deinit(allocator);

        var hex: [40]u8 = undefined;
        current.toHex(&hex);

        line_buf.clearRetainingCapacity();

        if (oneline) {
            // Subject = first line of the message, no trailing '\n'.
            const subject_end = std.mem.indexOfScalar(u8, parsed.message, '\n') orelse parsed.message.len;
            const subject = parsed.message[0..subject_end];
            try line_buf.writer.print("{s} {s}\n", .{ hex[0..short_oid_len], subject });
        } else {
            try line_buf.writer.print("commit {s}\n", .{hex[0..40]});

            // The author header is "<name> <<email>> <unix> <tz>".
            // Split it for human-friendly Author/Date lines; if the
            // header is malformed, fall back to dumping the line raw.
            if (formatIdentityForHumans(parsed.author_line)) |author| {
                try line_buf.writer.print("Author: {s}\n", .{author.identity});
                try line_buf.writer.print("Date:   {d} {s}\n\n", .{ author.unix, author.tz });
            } else |_| {
                try line_buf.writer.print("Author: {s}\n\n", .{parsed.author_line});
            }

            // Indent the message body with 4 spaces to match git.
            var msg_iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, parsed.message, "\n"), '\n');
            while (msg_iter.next()) |line| {
                try line_buf.writer.print("    {s}\n", .{line});
            }
            try line_buf.writer.writeAll("\n");
        }

        try out.writeStreamingAll(io, line_buf.written());

        // Walk to first parent.
        current_opt = if (parsed.parent_oids.len > 0) parsed.parent_oids[0] else null;
        shown += 1;
    }
}

const HumanIdentity = struct {
    /// "<name> <<email>>" (everything before the timestamp).
    identity: []const u8,
    unix: i64,
    tz: []const u8,
};

/// Split an "<name> <<email>> <unix> <tz>" header into its parts
/// without copying.
fn formatIdentityForHumans(line: []const u8) !HumanIdentity {
    // tz is the last whitespace-separated token, unix the one before
    // it, and identity is everything before unix.
    const tz_sep = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return error.MalformedIdentity;
    const tz = line[tz_sep + 1 ..];
    const head = line[0..tz_sep];

    const unix_sep = std.mem.lastIndexOfScalar(u8, head, ' ') orelse return error.MalformedIdentity;
    const unix_str = head[unix_sep + 1 ..];
    const identity = head[0..unix_sep];

    return .{
        .identity = identity,
        .unix = try std.fmt.parseInt(i64, unix_str, 10),
        .tz = tz,
    };
}
