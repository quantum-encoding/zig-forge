//! zig_tui - Terminal UI Framework
//!
//! A ncurses-style TUI library for Zig with widgets, layouts, and mouse support.
//!
//! ## Quick Start
//! ```zig
//! const tui = @import("zig_tui");
//!
//! pub fn main() !void {
//!     const allocator = std.heap.c_allocator;
//!
//!     var app = try tui.Application.init(allocator, .{});
//!     defer app.deinit();
//!
//!     app.setRenderCallback(render);
//!     app.setEventCallback(handleEvent);
//!
//!     try app.run();
//! }
//!
//! fn render(buf: *tui.Buffer, size: tui.Size) void {
//!     _ = buf.writeStr(0, 0, "Hello, TUI!", tui.Style.default);
//! }
//!
//! fn handleEvent(event: tui.Event) bool {
//!     if (event.isKey(.escape)) return false; // Quit
//!     return true;
//! }
//! ```

const std = @import("std");

// Core module
pub const core = @import("core/core.zig");
pub const Buffer = core.Buffer;
pub const Cell = core.Cell;
pub const Color = core.Color;
pub const Style = core.Style;
pub const Attrs = core.Attrs;
pub const Rect = core.Rect;
pub const Size = core.Size;
pub const Position = core.Position;
pub const Align = core.Align;
pub const VAlign = core.VAlign;
pub const BorderStyle = core.BorderStyle;
pub const Constraint = core.Constraint;
pub const charWidth = core.charWidth;
pub const stringWidth = core.stringWidth;

// Theme system
pub const Theme = core.Theme;
pub const Palette = core.Palette;
pub const ThemeManager = core.ThemeManager;
pub const WidgetState = core.WidgetState;
pub const TextVariant = core.TextVariant;
pub const dark_theme = core.dark_theme;
pub const light_theme = core.light_theme;
pub const high_contrast_theme = core.high_contrast_theme;

// Input module
pub const input = @import("input/input.zig");
pub const Event = input.Event;
pub const KeyEvent = input.KeyEvent;
pub const MouseEvent = input.MouseEvent;
pub const Key = input.Key;
pub const Modifiers = input.Modifiers;
pub const MouseButton = input.MouseButton;
pub const Parser = input.Parser;
pub const Keybindings = input.Keybindings;
pub const KeyBinding = input.KeyBinding;
pub const KeyMode = input.Mode;

// Render module
pub const render = @import("render/render.zig");
pub const Renderer = render.Renderer;
pub const TerminalMode = render.TerminalMode;

// App module
pub const app = @import("app/app.zig");
pub const Application = app.Application;
pub const Config = app.Config;

// Widget module
pub const widget = @import("widget/mod.zig");
pub const Widget = widget.Widget;
pub const makeWidget = widget.makeWidget;
pub const BaseWidget = widget.BaseWidget;
pub const StatefulWidget = widget.StatefulWidget;
pub const FocusManager = widget.FocusManager;

// Layout module
pub const layout = @import("layout/layout.zig");
pub const BoxLayout = layout.BoxLayout;
pub const Direction = layout.Direction;
pub const hbox = layout.hbox;
pub const vbox = layout.vbox;

// Widgets
pub const widgets = @import("widgets/widgets.zig");
pub const Label = widgets.Label;
pub const Button = widgets.Button;
pub const TextInput = widgets.TextInput;
pub const List = widgets.List;
pub const ListItem = widgets.ListItem;
pub const SelectionMode = widgets.SelectionMode;
pub const Table = widgets.Table;
pub const Column = widgets.Column;
pub const ColumnWidth = widgets.ColumnWidth;
pub const Row = widgets.Row;
pub const TableAlignment = widgets.Alignment;

// Checkbox and RadioGroup
pub const Checkbox = widgets.Checkbox;
pub const RadioGroup = widgets.RadioGroup;
pub const CheckboxStyle = widgets.CheckboxStyle;

// Progress indicators
pub const ProgressBar = widgets.ProgressBar;
pub const Spinner = widgets.Spinner;
pub const ProgressStyle = widgets.ProgressStyle;
pub const LabelPosition = widgets.LabelPosition;

// Tabs
pub const Tabs = widgets.Tabs;
pub const Tab = widgets.Tab;
pub const TabPosition = widgets.TabPosition;
pub const TabStyle = widgets.TabStyle;

// TextArea
pub const TextArea = widgets.TextArea;

// Tree
pub const Tree = widgets.Tree;
pub const TreeNode = widgets.TreeNode;

// Modal/Dialog
pub const Modal = widgets.Modal;
pub const DialogButton = widgets.DialogButton;
pub const DialogResult = widgets.DialogResult;
pub const Toast = widgets.Toast;

// File Browser
pub const FileBrowser = widgets.FileBrowser;
pub const FileEntry = widgets.FileEntry;
pub const EntryType = widgets.EntryType;

// Command Palette
pub const CommandPalette = widgets.CommandPalette;
pub const Command = widgets.Command;

// Status Bar
pub const StatusBar = widgets.StatusBar;
pub const Segment = widgets.Segment;
pub const SegmentAlign = widgets.SegmentAlign;

test {
    std.testing.refAllDecls(@This());
}
