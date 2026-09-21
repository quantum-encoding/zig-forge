//! Build input for `zig build ct-check` (tools/ct_divide_check.py). Not part of the library.
//!
//! Exports every entry point that handles secret data so that none of it is removed as dead code
//! and all of it appears, attributable to a function, in the emitted assembly.
const kem = @import("ml_kem_api.zig");
const dsa = @import("ml_dsa.zig");

export fn ct_probe_kem_keygen(d: *const [32]u8, z: *const [32]u8, ek: *[1184]u8, dk: *[2400]u8) void {
    const kp = kem.keyGenInternal768(d, z) catch return;
    ek.* = kp.ek.data;
    dk.* = kp.dk.data;
}

export fn ct_probe_kem_encaps(ek: *const [1184]u8, m: *const [32]u8, ct: *[1088]u8, ss: *[32]u8) void {
    const r = kem.encapsInternal768(&kem.EncapsulationKey768{ .data = ek.* }, m) catch return;
    ct.* = r.c.data;
    ss.* = r.K;
}

export fn ct_probe_kem_decaps(dk: *const [2400]u8, ct: *const [1088]u8, ss: *[32]u8) void {
    ss.* = kem.decaps768(&kem.DecapsulationKey768{ .data = dk.* }, &kem.Ciphertext768{ .data = ct.* });
}

export fn ct_probe_dsa_keygen(seed: *const [32]u8, pk: *[dsa.PUBLIC_KEY_SIZE]u8, sk: *[dsa.SECRET_KEY_SIZE]u8) void {
    const kp = dsa.keyGen(seed) catch return;
    pk.* = kp.pk.data;
    sk.* = kp.sk.data;
}

export fn ct_probe_dsa_sign(sk: *const [dsa.SECRET_KEY_SIZE]u8, msg: [*]const u8, len: usize, sig: *[dsa.SIGNATURE_SIZE]u8) void {
    const s = dsa.signWithContext(&dsa.SecretKey{ .data = sk.* }, msg[0..len], "ct-check", false) catch return;
    sig.* = s.data;
}
