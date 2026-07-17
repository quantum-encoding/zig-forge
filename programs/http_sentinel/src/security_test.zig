// Copyright (c) 2026 QUANTUM ENCODING LTD
//
// Externally-anchored security regression tests for the SSRF guard.
//
// The manifest engine (engine/core.zig) now offers an opt-in
// `block_private_urls` guard that rejects the INITIAL request URL when it
// targets a private / link-local / loopback / cloud-metadata host. That
// guard delegates to `http_client.isPrivateRedirect`, so these tests pin
// that function against the address blocks defined by published specs — the
// inputs AND expected verdicts come from the IANA registries / RFCs below,
// not from this codebase, so they are external anchors, not roundtrips.
//
// External anchors:
//   * RFC 1918 §3        — private IPv4 ranges 10/8, 172.16/12, 192.168/16
//   * RFC 3927 §2.1      — link-local 169.254.0.0/16 (used by AWS/GCP/Azure
//                          metadata service at 169.254.169.254)
//   * RFC 1122 §3.2.1.3  — loopback 127.0.0.0/8 and "this host" 0.0.0.0/8
//   * RFC 4291 §2.5.3    — IPv6 loopback ::1
//   * IANA IPv4 Special-Purpose Address Registry — these blocks are all
//     flagged "Forwardable: False" / not globally reachable.
// Public control addresses:
//   * 8.8.8.8            — Google Public DNS, globally routable (must pass).
//   * documentation host — must pass (public scheme + name).

const std = @import("std");
const http_client = @import("http_client.zig");
const isPrivateRedirect = http_client.isPrivateRedirect;

test "SSRF guard blocks IANA/RFC special-purpose (non-forwardable) addresses" {
    // Each entry is a canonical member of a published special-purpose block.
    // isPrivateRedirect MUST classify every one as private (return true).
    const must_block = [_][]const u8{
        // RFC 3927 link-local — the cloud metadata endpoint.
        "http://169.254.169.254/latest/meta-data/",
        "http://169.254.0.1/",
        // RFC 1918 private ranges.
        "http://10.0.0.1/internal",
        "http://10.255.255.254/",
        "http://172.16.0.1/admin",
        "http://172.31.255.254/",
        "http://192.168.1.1/config",
        // RFC 1122 loopback + "this host".
        "http://127.0.0.1:8080/secret",
        "http://0.0.0.0/",
        // Reserved / metadata hostnames.
        "http://localhost/admin",
        "http://metadata.google.internal/computeMetadata/v1/",
        // RFC 4291 IPv6 loopback.
        "http://[::1]/admin",
        // Non-HTTP(S) scheme — SSRF via file/ftp/gopher etc.
        "ftp://example.com/file",
        "gopher://127.0.0.1:70/",
    };
    for (must_block) |url| {
        std.testing.expect(isPrivateRedirect(url)) catch |err| {
            std.debug.print("FAIL: expected BLOCK for {s}\n", .{url});
            return err;
        };
    }
}

test "SSRF guard permits globally-routable public addresses" {
    // Globally-reachable per the IANA registry — must NOT be blocked.
    const must_allow = [_][]const u8{
        "https://api.example.com/data",
        "http://8.8.8.8/dns", // Google Public DNS — globally routable.
        "https://cdn.provider.com/file.bin",
    };
    for (must_allow) |url| {
        std.testing.expect(!isPrivateRedirect(url)) catch |err| {
            std.debug.print("FAIL: expected ALLOW for {s}\n", .{url});
            return err;
        };
    }
}
