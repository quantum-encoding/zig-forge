//! ledger-verify — replay an NDJSON ledger through the shared detector and print
//! a findings report. This is the runnable reference for the proxy's detection
//! pass (the proxy will call the same `detect.Detector` via C-ABI), the
//! app-user session-end inspection tool, and a CI gate (exit 2 on high/critical).
//!
//! Config via environment (this stripped std lacks os.argv):
//!   CHRONOS_LEDGER_OUT       ndjson ledger path   (default /tmp/chronos-ledger.ndjson)
//!   CHRONOS_LEDGER_PUB       pubkey hex file      (default <OUT>.pub)
//!   CHRONOS_LEDGER_ALLOWLIST comma-separated pinned egress hosts
//!                            (default: api.quantumencoding.ai,api.github.com,github.com)

const std = @import("std");
const c = std.c;
const cl = @import("chronos_ledger");

const DEFAULT_OUT = "/tmp/chronos-ledger.ndjson";
const DEFAULT_ALLOWLIST = "api.quantumencoding.ai,api.github.com,github.com";

pub fn main() !u8 {
    const allocator = std.heap.c_allocator;

    const out_path = envOr("CHRONOS_LEDGER_OUT", DEFAULT_OUT);
    const pub_path = if (c.getenv("CHRONOS_LEDGER_PUB")) |p|
        try allocator.dupe(u8, std.mem.span(p))
    else
        try std.fmt.allocPrint(allocator, "{s}.pub", .{out_path});
    defer allocator.free(pub_path);
    const allow_csv = if (c.getenv("CHRONOS_LEDGER_ALLOWLIST")) |p| std.mem.span(p) else DEFAULT_ALLOWLIST;

    // ── Public key ──────────────────────────────────────────────────────────
    const pub_raw = readAll(allocator, pub_path) catch {
        printz("ledger-verify: cannot read pubkey file: ");
        printz(pub_path);
        printz("\n");
        return 1;
    };
    defer allocator.free(pub_raw);
    const pub_hex = std.mem.trim(u8, pub_raw, " \r\n\t");
    if (pub_hex.len != cl.PK_LEN * 2) {
        printz("ledger-verify: pubkey hex has wrong length\n");
        return 1;
    }
    var pk: [cl.PK_LEN]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk, pub_hex) catch {
        printz("ledger-verify: pubkey is not valid hex\n");
        return 1;
    };

    // ── Allowlist ───────────────────────────────────────────────────────────
    var allow: std.ArrayList([]const u8) = .empty;
    defer allow.deinit(allocator);
    var it = std.mem.splitScalar(u8, allow_csv, ',');
    while (it.next()) |tok| {
        const h = std.mem.trim(u8, tok, " \r\n\t");
        if (h.len != 0) try allow.append(allocator, h);
    }

    // ── Replay the ledger ─────────────────────────────────────────────────────
    const ndjson = readAll(allocator, out_path) catch {
        printz("ledger-verify: cannot read ledger: ");
        printz(out_path);
        printz("\n");
        return 1;
    };
    defer allocator.free(ndjson);

    var det = cl.Detector.init(allocator, .{ .allowlist = allow.items }, &pk);
    defer det.deinit();

    var events: usize = 0;
    var lines = std.mem.splitScalar(u8, ndjson, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\n\t").len == 0) continue;
        try det.feed(line);
        events += 1;
    }

    // ── Report ────────────────────────────────────────────────────────────────
    outLine(allocator, "ledger-verify: {d} event(s) from {s}", .{ events, out_path });
    outLine(allocator, "allowlist: {s}", .{allow_csv});
    if (det.findings.items.len == 0) {
        outLine(allocator, "  no findings — chain intact, no policy violations.", .{});
    } else {
        outLine(allocator, "  {d} finding(s):", .{det.findings.items.len});
        for (det.findings.items) |f| {
            outLine(allocator, "    [{s:<8}] {s:<16} seq={d:<4} {s}", .{ @tagName(f.severity), f.rule, f.seq, f.detail });
        }
    }
    outLine(allocator, "verdict: {s}", .{@tagName(det.worst())});

    // CI/gate semantics: high or critical → non-zero exit.
    return if (@intFromEnum(det.worst()) >= @intFromEnum(cl.Severity.high)) 2 else 0;
}

fn envOr(key: [*:0]const u8, fallback: []const u8) []const u8 {
    if (c.getenv(key)) |p| return std.mem.span(p);
    return fallback;
}

fn printz(s: []const u8) void {
    _ = c.write(2, s.ptr, s.len);
}

/// Format one line to stdout (this std's unmanaged ArrayList has no writer).
fn outLine(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(allocator, fmt ++ "\n", args) catch return;
    defer allocator.free(s);
    _ = c.write(1, s.ptr, s.len);
}

/// Read an entire file via libc (this std lacks std.fs.cwd). Caller frees.
fn readAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return buf.toOwnedSlice(allocator);
}
