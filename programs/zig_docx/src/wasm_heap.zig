// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! `std.heap.wasm_allocator` for a long-lived module instance.
//!
//! The std allocator (BrkAllocator, Zig 0.17.0 and 0.18-dev) keeps small
//! slots (under 64 KiB) in per-size slabs and larger ones as whole 64 KiB
//! big pages. Its `resize` lets a one-big-page allocation shrink in place to
//! a small length, but `free` then files the big page under the small size
//! class: every such shrink loses a big page, and an instance reused across
//! calls grows by 64 KiB per occurrence. Two paths hit it: the ZIP reader
//! inflates a part into a list that jumps straight past 32 KiB and is cut to
//! its length on return (any .xlsx or .docx part of roughly 25 to 32 KiB), and
//! zig_pdf_generator's `deflateCompress`, whose output buffer starts at half
//! the input (an image or alpha mask of 64 to 128 KiB that compresses below
//! 32 KiB, a typical logo or signature).
//! This wrapper refuses a resize that would move an allocation between the
//! small and big kinds, so the caller allocates and copies instead; every
//! other call goes straight to the std allocator. Used by every wasm build of
//! zig_docx and zig_pdf_generator (which reaches it as
//! `@import("zig_docx").wasm_heap`). Same code as
//! programs/zig_xlsx/src/wasm_heap.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const backing = std.heap.wasm_allocator;
const bigpage_size: usize = @max(64 * 1024, std.heap.page_size_max);

pub const allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

/// Whether the std allocator serves `len` bytes from a small-class slot
/// (same arithmetic as its `alloc`).
fn isSmall(len: usize, alignment: Alignment) bool {
    const actual = @max(len +| @sizeOf(usize), alignment.toByteUnits());
    const slot = std.math.ceilPowerOfTwo(usize, actual) catch return false;
    return slot < bigpage_size;
}

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    return backing.rawAlloc(len, alignment, ra);
}

fn resize(_: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
    if (isSmall(buf.len, alignment) != isSmall(new_len, alignment)) return false;
    return backing.rawResize(buf, alignment, new_len, ra);
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resize(ctx, buf, alignment, new_len, ra)) buf.ptr else null;
}

fn free(_: *anyopaque, buf: []u8, alignment: Alignment, ra: usize) void {
    backing.rawFree(buf, alignment, ra);
}
