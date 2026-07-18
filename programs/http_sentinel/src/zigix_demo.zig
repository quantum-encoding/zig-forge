//! Zigix bring-up demo — the first `http_sentinel` binary intended to run as a
//! Zigix userspace ELF (`os_tag = .linux`, `abi = .none`, no libc).
//!
//! Zigix implements the Linux syscall ABI (including the `syscall` instruction
//! that `std.os.linux` emits), a from-scratch TCP/IP stack with BSD socket
//! syscalls, `clone`/`futex`, and anonymous `mmap`. That is enough to run a
//! stock `std.http.Client` — no bespoke `std.Io` vtable required. This program
//! exercises the minimal path.
//!
//! It drives `HttpClient` through a caller-owned single-threaded Io (matching
//! Zigix's current BSP-only scheduler) via `HttpClient.initWithIo`, then
//! performs one GET against `build_options.zigix_url`.
//!
//! Bring-up milestones:
//!   1. plaintext `http://`  — needs only socket + mmap + Io (all present on
//!      Zigix today). This is the first thing to get green on real hardware/VM.
//!   2. `https://`           — additionally needs a pinned cert-validation time
//!      and an explicit CA bundle (both wired below), plus — for real security
//!      rather than just a completed handshake — a Zigix RTC and CSPRNG. Those
//!      are kernel-side gaps tracked in ZIGIX_INTEGRATION.md.

const std = @import("std");
const build_options = @import("build_options");
const HttpClient = @import("http-sentinel").HttpClient;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Single-threaded Io: Zigix schedules application threads on the BSP only
    // (no SMP parallelism yet), so bring-up must not depend on multiple cores.
    // This is also the tightest possible exercise of the `initWithIo` seam.
    var io_threaded = std.Io.Threaded.init_single_threaded;
    const io = io_threaded.io();

    var client = HttpClient.initWithIo(allocator, io);
    defer client.deinit();

    const url = build_options.zigix_url;
    const is_https = std.mem.startsWith(u8, url, "https://");

    if (is_https) {
        // Zigix's CLOCK_REALTIME is boot-relative today (reads ~1970), which
        // would reject every valid certificate. Pin a plausible validation
        // time; this also suppresses the filesystem CA rescan, so we must
        // supply trust anchors ourselves. `.empty` lets the handshake complete
        // for transport bring-up but fails chain verification — swap in a real
        // bundle (packaged on the ext image, or embedded) for milestone 2.
        client.setCertValidationTime(.{ .nanoseconds = build_options.zigix_cert_epoch_ns });
        client.setCaBundle(.empty);
    }

    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "*/*" },
        .{ .name = "User-Agent", .value = "zigix-sentinel/0.1" },
    };

    std.debug.print("zigix-demo: GET {s} ...\n", .{url});
    var resp = client.get(url, &headers) catch |err| {
        std.debug.print("zigix-demo: request failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer resp.deinit();

    const preview_len = @min(resp.body.len, 256);
    std.debug.print(
        "zigix-demo: status={d} body={d} bytes\n----\n{s}\n----\n",
        .{ @intFromEnum(resp.status), resp.body.len, resp.body[0..preview_len] },
    );
}
