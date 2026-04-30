// `zigit hash-object [-w] [-t kind] [--stdin] <file>`
//
// Computes the SHA-1 of <kind> <size>\0<content> for the given input
// and prints the hex digest. With -w, the loose object is also
// written to .git/objects/.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var write_to_store = false;
    var from_stdin = false;
    var kind: zigit.Kind = .blob;
    var path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-w")) {
            write_to_store = true;
        } else if (std.mem.eql(u8, a, "--stdin")) {
            from_stdin = true;
        } else if (std.mem.eql(u8, a, "-t")) {
            i += 1;
            if (i >= args.len) return error.MissingKindArgument;
            kind = zigit.Kind.parse(args[i]) orelse return error.UnknownKind;
        } else if (path == null) {
            path = a;
        } else {
            return error.TooManyArguments;
        }
    }

    if (!from_stdin and path == null) return error.MissingFileArgument;

    const content = if (from_stdin) blk: {
        // Slurp stdin via a streaming reader into an Allocating writer.
        var read_buf: [4096]u8 = undefined;
        const stdin = File.stdin();
        var reader = stdin.readerStreaming(io, &read_buf);
        var sink: std.Io.Writer.Allocating = .init(allocator);
        defer sink.deinit();
        _ = try reader.interface.streamRemaining(&sink.writer);
        break :blk try sink.toOwnedSlice();
    } else blk: {
        break :blk try Io.Dir.cwd().readFileAlloc(
            io,
            path.?,
            allocator,
            .unlimited,
        );
    };
    defer allocator.free(content);

    const oid = zigit.object.computeOid(kind, content);

    if (write_to_store) {
        var repo = try zigit.Repository.discover(allocator, io);
        defer repo.deinit();
        var store = repo.looseStore();
        try store.write(allocator, kind, content, oid);
    }

    var hex: [40]u8 = undefined;
    oid.toHex(&hex);
    var line: [42]u8 = undefined;
    @memcpy(line[0..40], &hex);
    line[40] = '\n';
    try File.stdout().writeStreamingAll(io, line[0..41]);
}
