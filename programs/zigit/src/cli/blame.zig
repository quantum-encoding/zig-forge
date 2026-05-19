// `zigit blame [OPTIONS] PATH`
//
//   -L <N>[,<M>]     Restrict blame to lines N through M (1-based,
//                    inclusive). With only N: blame from N to EOF.
//   --porcelain      Machine-readable output matching `git blame
//                    --porcelain` byte-for-byte where mechanically
//                    possible.
//   --verbose        Emit per-phase counters to stderr after the
//                    result.
//   --max-commits N  Stop walking after N commits and pin residue to
//                    HEAD's commit. metrics.partial = true.
//
// PATH is relative to the working tree. Implicit ref is HEAD.
//
// Exit codes:
//   0    blame produced for all lines
//   1    partial result (max_commits cap hit)
//   128  fatal — path/ref errors, malformed objects

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !u8 {
    var porcelain = false;
    var verbose = false;
    var line_range: ?zigit.blame.BlameOptions.LineRange = null;
    var max_commits: ?u32 = null;
    var path_opt: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--porcelain")) {
            porcelain = true;
        } else if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "-L")) {
            i += 1;
            if (i >= args.len) return error.MissingDashLArg;
            line_range = try parseLineRange(args[i]);
        } else if (std.mem.startsWith(u8, a, "-L")) {
            // Also accept the `-L1,5` form (no space).
            line_range = try parseLineRange(a[2..]);
        } else if (std.mem.eql(u8, a, "--max-commits")) {
            i += 1;
            if (i >= args.len) return error.MissingMaxCommitsArg;
            max_commits = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownBlameFlag;
        } else {
            if (path_opt != null) return error.MultiplePaths;
            path_opt = a;
        }
    }

    const path = path_opt orelse return error.MissingPath;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    const head_oid = (try zigit.refs.tryResolve(allocator, io, repo.git_dir, zigit.refs.head_path)) orelse
        return error.UnbornHeadNothingToBlame;

    var result = try zigit.blame.blameFile(allocator, &store, head_oid, path, .{
        .line_range = line_range,
        .max_commits = max_commits,
    });
    defer result.deinit();

    // Buffer the entire output in memory, then flush in one write.
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer out.deinit();
    if (porcelain) {
        try zigit.blame.format.writePorcelain(allocator, &out.writer, result, path);
    } else {
        try zigit.blame.format.writeHuman(allocator, &out.writer, result);
    }
    try File.stdout().writeStreamingAll(io, out.written());

    if (verbose) {
        var msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &msg_buf,
            "zigit blame: examined {d} commits, short-circuit hits {d}, diffs run {d}\n",
            .{
                result.metrics.commits_examined,
                result.metrics.short_circuit_hits,
                result.metrics.diffs_run,
            },
        );
        try File.stderr().writeStreamingAll(io, msg);
    }

    return if (result.metrics.partial) 1 else 0;
}

fn parseLineRange(s: []const u8) !zigit.blame.BlameOptions.LineRange {
    // `-L N`     → (N, max)   — caller can't know "max" yet; we pass
    //                            range_end = std.math.maxInt(u32) and
    //                            let the algorithm clamp to file end.
    //                            Actually blameFile rejects ranges past
    //                            the file end, so we sentinel here and
    //                            patch up at call site — simpler to
    //                            just emit a sentinel and let blameFile
    //                            handle it.
    // `-L N,M`   → (N, M)
    if (s.len == 0) return error.EmptyDashL;
    if (std.mem.indexOfScalar(u8, s, ',')) |comma| {
        const start_str = s[0..comma];
        const end_str = s[comma + 1 ..];
        const start = try std.fmt.parseInt(u32, start_str, 10);
        const end = try std.fmt.parseInt(u32, end_str, 10);
        if (start == 0 or end == 0 or start > end) return error.InvalidLineRange;
        return .{ .start = start, .end = end };
    } else {
        const start = try std.fmt.parseInt(u32, s, 10);
        if (start == 0) return error.InvalidLineRange;
        return .{ .start = start, .end = std.math.maxInt(u32) };
    }
}
