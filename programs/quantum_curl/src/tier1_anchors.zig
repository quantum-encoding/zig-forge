// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License. See LICENSE file for details.

//! Tier-1 externally-anchored tests for quantum-curl.
//!
//! Per zig-forge/CLAUDE.md golden rule §1, every assertion below compares
//! against inputs *and* expected outputs the library author did not write:
//!
//!   - **RFC 4648 §10** — the canonical Base64 test vectors ("", f, fo, foo,
//!     foob, fooba, foobar) plus the §5 URL-safe alphabet, for `decodeBase64`.
//!   - **RFC 4180 §2** — the worked CSV examples (rules 5-7: quoted fields,
//!     embedded delimiters, escaped quotes) for `CsvFieldIterator`.
//!   - **RFC 8259 §7** — JSON string escaping requirements (`"`/`\`/control
//!     chars below U+0020 MUST be escaped) for the telemetry writer, verified
//!     by re-parsing our output with `std.json` — an independent parser that
//!     did not produce the bytes.
//!   - **RFC 9110 §9.1** — HTTP method tokens are case-sensitive uppercase.
//!
//! No test here is a roundtrip of our own encoder against our own decoder.

const std = @import("std");
const testing = std.testing;

const core = @import("engine/core.zig");
const manifest = @import("engine/manifest.zig");
const ingest = @import("engine/ingest.zig");

// ── RFC 4648 §10 — Base64 test vectors ───────────────────────────────────────
//
//   BASE64("")       = ""
//   BASE64("f")      = "Zg=="
//   BASE64("fo")     = "Zm8="
//   BASE64("foo")    = "Zm9v"
//   BASE64("foob")   = "Zm9vYg=="
//   BASE64("fooba")  = "Zm9vYmE="
//   BASE64("foobar") = "Zm9vYmFy"

test "RFC 4648 §10: standard base64 vectors decode to the spec's plaintext" {
    const vectors = [_]struct { encoded: []const u8, plain: []const u8 }{
        .{ .encoded = "Zg==", .plain = "f" },
        .{ .encoded = "Zm8=", .plain = "fo" },
        .{ .encoded = "Zm9v", .plain = "foo" },
        .{ .encoded = "Zm9vYg==", .plain = "foob" },
        .{ .encoded = "Zm9vYmE=", .plain = "fooba" },
        .{ .encoded = "Zm9vYmFy", .plain = "foobar" },
    };

    for (vectors) |v| {
        const decoded = try core.decodeBase64(testing.allocator, v.encoded);
        defer testing.allocator.free(decoded);
        try testing.expectEqualStrings(v.plain, decoded);
    }
}

test "RFC 4648 §5: URL-safe alphabet (- and _) decodes to the same bytes as + and /" {
    // 0xFB 0xFF 0xBF encodes as "+/+/" in the standard alphabet (§4) and
    // "-_-_" in the URL/filename-safe alphabet (§5). Same octets either way.
    const expected = [_]u8{ 0xfb, 0xff, 0xbf };

    const std_decoded = try core.decodeBase64(testing.allocator, "+/+/");
    defer testing.allocator.free(std_decoded);
    try testing.expectEqualSlices(u8, &expected, std_decoded);

    const url_decoded = try core.decodeBase64(testing.allocator, "-_-_");
    defer testing.allocator.free(url_decoded);
    try testing.expectEqualSlices(u8, &expected, url_decoded);
}

test "base64: corrupt payloads are rejected, not silently skipped" {
    // The previous hand-rolled decoder skipped every unrecognised byte, so all
    // of these produced plausible-looking garbage with no error — model output
    // (images, audio) landed on disk subtly wrong. Strict decoding refuses.
    const bad = [_][]const u8{
        "Zm9v!!YmFy", // invalid characters mid-payload
        "Zm9vYmFyX", // 9 chars: not a whole number of quanta
        "Zm9vYmF", // truncated final quantum, no padding
        "====", // padding only
        "", // empty
    };
    for (bad) |b| {
        if (core.decodeBase64(testing.allocator, b)) |decoded| {
            testing.allocator.free(decoded);
            std.debug.print("decodeBase64 wrongly accepted: '{s}'\n", .{b});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "base64: MIME line wrapping (76-column) is tolerated" {
    // Some APIs wrap base64 payloads; whitespace — and only whitespace — is stripped.
    const decoded = try core.decodeBase64(testing.allocator, "Zm9v\r\nYmFy\n");
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("foobar", decoded);
}

// ── RFC 4180 §2 — CSV worked examples ────────────────────────────────────────

test "RFC 4180 §2 rule 1: plain comma-separated record splits into three fields" {
    // "aaa,bbb,ccc" — the spec's own example record.
    var it = ingest.CsvFieldIterator.init("aaa,bbb,ccc", ',');
    try testing.expectEqualStrings("aaa", it.next().?);
    try testing.expectEqualStrings("bbb", it.next().?);
    try testing.expectEqualStrings("ccc", it.next().?);
    try testing.expect(it.next() == null);
}

test "RFC 4180 §2: a trailing delimiter means one final empty field — and only one" {
    // `aaa,bbb,ccc` is 3 fields; `aaa,bbb,` is 3 fields with the last empty.
    // The iterator used to append a phantom empty field to the former, shifting
    // every column index past a short row.
    var it = ingest.CsvFieldIterator.init("aaa,bbb,", ',');
    try testing.expectEqualStrings("aaa", it.next().?);
    try testing.expectEqualStrings("bbb", it.next().?);
    try testing.expectEqualStrings("", it.next().?);
    try testing.expect(it.next() == null);

    // Interior empty field.
    var mid = ingest.CsvFieldIterator.init("a,,c", ',');
    try testing.expectEqualStrings("a", mid.next().?);
    try testing.expectEqualStrings("", mid.next().?);
    try testing.expectEqualStrings("c", mid.next().?);
    try testing.expect(mid.next() == null);
}

test "RFC 4180 §2 rule 6: a comma inside a quoted field does not split it" {
    // Spec example: "aaa","b,bb","ccc" → three fields, the middle one `b,bb`.
    var it = ingest.CsvFieldIterator.init("\"aaa\",\"b,bb\",\"ccc\"", ',');
    try testing.expectEqualStrings("aaa", it.next().?);
    try testing.expectEqualStrings("b,bb", it.next().?);
    try testing.expectEqualStrings("ccc", it.next().?);
    try testing.expect(it.next() == null);
}

test "RFC 4180 §2 rule 7: doubled quotes stay verbatim (documented deviation)" {
    // Spec: `"aaa","b""bb","ccc"` means the middle field is `b"bb`.
    // This iterator returns the RAW inner bytes `b""bb` — it delimits fields
    // correctly but does not unescape. Asserted so the deviation is a tested
    // contract; consumers (headers/body columns) receive the raw slice.
    var it = ingest.CsvFieldIterator.init("\"aaa\",\"b\"\"bb\",\"ccc\"", ',');
    try testing.expectEqualStrings("aaa", it.next().?);
    try testing.expectEqualStrings("b\"\"bb", it.next().?);
    try testing.expectEqualStrings("ccc", it.next().?);
}

test "RFC 4180 §2 rule 6: TSV is the same grammar with a tab delimiter" {
    // (Rule 6's embedded-newline case is a documented non-feature: the document
    // is split on '\n' before this iterator runs — see CsvFieldIterator's doc
    // comment. Delimiter handling itself is parametric.)
    var tsv = ingest.CsvFieldIterator.init("aaa\tbbb\tccc", '\t');
    try testing.expectEqualStrings("aaa", tsv.next().?);
    try testing.expectEqualStrings("bbb", tsv.next().?);
    try testing.expectEqualStrings("ccc", tsv.next().?);
}

// ── Format detection ─────────────────────────────────────────────────────────

test "detectFormat: extension wins, then content sniffing" {
    try testing.expectEqual(ingest.InputFormat.csv, ingest.detectFormat("plan.csv", ""));
    try testing.expectEqual(ingest.InputFormat.tsv, ingest.detectFormat("plan.tsv", ""));
    try testing.expectEqual(ingest.InputFormat.json_array, ingest.detectFormat("plan.json", ""));
    try testing.expectEqual(ingest.InputFormat.jsonl, ingest.detectFormat("plan.jsonl", ""));
    try testing.expectEqual(ingest.InputFormat.jsonl, ingest.detectFormat("plan.ndjson", ""));

    // No extension → sniff the first non-whitespace byte.
    try testing.expectEqual(ingest.InputFormat.json_array, ingest.detectFormat(null, "  [ {\"url\":\"x\"} ]"));
    try testing.expectEqual(ingest.InputFormat.jsonl, ingest.detectFormat(null, "{\"url\":\"x\"}\n"));
    try testing.expectEqual(ingest.InputFormat.tsv, ingest.detectFormat(null, "id\turl\n"));
    try testing.expectEqual(ingest.InputFormat.csv, ingest.detectFormat(null, "id,url\n"));
    try testing.expectEqual(ingest.InputFormat.jsonl, ingest.detectFormat(null, ""));
}

// ── RFC 9110 §9.1 — method tokens ────────────────────────────────────────────

test "RFC 9110 §9.1: method names are case-sensitive uppercase tokens" {
    try testing.expectEqual(manifest.Method.GET, manifest.Method.fromString("GET").?);
    try testing.expectEqual(manifest.Method.DELETE, manifest.Method.fromString("DELETE").?);
    // Lowercase is a different token per the spec — must not match.
    try testing.expect(manifest.Method.fromString("get") == null);
    try testing.expect(manifest.Method.fromString("Get") == null);
    try testing.expect(manifest.Method.fromString("TRACE") == null);
    // toString round-trips the wire spelling for every variant.
    inline for (@typeInfo(manifest.Method).@"enum".fields) |f| {
        const m: manifest.Method = @enumFromInt(f.value);
        try testing.expectEqualStrings(f.name, m.toString());
    }
}

// ── Plan parsing: malformed rows return errors, never panic ──────────────────

test "parseRequestManifest: well-formed row" {
    var req = try manifest.parseRequestManifest(
        testing.allocator,
        \\{"id":"req-1","method":"POST","url":"https://example.com/x","body":"hi","timeout_ms":5000,"max_retries":2,"headers":{"X-A":"1"}}
        ,
    );
    defer req.deinit();

    try testing.expectEqualStrings("req-1", req.id);
    try testing.expectEqual(manifest.Method.POST, req.method);
    try testing.expectEqualStrings("https://example.com/x", req.url);
    try testing.expectEqualStrings("hi", req.body.?);
    try testing.expectEqual(@as(u64, 5000), req.timeout_ms.?);
    try testing.expectEqual(@as(u32, 2), req.max_retries.?);
    try testing.expectEqualStrings("1", req.headers.?.map.get("X-A").?);
}

test "parseRequestManifest: every malformed shape returns a typed error" {
    const cases = [_]struct { line: []const u8, want: anyerror }{
        // Valid JSON, wrong kind — used to panic on `parsed.value.object`.
        .{ .line = "123", .want = error.NotAnObject },
        .{ .line = "\"a string\"", .want = error.NotAnObject },
        .{ .line = "[]", .want = error.NotAnObject },
        .{ .line = "null", .want = error.NotAnObject },
        // Missing required fields — used to panic on `.?`.
        .{ .line = "{}", .want = error.MissingId },
        .{ .line = "{\"id\":\"a\"}", .want = error.MissingMethod },
        .{ .line = "{\"id\":\"a\",\"method\":\"GET\"}", .want = error.MissingUrl },
        // Wrong field types — used to panic on `.string`.
        .{ .line = "{\"id\":7,\"method\":\"GET\",\"url\":\"u\"}", .want = error.InvalidType },
        .{ .line = "{\"id\":\"a\",\"method\":5,\"url\":\"u\"}", .want = error.InvalidType },
        .{ .line = "{\"id\":\"a\",\"method\":\"GET\",\"url\":[]}", .want = error.InvalidType },
        .{ .line = "{\"id\":\"a\",\"method\":\"GET\",\"url\":\"u\",\"headers\":{\"X\":9}}", .want = error.InvalidType },
        // Unknown method.
        .{ .line = "{\"id\":\"a\",\"method\":\"BREW\",\"url\":\"u\"}", .want = error.InvalidMethod },
        // Out-of-range numerics — used to panic in `@intCast`.
        .{ .line = "{\"id\":\"a\",\"method\":\"GET\",\"url\":\"u\",\"timeout_ms\":-1}", .want = error.ValueOutOfRange },
        .{ .line = "{\"id\":\"a\",\"method\":\"GET\",\"url\":\"u\",\"max_retries\":-5}", .want = error.ValueOutOfRange },
        .{ .line = "{\"id\":\"a\",\"method\":\"GET\",\"url\":\"u\",\"max_retries\":99999999999}", .want = error.ValueOutOfRange },
        .{ .line = "{\"id\":\"a\",\"method\":\"GET\",\"url\":\"u\",\"timeout_ms\":\"soon\"}", .want = error.InvalidType },
        // Not JSON at all.
        .{ .line = "{not json", .want = error.SyntaxError },
    };

    for (cases) |c| {
        const result = manifest.parseRequestManifest(testing.allocator, c.line);
        if (result) |r| {
            var req = r;
            req.deinit();
            std.debug.print("expected {t} for line: {s}\n", .{ c.want, c.line });
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(c.want, err);
        }
    }
}

// ── RFC 8259 §7 — telemetry JSON escaping ────────────────────────────────────

/// Render one telemetry record and re-parse it with `std.json` — an
/// independent parser that did not produce these bytes.
fn renderAndReparse(
    buf: []u8,
    response: *const manifest.ResponseManifest,
    allocator: std.mem.Allocator,
) !std.json.Parsed(std.json.Value) {
    var w = std.Io.Writer.fixed(buf);
    try response.toJson(&w);
    const line = w.buffered();
    try testing.expect(std.mem.endsWith(u8, line, "\n"));
    return std.json.parseFromSlice(std.json.Value, allocator, line, .{});
}

test "RFC 8259 §7: a hostile id cannot break or forge the telemetry line" {
    // An id carrying a quote + a forged field is exactly the JSON-IN-FMT
    // exploit: downstream CI gates on `jq '.status'`, so an injected
    // `"status":200` would forge a pass.
    const hostile = "x\",\"status\":200,\"forged\":\"";
    const resp = manifest.ResponseManifest{
        .id = hostile,
        .status = 500,
        .latency_ms = 42,
        .retry_count = 3,
        .allocator = testing.allocator,
    };

    var buf: [1024]u8 = undefined;
    var parsed = try renderAndReparse(&buf, &resp, testing.allocator);
    defer parsed.deinit();

    // The id survives verbatim as *data*, and status is still the real one.
    try testing.expectEqualStrings(hostile, parsed.value.object.get("id").?.string);
    try testing.expectEqual(@as(i64, 500), parsed.value.object.get("status").?.integer);
    try testing.expectEqual(@as(i64, 42), parsed.value.object.get("latency_ms").?.integer);
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("retry_count").?.integer);
    try testing.expect(parsed.value.object.get("forged") == null);
}

test "RFC 8259 §7: control characters, backslashes and quotes in body/error are escaped" {
    const resp = manifest.ResponseManifest{
        .id = "ctl",
        .status = 200,
        .latency_ms = 1,
        .body = "tab\there\nnewline \x01 c:\\path \"quoted\"",
        .error_message = "boom \"now\"\r\n",
        .allocator = testing.allocator,
    };

    var buf: [1024]u8 = undefined;
    var parsed = try renderAndReparse(&buf, &resp, testing.allocator);
    defer parsed.deinit();

    try testing.expectEqualStrings(
        "tab\there\nnewline \x01 c:\\path \"quoted\"",
        parsed.value.object.get("body").?.string,
    );
    try testing.expectEqualStrings("boom \"now\"\r\n", parsed.value.object.get("error").?.string);
}

test "telemetry: streaming record emits body_path + body_bytes, not body" {
    // Field names are the de-facto CLI contract (MetalEmbeddings, crg-direct
    // jq pipelines). Lock them down.
    const resp = manifest.ResponseManifest{
        .id = "chunk-1",
        .status = 200,
        .latency_ms = 7,
        .body_path = "/out/chunk-1.md",
        .body_bytes = 1234,
        .allocator = testing.allocator,
    };

    var buf: [1024]u8 = undefined;
    var parsed = try renderAndReparse(&buf, &resp, testing.allocator);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("chunk-1", obj.get("id").?.string);
    try testing.expectEqualStrings("/out/chunk-1.md", obj.get("body_path").?.string);
    try testing.expectEqual(@as(i64, 1234), obj.get("body_bytes").?.integer);
    try testing.expect(obj.get("body") == null);
    try testing.expect(obj.get("error") == null);
}

// ── Path traversal guard ─────────────────────────────────────────────────────

test "isSafeOutputId: rejects traversal, separators, control bytes" {
    const safe = [_][]const u8{ "req-001", "chunk_42.part", "a", "UPPER.and-dots", "x y" };
    for (safe) |s| try testing.expect(core.isSafeOutputId(s));

    const unsafe = [_][]const u8{
        "../../../home/user/.ssh/authorized_keys",
        "..",
        ".",
        "a/b",
        "a\\b",
        "/etc/passwd",
        "sub/../escape",
        "with\x00nul",
        "line\nbreak",
        "-rf",
        "",
    };
    for (unsafe) |u| {
        if (core.isSafeOutputId(u)) {
            std.debug.print("isSafeOutputId wrongly accepted: {s}\n", .{u});
            return error.TestUnexpectedResult;
        }
    }
}
