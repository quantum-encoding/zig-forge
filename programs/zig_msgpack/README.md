# zig_msgpack

A streaming MessagePack encoder and decoder for Zig, designed to consume **untrusted input** safely.

Bidirectional: `Encoder` (encoder.zig) writes the wire format, `Decoder` (decoder.zig) reads it. Both follow the [MessagePack specification](https://github.com/msgpack/msgpack/blob/master/spec.md).

## Threat model — read this if you parse untrusted bytes

This is a wire-format library at a hostile boundary. The decoder is hardened against the standard family of MessagePack DoS / parsing attacks:

| Defense | Mechanism |
|---|---|
| **Recursion DoS via deep nesting** | `Decoder.max_depth` (default 512) caps the depth of `skip()` via an iterative work-stack. External recursive walkers must bound themselves to the same `max_depth` (see "Walking trees safely" below). |
| **Integer overflow on length prefixes** | All `pos + len` computations go through `std.math.add(usize, ...)`. On 32-bit targets (Android ARMv7, WASM) a hostile u32 length plus `pos` cannot wrap to bypass the bounds check. |
| **Length-vs-buffer sanity** | After reading any `str` / `bin` / `ext` length header, the decoder eagerly errors with `UnexpectedEndOfData` if the claimed length exceeds the remaining input. Failure surfaces at the header, not after a partial read. |
| **Iterator poisoning on partial failure** | If an `ArrayIterator.next()` or `MapIterator.next()` errors mid-element, the iterator's `remaining` is forced to 0. Subsequent `next()` calls return `null` cleanly instead of reading at a corrupted byte offset. |
| **MapIterator atomicity** | The `remaining` counter only decrements after BOTH key and value reads succeed. A key-read or value-read failure does not advance the iterator past the partial entry. |
| **UTF-8 validation (opt-in)** | `Decoder.readStringValidated()` checks the bytes via `std.unicode.utf8ValidateSlice` and errors with `InvalidUtf8` on malformed input. Use this for strings that flow into UTF-8-aware downstream code. `readString` returns raw bytes (faster, opaque). |
| **Reserved opcode rejection** | The never-used `0xc1` byte errors with `InvalidFormat`. |

The encoder is hardened against silent data corruption:

| Defense | Mechanism |
|---|---|
| **Deterministic float encoding** | The non-canonical `writeFloat` auto-precision helper was **removed**. Callers must pick `writeFloat32` (5 bytes) or `writeFloat64` (9 bytes) explicitly. This matters for any protocol that hashes or signs the encoded form. |
| **Timestamp nanosecond validation** | `writeTimestamp` rejects `nanoseconds >= 1_000_000_000` with `error.InvalidNanoseconds`. Without this, a u32 value ≥ 2³⁰ would silently overflow the 30-bit nanoseconds field of the packed timestamp-64 representation. `Decoder.readTimestamp()` / `decodeTimestamp(ext)` mirror the same check on the decode side (hostile ts64/ts96 payloads claiming out-of-range nanoseconds are rejected with `error.InvalidTimestamp`). |
| **Overflow-safe writes** | Same `std.math.add` guard as the decoder, on the writer side. |

See [CHANGELOG / audit findings](#audit-may-2025) below for the bugs each defense closed.

## Zero-copy lifetime contract — READ THIS

`Value.string`, `Value.binary`, and `Value.ext.data` are **zero-copy slices borrowed from the input buffer** you passed to `Decoder.init`. This is intentional — the library does no allocation on the hot path — and it means:

> The caller MUST keep the input buffer alive for as long as any `Value`, `ArrayIterator`, `MapIterator`, or `Extension` derived from it is still in use.

Don't do this:

```zig
fn parseMessage(input_owned: []u8) !void {
    var dec = msgpack.Decoder.init(input_owned);
    const v = try dec.read();
    allocator.free(input_owned);   // 💥 v.string now dangles
    useString(v.string);            // use-after-free
}
```

Do this instead — defer the free until after all `Value`s are consumed:

```zig
fn parseMessage(input_owned: []u8) !void {
    defer allocator.free(input_owned);
    var dec = msgpack.Decoder.init(input_owned);
    const v = try dec.read();
    useString(v.string);            // ✓ input still alive
}
```

If you need to outlive the input buffer, **copy the slice** before the input is freed:

```zig
const v = try dec.read();
const owned = try allocator.dupe(u8, v.string);
defer allocator.free(owned);
```

The same rule applies to `ArrayIterator` and `MapIterator` — they hold a `*Decoder` which holds the input slice.

## Walking trees safely (external recursive walkers)

`Decoder.skip()` enforces its own depth cap, but if you walk the parsed tree recursively in your own code (e.g. to convert it to a domain type), the depth cap doesn't extend into your stack frames. You must bound your own recursion explicitly. The recommended pattern matches msgpack-c and serde:

```zig
fn walkValue(value: msgpack.Value, depth: u32, max_depth: u32) !void {
    if (depth >= max_depth) return error.MaxDepthExceeded;
    switch (value) {
        .array => |arr| {
            var iter = arr;
            while (try iter.next()) |inner| try walkValue(inner, depth + 1, max_depth);
        },
        .map => |m| {
            var iter = m;
            while (try iter.next()) |entry| {
                try walkValue(entry.key, depth + 1, max_depth);
                try walkValue(entry.value, depth + 1, max_depth);
            }
        },
        else => {}, // primitive — nothing to recurse into
    }
}

// Call as: try walkValue(root_value, 0, dec.max_depth);
```

The library design decision (and why the depth counter lives on `skip()` rather than on the iterators themselves) is documented at the top of `src/decoder.zig`. Short version: Zig has no destructors on non-allocated structs, so a lazy iterator can't reliably tell when its container is "done," which makes iterator-driven depth bookkeeping either over-count or under-count. The explicit walker pattern above is what every production msgpack library does.

## Single-use Decoder convention

A `Decoder` is intended to parse one message. Reuse across messages is unsupported — build a fresh `Decoder` per message. The same applies to iterators: don't try to share or interleave iterators that hold the same underlying decoder pointer (their `next()` calls each advance the shared position; interleaving will read at corrupt offsets).

## Example: encoding

```zig
const msgpack = @import("msgpack");

var buffer: [1024]u8 = undefined;
var enc = msgpack.Encoder.init(&buffer);

try enc.writeMapHeader(2);
try enc.writeString("name");
try enc.writeString("Alice");
try enc.writeString("age");
try enc.writeUint(30);

const wire_bytes: []const u8 = enc.getWritten();
```

## Example: decoding (safe untrusted input)

```zig
const std = @import("std");
const msgpack = @import("msgpack");

var dec = msgpack.Decoder.init(payload);   // keep `payload` alive!
const value = try dec.read();

switch (value) {
    .map => |m| {
        var iter = m;
        while (try iter.next()) |entry| {
            const key_str = switch (entry.key) {
                .string => |s| s,
                else => return error.UnexpectedKeyType,
            };
            if (!std.unicode.utf8ValidateSlice(key_str)) return error.InvalidUtf8;
            // Use entry.value here. Remember: key_str borrows from `payload`.
        }
    },
    else => return error.UnexpectedShape,
}
```

For a top-level string call site, `readStringValidated()` does the same in one step:

```zig
var dec = msgpack.Decoder.init(payload);
const s: []const u8 = try dec.readStringValidated();  // errors on bad UTF-8
```

## Building

```bash
zig build           # produces zig-out/bin/msgpack-demo, zig-out/lib/libzig_msgpack.a
zig build run       # run the demo
zig build test      # run the full test suite (lib + comprehensive + tier1 anchors + fuzz harness, 1 iteration)
zig build fuzz --fuzz  # coverage-guided fuzzing of the decoder against arbitrary bytes
zig build bench     # run benchmarks
```

## Test architecture (Tier 1 / 2 / 3)

Per the in-tree library promotion rule documented in `/CLAUDE.md`:

| File | Tier | Purpose |
|---|---|---|
| `src/tier1_anchors.zig` | 1 | Externally-anchored byte vectors from the [MessagePack spec](https://github.com/msgpack/msgpack/blob/master/spec.md). Each test pins encode + decode to a published wire-format sequence written by people who don't work on this library. Removing or weakening these requires a re-audit, not a refactor. |
| `src/decoder.zig` (tests at bottom) | 2 | Failure-mode tests — depth cap, length sanity, iterator poisoning, malformed input, UTF-8 validation. |
| `src/encoder.zig` (tests at bottom) | 2 | Failure-mode tests — nanosecond bounds, buffer overflow, deterministic float widths. |
| `src/comprehensive_test.zig` | 3 | End-to-end encode → decode roundtrips for every type. Cheap to keep, never sufficient on their own. |
| `src/fuzz.zig` | 2 | Structured fuzz harness (`std.testing.fuzz`) feeding the decoder arbitrary bytes; asserts `skip()` and `read()` never crash, over-read, or corrupt memory (including with `max_depth` raised above the fixed stack size). Runs one deterministic iteration under `zig build test`; drive real fuzzing with `zig build fuzz --fuzz`. |

`zig build test` runs all four test entry points (lib, comprehensive, tier1 anchors, fuzz).

## Audit (May 2025)

This library was promoted via the audit gate after closing the following findings:

| ID | Class | Issue | Fix |
|----|-------|-------|-----|
| H-1 | Coverage | `comprehensive_test.zig` was orphan code, never executed by `zig build test` (22 tests gave false confidence) | Wired into the build's test step alongside `tier1_anchors.zig` |
| H-2 | Coverage | Every existing test was an internal-consistency roundtrip — same failure mode that hid the SHA-256 bug in `zig_base58` | Created `tier1_anchors.zig` with published MessagePack spec byte vectors as ground truth |
| H-3 | DoS + correctness | `skip()` walked nested containers without a depth limit (~50KB hostile payload crashed the process via stack overflow) AND only drained the top level — nested element bytes were left unread, leaving the decoder at the wrong position. | Rewrote `skip()` as an iterative loop with an explicit work-stack capped at `max_depth = 512`. `MaxDepthExceeded` errors immediately on oversized nesting; nested containers are now fully drained. |
| H-4 | Encoder data integrity | `writeTimestamp` accepted any u32 nanoseconds; values ≥ 2³⁰ overflowed into the seconds field of the packed timestamp-64 | Explicit `nanoseconds >= 1_000_000_000` check |
| M-1 | Overflow | `pos + len` could wrap on 32-bit targets | `std.math.add(usize, ...)` in both reader and writer |
| M-2 | Bounds | `str32` / `bin32` / `ext32` headers claiming more bytes than available didn't fail until partway through the read | `ensureCanRead` guard immediately after every length header |
| M-3 | Non-determinism | `writeFloat` auto-promoted f64→f32 when lossless, producing different bytes for the same logical value (footgun for signed/hashed protocols) | Removed. Callers must pick `writeFloat32` / `writeFloat64` explicitly |
| M-4 | Iterator state | `MapIterator.next()` decremented `remaining` before reading; a mid-entry error left the iterator in a corrupt state | `remaining -= 1` only after BOTH key and value reads succeed. Errors poison the iterator (sets `remaining = 0`) |
| M-5 | Lifetime | Zero-copy slice contract was undocumented — naive callers could trigger UAF | Documented in this README + decoder docstring |
| M-6 | Spec compliance | `readString` returned raw bytes (msgpack spec says str = UTF-8) | Added `readStringValidated` opt-in variant; `readString` still returns raw bytes for speed |
| M-7 | Hygiene | No README — failed CLAUDE.md rule #4 | This file |

## Limitations

- **`skip()` uses a fixed-size work-stack, not Zig call frames.** It is iterative — its explicit stack is sized `DEFAULT_MAX_DEPTH` (512 `usize` slots), so it cannot overflow the machine stack no matter how deeply nested the input is. Nesting past `max_depth` (or past 512, whichever is smaller) returns `error.MaxDepthExceeded`. Raising `max_depth` above 512 does **not** raise the effective `skip()` limit — the backing buffer is fixed — but it is memory-safe (never an out-of-bounds write). Lower `max_depth` if you want a tighter cap.
- **No streaming I/O.** The decoder operates on a complete in-memory slice. For very large payloads, splice them in chunks at the application level.
- **Single-use Decoder.** See note above.
