// `zigit reflog [show [REF]]`
//
// Walk a reflog file in newest-first order and print one line per
// entry, mirroring the format git's own porcelain uses:
//
//   <oid_short> <ref>@{N}: <message>
//
// `REF` defaults to HEAD. Branch names are accepted shorthand for
// `refs/heads/<NAME>`.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var ref_arg: []const u8 = "HEAD";

    if (args.len >= 1) {
        // The "show" subcommand is optional; we accept either
        //   zigit reflog
        //   zigit reflog show
        //   zigit reflog show REF
        //   zigit reflog REF        (anything that isn't "show")
        if (std.mem.eql(u8, args[0], "show")) {
            if (args.len >= 2) ref_arg = args[1];
        } else {
            ref_arg = args[0];
        }
    }
    if (args.len > 2) return error.UsageReflogShowOptionalRef;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    // Build the log path. Branch shorthand: if it doesn't already
    // start with refs/ or HEAD, prefix refs/heads/.
    var ref_buf: [Dir.max_path_bytes]u8 = undefined;
    const ref_name: []const u8 = if (std.mem.eql(u8, ref_arg, "HEAD") or std.mem.startsWith(u8, ref_arg, "refs/"))
        ref_arg
    else
        try std.fmt.bufPrint(&ref_buf, "refs/heads/{s}", .{ref_arg});

    var log_buf: [Dir.max_path_bytes]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "logs/{s}", .{ref_name});

    const bytes = repo.git_dir.readFileAlloc(io, log_path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.NoReflogForRef,
        else => return err,
    };
    defer allocator.free(bytes);

    // Pull every entry into a list so we can print newest-first.
    var entries: std.ArrayListUnmanaged(zigit.reflog.Entry) = .empty;
    defer entries.deinit(allocator);
    var it = zigit.reflog.iterate(bytes);
    while (it.next()) |e| try entries.append(allocator, e);

    // Display short name (drop refs/heads/) for the "ref@{N}" prefix.
    const display: []const u8 = if (std.mem.startsWith(u8, ref_name, "refs/heads/"))
        ref_name[11..]
    else
        ref_name;

    const out = File.stdout();
    var line_buf: [1024]u8 = undefined;

    var i: usize = entries.items.len;
    var n: usize = 0;
    while (i > 0) {
        i -= 1;
        const e = entries.items[i];
        const line = try std.fmt.bufPrint(
            &line_buf,
            "{s} {s}@{{{d}}}: {s}\n",
            .{ e.new_hex[0..7], display, n, e.message },
        );
        try out.writeStreamingAll(io, line);
        n += 1;
    }
}
