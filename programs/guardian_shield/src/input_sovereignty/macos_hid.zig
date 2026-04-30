//! macOS HID Input Reader — IOHIDManager-based device monitoring
//!
//! Uses Apple's IOHIDManager API to capture input events from all connected
//! HID devices (gamepads, mice, keyboards). Events are normalized to the
//! platform-agnostic InputEvent format used by the Grimoire pattern engine.
//!
//! Requires: DriverKit HID entitlement (com.apple.developer.driverkit.transport.hid)
//!
//! Copyright (c) 2025-2026 Richard Tune / Quantum Encoding Ltd
//! License: Dual License - MIT (Non-Commercial) / Commercial License

const std = @import("std");
const builtin = @import("builtin");
const patterns = @import("patterns/gaming_cheats.zig");
const guardian = @import("input-guardian.zig");

// Only compile on macOS
comptime {
    if (builtin.os.tag != .macos) @compileError("macos_hid.zig is macOS-only");
}

const c = std.c;

// ═══════════════════════════════════════════════════════════════════════════════
// IOHIDManager C bindings (CoreFoundation + IOKit)
// ═══════════════════════════════════════════════════════════════════════════════

// Opaque CF/IOKit types
const CFAllocatorRef = *opaque {};
const CFDictionaryRef = *opaque {};
const CFMutableDictionaryRef = *opaque {};
const CFStringRef = *opaque {};
const CFNumberRef = *opaque {};
const CFRunLoopRef = *opaque {};
const CFRunLoopMode = *opaque {};
const IOHIDManagerRef = *opaque {};
const IOHIDDeviceRef = *opaque {};
const IOHIDValueRef = *opaque {};
const IOHIDElementRef = *opaque {};
const IOReturn = i32;

// CF constants
extern "c" var kCFAllocatorDefault: ?CFAllocatorRef;
extern "c" var kCFRunLoopDefaultMode: CFRunLoopMode;

// IOHIDManager functions
extern "c" fn IOHIDManagerCreate(allocator: ?CFAllocatorRef, options: u32) IOHIDManagerRef;
extern "c" fn IOHIDManagerSetDeviceMatching(manager: IOHIDManagerRef, matching: ?CFDictionaryRef) void;
extern "c" fn IOHIDManagerRegisterInputValueCallback(manager: IOHIDManagerRef, callback: *const fn (?*anyopaque, IOReturn, ?*anyopaque, IOHIDValueRef) callconv(.c) void, context: ?*anyopaque) void;
extern "c" fn IOHIDManagerScheduleWithRunLoop(manager: IOHIDManagerRef, runLoop: CFRunLoopRef, mode: CFRunLoopMode) void;
extern "c" fn IOHIDManagerOpen(manager: IOHIDManagerRef, options: u32) IOReturn;
extern "c" fn IOHIDManagerClose(manager: IOHIDManagerRef, options: u32) IOReturn;

// IOHIDValue functions
extern "c" fn IOHIDValueGetElement(value: IOHIDValueRef) IOHIDElementRef;
extern "c" fn IOHIDValueGetIntegerValue(value: IOHIDValueRef) i64;
extern "c" fn IOHIDValueGetTimeStamp(value: IOHIDValueRef) u64;

// IOHIDElement functions
extern "c" fn IOHIDElementGetType(element: IOHIDElementRef) u32;
extern "c" fn IOHIDElementGetUsagePage(element: IOHIDElementRef) u32;
extern "c" fn IOHIDElementGetUsage(element: IOHIDElementRef) u32;
extern "c" fn IOHIDElementGetCookie(element: IOHIDElementRef) u32;

// IOHIDDevice functions
extern "c" fn IOHIDValueGetDevice(value: IOHIDValueRef) IOHIDDeviceRef;

// CoreFoundation RunLoop
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopRunInMode(mode: CFRunLoopMode, seconds: f64, returnAfterSourceHandled: bool) i32;
extern "c" fn CFRelease(cf: *anyopaque) void;

// ═══════════════════════════════════════════════════════════════════════════════
// HID Usage Pages & Usages (USB HID spec)
// ═══════════════════════════════════════════════════════════════════════════════

const UsagePage = struct {
    const GenericDesktop: u32 = 0x01;
    const Button: u32 = 0x09;
};

const GenericDesktopUsage = struct {
    const X: u32 = 0x30;
    const Y: u32 = 0x31;
    const Z: u32 = 0x32;
    const Rx: u32 = 0x33;
    const Ry: u32 = 0x34;
    const Rz: u32 = 0x35;
    const Hat: u32 = 0x39;
    const Joystick: u32 = 0x04;
    const GamePad: u32 = 0x05;
    const Mouse: u32 = 0x02;
    const Keyboard: u32 = 0x06;
};

// IOHIDElement types
const kIOHIDElementTypeInput_Misc: u32 = 1;
const kIOHIDElementTypeInput_Button: u32 = 2;
const kIOHIDElementTypeInput_Axis: u32 = 3;

// ═══════════════════════════════════════════════════════════════════════════════
// Event normalization — macOS HID → platform-agnostic InputEvent
// ═══════════════════════════════════════════════════════════════════════════════

/// Use the same InputEvent type as the pattern engine
const InputEvent = guardian.InputEvent;

/// Convert IOHIDValue → InputEvent
fn hidValueToInputEvent(value: IOHIDValueRef) ?InputEvent {
    const element = IOHIDValueGetElement(value);
    const elem_type = IOHIDElementGetType(element);
    const usage_page = IOHIDElementGetUsagePage(element);
    const usage = IOHIDElementGetUsage(element);
    const int_value = IOHIDValueGetIntegerValue(value);

    // Timestamp: IOHIDValueGetTimeStamp returns mach_absolute_time (nanoseconds on Apple Silicon)
    const mach_time = IOHIDValueGetTimeStamp(value);
    const ts_us = mach_time / 1000; // Convert to microseconds
    const tv_sec: i64 = @intCast(ts_us / 1_000_000);
    const tv_usec: i64 = @intCast(ts_us % 1_000_000);

    // Map element type + usage to Linux event types
    var event_type: u16 = undefined;
    var code: u16 = undefined;
    const val: i32 = @intCast(int_value);

    if (elem_type == kIOHIDElementTypeInput_Button or usage_page == UsagePage.Button) {
        // Button → EV_KEY
        event_type = @intFromEnum(patterns.InputEventType.EV_KEY);
        code = mapButtonUsageToCode(usage);
    } else if (usage_page == UsagePage.GenericDesktop) {
        switch (usage) {
            GenericDesktopUsage.X, GenericDesktopUsage.Y => {
                // Mouse pointer or stick → EV_REL
                event_type = @intFromEnum(patterns.InputEventType.EV_REL);
                code = if (usage == GenericDesktopUsage.X) patterns.RelativeAxis.REL_X else patterns.RelativeAxis.REL_Y;
            },
            GenericDesktopUsage.Rx, GenericDesktopUsage.Ry, GenericDesktopUsage.Rz,
            GenericDesktopUsage.Z, GenericDesktopUsage.Hat,
            => {
                // Joystick axes → EV_ABS
                event_type = @intFromEnum(patterns.InputEventType.EV_ABS);
                code = @intCast(usage);
            },
            else => return null, // Skip unknown
        }
    } else {
        return null; // Skip non-input elements
    }

    return InputEvent{
        .time = .{ .tv_sec = tv_sec, .tv_usec = tv_usec },
        .type = event_type,
        .code = code,
        .value = val,
    };
}

/// Map HID button usage ID to Linux BTN_* code
fn mapButtonUsageToCode(usage: u32) u16 {
    // HID button usage IDs start at 1
    // Map to Linux gamepad codes
    return switch (usage) {
        1 => patterns.ButtonCode.BTN_SOUTH, // Button 1 → A
        2 => patterns.ButtonCode.BTN_EAST, // Button 2 → B
        3 => patterns.ButtonCode.BTN_WEST, // Button 3 → X
        4 => patterns.ButtonCode.BTN_NORTH, // Button 4 → Y
        5 => patterns.ButtonCode.BTN_TL, // Button 5 → LB
        6 => patterns.ButtonCode.BTN_TR, // Button 6 → RB
        7 => patterns.ButtonCode.BTN_TL2, // Button 7 → LT
        8 => patterns.ButtonCode.BTN_TR2, // Button 8 → RT
        9 => patterns.ButtonCode.BTN_SELECT, // Button 9 → Select
        10 => patterns.ButtonCode.BTN_START, // Button 10 → Start
        11 => patterns.ButtonCode.BTN_THUMBL, // Button 11 → L3
        12 => patterns.ButtonCode.BTN_THUMBR, // Button 12 → R3
        13 => patterns.ButtonCode.BTN_MODE, // Button 13 → Guide
        else => @intCast(0x130 + usage), // Generic mapping
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Callback state (passed through IOHIDManager context pointer)
// ═══════════════════════════════════════════════════════════════════════════════

const CallbackContext = struct {
    g: *guardian.InputGuardian,
    event_count: u64,
    detection_count: u64,
};

fn hidInputCallback(_: ?*anyopaque, _: IOReturn, _: ?*anyopaque, value: IOHIDValueRef) callconv(.c) void {
    // Get context from global (IOHIDManager context passing is unreliable)
    const ctx = &global_context;

    const event = hidValueToInputEvent(value) orelse return;

    // Feed to pattern engine
    if (ctx.g.processEvent(&event) catch null) |result| {
        if (result.matched) {
            ctx.detection_count += 1;
            ctx.g.handleDetection(result) catch {};
        }
    }
    ctx.event_count += 1;
}

var global_context: CallbackContext = undefined;

// ═══════════════════════════════════════════════════════════════════════════════
// Public API — start monitoring
// ═══════════════════════════════════════════════════════════════════════════════

/// Start monitoring all HID devices for cheat patterns.
/// Blocks until duration expires or process receives SIGINT.
pub fn monitorAllDevices(g: *guardian.InputGuardian, duration_sec: ?u32) !void {
    log("macOS HID Input Monitor — IOHIDManager", .{});
    log("Monitoring all connected HID devices", .{});

    // Initialize context
    global_context = .{
        .g = g,
        .event_count = 0,
        .detection_count = 0,
    };

    // Create HID Manager
    const manager = IOHIDManagerCreate(kCFAllocatorDefault, 0);

    // Match ALL input devices (gamepads, mice, keyboards)
    // Passing null matches everything
    IOHIDManagerSetDeviceMatching(manager, null);

    // Register callback
    IOHIDManagerRegisterInputValueCallback(manager, hidInputCallback, null);

    // Schedule with run loop
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    // Open manager
    const open_result = IOHIDManagerOpen(manager, 0);
    if (open_result != 0) {
        log("ERROR: IOHIDManagerOpen failed: {d}", .{open_result});
        return error.HIDManagerOpenFailed;
    }
    defer _ = IOHIDManagerClose(manager, 0);

    log("HID Manager active — monitoring {d} patterns", .{patterns.PATTERN_COUNT});
    if (g.enforce_mode) {
        log("ENFORCEMENT MODE: Detections will trigger actions", .{});
    } else {
        log("Monitor mode: Detections logged only", .{});
    }

    // Run loop
    if (duration_sec) |dur| {
        _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, @floatFromInt(dur), false);
    } else {
        // Run forever (until signal)
        while (true) {
            _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        }
    }

    log("HID Monitor shutdown — events: {d}, detections: {d}", .{ global_context.event_count, global_context.detection_count });
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[input-guardian-macos] " ++ fmt ++ "\n", args) catch return;
    _ = c.write(2, msg.ptr, msg.len);
}
