//! Hardware random number generation via the x86_64 RDRAND instruction.
//!
//! RDRAND is a NIST SP 800-90A/B/C compliant AES-CTR DRBG that is continuously
//! reseeded by an on-die hardware entropy source. Its output is cryptographically
//! strong, so `getrandom(2)` draws from it directly rather than post-processing
//! it through a software DRBG. This replaces the previous RDTSC-seeded LCG,
//! whose output was fully predictable and unusable for TLS key material.
//!
//! Availability is probed once via CPUID.01H:ECX.RDRAND[bit 30]. On parts
//! without RDRAND (very old CPUs, or some minimal hypervisor configurations),
//! `fill` returns false and the caller must fall back explicitly.

const std = @import("std");

var probed: bool = false;
var rdrand_ok: bool = false;

const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// Probe CPUID for RDRAND support. Result is cached after the first call.
pub fn available() bool {
    if (!probed) {
        const r = cpuid(1, 0);
        rdrand_ok = (r.ecx & (@as(u32, 1) << 30)) != 0;
        probed = true;
    }
    return rdrand_ok;
}

/// Attempt one 64-bit RDRAND. Intel's software guidance is to retry up to 10
/// times before treating a cleared carry flag as a hardware failure. Returns
/// null if no random value was produced within that budget.
fn rdrand64() ?u64 {
    var attempts: u32 = 0;
    while (attempts < 10) : (attempts += 1) {
        var value: u64 = undefined;
        var ok: u8 = 0;
        // rdrand + setc must stay in one asm block so nothing between them can
        // clobber the carry flag that setc reads back.
        asm volatile ("rdrand %[val]\n\tsetc %[ok]"
            : [val] "=r" (value),
              [ok] "=r" (ok),
            :
            : .{ .cc = true });
        if (ok != 0) return value;
    }
    return null;
}

/// Fill `dest` with hardware random bytes. Returns false if RDRAND is
/// unavailable, or a 64-bit draw could not be produced within the retry
/// budget; in that case `dest` contents are unspecified and must not be used.
pub fn fill(dest: []u8) bool {
    if (!available()) return false;

    var i: usize = 0;
    while (i < dest.len) {
        const value = rdrand64() orelse return false;
        const bytes = std.mem.asBytes(&value);
        const remaining = dest.len - i;
        const n = if (remaining < 8) remaining else 8;
        @memcpy(dest[i .. i + n], bytes[0..n]);
        i += n;
    }
    return true;
}
