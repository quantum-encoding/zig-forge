//! Widget interface
//!
//! Defines the core widget abstraction using a VTable pattern
//! for polymorphic widgets.

const std = @import("std");
const core = @import("../core/core.zig");
const input = @import("../input/input.zig");

pub const Buffer = core.Buffer;
pub const Rect = core.Rect;
pub const Size = core.Size;
pub const Style = core.Style;
pub const Event = input.Event;

/// Widget interface - type-erased wrapper for any widget
pub const Widget = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    pub const VTable = struct {
        /// Render the widget to the buffer
        render: *const fn (ptr: *anyopaque, area: Rect, buf: *Buffer, state: RenderState) void,
        /// Handle an event, return true if consumed
        handleEvent: *const fn (ptr: *anyopaque, event: Event) bool,
        /// Get minimum size needed by this widget
        minSize: *const fn (ptr: *anyopaque) Size,
        /// Check if widget can receive focus
        canFocus: *const fn (ptr: *anyopaque) bool,
        /// Called when widget gains focus
        onFocus: *const fn (ptr: *anyopaque) void,
        /// Called when widget loses focus
        onBlur: *const fn (ptr: *anyopaque) void,
        /// Get child widgets (for containers)
        children: *const fn (ptr: *anyopaque) []Widget,
        /// Get widget ID (for focus management)
        getId: *const fn (ptr: *anyopaque) ?[]const u8,
    };

    /// Render state passed to widgets
    pub const RenderState = struct {
        focused: bool = false,
        hovered: bool = false,
        disabled: bool = false,
    };

    /// Render the widget
    pub fn render(self: Self, area: Rect, buf: *Buffer, state: RenderState) void {
        self.vtable.render(self.ptr, area, buf, state);
    }

    /// Handle an event
    pub fn handleEvent(self: Self, event: Event) bool {
        return self.vtable.handleEvent(self.ptr, event);
    }

    /// Get minimum size
    pub fn minSize(self: Self) Size {
        return self.vtable.minSize(self.ptr);
    }

    /// Check if focusable
    pub fn canFocus(self: Self) bool {
        return self.vtable.canFocus(self.ptr);
    }

    /// Focus callback
    pub fn onFocus(self: Self) void {
        self.vtable.onFocus(self.ptr);
    }

    /// Blur callback
    pub fn onBlur(self: Self) void {
        self.vtable.onBlur(self.ptr);
    }

    /// Get children
    pub fn children(self: Self) []Widget {
        return self.vtable.children(self.ptr);
    }

    /// Get widget ID
    pub fn getId(self: Self) ?[]const u8 {
        return self.vtable.getId(self.ptr);
    }
};

/// Generate widget() function for a type
pub fn makeWidget(comptime T: type, self: *T) Widget {
    const gen = struct {
        const vtable = Widget.VTable{
            .render = doRender,
            .handleEvent = doHandleEvent,
            .minSize = doMinSize,
            .canFocus = doCanFocus,
            .onFocus = doOnFocus,
            .onBlur = doOnBlur,
            .children = doChildren,
            .getId = doGetId,
        };

        fn doRender(ptr: *anyopaque, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
            const s: *T = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "render")) {
                s.render(area, buf, state);
            }
        }

        fn doHandleEvent(ptr: *anyopaque, event: Event) bool {
            const s: *T = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "handleEvent")) {
                return s.handleEvent(event);
            }
            return false;
        }

        fn doMinSize(ptr: *anyopaque) Size {
            const s: *T = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "minSize")) {
                return s.minSize();
            }
            return .{ .width = 0, .height = 0 };
        }

        fn doCanFocus(ptr: *anyopaque) bool {
            const s: *T = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "canFocus")) {
                return s.canFocus();
            }
            return false;
        }

        fn doOnFocus(ptr: *anyopaque) void {
            const s: *T = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "onFocus")) {
                s.onFocus();
            }
        }

        fn doOnBlur(ptr: *anyopaque) void {
            const s: *T = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "onBlur")) {
                s.onBlur();
            }
        }

        fn doChildren(ptr: *anyopaque) []Widget {
            const s: *T = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "children")) {
                return s.children();
            }
            return &[_]Widget{};
        }

        fn doGetId(ptr: *anyopaque) ?[]const u8 {
            const s: *T = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "getId")) {
                return s.getId();
            }
            return null;
        }
    };

    return .{
        .ptr = self,
        .vtable = &gen.vtable,
    };
}

/// Base widget implementation with common functionality
pub const BaseWidget = struct {
    id: ?[]const u8 = null,
    style: Style = .{},
    focused_style: ?Style = null,
    disabled: bool = false,
    visible: bool = true,

    const Self = @This();

    pub fn getStyle(self: *const Self, focused: bool) Style {
        if (focused) {
            return self.focused_style orelse self.style;
        }
        return self.style;
    }

    pub fn getId(self: *const Self) ?[]const u8 {
        return self.id;
    }
};

/// Stateful widget base with lifecycle hooks
pub fn StatefulWidget(comptime State: type) type {
    return struct {
        state: State,
        base: BaseWidget = .{},

        const Self = @This();

        pub fn init(initial_state: State) Self {
            return .{ .state = initial_state };
        }

        pub fn setState(self: *Self, new_state: State) void {
            self.state = new_state;
        }

        pub fn getState(self: *const Self) State {
            return self.state;
        }
    };
}

test "Widget VTable" {
    const TestWidget = struct {
        value: u32 = 0,

        const Self = @This();

        pub fn widget(self: *Self) Widget {
            return makeWidget(Self, self);
        }

        pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
            _ = self;
            _ = area;
            _ = buf;
            _ = state;
        }

        pub fn canFocus(self: *Self) bool {
            _ = self;
            return true;
        }
    };

    var w = TestWidget{};
    const widg = w.widget();

    try std.testing.expect(widg.canFocus());
}
