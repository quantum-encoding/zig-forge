//! Recon target — exercises the full HttpClient + std.crypto.tls path under
//! os_tag = .linux, abi = .none, link_libc = false.
//!
//! Goal: force the compiler to pull in every std.os.linux.* symbol the HTTP
//! client and TLS stack actually need on a hosted Linux build, so we have
//! a precise checklist for the freestanding Zigix Io vtable.
//!
//! This binary is never run — we only care about what compiles and what links.

const std = @import("std");
const HttpClient = @import("http-sentinel").HttpClient;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "zigix-recon/0.1" },
    };

    // Plaintext HTTP — exercises socket() + connect() + read/write
    var http_resp = try client.get("http://example.com/", &headers);
    defer http_resp.deinit();

    // HTTPS — exercises std.crypto.tls + RNG + clock
    var https_resp = try client.get("https://example.com/", &headers);
    defer https_resp.deinit();

    // POST — exercises body writer flush path
    var post_resp = try client.post(
        "https://httpbin.org/post",
        &headers,
        "{\"hello\":\"zigix\"}",
    );
    defer post_resp.deinit();

    std.debug.print("status: {} {} {}\n", .{
        http_resp.status,
        https_resp.status,
        post_resp.status,
    });
}
