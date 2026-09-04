//! Hybrid KEM vector generator
//!
//! Prints the combiner known-answer vectors and the full-path deterministic
//! vector (fixed seeds -> ek, dk, ct, K_v1, K_v2) as `name = hex` lines, for
//! docs/HYBRID-V2.md and for other implementations to check against.
//!
//!   zig build hybrid-vectors

const std = @import("std");
const Io = std.Io;
const hybrid = @import("hybrid");

fn line(io: Io, out: Io.File, name: []const u8, bytes: []const u8) !void {
    var buf: [8192]u8 = undefined;
    var w: usize = 0;
    @memcpy(buf[w .. w + name.len], name);
    w += name.len;
    @memcpy(buf[w .. w + 3], " = ");
    w += 3;
    const digits = "0123456789abcdef";
    for (bytes) |b| {
        buf[w] = digits[b >> 4];
        buf[w + 1] = digits[b & 0x0f];
        w += 2;
    }
    buf[w] = '\n';
    w += 1;
    try out.writeStreamingAll(io, buf[0..w]);
}

pub fn main() !void {
    const io = Io.Threaded.global_single_threaded.io();
    const out = Io.File.stdout();

    try out.writeStreamingAll(io, "# combiner KAT inputs\n");
    try line(io, out, "ss_m", &hybrid.kat_ss_m);
    try line(io, out, "ss_x", &hybrid.kat_ss_x);
    try line(io, out, "ct_x", &hybrid.kat_ct_x);
    try line(io, out, "pk_x", &hybrid.kat_pk_x);
    try line(io, out, "v1_label", hybrid.V1_LABEL);
    try line(io, out, "v2_info", hybrid.V2_INFO);

    try out.writeStreamingAll(io, "# combiner KAT outputs\n");
    const zero = [_]u8{0} ** 32;
    try line(io, out, "K_v1", &hybrid.combineSecretsV1(&hybrid.kat_ss_m, &hybrid.kat_ss_x));
    try line(io, out, "K_v2", &hybrid.combineSecretsV2(&hybrid.kat_ss_m, &hybrid.kat_ss_x, &hybrid.kat_ct_x, &hybrid.kat_pk_x));
    try line(io, out, "K_v2_zero_ss_x", &hybrid.combineSecretsV2(&hybrid.kat_ss_m, &zero, &hybrid.kat_ct_x, &hybrid.kat_pk_x));

    try out.writeStreamingAll(io, "# full-path vector seeds\n");
    try line(io, out, "d", &hybrid.kat_seed_d);
    try line(io, out, "z", &hybrid.kat_seed_z);
    try line(io, out, "x25519_sk", &hybrid.kat_seed_x25519_sk);
    try line(io, out, "m", &hybrid.kat_seed_m);
    try line(io, out, "eph_sk", &hybrid.kat_seed_eph_sk);

    const kp = try hybrid.keyGenDeterministic(&hybrid.kat_seed_d, &hybrid.kat_seed_z, &hybrid.kat_seed_x25519_sk);
    const enc_v1 = try hybrid.encapsDeterministic(&kp.ek, .v1, &hybrid.kat_seed_m, &hybrid.kat_seed_eph_sk);
    const enc_v2 = try hybrid.encapsDeterministic(&kp.ek, .v2, &hybrid.kat_seed_m, &hybrid.kat_seed_eph_sk);

    try out.writeStreamingAll(io, "# full-path vector outputs\n");
    try line(io, out, "ek", &kp.ek);
    try line(io, out, "dk", &kp.dk);
    try line(io, out, "ct", &enc_v1.ct);
    try line(io, out, "K_v1", &enc_v1.K);
    try line(io, out, "K_v2", &enc_v2.K);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha3.Sha3_256.hash(&kp.ek, &digest, .{});
    try line(io, out, "sha3_256(ek)", &digest);
    std.crypto.hash.sha3.Sha3_256.hash(&kp.dk, &digest, .{});
    try line(io, out, "sha3_256(dk)", &digest);
    std.crypto.hash.sha3.Sha3_256.hash(&enc_v1.ct, &digest, .{});
    try line(io, out, "sha3_256(ct)", &digest);
}
