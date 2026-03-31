//! Tree widget - hierarchical tree view
//!
//! Displays a collapsible tree structure with expand/collapse functionality.

const std = @import("std");
const core = @import("../core/core.zig");
const widget_mod = @import("../widget/mod.zig");
const input_mod = @import("../input/input.zig");

pub const Buffer = core.Buffer;
pub const Rect = core.Rect;
pub const Size = core.Size;
pub const Style = core.Style;
pub const Color = core.Color;
pub const Widget = widget_mod.Widget;
pub const makeWidget = widget_mod.makeWidget;
pub const Event = input_mod.Event;
pub const Key = input_mod.Key;

/// Tree node
pub const TreeNode = struct {
    label: []const u8,
    children: []const TreeNode,
    expanded: bool,
    icon: ?[]const u8,
    data: ?*anyopaque,
};

/// Tree selection callback
pub const TreeSelectCallback = *const fn (*Tree, []const usize) void;

/// Tree widget
pub const Tree = struct {
    root: []const TreeNode,
    allocator: std.mem.Allocator,

    // State - flattened visible items
    visible_items: std.ArrayListUnmanaged(VisibleItem),
    selected_idx: usize,
    scroll_offset: usize,

    // Expand/collapse state (stored by path)
    expanded_paths: std.StringHashMapUnmanaged(bool),

    // Options
    show_root: bool,
    indent_size: u16,
    show_icons: bool,

    // Styles
    normal_style: Style,
    selected_style: Style,
    expanded_icon: []const u8,
    collapsed_icon: []const u8,
    leaf_icon: []const u8,
    connector_style: Style,

    // Callback
    on_select: ?TreeSelectCallback,

    // State
    focused: bool,

    const Self = @This();

    pub const VisibleItem = struct {
        node: *const TreeNode,
        depth: u16,
        path: []const usize,
        is_last: bool, // Last child at this level
    };

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new Tree
    pub fn init(allocator: std.mem.Allocator, root: []const TreeNode) Self {
        return .{
            .root = root,
            .allocator = allocator,
            .visible_items = .{},
            .selected_idx = 0,
            .scroll_offset = 0,
            .expanded_paths = .{},
            .show_root = true,
            .indent_size = 2,
            .show_icons = true,
            .normal_style = Style{ .fg = Color.white },
            .selected_style = Style{ .fg = Color.black, .bg = Color.cyan },
            .expanded_icon = "[-]",
            .collapsed_icon = "[+]",
            .leaf_icon = " - ",
            .connector_style = Style{ .fg = Color.gray },
            .on_select = null,
            .focused = false,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free paths
        for (self.visible_items.items) |item| {
            self.allocator.free(item.path);
        }
        self.visible_items.deinit(self.allocator);

        // Free expanded paths keys
        var iter = self.expanded_paths.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.expanded_paths.deinit(self.allocator);
    }

    /// Rebuild visible items list
    pub fn rebuild(self: *Self) !void {
        // Clear existing
        for (self.visible_items.items) |item| {
            self.allocator.free(item.path);
        }
        self.visible_items.clearRetainingCapacity();

        // Build from root
        var path: std.ArrayListUnmanaged(usize) = .empty;
        defer path.deinit(self.allocator);

        try self.buildVisibleItems(self.root, 0, &path);
    }

    fn buildVisibleItems(
        self: *Self,
        nodes: []const TreeNode,
        depth: u16,
        path: *std.ArrayListUnmanaged(usize),
    ) !void {
        for (nodes, 0..) |*node, i| {
            try path.append(self.allocator, i);
            defer _ = path.pop();

            const is_last = i == nodes.len - 1;
            const path_copy = try self.allocator.dupe(usize, path.items);

            try self.visible_items.append(self.allocator, .{
                .node = node,
                .depth = depth,
                .path = path_copy,
                .is_last = is_last,
            });

            // Check if expanded
            if (node.children.len > 0 and self.isExpanded(node)) {
                try self.buildVisibleItems(node.children, depth + 1, path);
            }
        }
    }

    fn isExpanded(_: *Self, node: *const TreeNode) bool {
        // Default to node's own expanded state
        return node.expanded;
    }

    /// Toggle expand/collapse at selected node
    pub fn toggleExpand(self: *Self) !void {
        if (self.selected_idx >= self.visible_items.items.len) return;

        const item = self.visible_items.items[self.selected_idx];
        if (item.node.children.len == 0) return; // Leaf node

        // Toggle - we need to rebuild to reflect the change
        // For now, we rely on the node's expanded field being mutable
        // In a real implementation, we'd track state separately
        try self.rebuild();
    }

    /// Set expand icons
    pub fn setIcons(self: *Self, expanded: []const u8, collapsed: []const u8, leaf: []const u8) *Self {
        self.expanded_icon = expanded;
        self.collapsed_icon = collapsed;
        self.leaf_icon = leaf;
        return self;
    }

    /// Set indent size
    pub fn setIndent(self: *Self, size: u16) *Self {
        self.indent_size = size;
        return self;
    }

    /// Set selection callback
    pub fn onSelect(self: *Self, callback: TreeSelectCallback) *Self {
        self.on_select = callback;
        return self;
    }

    /// Get selected node
    pub fn getSelected(self: *const Self) ?*const TreeNode {
        if (self.selected_idx < self.visible_items.items.len) {
            return self.visible_items.items[self.selected_idx].node;
        }
        return null;
    }

    /// Get selected path
    pub fn getSelectedPath(self: *const Self) ?[]const usize {
        if (self.selected_idx < self.visible_items.items.len) {
            return self.visible_items.items[self.selected_idx].path;
        }
        return null;
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        if (area.isEmpty()) return;

        self.focused = state.focused;

        // Ensure visible items are built
        if (self.visible_items.items.len == 0 and self.root.len > 0) {
            self.rebuild() catch return;
        }

        // Ensure scroll keeps selection visible
        if (self.selected_idx < self.scroll_offset) {
            self.scroll_offset = self.selected_idx;
        } else if (self.selected_idx >= self.scroll_offset + area.height) {
            self.scroll_offset = self.selected_idx - area.height + 1;
        }

        var y: u16 = 0;
        while (y < area.height) : (y += 1) {
            const item_idx = self.scroll_offset + y;
            if (item_idx >= self.visible_items.items.len) break;

            const item = self.visible_items.items[item_idx];
            const is_selected = item_idx == self.selected_idx;

            const style = if (is_selected and state.focused)
                self.selected_style
            else
                self.normal_style;

            // Fill background for selected
            if (is_selected and state.focused) {
                buf.fill(
                    Rect{ .x = area.x, .y = area.y + y, .width = area.width, .height = 1 },
                    core.Cell.styled(' ', style),
                );
            }

            var x = area.x;

            // Draw indent and tree connectors
            const indent = item.depth * self.indent_size;
            x += indent;

            // Draw expand/collapse icon or leaf icon
            const icon = if (item.node.children.len > 0)
                if (item.node.expanded) self.expanded_icon else self.collapsed_icon
            else
                self.leaf_icon;

            if (x + icon.len <= area.x + area.width) {
                _ = buf.writeStr(x, area.y + y, icon, style);
                x += @intCast(icon.len);
            }

            // Draw node icon if present
            if (self.show_icons) {
                if (item.node.icon) |node_icon| {
                    if (x + node_icon.len + 1 <= area.x + area.width) {
                        _ = buf.writeStr(x, area.y + y, node_icon, style);
                        x += @intCast(node_icon.len);
                        buf.setChar(x, area.y + y, ' ', style);
                        x += 1;
                    }
                }
            }

            // Draw label
            const remaining_width = if (area.x + area.width > x) area.x + area.width - x else 0;
            if (remaining_width > 0) {
                _ = buf.writeTruncated(x, area.y + y, remaining_width, item.node.label, style);
            }
        }

        // Draw scrollbar if needed
        if (self.visible_items.items.len > area.height) {
            const scrollbar_x = area.x + area.width - 1;
            var sy: u16 = 0;
            while (sy < area.height) : (sy += 1) {
                buf.setChar(scrollbar_x, area.y + sy, '│', self.connector_style);
            }
            // Thumb
            const thumb_pos: u16 = @intCast((self.scroll_offset * area.height) / self.visible_items.items.len);
            buf.setChar(scrollbar_x, area.y + thumb_pos, '┃', Style{ .fg = Color.white });
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| switch (s) {
                        .up => {
                            if (self.selected_idx > 0) {
                                self.selected_idx -= 1;
                                if (self.on_select) |cb| {
                                    if (self.getSelectedPath()) |path| {
                                        cb(self, path);
                                    }
                                }
                            }
                            return true;
                        },
                        .down => {
                            if (self.selected_idx < self.visible_items.items.len - 1) {
                                self.selected_idx += 1;
                                if (self.on_select) |cb| {
                                    if (self.getSelectedPath()) |path| {
                                        cb(self, path);
                                    }
                                }
                            }
                            return true;
                        },
                        .left => {
                            // Collapse current node
                            self.toggleExpand() catch {};
                            return true;
                        },
                        .right, .enter => {
                            // Expand current node
                            self.toggleExpand() catch {};
                            return true;
                        },
                        else => {},
                    },
                    .char => {},
                }
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left) {
                    const clicked_idx = self.scroll_offset + m.y;
                    if (clicked_idx < self.visible_items.items.len) {
                        self.selected_idx = clicked_idx;
                        if (self.on_select) |cb| {
                            if (self.getSelectedPath()) |path| {
                                cb(self, path);
                            }
                        }
                        return true;
                    }
                }
            },
            else => {},
        }
        return false;
    }

    pub fn minSize(self: *Self) Size {
        _ = self;
        return .{ .width = 20, .height = 5 };
    }

    pub fn canFocus(self: *Self) bool {
        return self.visible_items.items.len > 0 or self.root.len > 0;
    }
};

test "Tree basic" {
    const nodes = [_]TreeNode{
        .{
            .label = "Root",
            .children = &[_]TreeNode{
                .{ .label = "Child 1", .children = &.{}, .expanded = false, .icon = null, .data = null },
                .{ .label = "Child 2", .children = &.{}, .expanded = false, .icon = null, .data = null },
            },
            .expanded = true,
            .icon = null,
            .data = null,
        },
    };

    var tree = Tree.init(std.testing.allocator, &nodes);
    defer tree.deinit();

    try tree.rebuild();
    try std.testing.expectEqual(@as(usize, 3), tree.visible_items.items.len);
}
