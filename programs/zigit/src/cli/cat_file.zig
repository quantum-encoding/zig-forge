// `zigit cat-file (-p|-t|-s|-e) <oid>`
//
//   -p  print the object payload (no headers)
//   -t  print the object kind
//   -s  print the payload size in bytes
//   -e  exit 0 if the object exists, 1 otherwise

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const zigit = @import("zigit");

const Mode = enum { pretty, kind, size, exists };

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 2) return error.UsageExpectsModeAndOid;

    const mode: Mode = if (std.mem.eql(u8, args[0], "-p"))
        .pretty
    else if (std.mem.eql(u8, args[0], "-t"))
        .kind
    else if (std.mem.eql(u8, args[0], "-s"))
        .size
    else if (std.mem.eql(u8, args[0], "-e"))
        .exists
    else
        return error.UnknownMode;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    const oid = try store.resolvePrefix(args[1]);

    var loaded = try store.read(allocator, oid);
    defer loaded.deinit(allocator);

    const out = File.stdout();
    switch (mode) {
        .pretty => {
            // Trees aren't readable as raw bytes — git formats them as
            // `mode type oid\tname` per entry. Other kinds print verbatim.
            if (loaded.kind == .tree) {
                try prettyPrintTree(allocator, io, loaded.payload);
            } else {
                try out.writeStreamingAll(io, loaded.payload);
            }
        },
        .kind => {
            var buf: [16]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "{s}\n", .{loaded.kind.name()});
            try out.writeStreamingAll(io, line);
        },
        .size => {
            var buf: [32]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "{d}\n", .{loaded.payload.len});
            try out.writeStreamingAll(io, line);
        },
        .exists => {}, // a successful read is the success signal
    }
}

fn prettyPrintTree(allocator: std.mem.Allocator, io: Io, payload: []const u8) !void {
    var it: zigit.object.tree.Iterator = .{ .bytes = payload };

    var line_buf: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer line_buf.deinit();
    const out = File.stdout();

    while (try it.next()) |entry| {
        const kind_str = switch (entry.mode) {
            zigit.object.tree.tree_mode_octal => "tree",
            0o160000 => "commit", // gitlink (submodule head)
            else => "blob",
        };

        var hex: [40]u8 = undefined;
        entry.oid.toHex(&hex);

        line_buf.clearRetainingCapacity();
        try line_buf.writer.print(
            "{o:0>6} {s} {s}\t{s}\n",
            .{ entry.mode, kind_str, hex[0..40], entry.name },
        );
        try out.writeStreamingAll(io, line_buf.written());
    }
}
