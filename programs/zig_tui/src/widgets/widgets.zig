//! Widgets module - concrete widget implementations
//!
//! Re-exports all widget types.

pub const label = @import("label.zig");
pub const button = @import("button.zig");
pub const text_input = @import("text_input.zig");
pub const list = @import("list.zig");
pub const table = @import("table.zig");
pub const checkbox = @import("checkbox.zig");
pub const progress = @import("progress.zig");
pub const tabs = @import("tabs.zig");
pub const textarea = @import("textarea.zig");
pub const tree = @import("tree.zig");
pub const modal = @import("modal.zig");
pub const filebrowser = @import("filebrowser.zig");
pub const commandpalette = @import("commandpalette.zig");
pub const statusbar = @import("statusbar.zig");

pub const Label = label.Label;
pub const Button = button.Button;
pub const TextInput = text_input.TextInput;
pub const List = list.List;
pub const ListItem = list.ListItem;
pub const SelectionMode = list.SelectionMode;
pub const Table = table.Table;
pub const Column = table.Column;
pub const ColumnWidth = table.ColumnWidth;
pub const Row = table.Row;
pub const Alignment = table.Alignment;

// Checkbox and RadioGroup
pub const Checkbox = checkbox.Checkbox;
pub const RadioGroup = checkbox.RadioGroup;
pub const CheckboxStyle = checkbox.CheckboxStyle;

// Progress indicators
pub const ProgressBar = progress.ProgressBar;
pub const Spinner = progress.Spinner;
pub const ProgressStyle = progress.ProgressStyle;
pub const LabelPosition = progress.LabelPosition;

// Tabs
pub const Tabs = tabs.Tabs;
pub const Tab = tabs.Tab;
pub const TabPosition = tabs.TabPosition;
pub const TabStyle = tabs.TabStyle;

// TextArea
pub const TextArea = textarea.TextArea;

// Tree
pub const Tree = tree.Tree;
pub const TreeNode = tree.TreeNode;

// Modal/Dialog
pub const Modal = modal.Modal;
pub const DialogButton = modal.DialogButton;
pub const DialogResult = modal.DialogResult;
pub const Toast = modal.Toast;

// File Browser
pub const FileBrowser = filebrowser.FileBrowser;
pub const FileEntry = filebrowser.FileEntry;
pub const EntryType = filebrowser.EntryType;

// Command Palette
pub const CommandPalette = commandpalette.CommandPalette;
pub const Command = commandpalette.Command;

// Status Bar
pub const StatusBar = statusbar.StatusBar;
pub const Segment = statusbar.Segment;
pub const SegmentAlign = statusbar.SegmentAlign;

// Convenience constructors
pub const centered = label.centered;
pub const boldLabel = label.boldLabel;

test {
    @import("std").testing.refAllDecls(@This());
}
