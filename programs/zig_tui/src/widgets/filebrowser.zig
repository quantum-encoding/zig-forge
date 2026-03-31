//! File Browser widget - directory and file navigation
//!
//! Displays a navigable file system tree with icons and filtering.

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

/// Linux dirent64 structure for reading directories
const LinuxDirent64 = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    // d_name follows
};

/// File entry type
pub const EntryType = enum {
    file,
    directory,
    symlink,
    unknown,
};

/// File entry
pub const FileEntry = struct {
    name: []const u8,
    entry_type: EntryType,
    size: u64,
    is_hidden: bool,
    is_executable: bool,
};

/// File selection callback
pub const FileSelectCallback = *const fn (*FileBrowser, []const u8) void;

/// File browser widget
pub const FileBrowser = struct {
    allocator: std.mem.Allocator,

    // Current state
    current_path: []u8,
    entries: std.ArrayListUnmanaged(FileEntry),
    selected_idx: usize,
    scroll_offset: usize,

    // Options
    show_hidden: bool,
    show_icons: bool,
    show_size: bool,
    sort_directories_first: bool,

    // Filter
    filter_pattern: ?[]const u8,

    // Styles
    dir_style: Style,
    file_style: Style,
    symlink_style: Style,
    hidden_style: Style,
    selected_style: Style,
    header_style: Style,

    // Icons
    dir_icon: []const u8,
    file_icon: []const u8,
    symlink_icon: []const u8,
    parent_icon: []const u8,

    // Callback
    on_select: ?FileSelectCallback,
    on_open: ?FileSelectCallback,

    // State
    focused: bool,
    visible_height: u16,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new FileBrowser
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .current_path = &.{},
            .entries = .{},
            .selected_idx = 0,
            .scroll_offset = 0,
            .show_hidden = false,
            .show_icons = true,
            .show_size = true,
            .sort_directories_first = true,
            .filter_pattern = null,
            .dir_style = Style{ .fg = Color.blue, .attrs = .{ .bold = true } },
            .file_style = Style{ .fg = Color.white },
            .symlink_style = Style{ .fg = Color.cyan },
            .hidden_style = Style{ .fg = Color.gray },
            .selected_style = Style{ .fg = Color.black, .bg = Color.cyan },
            .header_style = Style{ .fg = Color.yellow, .attrs = .{ .bold = true } },
            .dir_icon = " ",
            .file_icon = " ",
            .symlink_icon = " ",
            .parent_icon = " ",
            .on_select = null,
            .on_open = null,
            .focused = false,
            .visible_height = 20,
        };
    }

    pub fn deinit(self: *Self) void {
        self.freeEntries();
        if (self.current_path.len > 0) {
            self.allocator.free(self.current_path);
        }
    }

    fn freeEntries(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Set current directory
    pub fn setPath(self: *Self, path: []const u8) !void {
        if (self.current_path.len > 0) {
            self.allocator.free(self.current_path);
        }
        self.current_path = try self.allocator.dupe(u8, path);
        try self.refresh();
    }

    /// Refresh directory listing
    pub fn refresh(self: *Self) !void {
        self.freeEntries();
        self.selected_idx = 0;
        self.scroll_offset = 0;

        // Add parent directory entry if not at root
        if (self.current_path.len > 1) {
            const parent_name = try self.allocator.dupe(u8, "..");
            try self.entries.append(self.allocator, .{
                .name = parent_name,
                .entry_type = .directory,
                .size = 0,
                .is_hidden = false,
                .is_executable = false,
            });
        }

        // Open directory using posix API
        var path_z: [4097]u8 = undefined;
        @memcpy(path_z[0..self.current_path.len], self.current_path);
        path_z[self.current_path.len] = 0;

        const fd = std.posix.openat(std.posix.AT.FDCWD, path_z[0..self.current_path.len :0], .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
        }, 0) catch {
            return;
        };
        defer _ = std.c.close(fd);

        // Collect entries
        var dirs: std.ArrayListUnmanaged(FileEntry) = .empty;
        defer dirs.deinit(self.allocator);
        var files: std.ArrayListUnmanaged(FileEntry) = .empty;
        defer files.deinit(self.allocator);

        // Read directory entries using getdents64
        var buf: [4096]u8 = undefined;
        while (true) {
            const nread = std.os.linux.getdents64(fd, &buf, buf.len);
            if (nread == 0) break;
            if (nread > buf.len) break;

            var bpos: usize = 0;
            while (bpos < nread) {
                const d: *align(1) const LinuxDirent64 = @ptrCast(&buf[bpos]);
                const name_ptr: [*]const u8 = @ptrCast(&buf[bpos + 19]);
                const name_end = std.mem.indexOfScalar(u8, name_ptr[0 .. d.d_reclen - 19], 0) orelse (d.d_reclen - 19);
                const entry_name = name_ptr[0..name_end];

                // Skip . and ..
                if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) {
                    bpos += d.d_reclen;
                    continue;
                }

                const is_hidden = entry_name.len > 0 and entry_name[0] == '.';

                // Skip hidden if not showing
                if (is_hidden and !self.show_hidden) {
                    bpos += d.d_reclen;
                    continue;
                }

                // Apply filter if set
                if (self.filter_pattern) |pattern| {
                    if (std.mem.indexOf(u8, entry_name, pattern) == null) {
                        bpos += d.d_reclen;
                        continue;
                    }
                }

                const file_entry = FileEntry{
                    .name = self.allocator.dupe(u8, entry_name) catch {
                        bpos += d.d_reclen;
                        continue;
                    },
                    .entry_type = switch (d.d_type) {
                        4 => .directory, // DT_DIR
                        10 => .symlink, // DT_LNK
                        8 => .file, // DT_REG
                        else => .unknown,
                    },
                    .size = 0,
                    .is_hidden = is_hidden,
                    .is_executable = false,
                };

                if (self.sort_directories_first) {
                    if (d.d_type == 4) { // DT_DIR
                        try dirs.append(self.allocator, file_entry);
                    } else {
                        try files.append(self.allocator, file_entry);
                    }
                } else {
                    try self.entries.append(self.allocator, file_entry);
                }

                bpos += d.d_reclen;
            }
        }

        // Sort and combine
        if (self.sort_directories_first) {
            // Sort directories
            std.mem.sort(FileEntry, dirs.items, {}, struct {
                fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
                    return std.mem.lessThan(u8, a.name, b.name);
                }
            }.lessThan);

            // Sort files
            std.mem.sort(FileEntry, files.items, {}, struct {
                fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
                    return std.mem.lessThan(u8, a.name, b.name);
                }
            }.lessThan);

            // Add sorted entries
            for (dirs.items) |entry| {
                try self.entries.append(self.allocator, entry);
            }
            for (files.items) |entry| {
                try self.entries.append(self.allocator, entry);
            }
        }
    }

    /// Get selected entry
    pub fn getSelected(self: *const Self) ?FileEntry {
        if (self.selected_idx < self.entries.items.len) {
            return self.entries.items[self.selected_idx];
        }
        return null;
    }

    /// Get full path of selected entry
    pub fn getSelectedPath(self: *const Self, buf: []u8) ?[]const u8 {
        if (self.getSelected()) |entry| {
            const path_len = self.current_path.len;
            const name_len = entry.name.len;
            const total = path_len + 1 + name_len;

            if (total <= buf.len) {
                @memcpy(buf[0..path_len], self.current_path);
                buf[path_len] = '/';
                @memcpy(buf[path_len + 1 ..][0..name_len], entry.name);
                return buf[0..total];
            }
        }
        return null;
    }

    /// Navigate into selected directory or open file
    pub fn openSelected(self: *Self) !void {
        if (self.getSelected()) |entry| {
            if (entry.entry_type == .directory) {
                if (std.mem.eql(u8, entry.name, "..")) {
                    // Go to parent
                    try self.goUp();
                } else {
                    // Enter directory
                    var path_buf: [4096]u8 = undefined;
                    if (self.getSelectedPath(&path_buf)) |full_path| {
                        const path_copy = try self.allocator.dupe(u8, full_path);
                        self.allocator.free(self.current_path);
                        self.current_path = path_copy;
                        try self.refresh();
                    }
                }
            } else {
                // Fire open callback for files
                if (self.on_open) |cb| {
                    var path_buf: [4096]u8 = undefined;
                    if (self.getSelectedPath(&path_buf)) |full_path| {
                        cb(self, full_path);
                    }
                }
            }
        }
    }

    /// Go to parent directory
    pub fn goUp(self: *Self) !void {
        if (self.current_path.len <= 1) return;

        // Find last separator
        var i = self.current_path.len - 1;
        while (i > 0 and self.current_path[i] != '/') : (i -= 1) {}

        const new_len = if (i == 0) 1 else i;
        const new_path = try self.allocator.dupe(u8, self.current_path[0..new_len]);
        self.allocator.free(self.current_path);
        self.current_path = new_path;
        try self.refresh();
    }

    /// Set show hidden files
    pub fn setShowHidden(self: *Self, show: bool) *Self {
        self.show_hidden = show;
        return self;
    }

    /// Set filter pattern
    pub fn setFilter(self: *Self, pattern: ?[]const u8) *Self {
        self.filter_pattern = pattern;
        return self;
    }

    /// Set selection callback
    pub fn onSelect(self: *Self, callback: FileSelectCallback) *Self {
        self.on_select = callback;
        return self;
    }

    /// Set open callback
    pub fn onOpen(self: *Self, callback: FileSelectCallback) *Self {
        self.on_open = callback;
        return self;
    }

    fn ensureVisible(self: *Self) void {
        if (self.selected_idx < self.scroll_offset) {
            self.scroll_offset = self.selected_idx;
        } else if (self.selected_idx >= self.scroll_offset + self.visible_height - 1) {
            self.scroll_offset = self.selected_idx - self.visible_height + 2;
        }
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        if (area.isEmpty()) return;

        self.focused = state.focused;
        self.visible_height = if (area.height > 2) area.height - 2 else 1;

        // Draw header with current path
        const header_width = @min(self.current_path.len, area.width);
        _ = buf.writeTruncated(area.x, area.y, area.width, self.current_path, self.header_style);

        // Draw separator
        buf.hLine(area.x, area.y + 1, area.width, '─', Style{ .fg = Color.gray });

        // Draw entries
        const list_y = area.y + 2;
        var y: u16 = 0;

        while (y < self.visible_height) : (y += 1) {
            const entry_idx = self.scroll_offset + y;
            if (entry_idx >= self.entries.items.len) break;

            const entry = self.entries.items[entry_idx];
            const is_selected = entry_idx == self.selected_idx;

            // Determine style
            var style = switch (entry.entry_type) {
                .directory => self.dir_style,
                .symlink => self.symlink_style,
                .file => self.file_style,
                .unknown => self.file_style,
            };

            if (entry.is_hidden and !is_selected) {
                style = self.hidden_style;
            }

            if (is_selected and state.focused) {
                style = self.selected_style;
                // Fill background
                buf.fill(
                    Rect{ .x = area.x, .y = list_y + y, .width = area.width, .height = 1 },
                    core.Cell.styled(' ', style),
                );
            }

            var x = area.x;

            // Draw icon
            if (self.show_icons) {
                const icon = if (std.mem.eql(u8, entry.name, ".."))
                    self.parent_icon
                else switch (entry.entry_type) {
                    .directory => self.dir_icon,
                    .symlink => self.symlink_icon,
                    else => self.file_icon,
                };
                _ = buf.writeStr(x, list_y + y, icon, style);
                x += @intCast(icon.len);
            }

            // Draw name
            const name_width = if (area.width > x - area.x) area.width - (x - area.x) else 0;
            _ = buf.writeTruncated(x, list_y + y, name_width, entry.name, style);
        }

        // Draw scrollbar if needed
        if (self.entries.items.len > self.visible_height) {
            const scrollbar_x = area.x + area.width - 1;
            var sy: u16 = 0;
            while (sy < self.visible_height) : (sy += 1) {
                buf.setChar(scrollbar_x, list_y + sy, '│', Style{ .fg = Color.gray });
            }
            // Thumb
            const thumb_pos: u16 = @intCast((self.scroll_offset * self.visible_height) / self.entries.items.len);
            buf.setChar(scrollbar_x, list_y + thumb_pos, '┃', Style{ .fg = Color.white });
        }

        _ = header_width;
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| switch (s) {
                        .up => {
                            if (self.selected_idx > 0) {
                                self.selected_idx -= 1;
                                self.ensureVisible();
                                if (self.on_select) |cb| {
                                    var path_buf: [4096]u8 = undefined;
                                    if (self.getSelectedPath(&path_buf)) |path| {
                                        cb(self, path);
                                    }
                                }
                            }
                            return true;
                        },
                        .down => {
                            if (self.selected_idx < self.entries.items.len - 1) {
                                self.selected_idx += 1;
                                self.ensureVisible();
                                if (self.on_select) |cb| {
                                    var path_buf: [4096]u8 = undefined;
                                    if (self.getSelectedPath(&path_buf)) |path| {
                                        cb(self, path);
                                    }
                                }
                            }
                            return true;
                        },
                        .enter => {
                            self.openSelected() catch {};
                            return true;
                        },
                        .backspace => {
                            self.goUp() catch {};
                            return true;
                        },
                        .home => {
                            self.selected_idx = 0;
                            self.ensureVisible();
                            return true;
                        },
                        .end => {
                            if (self.entries.items.len > 0) {
                                self.selected_idx = self.entries.items.len - 1;
                                self.ensureVisible();
                            }
                            return true;
                        },
                        else => {},
                    },
                    .char => |c| {
                        // Toggle hidden files with '.'
                        if (c == '.') {
                            self.show_hidden = !self.show_hidden;
                            self.refresh() catch {};
                            return true;
                        }
                        // Quick search - jump to first entry starting with character
                        for (self.entries.items, 0..) |entry, i| {
                            if (entry.name.len > 0 and entry.name[0] == @as(u8, @intCast(c))) {
                                self.selected_idx = i;
                                self.ensureVisible();
                                return true;
                            }
                        }
                    },
                }
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left) {
                    if (m.y >= 2) {
                        const clicked_idx = self.scroll_offset + (m.y - 2);
                        if (clicked_idx < self.entries.items.len) {
                            if (self.selected_idx == clicked_idx) {
                                // Double-click effect
                                self.openSelected() catch {};
                            } else {
                                self.selected_idx = clicked_idx;
                            }
                            return true;
                        }
                    }
                }
            },
            else => {},
        }
        return false;
    }

    pub fn minSize(self: *Self) Size {
        _ = self;
        return .{ .width = 30, .height = 10 };
    }

    pub fn canFocus(self: *Self) bool {
        _ = self;
        return true;
    }
};

test "FileBrowser basic" {
    var fb = FileBrowser.init(std.testing.allocator);
    defer fb.deinit();

    try std.testing.expect(fb.entries.items.len == 0);
}
