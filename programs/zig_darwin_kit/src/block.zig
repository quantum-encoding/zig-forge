//! Objective-C block ABI for Zig callers of Apple C APIs that take `^` blocks.
//!
//! Zig has no block literal syntax, yet EndpointSecurity, libdispatch, XPC and
//! most of Apple's C surface accept only blocks. This module lays out the
//! `Block_literal` / `Block_descriptor` structures exactly as clang emits them
//! (see clang's "Block Implementation Specification", Apple ABI) so a Zig
//! function plus a captured context can be handed to those APIs.
//!
//! Layout (Apple, 64-bit):
//!
//!   struct Block_literal {
//!       void *isa;                     // _NSConcreteStackBlock / _NSConcreteGlobalBlock / malloc'd
//!       int   flags;
//!       int   reserved;
//!       void (*invoke)(Block_literal *, ...);
//!       struct Block_descriptor *descriptor;
//!       /* captured variables follow */
//!   };
//!   struct Block_descriptor { unsigned long reserved; unsigned long size; };
//!
//! Captured context is stored by value and copied bit-for-bit by `_Block_copy`,
//! so `Ctx` must be plain data with a defined layout (integers, pointers,
//! `extern struct`s); the literal is itself an `extern struct`. No
//! copy/dispose helpers are emitted; a `Ctx` that owns resources must be freed
//! by the owner of the block, not by the block runtime.
//!
//! Lifetime rules, same as in C:
//!   * a stack literal is valid only at its original address, while in scope;
//!   * `copy()` returns a heap block holding one reference the caller owns and
//!     must `release()`; APIs that keep the block (`es_new_client`,
//!     `dispatch_async`) take their own reference via `_Block_copy`.

const std = @import("std");

pub const flags = struct {
    pub const has_copy_dispose: i32 = 1 << 25;
    pub const has_ctor: i32 = 1 << 26;
    pub const is_global: i32 = 1 << 28;
    pub const has_stret: i32 = 1 << 29;
    pub const has_signature: i32 = 1 << 30;
};

pub const Descriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

// Block class objects from libSystem; only their addresses are used.
extern const _NSConcreteStackBlock: [32]?*anyopaque;
extern const _NSConcreteGlobalBlock: [32]?*anyopaque;

extern "c" fn _Block_copy(block: *const anyopaque) ?*anyopaque;
extern "c" fn _Block_release(block: *const anyopaque) void;

/// Type-erased block pointer, the thing a C parameter of block type receives.
pub const Ref = *const anyopaque;

/// Retain an existing block (`_Block_copy`). For a heap block this bumps the
/// reference count; for a stack block it allocates a heap copy.
pub fn retain(block: Ref) error{OutOfMemory}!Ref {
    return _Block_copy(block) orelse error.OutOfMemory;
}

/// Drop one reference (`_Block_release`).
pub fn release(block: Ref) void {
    _Block_release(block);
}

/// A block whose captured state is one value of type `Ctx` and whose body is
/// `handler`, a Zig function `fn (*Ctx, A1, A2, ...) R` with up to four
/// arguments after the context. The block invokes as a C function taking
/// `(A1, A2, ...)`, which is what the C API expects.
pub fn Block(comptime Ctx: type, comptime handler: anytype) type {
    const Fn = @TypeOf(handler);
    const fn_info = switch (@typeInfo(Fn)) {
        .@"fn" => |f| f,
        else => @compileError("Block handler must be a function, got " ++ @typeName(Fn)),
    };
    const params = fn_info.params;
    if (params.len == 0 or params[0].type != *Ctx)
        @compileError("Block handler's first parameter must be *" ++ @typeName(Ctx));
    if (params.len > 5)
        @compileError("Block supports at most four arguments after the context");
    if (@sizeOf(Ctx) == 0)
        @compileError("Block context must have a size; use a small integer as a placeholder for a context-free block");
    const Ret = fn_info.return_type.?;

    return extern struct {
        const Self = @This();

        isa: *const anyopaque,
        flags: i32,
        reserved: i32 = 0,
        invoke: *const anyopaque,
        descriptor: *const Descriptor,
        ctx: Ctx,

        const descriptor_storage = Descriptor{ .size = @sizeOf(Self) };

        fn Param(comptime i: usize) type {
            return params[i].type.?;
        }

        const Thunks = struct {
            fn invoke0(self: *Self) callconv(.c) Ret {
                return handler(&self.ctx);
            }
            fn invoke1(self: *Self, a: Param(1)) callconv(.c) Ret {
                return handler(&self.ctx, a);
            }
            fn invoke2(self: *Self, a: Param(1), b: Param(2)) callconv(.c) Ret {
                return handler(&self.ctx, a, b);
            }
            fn invoke3(self: *Self, a: Param(1), b: Param(2), c: Param(3)) callconv(.c) Ret {
                return handler(&self.ctx, a, b, c);
            }
            fn invoke4(self: *Self, a: Param(1), b: Param(2), c: Param(3), d: Param(4)) callconv(.c) Ret {
                return handler(&self.ctx, a, b, c, d);
            }
        };

        const invoke_ptr: *const anyopaque = switch (params.len) {
            1 => @ptrCast(&Thunks.invoke0),
            2 => @ptrCast(&Thunks.invoke1),
            3 => @ptrCast(&Thunks.invoke2),
            4 => @ptrCast(&Thunks.invoke3),
            5 => @ptrCast(&Thunks.invoke4),
            else => unreachable,
        };

        /// A stack literal. Keep it in a `var` and pass `.ref()` to APIs that
        /// invoke synchronously; use `copy()` for APIs that keep the block.
        pub fn initStack(ctx: Ctx) Self {
            return .{
                .isa = @ptrCast(&_NSConcreteStackBlock),
                .flags = 0,
                .invoke = invoke_ptr,
                .descriptor = &descriptor_storage,
                .ctx = ctx,
            };
        }

        /// Heap block with one reference owned by the caller. Equivalent to
        /// building a stack literal and calling `_Block_copy` on it.
        pub fn create(ctx: Ctx) error{OutOfMemory}!*Self {
            var stack = initStack(ctx);
            return stack.copy();
        }

        /// `_Block_copy`: promotes a stack literal to the heap, or retains a
        /// heap block. The result is owned by the caller and released with
        /// `release()`.
        pub fn copy(self: *Self) error{OutOfMemory}!*Self {
            const raw = _Block_copy(@ptrCast(self)) orelse return error.OutOfMemory;
            return @ptrCast(@alignCast(raw));
        }

        /// `_Block_release` on a heap block. Never call on a stack literal.
        pub fn release(self: *Self) void {
            _Block_release(@ptrCast(self));
        }

        /// The pointer a C parameter of block type expects.
        pub fn ref(self: *Self) Ref {
            return @ptrCast(self);
        }

        const InvokeFn = switch (params.len) {
            1 => @TypeOf(Thunks.invoke0),
            2 => @TypeOf(Thunks.invoke1),
            3 => @TypeOf(Thunks.invoke2),
            4 => @TypeOf(Thunks.invoke3),
            5 => @TypeOf(Thunks.invoke4),
            else => unreachable,
        };

        /// Call the block directly through its `invoke` slot, as `block(args...)` would in C.
        pub fn call(self: *Self, args: anytype) Ret {
            const f: *const InvokeFn = @ptrCast(@alignCast(self.invoke));
            return @call(.auto, f, .{self} ++ args);
        }

        /// A statically allocated global block for a comptime-known context.
        /// `_Block_copy` returns the same pointer for global blocks, so it
        /// never needs releasing.
        pub fn global(comptime ctx: Ctx) *Self {
            const Static = struct {
                var literal: Self = .{
                    .isa = @ptrCast(&_NSConcreteGlobalBlock),
                    .flags = flags.is_global,
                    .invoke = invoke_ptr,
                    .descriptor = &descriptor_storage,
                    .ctx = ctx,
                };
            };
            return &Static.literal;
        }
    };
}

// ───────────────────────────── tests ─────────────────────────────
//
// libdispatch is the external anchor: it copies, invokes and releases blocks
// through the same runtime every Apple framework uses. A layout mistake
// (wrong field order, wrong descriptor size) crashes or silently misreads
// the context here before it ever reaches EndpointSecurity.

const dispatch = struct {
    extern "c" fn dispatch_queue_create(label: ?[*:0]const u8, attr: ?*anyopaque) *anyopaque;
    extern "c" fn dispatch_sync(queue: *anyopaque, block: Ref) void;
    extern "c" fn dispatch_async(queue: *anyopaque, block: Ref) void;
    extern "c" fn dispatch_release(object: *anyopaque) void;
    extern "c" fn dispatch_semaphore_create(value: isize) *anyopaque;
    extern "c" fn dispatch_semaphore_wait(sema: *anyopaque, timeout: u64) isize;
    extern "c" fn dispatch_semaphore_signal(sema: *anyopaque) isize;
    const forever: u64 = ~@as(u64, 0);
};

const Counter = extern struct { hits: u32, last: i64 };

fn bump(ctx: *Counter) void {
    ctx.hits += 1;
}

fn bumpWithArgs(ctx: **Counter, a: i64, b: i64) void {
    ctx.*.hits += 1;
    ctx.*.last = a * b;
}

test "layout matches the clang Block_literal header" {
    const B = Block(Counter, bump);
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(B, "isa"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(B, "flags"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(B, "reserved"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(B, "invoke"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(B, "descriptor"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(B, "ctx"));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Descriptor));
}

test "dispatch_sync invokes a stack block and mutates the captured context" {
    const B = Block(Counter, bump);
    var b = B.initStack(.{ .hits = 0, .last = 0 });
    const q = dispatch.dispatch_queue_create("zig_darwin_kit.block.sync", null);
    defer dispatch.dispatch_release(q);
    dispatch.dispatch_sync(q, b.ref());
    dispatch.dispatch_sync(q, b.ref());
    try std.testing.expectEqual(@as(u32, 2), b.ctx.hits);
}

test "dispatch_async copies a stack block to the heap and invokes it on another thread" {
    // libdispatch calls _Block_copy on the stack literal, which reads
    // descriptor.size to know how many bytes to copy. A wrong size copies a
    // truncated or overrun context and this test reads garbage or crashes.
    var counter = Counter{ .hits = 0, .last = 0 };
    const Ctx = extern struct { counter: *Counter, sema: *anyopaque };
    const B = Block(Ctx, struct {
        fn run(ctx: *Ctx) void {
            ctx.counter.hits += 100;
            _ = dispatch.dispatch_semaphore_signal(ctx.sema);
        }
    }.run);
    const sema = dispatch.dispatch_semaphore_create(0);
    defer dispatch.dispatch_release(sema);
    const q = dispatch.dispatch_queue_create("zig_darwin_kit.block.async", null);
    defer dispatch.dispatch_release(q);
    {
        var stack = B.initStack(.{ .counter = &counter, .sema = sema });
        dispatch.dispatch_async(q, stack.ref());
        // `stack` goes out of scope here; the queue must be running its own copy.
    }
    try std.testing.expectEqual(@as(isize, 0), dispatch.dispatch_semaphore_wait(sema, dispatch.forever));
    try std.testing.expectEqual(@as(u32, 100), counter.hits);
}

test "copy and release round-trip through the block runtime" {
    var counter = Counter{ .hits = 0, .last = 0 };
    const B = Block(*Counter, bumpWithArgs);
    const heap = try B.create(&counter);
    const second = try heap.copy(); // refcount 2
    try std.testing.expectEqual(@intFromPtr(heap), @intFromPtr(second));
    heap.call(.{ @as(i64, 6), @as(i64, 7) });
    second.release();
    heap.call(.{ @as(i64, 2), @as(i64, 3) });
    heap.release();
    try std.testing.expectEqual(@as(u32, 2), counter.hits);
    try std.testing.expectEqual(@as(i64, 6), counter.last);
}

test "global block is invocable through dispatch and survives retain/release" {
    const B = Block(u8, struct {
        var seen: u8 = 0;
        fn run(ctx: *u8) void {
            seen = ctx.*;
        }
    }.run);
    const g = B.global(42);
    const q = dispatch.dispatch_queue_create("zig_darwin_kit.block.global", null);
    defer dispatch.dispatch_release(q);
    const retained = try retain(g.ref());
    try std.testing.expectEqual(@intFromPtr(g), @intFromPtr(retained));
    release(retained);
    dispatch.dispatch_sync(q, g.ref());
    try std.testing.expectEqual(@as(u8, 42), g.ctx);
}
