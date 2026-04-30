// `zigit ls-files [-s|--stage]`
//
// Default output: one indexed path per line.
// With -s/--stage: `MODE OID STAGE\tPATH` per entry, matching git.
//
// Reads .git/index — does not touch the work tree.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var stage_format = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--stage")) {
            stage_format = true;
        } else {
            return error.UnknownFlag;
        }
    }

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    var index = try zigit.Index.load(allocator, io, repo.git_dir);
    defer index.deinit();

    var line_buf: [1024]u8 = undefined;
    const out = File.stdout();

    for (index.entries.items) |e| {
        if (stage_format) {
            var hex: [40]u8 = undefined;
            e.oid.toHex(&hex);
            const line = try std.fmt.bufPrint(
                &line_buf,
                "{o:0>6} {s} {d}\t{s}\n",
                .{ e.mode, hex[0..40], e.stage(), e.path },
            );
            try out.writeStreamingAll(io, line);
        } else {
            try out.writeStreamingAll(io, e.path);
            try out.writeStreamingAll(io, "\n");
        }
    }
}
