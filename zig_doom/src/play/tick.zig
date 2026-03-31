//! zig_doom/src/play/tick.zig
//!
//! Thinker list management — the core game object iteration system.
//! Translated from: linuxdoom-1.10/p_tick.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! DOOM manages all game objects through a circular doubly-linked list of "thinkers".
//! Each game tic, all thinkers are iterated and their think functions called.
//! Map objects (mobj_t) embed a thinker as their first field, enabling
//! @fieldParentPtr to recover the mobj from the thinker pointer.

const std = @import("std");

/// Think function type — called once per tic for each active thinker
pub const ThinkFn = *const fn (*Thinker) void;

/// Thinker — doubly-linked list node for all game objects
pub const Thinker = struct {
    prev: ?*Thinker = null,
    next: ?*Thinker = null,
    function: ?ThinkFn = null,
};

/// Sentinel head of the thinker list (circular doubly-linked)
var thinker_cap: Thinker = .{};

/// Initialize the thinker list as empty circular list
pub fn initThinkers() void {
    thinker_cap.prev = &thinker_cap;
    thinker_cap.next = &thinker_cap;
    thinker_cap.function = null;
}

/// Add a thinker to the end of the list (before the cap)
pub fn addThinker(thinker: *Thinker) void {
    // Insert before cap (= at end of list)
    thinker.next = &thinker_cap;
    thinker.prev = thinker_cap.prev;
    if (thinker_cap.prev) |prev| {
        prev.next = thinker;
    }
    thinker_cap.prev = thinker;
}

/// Mark a thinker for deferred removal (set function to sentinel value)
/// Actual unlinking happens during runThinkers iteration.
pub fn removeThinker(thinker: *Thinker) void {
    // Set function to removal sentinel — a special non-null marker
    // that runThinkers recognizes as "remove me"
    thinker.function = @ptrCast(&removal_sentinel);
}

/// Sentinel function used to mark thinkers for removal
fn removal_sentinel(_: *Thinker) void {}

/// Iterate all thinkers, calling their think functions.
/// Thinkers marked for removal (function == removal_sentinel) are unlinked.
pub fn runThinkers() void {
    var current = thinker_cap.next;
    while (current != null and current != &thinker_cap) {
        const thinker = current.?;
        const next = thinker.next; // Save next before potential removal

        if (thinker.function) |func| {
            if (func == @as(ThinkFn, @ptrCast(&removal_sentinel))) {
                // Unlink from list
                unlinkThinker(thinker);
            } else {
                func(thinker);
            }
        }

        current = next;
    }
}

/// Unlink a thinker from the list
fn unlinkThinker(thinker: *Thinker) void {
    if (thinker.next) |next| {
        next.prev = thinker.prev;
    }
    if (thinker.prev) |prev| {
        prev.next = thinker.next;
    }
    thinker.prev = null;
    thinker.next = null;
    thinker.function = null;
}

/// Count the number of active thinkers (for testing/debugging)
pub fn countThinkers() usize {
    var count: usize = 0;
    var current = thinker_cap.next;
    while (current != null and current != &thinker_cap) {
        count += 1;
        current = current.?.next;
    }
    return count;
}

/// Get the sentinel head (for testing)
pub fn getThinkerCap() *Thinker {
    return &thinker_cap;
}

// ============================================================================
// Tests
// ============================================================================

test "thinker list init" {
    initThinkers();
    try std.testing.expectEqual(&thinker_cap, thinker_cap.next.?);
    try std.testing.expectEqual(&thinker_cap, thinker_cap.prev.?);
    try std.testing.expectEqual(@as(usize, 0), countThinkers());
}

test "thinker add and count" {
    initThinkers();

    var t1 = Thinker{};
    var t2 = Thinker{};
    var t3 = Thinker{};

    addThinker(&t1);
    try std.testing.expectEqual(@as(usize, 1), countThinkers());

    addThinker(&t2);
    addThinker(&t3);
    try std.testing.expectEqual(@as(usize, 3), countThinkers());

    // Verify circular links
    try std.testing.expectEqual(&t1, thinker_cap.next.?);
    try std.testing.expectEqual(&t3, thinker_cap.prev.?);
    try std.testing.expectEqual(&t2, t1.next.?);
    try std.testing.expectEqual(&t3, t2.next.?);
    try std.testing.expectEqual(&thinker_cap, t3.next.?);
}

test "thinker remove during iteration" {
    initThinkers();

    var t1 = Thinker{};
    var t2 = Thinker{};
    var t3 = Thinker{};

    addThinker(&t1);
    addThinker(&t2);
    addThinker(&t3);

    // Set t1 and t3 to do-nothing functions, mark t2 for removal
    const noop = struct {
        fn f(_: *Thinker) void {}
    }.f;
    t1.function = noop;
    t3.function = noop;
    removeThinker(&t2);

    // Run thinkers — t2 should be removed
    runThinkers();
    try std.testing.expectEqual(@as(usize, 2), countThinkers());

    // Verify t1 -> t3 link
    try std.testing.expectEqual(&t1, thinker_cap.next.?);
    try std.testing.expectEqual(&t3, t1.next.?);
}

test "thinker function is called" {
    initThinkers();

    var call_count: u32 = 0;
    const counter = struct {
        var count_ptr: *u32 = undefined;
        fn think(_: *Thinker) void {
            count_ptr.* += 1;
        }
    };
    counter.count_ptr = &call_count;

    var t1 = Thinker{ .function = counter.think };
    var t2 = Thinker{ .function = counter.think };

    addThinker(&t1);
    addThinker(&t2);

    runThinkers();
    try std.testing.expectEqual(@as(u32, 2), call_count);

    runThinkers();
    try std.testing.expectEqual(@as(u32, 4), call_count);
}

test "thinker remove all" {
    initThinkers();

    var t1 = Thinker{};
    var t2 = Thinker{};

    addThinker(&t1);
    addThinker(&t2);

    removeThinker(&t1);
    removeThinker(&t2);

    runThinkers();
    try std.testing.expectEqual(@as(usize, 0), countThinkers());
}
