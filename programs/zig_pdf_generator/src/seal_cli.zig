//! pdf-seal — apply / verify an ML-DSA-65 post-quantum tamper-seal on a PDF.
//!
//!   pdf-seal sign   <in.pdf> <out.pdf> <64-hex-char-seed>
//!   pdf-seal verify <in.pdf>
//!
//! The seed is the signer's persistent 32-byte ML-DSA key seed (hex). NOT a
//! standard PDF signature — verify with this tool (see src/seal.zig).

const std = @import("std");
const seal = @import("seal.zig");

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    var stderr_buf: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr.interface;

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(a);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |arg| try args.append(a, arg);

    if (args.items.len < 3) {
        try err.writeAll("usage:\n  pdf-seal sign <in.pdf> <out.pdf> <64-hex-seed>\n  pdf-seal verify <in.pdf>\n");
        try err.flush();
        std.process.exit(2);
    }
    const cmd = args.items[1];

    if (std.mem.eql(u8, cmd, "sign")) {
        if (args.items.len < 5) {
            try err.writeAll("sign needs: <in.pdf> <out.pdf> <64-hex-seed>\n");
            try err.flush();
            std.process.exit(2);
        }
        var seed: [32]u8 = undefined;
        if (args.items[4].len != 64 or (std.fmt.hexToBytes(&seed, args.items[4]) catch null) == null) {
            try err.writeAll("seed must be 64 hex chars (32 bytes)\n");
            try err.flush();
            std.process.exit(2);
        }
        const pdf = try readFile(a, io, args.items[2]);
        defer a.free(pdf);
        const sealed = try seal.seal(a, pdf, seed);
        defer a.free(sealed);
        try writeFile(io, args.items[3], sealed);
        try err.print("sealed -> {s} ({d} bytes)\n", .{ args.items[3], sealed.len });
        try err.flush();
    } else if (std.mem.eql(u8, cmd, "verify")) {
        const pdf = try readFile(a, io, args.items[2]);
        defer a.free(pdf);
        const v = try seal.verify(a, pdf);
        try err.print("{s}\n", .{v.reason});
        if (v.has_seal) try err.print("public key: {s}...\n", .{v.public_key_hex[0..32]});
        try err.flush();
        std.process.exit(if (v.valid) 0 else 1);
    } else {
        try err.writeAll("unknown command (use sign|verify)\n");
        try err.flush();
        std.process.exit(2);
    }
}

fn readFile(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024 * 1024));
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(data);
    try std.Io.Writer.flush(&w.interface);
}
