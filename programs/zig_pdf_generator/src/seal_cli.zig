//! pdf-seal — apply / verify an ML-DSA-65 post-quantum tamper-seal on a PDF.
//!
//!   pdf-seal sign   <in.pdf> <out.pdf> <seed>
//!   pdf-seal verify <in.pdf> [--key <seed> | --pubkey <3904-hex>]
//!
//! A <seed> is the signer's persistent 32-byte ML-DSA key seed and may be given
//! as either `@<path>` (read the 64 hex chars from a file — preferred) or 64
//! hex chars inline. An inline seed is DEPRECATED: it is visible in `ps`, shell
//! history, and process telemetry (this tree runs CTK process-ancestry tracing),
//! so the tool prints a warning. Use `@<path>` to keep the key off argv.
//!
//! With `--key`/`--pubkey`, verify also PINS the seal to a known business key:
//! a valid seal from a different key is rejected (authenticity, not just
//! integrity).
//!
//! NOT a standard PDF signature — verify with this tool (see src/seal.zig).

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
        try err.writeAll("usage:\n  pdf-seal sign <in.pdf> <out.pdf> <seed>\n  pdf-seal verify <in.pdf> [--key <seed> | --pubkey <3904-hex>]\n  <seed> = @<path-to-64-hex-file> (preferred) or 64 hex chars inline (deprecated)\n");
        try err.flush();
        std.process.exit(2);
    }
    const cmd = args.items[1];

    if (std.mem.eql(u8, cmd, "sign")) {
        if (args.items.len < 5) {
            try err.writeAll("sign needs: <in.pdf> <out.pdf> <seed>\n");
            try err.flush();
            std.process.exit(2);
        }
        const seed = resolveSeedHex(a, io, args.items[4], err) catch std.process.exit(2);
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

        // Optional pinning: `--key <64-hex-seed>` (derive the expected pubkey
        // from the business's signing seed) or `--pubkey <3904-hex>` (the
        // expected public key directly). When given, the seal must be valid AND
        // match the pinned key (authenticity, not just integrity).
        var expected_pk: ?[seal.PK_BYTES]u8 = null;
        var i: usize = 3;
        while (i + 1 < args.items.len) : (i += 2) {
            const flag = args.items[i];
            const val = args.items[i + 1];
            if (std.mem.eql(u8, flag, "--key")) {
                const seed = resolveSeedHex(a, io, val, err) catch std.process.exit(2);
                expected_pk = seal.publicKeyFromSeed(seed) catch {
                    try err.writeAll("failed to derive public key from seed\n");
                    try err.flush();
                    std.process.exit(2);
                };
            } else if (std.mem.eql(u8, flag, "--pubkey")) {
                var pk: [seal.PK_BYTES]u8 = undefined;
                if (val.len != seal.PK_BYTES * 2 or (std.fmt.hexToBytes(&pk, val) catch null) == null) {
                    try err.print("--pubkey must be {d} hex chars\n", .{seal.PK_BYTES * 2});
                    try err.flush();
                    std.process.exit(2);
                }
                expected_pk = pk;
            } else {
                try err.print("unknown verify flag: {s}\n", .{flag});
                try err.flush();
                std.process.exit(2);
            }
        }

        const v = if (expected_pk) |*pk| try seal.verifyPinned(a, pdf, pk) else try seal.verify(a, pdf);
        try err.print("{s}\n", .{v.reason});
        if (v.has_seal) try err.print("public key: {s}...\n", .{v.public_key_hex[0..32]});
        if (v.pinned) |p| try err.print("key pin: {s}\n", .{if (p) "MATCH (recognized business key)" else "MISMATCH (unrecognized key)"});
        try err.flush();
        std.process.exit(if (v.valid) 0 else 1);
    } else {
        try err.writeAll("unknown command (use sign|verify)\n");
        try err.flush();
        std.process.exit(2);
    }
}

/// Resolve a 32-byte ML-DSA seed from a CLI token. `@<path>` reads the 64 hex
/// chars from a file (whitespace-trimmed) so the secret never touches argv;
/// otherwise the token is treated as inline hex, which is accepted but warned
/// about because argv is visible to `ps`, shell history, and process telemetry.
fn resolveSeedHex(a: std.mem.Allocator, io: std.Io, token: []const u8, err: *std.Io.Writer) ![32]u8 {
    var seed: [32]u8 = undefined;
    if (token.len > 1 and token[0] == '@') {
        const raw = std.Io.Dir.cwd().readFileAlloc(io, token[1..], a, .limited(4096)) catch {
            try err.print("could not read seed file: {s}\n", .{token[1..]});
            try err.flush();
            return error.SeedFile;
        };
        defer a.free(raw);
        const hex = std.mem.trim(u8, raw, " \t\r\n");
        if (hex.len != 64 or (std.fmt.hexToBytes(&seed, hex) catch null) == null) {
            try err.writeAll("seed file must contain 64 hex chars (32 bytes)\n");
            try err.flush();
            return error.BadSeed;
        }
        return seed;
    }
    try err.writeAll("warning: an inline seed is visible in `ps`, shell history, and process telemetry; prefer `@<path-to-seed-file>`\n");
    try err.flush();
    if (token.len != 64 or (std.fmt.hexToBytes(&seed, token) catch null) == null) {
        try err.writeAll("seed must be 64 hex chars (32 bytes)\n");
        try err.flush();
        return error.BadSeed;
    }
    return seed;
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
