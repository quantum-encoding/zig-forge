//! Widget module - widget interface and focus management
//!
//! Re-exports all widget-related types.

pub const widget = @import("widget.zig");
pub const focus = @import("focus.zig");

pub const Widget = widget.Widget;
pub const makeWidget = widget.makeWidget;
pub const BaseWidget = widget.BaseWidget;
pub const StatefulWidget = widget.StatefulWidget;

pub const FocusManager = focus.FocusManager;

test {
    @import("std").testing.refAllDecls(@This());
}
