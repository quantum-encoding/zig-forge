//! ═══════════════════════════════════════════════════════════════════════════
//! TIER 1 EXTERNAL ANCHORS — WebAssembly binary format & execution
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Per zig-forge/CLAUDE.md §1: a library that consumes untrusted input must be
//! tested against inputs AND expected outputs that this codebase did not
//! invent. Roundtrip tests prove self-consistency only, and this runtime
//! EXECUTES untrusted bytecode, so self-consistency is worth very little: a
//! parser and an interpreter that agree with each other about a wrong encoding
//! still hand the guest a sandbox escape.
//!
//! The anchors here are byte encodings transcribed from the published
//! WebAssembly Core Specification 1.0 (W3C Recommendation, 5 December 2019),
//! not values produced by this implementation:
//!
//!   • Module preamble        — Binary Format §5.5.16 (magic `\0asm`, version 1)
//!   • Section framing        — Binary Format §5.5.1
//!   • LEB128 integers        — Binary Format §5.2.2 (uN / sN well-formedness)
//!   • Function types         — Binary Format §5.3.6 (0x60 form byte)
//!   • Value types            — Binary Format §5.3.1 (i32 = 0x7F, ...)
//!   • Limits                 — Binary Format §5.3.7 (flag 0x00/0x01, n <= m)
//!   • Memory bound           — Structure §2.5.3 (2^16 pages)
//!   • Instruction opcodes    — Binary Format §5.4
//!   • Element segments       — Binary Format §5.5.12
//!
//! Two halves, both required:
//!
//!   1. VALID modules hand-assembled from the documented byte grammar; the
//!      parser must extract exactly the documented values, and the interpreter
//!      must compute the results the spec defines for those opcodes.
//!
//!   2. MALFORMED modules that must be REJECTED. A validator that accepts
//!      malformed input is the bug class that matters for a sandbox — and
//!      "rejected" specifically means an error return, never a host panic.
//!      Several of these are regression anchors for defects found in this
//!      file's companion audit; each is labelled with what it used to do.

const std = @import("std");
const testing = std.testing;

const binary = @import("core/binary.zig");
const interpreter = @import("core/interpreter.zig");
const types = @import("core/types.zig");

const Value = types.Value;

// ═══════════════════════════════════════════════════════════════════════════
// Module assembly helper
//
// Emits the documented binary grammar directly (magic, version, then
// `section_id size contents`) so each test reads as the spec's byte layout
// rather than as an opaque blob. Section sizes are computed, never guessed.
// ═══════════════════════════════════════════════════════════════════════════

const ModuleBuilder = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !ModuleBuilder {
        var mb = ModuleBuilder{ .allocator = allocator };
        try mb.buf.appendSlice(allocator, &binary.MAGIC);
        try mb.buf.appendSlice(allocator, &binary.VERSION);
        return mb;
    }

    fn deinit(self: *ModuleBuilder) void {
        self.buf.deinit(self.allocator);
    }

    /// Append `section_id u32:size contents` — Binary Format §5.5.1
    fn section(self: *ModuleBuilder, id: u8, contents: []const u8) !void {
        try self.buf.append(self.allocator, id);
        try appendUleb(&self.buf, self.allocator, @intCast(contents.len));
        try self.buf.appendSlice(self.allocator, contents);
    }

    fn bytes(self: *const ModuleBuilder) []const u8 {
        return self.buf.items;
    }
};

fn appendUleb(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var v = value;
    while (true) {
        var b: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v != 0) b |= 0x80;
        try list.append(allocator, b);
        if (v == 0) break;
    }
}

/// Parse, instantiate, and call an exported function — the whole pipeline.
fn runExport(
    allocator: std.mem.Allocator,
    module_bytes: []const u8,
    name: []const u8,
    args: []const Value,
) !?Value {
    var module = try binary.parse(allocator, module_bytes);
    defer module.deinit();

    var inst = try interpreter.Instance.init(allocator, &module);
    defer inst.deinit();

    return try inst.call(name, args);
}

// ═══════════════════════════════════════════════════════════════════════════
// PART 1 — VALID modules: documented bytes in, documented values out
// ═══════════════════════════════════════════════════════════════════════════

test "anchor: module preamble is the spec's 8 magic+version bytes" {
    // Binary Format §5.5.16: magic = 0x00 0x61 0x73 0x6D ("\0asm"),
    // version = 0x01 0x00 0x00 0x00. Spelled out literally rather than via the
    // constants, so a change to the constants cannot silently redefine "valid".
    const spec_preamble = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    try testing.expectEqualSlices(u8, &spec_preamble, &(binary.MAGIC ++ binary.VERSION));

    var module = try binary.parse(testing.allocator, &spec_preamble);
    defer module.deinit();

    // An empty module is valid and has no contents.
    try testing.expectEqual(@as(usize, 0), module.types.len);
    try testing.expectEqual(@as(usize, 0), module.codes.len);
    try testing.expectEqual(@as(usize, 0), module.exports.len);
}

test "anchor: LEB128 unsigned/signed published examples" {
    // The canonical LEB128 worked examples (DWARF §7.6, reused by the WASM
    // Binary Format §5.2.2): 624485 encodes as E5 8E 26; -123456 encodes as
    // C0 BB 78.
    var r1 = binary.Reader.init(&[_]u8{ 0xE5, 0x8E, 0x26 });
    try testing.expectEqual(@as(u32, 624485), try r1.readU32());

    var r2 = binary.Reader.init(&[_]u8{ 0xC0, 0xBB, 0x78 });
    try testing.expectEqual(@as(i32, -123456), try r2.readI32());

    // Boundary values that require the full 5-byte / 10-byte encodings.
    //
    // REGRESSION: the decoder tracked its shift in a `u5`/`u6`, so reaching
    // the 5th (i32) or 10th (i64) byte overflowed the shift counter and
    // PANICKED THE HOST — on a perfectly valid module. `i32.const 1000000000`
    // was enough to crash the runtime.
    var r3 = binary.Reader.init(&[_]u8{ 0x80, 0x94, 0xEB, 0xDC, 0x03 });
    try testing.expectEqual(@as(i32, 1000000000), try r3.readI32());

    // The i64 extremes need the full 10-byte sN encoding.
    var r4a = binary.Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7F });
    try testing.expectEqual(std.math.minInt(i64), try r4a.readI64());
    var r4b = binary.Reader.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 });
    try testing.expectEqual(std.math.maxInt(i64), try r4b.readI64());

    // maxInt(u32) is the widest legal u32: 5 bytes, final byte 0x0F.
    var r5 = binary.Reader.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F });
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), try r5.readU32());

    // sN sign extension across the full i32 range.
    var r6 = binary.Reader.init(&[_]u8{ 0x7F }); // -1
    try testing.expectEqual(@as(i32, -1), try r6.readI32());
    var r7 = binary.Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x78 }); // minInt(i32)
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), try r7.readI32());
}

test "anchor: type section decodes the spec's functype encoding" {
    // Binary Format §5.3.6: functype := 0x60 vec(valtype) vec(valtype)
    // Value types (§5.3.1): i32 = 0x7F, i64 = 0x7E, f32 = 0x7D, f64 = 0x7C.
    // Encoded here: (func (param i32 i64) (result f64))
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();
    try mb.section(1, &[_]u8{
        0x01, // 1 type
        0x60, // functype form byte
        0x02, 0x7F, 0x7E, // 2 params: i32, i64
        0x01, 0x7C, // 1 result: f64
    });

    var module = try binary.parse(testing.allocator, mb.bytes());
    defer module.deinit();

    try testing.expectEqual(@as(usize, 1), module.types.len);
    try testing.expectEqualSlices(types.ValType, &.{ .i32, .i64 }, module.types[0].params);
    try testing.expectEqualSlices(types.ValType, &.{.f64}, module.types[0].results);
}

/// `(module (func (export "add") (param i32 i32) (result i32)
///            local.get 0  local.get 1  i32.add))`
///
/// Opcodes (Binary Format §5.4): local.get = 0x20, i32.add = 0x6A, end = 0x0B.
fn buildAddModule(allocator: std.mem.Allocator) !ModuleBuilder {
    var mb = try ModuleBuilder.init(allocator);
    errdefer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F });
    try mb.section(3, &[_]u8{ 0x01, 0x00 }); // 1 func, type 0
    try mb.section(7, &[_]u8{ 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00 }); // export "add" func 0
    try mb.section(10, &[_]u8{
        0x01, // 1 body
        0x07, // body size
        0x00, // 0 local decls
        0x20, 0x00, // local.get 0
        0x20, 0x01, // local.get 1
        0x6A, // i32.add
        0x0B, // end
    });
    return mb;
}

test "anchor: end-to-end execution of a spec-encoded i32.add function" {
    var mb = try buildAddModule(testing.allocator);
    defer mb.deinit();

    const result = try runExport(testing.allocator, mb.bytes(), "add", &.{
        .{ .i32 = 2 }, .{ .i32 = 40 },
    });
    try testing.expectEqual(@as(i32, 42), result.?.i32);
}

test "anchor: i32.add wraps modulo 2^32 per spec, and i32.div_s traps on overflow" {
    // Exec §4.3.2: iadd is defined modulo 2^N, so maxInt + 1 == minInt.
    var mb = try buildAddModule(testing.allocator);
    defer mb.deinit();

    const wrapped = try runExport(testing.allocator, mb.bytes(), "add", &.{
        .{ .i32 = std.math.maxInt(i32) }, .{ .i32 = 1 },
    });
    try testing.expectEqual(std.math.minInt(i32), wrapped.?.i32);

    // Exec §4.3.2 idiv_s: division by zero and minInt/-1 both TRAP. A host
    // panic here would be a guest-triggerable crash, so the distinction
    // between "trap" and "panic" is the whole point.
    var dm = try ModuleBuilder.init(testing.allocator);
    defer dm.deinit();
    try dm.section(1, &[_]u8{ 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F });
    try dm.section(3, &[_]u8{ 0x01, 0x00 });
    try dm.section(7, &[_]u8{ 0x01, 0x03, 'd', 'i', 'v', 0x00, 0x00 });
    try dm.section(10, &[_]u8{ 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6D, 0x0B }); // i32.div_s = 0x6D

    try testing.expectError(error.IntegerDivideByZero, runExport(
        testing.allocator,
        dm.bytes(),
        "div",
        &.{ .{ .i32 = 1 }, .{ .i32 = 0 } },
    ));
    try testing.expectError(error.IntegerOverflow, runExport(
        testing.allocator,
        dm.bytes(),
        "div",
        &.{ .{ .i32 = std.math.minInt(i32) }, .{ .i32 = -1 } },
    ));
}

test "anchor: caller's locals survive a call to a fall-through callee" {
    // REGRESSION (audit finding 1): callFuncInternal pushed a frame but only
    // the explicit `return` opcode popped one. A callee that terminated by
    // falling off its final `end` left its frame on top of the call stack, so
    // the CALLER's next local.get read the CALLEE's locals.
    //
    //   (func $callee (result i32) i32.const 7)       ;; no `return` opcode
    //   (func $main (export "main") (param i32) (result i32)
    //     call $callee  drop
    //     local.get 0)                                ;; must still be the arg
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{
        0x02, // 2 types
        0x60, 0x00, 0x01, 0x7F, // type 0: () -> i32
        0x60, 0x01, 0x7F, 0x01, 0x7F, // type 1: (i32) -> i32
    });
    try mb.section(3, &[_]u8{ 0x02, 0x00, 0x01 }); // func 0: type 0, func 1: type 1
    try mb.section(7, &[_]u8{ 0x01, 0x04, 'm', 'a', 'i', 'n', 0x00, 0x01 });
    try mb.section(10, &[_]u8{
        0x02, // 2 bodies
        0x04, 0x00, 0x41, 0x07, 0x0B, // $callee: i32.const 7; end
        0x07, 0x00, 0x10, 0x00, 0x1A, 0x20, 0x00, 0x0B, // $main: call 0; drop; local.get 0; end
    });

    const result = try runExport(testing.allocator, mb.bytes(), "main", &.{.{ .i32 = 99 }});
    try testing.expectEqual(@as(i32, 99), result.?.i32);
}

test "anchor: a call nested inside a block terminates at the callee's own end" {
    // REGRESSION (audit finding 2): the label stack was instance-global and
    // `execute` terminated on `end` only when the stack was EMPTY. With a call
    // made from inside a caller's `block`, the caller's label was still
    // resident, so the callee's terminal `end` did not end the callee — it
    // ran on into whatever bytes followed.
    //
    //   (func $callee (result i32) i32.const 5)
    //   (func $main (export "main") (result i32)
    //     (block (result i32) call $callee))
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7F }); // () -> i32
    try mb.section(3, &[_]u8{ 0x02, 0x00, 0x00 });
    try mb.section(7, &[_]u8{ 0x01, 0x04, 'm', 'a', 'i', 'n', 0x00, 0x01 });
    try mb.section(10, &[_]u8{
        0x02,
        0x04, 0x00, 0x41, 0x05, 0x0B, // $callee: i32.const 5; end
        0x07, 0x00, 0x02, 0x7F, 0x10, 0x00, 0x0B, 0x0B, // $main: block i32; call 0; end; end
    });

    const result = try runExport(testing.allocator, mb.bytes(), "main", &.{});
    try testing.expectEqual(@as(i32, 5), result.?.i32);
}

test "anchor: caller resumes after a block containing a call" {
    // Sharper form of the label-scoping anchor above. That test ended the
    // caller immediately after the block, so a callee that wrongly popped the
    // CALLER's label still produced the right answer — the caller had nothing
    // left to run. Mutation testing (reverting the `.end` frame-base guard)
    // exposed that: the earlier test stayed green against the bug.
    //
    // Here the caller has work AFTER the block, so a stolen label makes the
    // caller terminate early and return 5 instead of 15.
    //
    //   (module
    //     (func $callee (result i32) (i32.const 5))
    //     (func (export "main") (result i32)
    //       (i32.add (block (result i32) (call $callee)) (i32.const 10))))
    const golden = "0061736d010000000105016000017f0303020000070801046d61696e00010a1102040041050b0a00027f10000b410a6a0b";

    var buf: [128]u8 = undefined;
    const module_bytes = try std.fmt.hexToBytes(buf[0..], golden);

    const result = try runExport(testing.allocator, module_bytes, "main", &.{});
    try testing.expectEqual(@as(i32, 15), result.?.i32);
}

test "anchor: br_table selects each labelled target and the default" {
    // Binary Format §5.4.1: br_table = 0x0E vec(labelidx) labelidx, i.e. the
    // vector of targets FOLLOWED BY a default label used when the operand is
    // out of range.
    //
    // REGRESSION (audit finding 5): the reader broke out of the label-reading
    // loop early on a match and then resumed a second "skip the rest" loop
    // from the same index, leaving the byte stream mid-vector and selecting
    // the wrong target for the default case.
    //
    //   (func (export "sel") (param i32) (result i32)
    //     (block (block (block
    //       (br_table 0 1 2 (local.get 0)))
    //       (return (i32.const 100)))     ;; target 0
    //       (return (i32.const 200)))     ;; target 1
    //     (i32.const 300))                ;; target 2 == default
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F });
    try mb.section(3, &[_]u8{ 0x01, 0x00 });
    try mb.section(7, &[_]u8{ 0x01, 0x03, 's', 'e', 'l', 0x00, 0x00 });

    const body = [_]u8{
        0x00, // 0 local decls
        0x02, 0x40, // block (void)
        0x02, 0x40, // block (void)
        0x02, 0x40, // block (void)
        0x20, 0x00, // local.get 0
        0x0E, 0x02, 0x00, 0x01, 0x02, // br_table 0 1 (default 2)
        0x0B, // end innermost
        0x41, 0xE4, 0x00, 0x0F, // i32.const 100; return
        0x0B, // end
        0x41, 0xC8, 0x01, 0x0F, // i32.const 200; return
        0x0B, // end
        0x41, 0xAC, 0x02, // i32.const 300
        0x0B, // end of function
    };
    var code = std.ArrayList(u8).empty;
    defer code.deinit(testing.allocator);
    try code.append(testing.allocator, 0x01); // 1 body
    try appendUleb(&code, testing.allocator, @intCast(body.len));
    try code.appendSlice(testing.allocator, &body);
    try mb.section(10, code.items);

    const cases = [_]struct { in: i32, out: i32 }{
        .{ .in = 0, .out = 100 },
        .{ .in = 1, .out = 200 },
        .{ .in = 2, .out = 300 }, // exact default index
        .{ .in = 99, .out = 300 }, // out of range -> default
    };
    for (cases) |c| {
        const result = try runExport(testing.allocator, mb.bytes(), "sel", &.{.{ .i32 = c.in }});
        try testing.expectEqual(c.out, result.?.i32);
    }
}

test "anchor: loop back-edge and br_if drive a counted loop to termination" {
    // Binary Format §5.4.1 / Exec §4.4.5: a `br` targeting a `loop` label
    // jumps BACK to the loop's start, unlike `block`/`if` which jump forward
    // past the `end`. This is the branch path that must NOT skip forward, so
    // it is the natural counterpart to the br_table anchor above.
    //
    //   (func (export "sum") (param i32) (result i32) (local i32 i32)
    //     ;; local 1 = accumulator, local 2 = counter
    //     (loop
    //       local.get 1  local.get 2  i32.add  local.set 1     ;; acc += i
    //       local.get 2  i32.const 1  i32.add  local.set 2      ;; i += 1
    //       local.get 2  local.get 0  i32.lt_s  br_if 0)        ;; while i < n
    //     local.get 1)
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F });
    try mb.section(3, &[_]u8{ 0x01, 0x00 });
    try mb.section(7, &[_]u8{ 0x01, 0x03, 's', 'u', 'm', 0x00, 0x00 });

    const body = [_]u8{
        0x01, 0x02, 0x7F, // 1 local decl: 2 x i32
        0x03, 0x40, // loop (void)
        0x20, 0x01, 0x20, 0x02, 0x6A, 0x21, 0x01, // acc += i
        0x20, 0x02, 0x41, 0x01, 0x6A, 0x21, 0x02, // i += 1
        0x20, 0x02, 0x20, 0x00, 0x48, // i < n  (i32.lt_s = 0x48)
        0x0D, 0x00, // br_if 0 -> back to loop start
        0x0B, // end loop
        0x20, 0x01, // local.get acc
        0x0B, // end function
    };
    var code = std.ArrayList(u8).empty;
    defer code.deinit(testing.allocator);
    try code.append(testing.allocator, 0x01);
    try appendUleb(&code, testing.allocator, @intCast(body.len));
    try code.appendSlice(testing.allocator, &body);
    try mb.section(10, code.items);

    // 0+1+2+3+4 == 10
    const result = try runExport(testing.allocator, mb.bytes(), "sum", &.{.{ .i32 = 5 }});
    try testing.expectEqual(@as(i32, 10), result.?.i32);
}

test "anchor: if/else selects the correct arm" {
    // Binary Format §5.4.1: if = 0x04 blocktype instr* (0x05 instr*)? 0x0B.
    // Skipping to the `else` and skipping from `else` to `end` both have to
    // consume nested blocktype immediates correctly.
    //
    //   (func (export "pick") (param i32) (result i32)
    //     (if (result i32) (local.get 0) (then i32.const 111) (else i32.const 222)))
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F });
    try mb.section(3, &[_]u8{ 0x01, 0x00 });
    try mb.section(7, &[_]u8{ 0x01, 0x04, 'p', 'i', 'c', 'k', 0x00, 0x00 });
    try mb.section(10, &[_]u8{
        0x01, 0x0E, 0x00,
        0x20, 0x00, // local.get 0
        0x04, 0x7F, // if (result i32)
        0x41, 0xEF, 0x00, // i32.const 111
        0x05, // else
        0x41, 0xDE, 0x01, // i32.const 222
        0x0B, // end if
        0x0B, // end function
    });

    try testing.expectEqual(@as(i32, 111), (try runExport(
        testing.allocator,
        mb.bytes(),
        "pick",
        &.{.{ .i32 = 1 }},
    )).?.i32);
    try testing.expectEqual(@as(i32, 222), (try runExport(
        testing.allocator,
        mb.bytes(),
        "pick",
        &.{.{ .i32 = 0 }},
    )).?.i32);
}

test "anchor: element section populates the table so call_indirect resolves" {
    // Binary Format §5.5.12. The element section was previously a NO-OP, so
    // `module.elements` was always empty and call_indirect could never find a
    // populated entry — every indirect call trapped with UndefinedElement.
    //
    //   (table 2 funcref)
    //   (elem (i32.const 0) $f0 $f1)
    //   (func $f0 (result i32) i32.const 11)
    //   (func $f1 (result i32) i32.const 22)
    //   (func (export "pick") (param i32) (result i32)
    //     (call_indirect (type 0) (local.get 0)))
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{
        0x02,
        0x60, 0x00, 0x01, 0x7F, // type 0: () -> i32
        0x60, 0x01, 0x7F, 0x01, 0x7F, // type 1: (i32) -> i32
    });
    try mb.section(3, &[_]u8{ 0x03, 0x00, 0x00, 0x01 });
    // Table section (§5.5.6): 1 table, funcref (0x70), limits flag 0x00, min 2
    try mb.section(4, &[_]u8{ 0x01, 0x70, 0x00, 0x02 });
    try mb.section(7, &[_]u8{ 0x01, 0x04, 'p', 'i', 'c', 'k', 0x00, 0x02 });
    // Element section: flags 0 (active, table 0, funcidx vector),
    // offset expr `i32.const 0 end`, then 2 function indices.
    try mb.section(9, &[_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0B, 0x02, 0x00, 0x01 });
    try mb.section(10, &[_]u8{
        0x03,
        0x04, 0x00, 0x41, 0x0B, 0x0B, // $f0: i32.const 11
        0x04, 0x00, 0x41, 0x16, 0x0B, // $f1: i32.const 22
        0x07, 0x00, 0x20, 0x00, 0x11, 0x00, 0x00, 0x0B, // call_indirect type 0 table 0
    });

    var module = try binary.parse(testing.allocator, mb.bytes());
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), module.elements.len);
    try testing.expectEqual(@as(usize, 2), module.elements[0].init.len);

    var inst = try interpreter.Instance.init(testing.allocator, &module);
    defer inst.deinit();

    try testing.expectEqual(@as(i32, 11), (try inst.call("pick", &.{.{ .i32 = 0 }})).?.i32);
    try testing.expectEqual(@as(i32, 22), (try inst.call("pick", &.{.{ .i32 = 1 }})).?.i32);

    // Out-of-range index traps rather than reading past the table.
    try testing.expectError(error.OutOfBoundsTableAccess, inst.call("pick", &.{.{ .i32 = 5 }}));
}

test "anchor: active data segment initializes memory and i32.load reads it" {
    // Binary Format §5.5.14 (data) + §5.4.4 (memory instructions).
    // i32.load = 0x28 with a memarg of {align, offset}.
    //
    //   (memory 1)
    //   (data (i32.const 0) "\2A\00\00\00")   ;; 42 little-endian
    //   (func (export "read") (result i32) (i32.load (i32.const 0)))
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7F });
    try mb.section(3, &[_]u8{ 0x01, 0x00 });
    try mb.section(5, &[_]u8{ 0x01, 0x00, 0x01 }); // 1 memory, min 1 page
    try mb.section(7, &[_]u8{ 0x01, 0x04, 'r', 'e', 'a', 'd', 0x00, 0x00 });
    // Sections must be emitted in ascending id order: code (10) then data (11).
    try mb.section(10, &[_]u8{
        0x01, 0x07, 0x00,
        0x41, 0x00, // i32.const 0
        0x28, 0x02, 0x00, // i32.load align=2 offset=0
        0x0B,
    });
    try mb.section(11, &[_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0B, 0x04, 0x2A, 0x00, 0x00, 0x00 });

    const result = try runExport(testing.allocator, mb.bytes(), "read", &.{});
    try testing.expectEqual(@as(i32, 42), result.?.i32);
}

// ═══════════════════════════════════════════════════════════════════════════
// PART 1b — Differential anchor against the reference toolchain
// ═══════════════════════════════════════════════════════════════════════════

/// Golden module bytes produced by WABT's `wat2wasm` (the WebAssembly
/// reference toolkit, github.com/WebAssembly/wabt) from the `.wat` source
/// quoted above each constant. These were emitted by a DIFFERENT
/// implementation — nothing in this repository produced them.
///
/// This is what lifts the tests above from "hand-assembled per our reading of
/// the spec" to "byte-identical to what the reference assembler emits". If our
/// reading of the grammar were wrong, the hand-built modules would still parse
/// happily in our own parser; only a comparison against an outside encoder
/// catches that. It already paid for itself: the comparison found two code
/// bodies whose declared `size` field disagreed with their actual length, and
/// in turn that our parser was ignoring that field entirely.
const wabt_goldens = struct {
    /// (module (func (export "add") (param i32 i32) (result i32)
    ///   local.get 0 local.get 1 i32.add))
    const add = "0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b";

    /// (module (func (export "sel") (param i32) (result i32)
    ///   (block (block (block (br_table 0 1 2 (local.get 0)))
    ///     (return (i32.const 100))) (return (i32.const 200))) (i32.const 300)))
    const sel = "0061736d0100000001060160017f017f030201000707010373656c00000a1f011d0002400240024020000e020001020b41e4000f0b41c8010f0b41ac020b";

    /// (module (func (export "sum") (param i32) (result i32) (local i32 i32)
    ///   (loop (local.set 1 (i32.add (local.get 1) (local.get 2)))
    ///         (local.set 2 (i32.add (local.get 2) (i32.const 1)))
    ///         (br_if 0 (i32.lt_s (local.get 2) (local.get 0))))
    ///   (local.get 1)))
    const sum = "0061736d0100000001060160017f017f030201000707010373756d00000a20011e01027f0340200120026a2101200241016a210220022000480d000b20010b";

    /// (module (func (export "pick") (param i32) (result i32)
    ///   (if (result i32) (local.get 0) (then (i32.const 111)) (else (i32.const 222)))))
    const pick = "0061736d0100000001060160017f017f03020100070801047069636b00000a10010e002000047f41ef000541de010b0b";

    /// (module (memory 1) (data (i32.const 0) "\2a\00\00\00")
    ///   (func (export "read") (result i32) (i32.load (i32.const 0))))
    const read = "0061736d010000000105016000017f030201000503010001070801047265616400000a0901070041002802000b0b0a010041000b042a000000";
};

fn expectMatchesGolden(hex: []const u8, actual: []const u8) !void {
    var expected: [512]u8 = undefined;
    const decoded = try std.fmt.hexToBytes(expected[0..], hex);
    try testing.expectEqualSlices(u8, decoded, actual);
}

test "anchor: our encodings are byte-identical to wat2wasm's output" {
    var add = try buildAddModule(testing.allocator);
    defer add.deinit();
    try expectMatchesGolden(wabt_goldens.add, add.bytes());

    // The remaining goldens are parsed and executed rather than re-encoded, so
    // the reference bytes themselves drive this runtime end to end.
    try testing.expectEqual(@as(i32, 300), (try runGoldenExport(wabt_goldens.sel, "sel", &.{.{ .i32 = 7 }})).?.i32);
    try testing.expectEqual(@as(i32, 10), (try runGoldenExport(wabt_goldens.sum, "sum", &.{.{ .i32 = 5 }})).?.i32);
    try testing.expectEqual(@as(i32, 111), (try runGoldenExport(wabt_goldens.pick, "pick", &.{.{ .i32 = 1 }})).?.i32);
    try testing.expectEqual(@as(i32, 42), (try runGoldenExport(wabt_goldens.read, "read", &.{})).?.i32);
}

fn runGoldenExport(hex: []const u8, name: []const u8, args: []const Value) !?Value {
    var buf: [512]u8 = undefined;
    const module_bytes = try std.fmt.hexToBytes(buf[0..], hex);
    return runExport(testing.allocator, module_bytes, name, args);
}

// ═══════════════════════════════════════════════════════════════════════════
// PART 2 — MALFORMED modules: every one must be REJECTED, none may panic
//
// The bug class that matters for a runtime executing untrusted bytecode is a
// validator that accepts (or crashes on) malformed input. Each case asserts a
// specific error, so "rejected" cannot silently degrade into "accepted".
// ═══════════════════════════════════════════════════════════════════════════

test "reject: bad magic, bad version, truncated preamble" {
    // Binary Format §5.5.16 — the preamble is fixed; anything else is malformed.
    try testing.expectError(error.InvalidMagic, binary.parse(
        testing.allocator,
        &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x00, 0x00, 0x00 },
    ));

    // Version 2 does not exist.
    try testing.expectError(error.InvalidVersion, binary.parse(
        testing.allocator,
        &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00 },
    ));

    // Truncated before the version field, and empty input.
    try testing.expectError(error.InvalidVersion, binary.parse(
        testing.allocator,
        &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00 },
    ));
    try testing.expectError(error.InvalidMagic, binary.parse(testing.allocator, &[_]u8{}));
}

test "reject: malformed LEB128 encodings" {
    // Binary Format §5.2.2. Each of these previously either panicked the host
    // on shift overflow or was silently truncated into a wrong value.

    // Continuation bit set but input ends.
    var r1 = binary.Reader.init(&[_]u8{0x80});
    try testing.expectError(error.UnexpectedEof, r1.readU32());

    // Over-long: 6 bytes for a u32 (the 6th continues past the 32-bit range).
    var r2 = binary.Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try testing.expectError(error.InvalidLeb128, r2.readU32());

    // 5 bytes, but the final byte carries value bits above bit 31.
    // (Only 4 value bits are legal in a u32's last byte.)
    var r3 = binary.Reader.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x7F });
    try testing.expectError(error.InvalidLeb128, r3.readU32());

    // Signed: the final byte's unused high bits must all equal the sign bit.
    // Here bit 3 (the sign of the surviving 4 value bits) is 1 but the bits
    // above it are 100, not 111 — not a valid sign extension.
    // (By contrast FF FF FF FF 7F *is* legal: it is -1.)
    var r4 = binary.Reader.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x4F });
    try testing.expectError(error.InvalidLeb128, r4.readI32());

    var r4ok = binary.Reader.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x7F });
    try testing.expectEqual(@as(i32, -1), try r4ok.readI32());

    // Over-long i64: an 11th byte cannot exist.
    var r5 = binary.Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try testing.expectError(error.InvalidLeb128, r5.readI64());
}

test "reject: section size that runs past end of module" {
    // Binary Format §5.5.1 — a section's declared size must fit the module.
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();
    // Type section declaring 0x7F bytes of contents but supplying one.
    try mb.buf.appendSlice(testing.allocator, &[_]u8{ 0x01, 0x7F, 0x01 });

    try testing.expectError(error.UnexpectedEof, binary.parse(testing.allocator, mb.bytes()));
}

test "reject: vector count larger than the bytes that could hold it" {
    // Every vector element occupies at least one byte, so a declared count
    // exceeding the remaining section length is malformed by construction.
    // Without this bound the parser attempted a multi-gigabyte allocation
    // driven purely by a 5-byte forged count.
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();
    // Type section: contents claim 0xFFFFFFFF types in 5 bytes.
    try mb.section(1, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F });

    try testing.expectError(error.InvalidSection, binary.parse(testing.allocator, mb.bytes()));
}

test "reject: data segment declaring more bytes than the module contains" {
    // REGRESSION: the declared length was used to slice the buffer directly,
    // with no bounds check — an over-long length panicked the host.
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();
    try mb.section(5, &[_]u8{ 0x01, 0x00, 0x01 }); // 1 memory
    // 1 segment, flags 0, offset `i32.const 0 end`, then length 0xFFFF with no data.
    try mb.section(11, &[_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0B, 0xFF, 0xFF, 0x03 });

    try testing.expectError(error.InvalidData, binary.parse(testing.allocator, mb.bytes()));
}

test "reject: limits with max below min, and a bad limits flag" {
    // Binary Format §5.3.7: the flag byte is 0x00 or 0x01 only, and n <= m.
    var mb1 = try ModuleBuilder.init(testing.allocator);
    defer mb1.deinit();
    try mb1.section(5, &[_]u8{ 0x01, 0x01, 0x0A, 0x05 }); // min 10, max 5
    try testing.expectError(error.InvalidSection, binary.parse(testing.allocator, mb1.bytes()));

    var mb2 = try ModuleBuilder.init(testing.allocator);
    defer mb2.deinit();
    try mb2.section(5, &[_]u8{ 0x01, 0x07, 0x01 }); // flag 0x07 is not defined
    try testing.expectError(error.InvalidSection, binary.parse(testing.allocator, mb2.bytes()));
}

test "reject: memory declaring more than the spec's 2^16 page maximum" {
    // Structure §2.5.3 caps a memory at 65536 pages (4 GiB). A module asking
    // for 0xFFFFFFFF pages would otherwise drive a 256 TiB allocation at
    // instantiation time.
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();
    try mb.section(5, &[_]u8{ 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F });

    try testing.expectError(error.InvalidSection, binary.parse(testing.allocator, mb.bytes()));
}

test "reject: unbounded recursion exhausts the call budget, not the host stack" {
    // The sandbox's whole purpose: a guest must not be able to crash the host.
    // `max_call_depth` was declared but never read, so `(func $f call $f)`
    // recursed through native Zig frames until the process died.
    //
    //   (func $f (export "f") call $f)
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x00, 0x00 }); // () -> ()
    try mb.section(3, &[_]u8{ 0x01, 0x00 });
    try mb.section(7, &[_]u8{ 0x01, 0x01, 'f', 0x00, 0x00 });
    try mb.section(10, &[_]u8{ 0x01, 0x04, 0x00, 0x10, 0x00, 0x0B });

    try testing.expectError(error.CallStackExhaustion, runExport(
        testing.allocator,
        mb.bytes(),
        "f",
        &.{},
    ));
}

test "reject: a guest that pushes forever hits the operand-stack bound" {
    // The operand-stack counterpart to the recursion bound. `max_stack_depth`
    // was declared but never read, so this module — which pushes an i32 every
    // iteration and never pops — grew the operand stack until the host ran out
    // of memory. Bytes below are wat2wasm's output for:
    //
    //   (module (func (export "grow") (loop (i32.const 1) (br 0))))
    const grow = "0061736d01000000010401600000030201000708010467726f7700000a0b010900034041010c000b0b";

    var buf: [128]u8 = undefined;
    const module_bytes = try std.fmt.hexToBytes(buf[0..], grow);

    try testing.expectError(error.StackOverflow, runExport(
        testing.allocator,
        module_bytes,
        "grow",
        &.{},
    ));
}

test "reject: memory instruction in a module that declares no memory" {
    // The parser accepts a module with memory instructions but no memory
    // section; the interpreter indexed `memories[0]` unconditionally, so the
    // guest could panic the host with an out-of-bounds slice index.
    //
    //   (func (export "boom") (result i32) (i32.load (i32.const 0)))
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7F });
    try mb.section(3, &[_]u8{ 0x01, 0x00 });
    try mb.section(7, &[_]u8{ 0x01, 0x04, 'b', 'o', 'o', 'm', 0x00, 0x00 });
    try mb.section(10, &[_]u8{ 0x01, 0x07, 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0B });

    try testing.expectError(error.InvalidMemory, runExport(testing.allocator, mb.bytes(), "boom", &.{}));
}

test "reject: out-of-bounds and wrapping memory accesses trap" {
    // Exec §4.4.7: an access whose effective address exceeds the memory size
    // traps. The effective address is `base + offset` where BOTH are guest
    // supplied, so it can land near maxInt(u32) — the bounds check must widen
    // before adding or it panics on overflow instead of trapping.
    //
    //   (memory 1)
    //   (func (export "load") (param i32) (result i32) (i32.load (local.get 0)))
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F });
    try mb.section(3, &[_]u8{ 0x01, 0x00 });
    try mb.section(5, &[_]u8{ 0x01, 0x00, 0x01 });
    try mb.section(7, &[_]u8{ 0x01, 0x04, 'l', 'o', 'a', 'd', 0x00, 0x00 });
    try mb.section(10, &[_]u8{ 0x01, 0x07, 0x00, 0x20, 0x00, 0x28, 0x02, 0x00, 0x0B });

    // In bounds: reads the zero-initialized page.
    const ok = try runExport(testing.allocator, mb.bytes(), "load", &.{.{ .i32 = 0 }});
    try testing.expectEqual(@as(i32, 0), ok.?.i32);

    // Just past the single 64 KiB page.
    try testing.expectError(error.OutOfBoundsMemoryAccess, runExport(
        testing.allocator,
        mb.bytes(),
        "load",
        &.{.{ .i32 = 65536 }},
    ));

    // Near maxInt(u32): `addr + 4` overflows a u32.
    try testing.expectError(error.OutOfBoundsMemoryAccess, runExport(
        testing.allocator,
        mb.bytes(),
        "load",
        &.{.{ .i32 = -1 }}, // 0xFFFFFFFF
    ));
}

test "anchor: float-to-int truncation traps out of range and saturates when asked" {
    // Exec §4.3.3. `trunc` traps on NaN and on any value whose truncation
    // falls outside the target range; `trunc_sat` instead yields 0 for NaN and
    // clamps to the nearest bound.
    //
    // REGRESSION: the i64 trapping forms checked only NaN, and the saturating
    // forms special-cased only NaN/infinity. A finite out-of-range value such
    // as 1e30 therefore reached `@intFromFloat` directly and PANICKED the host
    // in safe builds — a guest-triggerable crash from one arithmetic opcode.
    //
    //   (func (export "t") (param f64) (result i64) (i64.trunc_f64_s ...))
    //   (func (export "s") (param f64) (result i64) (i64.trunc_sat_f64_s ...))
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x01, 0x7C, 0x01, 0x7E }); // (f64) -> i64
    try mb.section(3, &[_]u8{ 0x02, 0x00, 0x00 });
    try mb.section(7, &[_]u8{
        0x02,
        0x01, 't', 0x00, 0x00,
        0x01, 's', 0x00, 0x01,
    });
    try mb.section(10, &[_]u8{
        0x02,
        0x05, 0x00, 0x20, 0x00, 0xB0, 0x0B, // i64.trunc_f64_s = 0xB0
        0x06, 0x00, 0x20, 0x00, 0xFC, 0x06, 0x0B, // i64.trunc_sat_f64_s = 0xFC 0x06
    });

    // In range: truncates toward zero.
    try testing.expectEqual(@as(i64, -3), (try runExport(
        testing.allocator,
        mb.bytes(),
        "t",
        &.{.{ .f64 = -3.9 }},
    )).?.i64);

    // Out of range and NaN both trap.
    try testing.expectError(error.IntegerOverflow, runExport(
        testing.allocator,
        mb.bytes(),
        "t",
        &.{.{ .f64 = 1e30 }},
    ));
    try testing.expectError(error.InvalidConversionToInteger, runExport(
        testing.allocator,
        mb.bytes(),
        "t",
        &.{.{ .f64 = std.math.nan(f64) }},
    ));

    // Saturating: clamps instead of trapping, and NaN becomes 0.
    try testing.expectEqual(std.math.maxInt(i64), (try runExport(
        testing.allocator,
        mb.bytes(),
        "s",
        &.{.{ .f64 = 1e30 }},
    )).?.i64);
    try testing.expectEqual(std.math.minInt(i64), (try runExport(
        testing.allocator,
        mb.bytes(),
        "s",
        &.{.{ .f64 = -1e30 }},
    )).?.i64);
    try testing.expectEqual(@as(i64, 0), (try runExport(
        testing.allocator,
        mb.bytes(),
        "s",
        &.{.{ .f64 = std.math.nan(f64) }},
    )).?.i64);
}

test "reject: memory.grow with an absurd page count returns -1, not a panic" {
    // Exec §4.4.7 memory.grow: returns -1 when the request cannot be met.
    // The u32 `old_pages + pages` add panicked in safe builds instead.
    var mem = try interpreter.Memory.init(testing.allocator, .{ .min = 1 });
    defer mem.deinit();

    try testing.expectEqual(@as(i32, -1), try mem.grow(0xFFFF_FFFF));
    try testing.expectEqual(@as(i32, -1), try mem.grow(65536));
    try testing.expectEqual(@as(u32, 1), mem.size()); // unchanged
}

test "reject: function declaring an unreasonable number of locals" {
    // Locals are allocated per call frame, so an unbounded declared count is a
    // memory-exhaustion vector that multiplies by the call depth. The declared
    // counts are summed with overflow checking and bounded.
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x00, 0x00 });
    try mb.section(3, &[_]u8{ 0x01, 0x00 });
    // One body: 1 local declaration of 0xFFFFFFFF i32 locals.
    try mb.section(10, &[_]u8{
        0x01, 0x09, 0x01,
        0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0x7F, // count = maxInt(u32), type i32
        0x0B,
    });

    try testing.expectError(error.InvalidCode, binary.parse(testing.allocator, mb.bytes()));
}

test "reject: no mutation of a valid module can panic the host" {
    // The contract for a runtime that executes untrusted bytecode is not
    // "parses correct modules" — it is "never crashes the process, whatever
    // the bytes". Every individual anchor above pins one known defect; this
    // sweeps the space around them.
    //
    // Systematically corrupts each WABT golden (single-byte overwrites across
    // every offset and a spread of values, plus every truncation length) and
    // runs the full parse -> instantiate -> call pipeline. Success and error
    // are BOTH acceptable outcomes; a panic is not, and would abort the test
    // binary here rather than in production.
    //
    // Deterministic — no RNG, so a failure reproduces exactly.
    const goldens = [_][]const u8{
        wabt_goldens.add,
        wabt_goldens.sel,
        wabt_goldens.sum,
        wabt_goldens.pick,
        wabt_goldens.read,
    };
    const exports = [_][]const u8{ "add", "sel", "sum", "pick", "read" };
    const poison = [_]u8{ 0x00, 0x01, 0x7F, 0x80, 0xFF, 0x0B, 0xFC, 0x41 };

    var buf: [512]u8 = undefined;
    var scratch: [512]u8 = undefined;

    for (goldens, exports) |hex, export_name| {
        const original = try std.fmt.hexToBytes(buf[0..], hex);

        // Single-byte corruption at every offset.
        for (0..original.len) |offset| {
            for (poison) |byte| {
                const mutant = scratch[0..original.len];
                @memcpy(mutant, original);
                mutant[offset] = byte;
                tryRun(mutant, export_name);
            }
        }

        // Every truncation.
        for (0..original.len) |len| {
            const mutant = scratch[0..len];
            @memcpy(mutant, original[0..len]);
            tryRun(mutant, export_name);
        }
    }
}

/// Run the pipeline and discard the outcome. Any error is a pass; the point is
/// that control returns here at all.
fn tryRun(module_bytes: []const u8, export_name: []const u8) void {
    var module = binary.parse(testing.allocator, module_bytes) catch return;
    defer module.deinit();

    var inst = interpreter.Instance.init(testing.allocator, &module) catch return;
    defer inst.deinit();

    // Arguments are deliberately arbitrary: a mutated module may have changed
    // the signature, and passing the "wrong" values must still only ever
    // produce an error.
    _ = inst.call(export_name, &.{ .{ .i32 = -1 }, .{ .i32 = 65535 } }) catch return;
}

test "reject: code body whose declared size disagrees with its actual length" {
    // Binary Format §5.5.13: each code entry is `size:u32 func`. The size was
    // previously read and DISCARDED, so a module could declare one length and
    // supply another — two decoders would then disagree about where the next
    // function begins. Found by diffing our hand-assembled modules against
    // wat2wasm's output, which is exactly the sort of thing only an external
    // encoder catches.
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x00, 0x00 });
    try mb.section(3, &[_]u8{ 0x02, 0x00, 0x00 });
    // Two bodies. The FIRST declares 3 bytes but is only 2 (`00` locals,
    // `0B` end); the second supplies enough trailing bytes that the declared
    // size still fits inside the section.
    //
    // That last part matters: an earlier draft declared a size larger than the
    // whole remaining section, which the cheap `size > remaining` guard
    // rejects — so the test passed even with the exact-length check deleted.
    // Mutation testing caught that. This shape can only be rejected by
    // comparing the declared size against the bytes actually consumed.
    try mb.section(10, &[_]u8{
        0x02, // 2 bodies
        0x03, 0x00, 0x0B, // body 1: declares 3, actually 2
        0x02, 0x00, 0x0B, // body 2: declares 2, actually 2
    });

    try testing.expectError(error.InvalidCode, binary.parse(testing.allocator, mb.bytes()));
}

test "reject: code body declaring fewer bytes than it occupies" {
    // The other direction of the same check.
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x00, 0x00 });
    try mb.section(3, &[_]u8{ 0x01, 0x00 });
    // Declares 2 bytes but the body runs to 4 (an i32.const before the end).
    try mb.section(10, &[_]u8{ 0x01, 0x02, 0x00, 0x41, 0x00, 0x0B });

    try testing.expectError(error.InvalidCode, binary.parse(testing.allocator, mb.bytes()));
}

test "reject: sections out of order or repeated" {
    // Binary Format §5.5.2: non-custom sections appear at most once, in
    // increasing id order. A repeat leaves it ambiguous which one wins.
    var mb1 = try ModuleBuilder.init(testing.allocator);
    defer mb1.deinit();
    try mb1.section(3, &[_]u8{0x00}); // function (3)
    try mb1.section(1, &[_]u8{0x00}); // type (1) — must precede function
    try testing.expectError(error.InvalidSection, binary.parse(testing.allocator, mb1.bytes()));

    var mb2 = try ModuleBuilder.init(testing.allocator);
    defer mb2.deinit();
    try mb2.section(1, &[_]u8{0x00});
    try mb2.section(1, &[_]u8{0x00}); // duplicate type section
    try testing.expectError(error.InvalidSection, binary.parse(testing.allocator, mb2.bytes()));
}

test "reject: truncated code body does not run off the end of the buffer" {
    // A body whose block nesting never closes must fail cleanly at EOF.
    var mb = try ModuleBuilder.init(testing.allocator);
    defer mb.deinit();

    try mb.section(1, &[_]u8{ 0x01, 0x60, 0x00, 0x00 });
    try mb.section(3, &[_]u8{ 0x01, 0x00 });
    try mb.section(10, &[_]u8{ 0x01, 0x03, 0x00, 0x02, 0x40 }); // `block` with no `end`

    try testing.expectError(error.InvalidCode, binary.parse(testing.allocator, mb.bytes()));
}
