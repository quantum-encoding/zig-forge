//! ledger-daemon — privileged reference sink for the Chronos Ledger.
//!
//! Binds an AF_UNIX datagram socket, receives event bodies from in-agent
//! emit-clients (chronos-hook → cl_emit), chains + signs them (milestones only),
//! and appends the canonical shipped events to an NDJSON log. That log is the
//! local buffer (cloud: pre-ship to the proxy) and the session bundle (app user:
//! delivered for inspection). Shipping to the qai proxy (`POST /v1/ledger`) is
//! the remaining seam — see `forward()`.
//!
//! Config via environment (no argv — this stripped std lacks os.argv):
//!   CHRONOS_LEDGER_SOCKET  unix datagram path   (default /tmp/chronos-ledger.sock)
//!   CHRONOS_LEDGER_OUT     ndjson log path      (default /tmp/chronos-ledger.ndjson)
//!   CHRONOS_LEDGER_KEY     pk||sk keyfile (5984B); generated + persisted if absent
//!
//! Syscalls the stripped std.posix doesn't expose are declared extern "c"
//! (same pattern as chronos-hook's fork/execvp); file I/O uses std.c.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const cl = @import("chronos_ledger");
const Sink = @import("sink.zig").Sink;

const DEFAULT_SOCKET = "/tmp/chronos-ledger.sock";
const DEFAULT_OUT = "/tmp/chronos-ledger.ndjson";
const KEYFILE_LEN = cl.PK_LEN + cl.SK_LEN; // 5984

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
extern "c" fn recvfrom(fd: c_int, buf: [*]u8, len: usize, flags: c_int, src: ?*anyopaque, srclen: ?*u32) isize;

const is_bsd = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};
const AF_UNIX: c_int = 1;
const SOCK_DGRAM: c_int = 2;

const SockaddrUn = if (is_bsd) extern struct {
    sun_len: u8,
    sun_family: u8,
    sun_path: [104]u8,
} else extern struct {
    sun_family: u16,
    sun_path: [108]u8,
};

fn logErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "[ledger-daemon] " ++ fmt ++ "\n", args) catch return;
    _ = c.write(2, s.ptr, s.len);
}

fn envOr(key: [*:0]const u8, fallback: []const u8) []const u8 {
    if (c.getenv(key)) |p| return std.mem.span(p);
    return fallback;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const socket_path = envOr("CHRONOS_LEDGER_SOCKET", DEFAULT_SOCKET);
    const out_path = envOr("CHRONOS_LEDGER_OUT", DEFAULT_OUT);
    const key_path: ?[]const u8 = if (c.getenv("CHRONOS_LEDGER_KEY")) |p| std.mem.span(p) else null;

    // ── Key: load pk||sk if present, else generate ephemeral and persist ────
    var pk: [cl.PK_LEN]u8 = undefined;
    var sk: [cl.SK_LEN]u8 = undefined;
    if (key_path) |kp_path| if (loadKey(kp_path, &pk, &sk)) {
        logErr("loaded signing key from {s}", .{kp_path});
    } else {
        const gen = try cl.generateKeypair(null);
        pk = gen.pk;
        sk = gen.sk;
        saveKey(kp_path, &pk, &sk);
        logErr("generated new signing key → {s}", .{kp_path});
    } else {
        const gen = try cl.generateKeypair(null);
        pk = gen.pk;
        sk = gen.sk;
        logErr("generated ephemeral signing key (set CHRONOS_LEDGER_KEY to persist)", .{});
    }

    // Publish the public key so a verifier (proxy / user) can check the chain.
    writePubkey(allocator, out_path, &pk);

    var sink = Sink.initSigning(allocator, &sk, &pk);

    // ── NDJSON output (append-only) ─────────────────────────────────────────
    const out_fd = openAppend(out_path) orelse {
        logErr("cannot open output {s}", .{out_path});
        return error.OutputUnavailable;
    };
    defer _ = c.close(out_fd);

    // ── Bind the datagram socket ────────────────────────────────────────────
    if (socket_path.len >= @as(usize, @sizeOf(@FieldType(SockaddrUn, "sun_path")))) {
        logErr("socket path too long", .{});
        return error.PathTooLong;
    }
    _ = c.unlink(@ptrCast(socket_path.ptr)); // stale socket from a prior run
    const fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);

    var addr: SockaddrUn = std.mem.zeroes(SockaddrUn);
    addr.sun_family = if (is_bsd) AF_UNIX else @intCast(AF_UNIX);
    if (is_bsd) addr.sun_len = @sizeOf(SockaddrUn);
    @memcpy(addr.sun_path[0..socket_path.len], socket_path);
    if (bind(fd, @ptrCast(&addr), @sizeOf(SockaddrUn)) != 0) {
        logErr("bind {s} failed", .{socket_path});
        return error.BindFailed;
    }
    logErr("listening on {s}, logging to {s}", .{ socket_path, out_path });

    // ── Receive loop ────────────────────────────────────────────────────────
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = recvfrom(fd, &buf, buf.len, 0, null, null);
        if (n < 0) continue; // EINTR etc. — keep serving
        if (n == 0) continue;
        const payload = buf[0..@intCast(n)];
        const ev = sink.process(payload) catch |e| {
            // A bad datagram from a buggy/hostile client must not take the sink
            // down — log and keep the chain intact for the next event.
            logErr("dropped datagram ({s})", .{@errorName(e)});
            continue;
        };
        defer allocator.free(ev.json);
        appendLine(out_fd, ev.json);
        if (ev.signed) _ = c.fsync(out_fd); // durably persist milestone heads
        forward(ev.json) catch {};
    }
}

/// Seam for shipping off-box to the qai proxy (`POST /v1/ledger`). For cloud
/// stateless sinks this becomes the source of truth; the NDJSON file is then a
/// crash buffer. Left unimplemented until the proxy endpoint exists.
fn forward(shipped_json: []const u8) !void {
    _ = shipped_json;
}

fn openAppend(path: []const u8) ?c.fd_t {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return null;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&pbuf), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c.mode_t, 0o600));
    return if (fd < 0) null else fd;
}

fn appendLine(fd: c.fd_t, bytes: []const u8) void {
    _ = c.write(fd, bytes.ptr, bytes.len);
    _ = c.write(fd, "\n", 1);
}

fn loadKey(path: []const u8, pk: *[cl.PK_LEN]u8, sk: *[cl.SK_LEN]u8) bool {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return false;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var both: [KEYFILE_LEN]u8 = undefined;
    var got: usize = 0;
    while (got < both.len) {
        const r = c.read(fd, both[got..].ptr, both.len - got);
        if (r <= 0) return false;
        got += @intCast(r);
    }
    @memcpy(pk, both[0..cl.PK_LEN]);
    @memcpy(sk, both[cl.PK_LEN..]);
    return true;
}

fn saveKey(path: []const u8, pk: *const [cl.PK_LEN]u8, sk: *const [cl.SK_LEN]u8) void {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&pbuf), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = c.close(fd);
    _ = c.write(fd, pk, pk.len);
    _ = c.write(fd, sk, sk.len);
}

fn writePubkey(allocator: std.mem.Allocator, out_path: []const u8, pk: *const [cl.PK_LEN]u8) void {
    const pub_path = std.fmt.allocPrint(allocator, "{s}.pub", .{out_path}) catch return;
    defer allocator.free(pub_path);
    var pbuf: [4096]u8 = undefined;
    if (pub_path.len >= pbuf.len) return;
    @memcpy(pbuf[0..pub_path.len], pub_path);
    pbuf[pub_path.len] = 0;
    const fd = c.open(@ptrCast(&pbuf), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);
    const hex = std.fmt.bytesToHex(pk.*, .lower);
    _ = c.write(fd, &hex, hex.len);
    _ = c.write(fd, "\n", 1);
}
