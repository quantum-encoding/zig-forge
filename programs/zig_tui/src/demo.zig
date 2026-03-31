//! zig_tui Demo Application
//!
//! Demonstrates the TUI framework capabilities.

const std = @import("std");
const tui = @import("zig_tui");

const Buffer = tui.Buffer;
const Size = tui.Size;
const Rect = tui.Rect;
const Event = tui.Event;
const Style = tui.Style;
const Color = tui.Color;
const BorderStyle = tui.BorderStyle;
const Key = tui.Key;

/// Create a style with bold attribute set
fn boldStyle(fg: Color, bg: Color) Style {
    return .{
        .fg = fg,
        .bg = bg,
        .attrs = .{ .bold = true },
    };
}

/// Create a style with just bold foreground
fn boldFg(fg: Color) Style {
    return .{
        .fg = fg,
        .attrs = .{ .bold = true },
    };
}

// Demo state
var counter: u32 = 0;
var input_text: [64]u8 = [_]u8{0} ** 64;
var input_len: usize = 0;
var selected_item: usize = 0;
var running: bool = true;
var color_selection: usize = 0; // For colors test - color picker
var attr_selection: usize = 0; // For colors test - attribute picker
var colors_row: usize = 0; // 0 = colors, 1 = attributes

// List demo state
var list_selected: usize = 0;
var list_scroll: usize = 0;

// Table demo state
var table_selected: usize = 0;
var table_scroll: usize = 0;

// Checkbox demo state
var checkbox_states = [_]bool{ true, false, true, false };
var radio_selected: usize = 0;

// Progress demo state
var progress_value: f32 = 0.35;
var progress_style_idx: usize = 0;
var spinner_frame: usize = 0;

// Tabs demo state
var tabs_selected: usize = 0;
var tabs_style_idx: usize = 0;

// File browser demo state
var fb_entries: [64]FbEntry = undefined;
var fb_entry_count: usize = 0;
var fb_selected: usize = 0;
var fb_scroll: usize = 0;
var fb_current_path: [512]u8 = undefined;
var fb_path_len: usize = 0;
var fb_show_hidden: bool = false;
var fb_initialized: bool = false;

const FbEntry = struct {
    name: [256]u8,
    name_len: usize,
    is_dir: bool,
    is_hidden: bool,
};

// Command palette demo state
var cp_visible: bool = false;
var cp_query: [64]u8 = [_]u8{0} ** 64;
var cp_query_len: usize = 0;
var cp_selected: usize = 0;
var cp_filtered: [32]usize = undefined;
var cp_filtered_count: usize = 0;
var cp_last_executed: ?usize = null;

const CpCommand = struct {
    id: []const u8,
    label: []const u8,
    shortcut: ?[]const u8,
    category: []const u8,
};

const cp_commands = [_]CpCommand{
    .{ .id = "file.new", .label = "New File", .shortcut = "Ctrl+N", .category = "File" },
    .{ .id = "file.open", .label = "Open File", .shortcut = "Ctrl+O", .category = "File" },
    .{ .id = "file.save", .label = "Save File", .shortcut = "Ctrl+S", .category = "File" },
    .{ .id = "file.saveas", .label = "Save As...", .shortcut = "Ctrl+Shift+S", .category = "File" },
    .{ .id = "file.close", .label = "Close File", .shortcut = "Ctrl+W", .category = "File" },
    .{ .id = "edit.undo", .label = "Undo", .shortcut = "Ctrl+Z", .category = "Edit" },
    .{ .id = "edit.redo", .label = "Redo", .shortcut = "Ctrl+Y", .category = "Edit" },
    .{ .id = "edit.cut", .label = "Cut", .shortcut = "Ctrl+X", .category = "Edit" },
    .{ .id = "edit.copy", .label = "Copy", .shortcut = "Ctrl+C", .category = "Edit" },
    .{ .id = "edit.paste", .label = "Paste", .shortcut = "Ctrl+V", .category = "Edit" },
    .{ .id = "edit.find", .label = "Find", .shortcut = "Ctrl+F", .category = "Edit" },
    .{ .id = "edit.replace", .label = "Find and Replace", .shortcut = "Ctrl+H", .category = "Edit" },
    .{ .id = "view.zoom_in", .label = "Zoom In", .shortcut = "Ctrl++", .category = "View" },
    .{ .id = "view.zoom_out", .label = "Zoom Out", .shortcut = "Ctrl+-", .category = "View" },
    .{ .id = "view.sidebar", .label = "Toggle Sidebar", .shortcut = "Ctrl+B", .category = "View" },
    .{ .id = "view.terminal", .label = "Toggle Terminal", .shortcut = "Ctrl+`", .category = "View" },
    .{ .id = "go.line", .label = "Go to Line", .shortcut = "Ctrl+G", .category = "Go" },
    .{ .id = "go.file", .label = "Go to File", .shortcut = "Ctrl+P", .category = "Go" },
    .{ .id = "go.symbol", .label = "Go to Symbol", .shortcut = "Ctrl+Shift+O", .category = "Go" },
    .{ .id = "go.definition", .label = "Go to Definition", .shortcut = "F12", .category = "Go" },
    .{ .id = "terminal.new", .label = "New Terminal", .shortcut = null, .category = "Terminal" },
    .{ .id = "terminal.clear", .label = "Clear Terminal", .shortcut = null, .category = "Terminal" },
    .{ .id = "help.docs", .label = "Documentation", .shortcut = "F1", .category = "Help" },
    .{ .id = "help.about", .label = "About", .shortcut = null, .category = "Help" },
};

// Status bar demo state
var sb_mode_idx: usize = 0;
var sb_filename_idx: usize = 0;
var sb_modified: bool = false;
var sb_readonly: bool = false;
var sb_line: usize = 42;
var sb_column: usize = 15;
var sb_percentage: u8 = 35;
var sb_message_timer: u8 = 0;
var sb_show_message: bool = false;

const sb_modes = [_][]const u8{ "NORMAL", "INSERT", "VISUAL", "COMMAND", "REPLACE" };
const sb_filenames = [_]?[]const u8{ "main.zig", "src/widgets/statusbar.zig", "build.zig", "README.md", null };
const sb_filetypes = [_]?[]const u8{ "Zig", "Zig", "Zig", "Markdown", null };

const menu_items = [_][]const u8{
    "Counter Demo",
    "Text Input",
    "List Demo",
    "Table Demo",
    "Checkbox Demo",
    "Progress Demo",
    "Tabs Demo",
    "File Browser",
    "Command Palette",
    "Status Bar",
    "Colors Test",
    "Exit",
};

// Sample data for list demo
const list_items = [_][]const u8{
    "Apple", "Banana", "Cherry", "Date", "Elderberry",
    "Fig", "Grape", "Honeydew", "Kiwi", "Lemon",
    "Mango", "Nectarine", "Orange", "Papaya", "Quince",
};

// Sample data for table demo
const table_data = [_][3][]const u8{
    .{ "Alice", "Engineer", "San Francisco" },
    .{ "Bob", "Designer", "New York" },
    .{ "Charlie", "Manager", "Chicago" },
    .{ "Diana", "Developer", "Seattle" },
    .{ "Eve", "Analyst", "Boston" },
    .{ "Frank", "Director", "Austin" },
    .{ "Grace", "Architect", "Denver" },
    .{ "Henry", "Lead", "Portland" },
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var app = try tui.Application.init(allocator, .{
        .mouse_enabled = true,
        .tick_rate_ms = 100,
    });
    defer app.deinit();

    app.setRenderCallback(render);
    app.setEventCallback(handleEvent);

    try app.run();
}

fn render(buf: *Buffer, size: Size) void {
    // Draw title
    const title = " zig_tui Demo ";
    const title_style = boldStyle(Color.black, Color.cyan);
    const title_x = (size.width - @as(u16, @intCast(title.len))) / 2;
    _ = buf.writeStr(title_x, 0, title, title_style);

    // Draw main border
    const main_area = Rect{
        .x = 2,
        .y = 2,
        .width = size.width - 4,
        .height = size.height - 4,
    };
    buf.drawBorder(main_area, .rounded, Style{ .fg = Color.cyan });

    // Draw menu
    const menu_x: u16 = 4;
    var menu_y: u16 = 4;

    var menu_style = Style{ .fg = Color.yellow };
    menu_style.attrs.bold = true;
    _ = buf.writeStr(menu_x, menu_y, "Menu:", menu_style);
    menu_y += 2;

    for (menu_items, 0..) |item, i| {
        const is_selected = i == selected_item;
        const item_style = if (is_selected)
            Style.init(Color.black, Color.white)
        else
            Style{ .fg = Color.white };

        const prefix: []const u8 = if (is_selected) "> " else "  ";
        _ = buf.writeStr(menu_x, menu_y, prefix, item_style);
        _ = buf.writeStr(menu_x + 2, menu_y, item, item_style);
        menu_y += 1;
    }

    // Draw content area (with safe width calculation)
    const content_x: u16 = 30;
    const content_y: u16 = 4;
    const content_width: u16 = if (size.width > content_x + 4) size.width - content_x - 4 else 10;

    // Draw vertical separator
    buf.vLine(content_x - 2, 3, size.height - 6, '│', Style{ .fg = Color.cyan });

    // Render selected content
    const content_height = if (size.height > content_y + 4) size.height - content_y - 4 else 5;
    switch (selected_item) {
        0 => renderCounterDemo(buf, content_x, content_y, content_width),
        1 => renderTextInput(buf, content_x, content_y, content_width),
        2 => renderListDemo(buf, content_x, content_y, content_width, content_height),
        3 => renderTableDemo(buf, content_x, content_y, content_width, content_height),
        4 => renderCheckboxDemo(buf, content_x, content_y, content_width),
        5 => renderProgressDemo(buf, content_x, content_y, content_width),
        6 => renderTabsDemo(buf, content_x, content_y, content_width),
        7 => renderFileBrowserDemo(buf, content_x, content_y, content_width, content_height),
        8 => renderCommandPaletteDemo(buf, content_x, content_y, content_width, content_height),
        9 => renderStatusBarDemo(buf, content_x, content_y, content_width, content_height),
        10 => renderColorsTest(buf, content_x, content_y, content_width),
        else => {},
    }

    // Draw footer (truncated if too wide)
    const footer = " Arrow keys: Navigate | Enter: Select | Q: Quit ";
    const footer_style = Style{ .fg = Color.gray };
    const max_footer_width = if (size.width > 4) size.width - 4 else 0;
    _ = buf.writeTruncated(2, size.height - 1, max_footer_width, footer, footer_style);
}

fn renderCounterDemo(buf: *Buffer, x: u16, y: u16, width: u16) void {
    _ = buf.writeTruncated(x, y, width, "Counter Demo", boldFg(Color.green));

    // Use wrapping for instructions
    const instructions = "Press Space or Enter to increment the counter";
    const wrap_area = Rect{ .x = x, .y = y + 2, .width = width, .height = 2 };
    _ = buf.writeWrapped(wrap_area, instructions, Style{ .fg = Color.white });

    // Draw counter value
    var counter_buf: [32]u8 = undefined;
    const counter_str = formatNumber(&counter_buf, counter);
    _ = buf.writeTruncated(x, y + 5, width, "Count: ", Style{ .fg = Color.yellow });
    _ = buf.writeTruncated(x + 7, y + 5, if (width > 7) width - 7 else 0, counter_str, boldFg(Color.bright_white));

    // Draw a simple progress bar (constrained to available width)
    const bar_width: u16 = @min(20, if (width > 2) width - 2 else 1);
    const filled: u16 = @intCast(@min(counter % (bar_width + 1), bar_width));
    _ = buf.writeStr(x, y + 7, "[", Style{ .fg = Color.cyan });
    var i: u16 = 0;
    while (i < bar_width) : (i += 1) {
        const char: u21 = if (i < filled) '=' else ' ';
        buf.setChar(x + 1 + i, y + 7, char, Style{ .fg = Color.green });
    }
    _ = buf.writeStr(x + bar_width + 1, y + 7, "]", Style{ .fg = Color.cyan });
}

fn renderTextInput(buf: *Buffer, x: u16, y: u16, width: u16) void {
    _ = buf.writeTruncated(x, y, width, "Text Input Demo", boldFg(Color.green));
    _ = buf.writeTruncated(x, y + 2, width, "Type to enter text:", Style{ .fg = Color.white });

    // Draw input box - constrain to available width
    const input_width: u16 = @min(30, if (width > 2) width - 2 else width);
    buf.hLine(x, y + 4, input_width, '─', Style{ .fg = Color.white });
    buf.hLine(x, y + 6, input_width, '─', Style{ .fg = Color.white });
    if (x > 0) buf.setChar(x - 1, y + 5, '│', Style{ .fg = Color.white });
    buf.setChar(x + input_width, y + 5, '│', Style{ .fg = Color.white });

    // Draw input text (truncated to fit)
    if (input_len > 0) {
        _ = buf.writeTruncated(x, y + 5, input_width, input_text[0..input_len], Style{ .fg = Color.bright_white });
    } else {
        _ = buf.writeTruncated(x, y + 5, input_width, "(empty)", Style{ .fg = Color.gray });
    }

    // Echo (truncated)
    _ = buf.writeStr(x, y + 8, "Echo: ", Style{ .fg = Color.yellow });
    if (input_len > 0) {
        const echo_width = if (width > 6) width - 6 else 0;
        _ = buf.writeTruncated(x + 6, y + 8, echo_width, input_text[0..input_len], Style{ .fg = Color.white });
    }
}

fn renderListDemo(buf: *Buffer, x: u16, y: u16, width: u16, height: u16) void {
    _ = buf.writeTruncated(x, y, width, "List Demo", boldFg(Color.green));
    _ = buf.writeTruncated(x, y + 1, width, "Up/Down: Navigate | Enter: Select", Style{ .fg = Color.gray });

    const list_y = y + 3;
    const list_height = if (height > 4) height - 4 else 1;

    // Ensure scroll keeps selection visible
    if (list_selected < list_scroll) {
        list_scroll = list_selected;
    } else if (list_selected >= list_scroll + list_height) {
        list_scroll = list_selected - list_height + 1;
    }

    // Draw list items
    var row: u16 = 0;
    while (row < list_height) : (row += 1) {
        const item_idx = list_scroll + row;
        if (item_idx >= list_items.len) break;

        const is_selected = item_idx == list_selected;
        const item_style = if (is_selected)
            Style.init(Color.black, Color.cyan)
        else
            Style{ .fg = Color.white };

        // Fill row background
        if (is_selected) {
            buf.fill(
                Rect{ .x = x, .y = list_y + row, .width = width, .height = 1 },
                tui.Cell.styled(' ', item_style),
            );
        }

        const prefix: []const u8 = if (is_selected) "> " else "  ";
        _ = buf.writeStr(x, list_y + row, prefix, item_style);
        _ = buf.writeTruncated(x + 2, list_y + row, width - 2, list_items[item_idx], item_style);
    }

    // Draw scrollbar if needed
    if (list_items.len > list_height) {
        const scrollbar_x = x + width - 1;
        var sy: u16 = 0;
        while (sy < list_height) : (sy += 1) {
            buf.setChar(scrollbar_x, list_y + sy, '│', Style{ .fg = Color.gray });
        }
        // Thumb position
        const thumb_pos: u16 = @intCast((list_scroll * list_height) / list_items.len);
        buf.setChar(scrollbar_x, list_y + thumb_pos, '┃', Style{ .fg = Color.white });
    }

    // Show selected item info
    const info_y = list_y + list_height + 1;
    _ = buf.writeStr(x, info_y, "Selected: ", Style{ .fg = Color.yellow });
    if (list_selected < list_items.len) {
        _ = buf.writeTruncated(x + 10, info_y, width - 10, list_items[list_selected], Style{ .fg = Color.bright_white });
    }
}

fn renderTableDemo(buf: *Buffer, x: u16, y: u16, width: u16, height: u16) void {
    _ = buf.writeTruncated(x, y, width, "Table Demo", boldFg(Color.green));
    _ = buf.writeTruncated(x, y + 1, width, "Up/Down: Navigate rows", Style{ .fg = Color.gray });

    const table_y = y + 3;
    const table_height = if (height > 5) height - 5 else 1;

    // Column definitions - adapt to available width
    const headers = [3][]const u8{ "Name", "Role", "Location" };
    const num_cols: u16 = 3;
    const separators: u16 = num_cols - 1; // Space between columns
    const available = if (width > separators) width - separators else width;

    // Distribute width proportionally (30%, 30%, 40%)
    const col_widths = [3]u16{
        @max(6, available * 30 / 100),
        @max(6, available * 30 / 100),
        @max(6, available - (available * 30 / 100) * 2), // Remainder to last column
    };

    // Draw header
    const header_style = Style{ .fg = Color.black, .bg = Color.white, .attrs = .{ .bold = true } };
    var col_x = x;
    for (headers, 0..) |header, i| {
        buf.fill(
            Rect{ .x = col_x, .y = table_y, .width = col_widths[i], .height = 1 },
            tui.Cell.styled(' ', header_style),
        );
        _ = buf.writeTruncated(col_x, table_y, col_widths[i], header, header_style);
        col_x += col_widths[i] + 1;
    }

    // Draw separator
    buf.hLine(x, table_y + 1, width, '─', Style{ .fg = Color.gray });

    // Ensure scroll keeps selection visible
    const data_height = table_height - 2;
    if (table_selected < table_scroll) {
        table_scroll = table_selected;
    } else if (table_selected >= table_scroll + data_height) {
        table_scroll = table_selected - data_height + 1;
    }

    // Draw rows
    var row: u16 = 0;
    while (row < data_height) : (row += 1) {
        const row_idx = table_scroll + row;
        if (row_idx >= table_data.len) break;

        const is_selected = row_idx == table_selected;
        const row_style = if (is_selected)
            Style.init(Color.black, Color.cyan)
        else
            Style{ .fg = Color.white };

        const row_y = table_y + 2 + row;

        // Fill row background
        if (is_selected) {
            buf.fill(
                Rect{ .x = x, .y = row_y, .width = width, .height = 1 },
                tui.Cell.styled(' ', row_style),
            );
        }

        // Draw cells
        col_x = x;
        for (table_data[row_idx], 0..) |cell, i| {
            _ = buf.writeTruncated(col_x, row_y, col_widths[i], cell, row_style);
            col_x += col_widths[i] + 1;
        }
    }

    // Show row count
    const info_y = table_y + table_height;
    var count_buf: [32]u8 = undefined;
    const count_str = formatNumber(&count_buf, @as(u32, @intCast(table_selected + 1)));
    _ = buf.writeStr(x, info_y, "Row ", Style{ .fg = Color.yellow });
    _ = buf.writeStr(x + 4, info_y, count_str, Style{ .fg = Color.bright_white });
    _ = buf.writeStr(x + 4 + @as(u16, @intCast(count_str.len)), info_y, " of ", Style{ .fg = Color.yellow });
    const total_str = formatNumber(&count_buf, @as(u32, @intCast(table_data.len)));
    _ = buf.writeStr(x + 8 + @as(u16, @intCast(count_str.len)), info_y, total_str, Style{ .fg = Color.bright_white });
}

fn renderCheckboxDemo(buf: *Buffer, x: u16, y: u16, width: u16) void {
    _ = buf.writeTruncated(x, y, width, "Checkbox & Radio Demo", boldFg(Color.green));
    _ = buf.writeTruncated(x, y + 1, width, "Space: Toggle | Up/Down: Navigate", Style{ .fg = Color.gray });

    var cy = y + 3;
    _ = buf.writeStr(x, cy, "Checkboxes:", Style{ .fg = Color.yellow });
    cy += 1;

    const checkbox_labels = [_][]const u8{
        "Enable notifications",
        "Dark mode",
        "Auto-save",
        "Show line numbers",
    };

    const checkbox_styles = [_][2][]const u8{
        .{ "[x]", "[ ]" }, // square
        .{ "(●)", "( )" }, // round
        .{ " ✓ ", " ✗ " }, // check
        .{ " ■ ", " □ " }, // filled
    };

    for (checkbox_labels, 0..) |label, i| {
        const checked = checkbox_states[i];
        const style_chars = checkbox_styles[i % checkbox_styles.len];
        const check_str = if (checked) style_chars[0] else style_chars[1];
        const check_style = if (checked)
            Style{ .fg = Color.green }
        else
            Style{ .fg = Color.gray };

        _ = buf.writeStr(x, cy, check_str, check_style);
        _ = buf.writeTruncated(x + 4, cy, width - 4, label, Style{ .fg = Color.white });
        cy += 1;
    }

    cy += 1;
    _ = buf.writeStr(x, cy, "Radio Group:", Style{ .fg = Color.yellow });
    cy += 1;

    const radio_options = [_][]const u8{
        "Option A - First choice",
        "Option B - Second choice",
        "Option C - Third choice",
    };

    for (radio_options, 0..) |option, i| {
        const is_selected = i == radio_selected;
        const radio_str: []const u8 = if (is_selected) "(●)" else "( )";
        const radio_style = if (is_selected)
            Style{ .fg = Color.cyan }
        else
            Style{ .fg = Color.gray };

        _ = buf.writeStr(x, cy, radio_str, radio_style);
        _ = buf.writeTruncated(x + 4, cy, width - 4, option, Style{ .fg = Color.white });
        cy += 1;
    }

    cy += 1;
    _ = buf.writeStr(x, cy, "Selected: Option ", Style{ .fg = Color.yellow });
    const sel_char: [1]u8 = .{@intCast('A' + radio_selected)};
    _ = buf.writeStr(x + 17, cy, &sel_char, Style{ .fg = Color.bright_white });
}

fn renderProgressDemo(buf: *Buffer, x: u16, y: u16, width: u16) void {
    _ = buf.writeTruncated(x, y, width, "Progress Bar Demo", boldFg(Color.green));
    _ = buf.writeTruncated(x, y + 1, width, "Left/Right: Adjust | Up/Down: Style", Style{ .fg = Color.gray });

    var cy = y + 3;

    // Current progress value
    const percentage: u8 = @intFromFloat(progress_value * 100.0);
    var pct_buf: [8]u8 = undefined;
    const pct_str = std.fmt.bufPrint(&pct_buf, "{d}%", .{percentage}) catch "??%";

    const style_names = [_][]const u8{ "Block", "ASCII", "Dots", "Gradient" };
    const style_name = if (progress_style_idx < style_names.len) style_names[progress_style_idx] else "Unknown";
    _ = buf.writeStr(x, cy, "Style: ", Style{ .fg = Color.yellow });
    _ = buf.writeStr(x + 7, cy, style_name, Style{ .fg = Color.bright_white });
    cy += 2;

    const bar_width: u16 = @min(40, if (width > 8) width - 8 else 10);
    const filled_width: u16 = @intFromFloat(progress_value * @as(f32, @floatFromInt(bar_width)));

    // Draw based on current style
    switch (progress_style_idx) {
        0 => {
            // Block style: ████████░░░░
            var i: u16 = 0;
            while (i < bar_width) : (i += 1) {
                const char: u21 = if (i < filled_width) '█' else '░';
                const style = if (i < filled_width)
                    Style{ .fg = Color.green }
                else
                    Style{ .fg = Color.gray };
                buf.setChar(x + i, cy, char, style);
            }
        },
        1 => {
            // ASCII style: [========  ]
            buf.setChar(x, cy, '[', Style{ .fg = Color.white });
            var i: u16 = 0;
            while (i < bar_width - 2) : (i += 1) {
                const char: u21 = if (i < filled_width) '=' else ' ';
                buf.setChar(x + 1 + i, cy, char, Style{ .fg = Color.green });
            }
            buf.setChar(x + bar_width - 1, cy, ']', Style{ .fg = Color.white });
        },
        2 => {
            // Dots style: ●●●●●○○○○○
            var i: u16 = 0;
            while (i < bar_width) : (i += 1) {
                const char: u21 = if (i < filled_width) '●' else '○';
                const style = if (i < filled_width)
                    Style{ .fg = Color.cyan }
                else
                    Style{ .fg = Color.gray };
                buf.setChar(x + i, cy, char, style);
            }
        },
        3 => {
            // Gradient style
            var i: u16 = 0;
            while (i < bar_width) : (i += 1) {
                if (i < filled_width) {
                    const ratio = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(bar_width));
                    const r: u8 = @intFromFloat(ratio * 255.0);
                    const g: u8 = @intFromFloat((1.0 - ratio * 0.5) * 255.0);
                    buf.setChar(x + i, cy, '█', Style{ .fg = Color.fromRgb(r, g, 0) });
                } else {
                    buf.setChar(x + i, cy, '░', Style{ .fg = Color.gray });
                }
            }
        },
        else => {},
    }

    // Show percentage
    _ = buf.writeStr(x + bar_width + 1, cy, pct_str, Style{ .fg = Color.white });

    cy += 2;
    _ = buf.writeStr(x, cy, "Spinner: ", Style{ .fg = Color.yellow });

    // Animated spinner
    const spinner_chars = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const frame = spinner_chars[spinner_frame % spinner_chars.len];
    _ = buf.writeStr(x + 9, cy, frame, Style{ .fg = Color.cyan });
    _ = buf.writeStr(x + 12, cy, "Loading...", Style{ .fg = Color.gray });

    cy += 2;
    _ = buf.writeStr(x, cy, "Indeterminate:", Style{ .fg = Color.yellow });
    cy += 1;

    // Simple indeterminate animation
    const pulse_pos = (spinner_frame * 2) % @as(usize, bar_width);
    var i: u16 = 0;
    while (i < bar_width) : (i += 1) {
        const dist = if (i >= pulse_pos) i - @as(u16, @intCast(pulse_pos)) else @as(u16, @intCast(pulse_pos)) - i;
        const in_pulse = dist < 5;
        const char: u21 = if (in_pulse) '█' else '░';
        const style = if (in_pulse)
            Style{ .fg = Color.blue }
        else
            Style{ .fg = Color.gray };
        buf.setChar(x + i, cy, char, style);
    }
}

fn renderTabsDemo(buf: *Buffer, x: u16, y: u16, width: u16) void {
    _ = buf.writeTruncated(x, y, width, "Tabs Demo", boldFg(Color.green));
    _ = buf.writeTruncated(x, y + 1, width, "Left/Right: Switch tabs | Up/Down: Style", Style{ .fg = Color.gray });

    var cy = y + 3;

    const style_names = [_][]const u8{ "Simple", "Rounded", "Underline" };
    const style_name = if (tabs_style_idx < style_names.len) style_names[tabs_style_idx] else "Unknown";
    _ = buf.writeStr(x, cy, "Tab Style: ", Style{ .fg = Color.yellow });
    _ = buf.writeStr(x + 11, cy, style_name, Style{ .fg = Color.bright_white });
    cy += 2;

    const tab_titles = [_][]const u8{ "Home", "Settings", "Profile", "Help" };

    // Draw tabs based on style
    var tx = x;
    for (tab_titles, 0..) |title, i| {
        const is_selected = i == tabs_selected;

        switch (tabs_style_idx) {
            0 => {
                // Simple: │ Tab1 │ Tab2 │
                buf.setChar(tx, cy, '│', Style{ .fg = Color.gray });
                tx += 1;
                const style = if (is_selected)
                    Style{ .fg = Color.black, .bg = Color.white, .attrs = .{ .bold = true } }
                else
                    Style{ .fg = Color.white };
                buf.setChar(tx, cy, ' ', style);
                tx += 1;
                _ = buf.writeStr(tx, cy, title, style);
                tx += @intCast(title.len);
                buf.setChar(tx, cy, ' ', style);
                tx += 1;
            },
            1 => {
                // Rounded: ╭─Tab1─╮╭─Tab2─╮
                const corner_l: u21 = if (is_selected) '╭' else '┌';
                const corner_r: u21 = if (is_selected) '╮' else '┐';
                buf.setChar(tx, cy, corner_l, Style{ .fg = Color.gray });
                tx += 1;
                buf.setChar(tx, cy, '─', Style{ .fg = Color.gray });
                tx += 1;
                const style = if (is_selected)
                    Style{ .fg = Color.black, .bg = Color.white, .attrs = .{ .bold = true } }
                else
                    Style{ .fg = Color.white };
                _ = buf.writeStr(tx, cy, title, style);
                tx += @intCast(title.len);
                buf.setChar(tx, cy, '─', Style{ .fg = Color.gray });
                tx += 1;
                buf.setChar(tx, cy, corner_r, Style{ .fg = Color.gray });
                tx += 1;
            },
            2 => {
                // Underline: Tab1  Tab2
                const style = if (is_selected)
                    Style{ .fg = Color.bright_white, .attrs = .{ .bold = true } }
                else
                    Style{ .fg = Color.gray };
                _ = buf.writeStr(tx, cy, title, style);
                if (is_selected) {
                    // Draw underline
                    var ui: u16 = 0;
                    while (ui < title.len) : (ui += 1) {
                        buf.setChar(tx + ui, cy + 1, '─', Style{ .fg = Color.cyan });
                    }
                }
                tx += @intCast(title.len);
                tx += 2; // spacing
            },
            else => {},
        }
    }

    // Final separator for simple style
    if (tabs_style_idx == 0) {
        buf.setChar(tx, cy, '│', Style{ .fg = Color.gray });
    }

    // Draw tab content
    cy += 3;
    buf.drawBorder(Rect{ .x = x, .y = cy, .width = width, .height = 6 }, .single, Style{ .fg = Color.cyan });
    cy += 1;

    const tab_contents = [_][]const u8{
        "Welcome to the Home tab!",
        "Configure your settings here.",
        "View and edit your profile.",
        "Need help? Check our docs.",
    };

    if (tabs_selected < tab_contents.len) {
        const content = tab_contents[tabs_selected];
        _ = buf.writeTruncated(x + 2, cy, width - 4, content, Style{ .fg = Color.white });
    }

    cy += 2;
    _ = buf.writeStr(x + 2, cy, "Tab ", Style{ .fg = Color.gray });
    var num_buf: [4]u8 = undefined;
    const num_str = formatNumber(&num_buf, @intCast(tabs_selected + 1));
    _ = buf.writeStr(x + 6, cy, num_str, Style{ .fg = Color.bright_white });
    _ = buf.writeStr(x + 7, cy, " of 4", Style{ .fg = Color.gray });
}

fn renderFileBrowserDemo(buf: *Buffer, x: u16, y: u16, width: u16, height: u16) void {
    _ = buf.writeTruncated(x, y, width, "File Browser Demo", boldFg(Color.green));
    _ = buf.writeTruncated(x, y + 1, width, "Up/Down: Navigate | Enter: Open | Backspace: Up | H: Hidden", Style{ .fg = Color.gray });

    // Initialize with current directory on first render
    if (!fb_initialized) {
        initFileBrowser();
    }

    var cy = y + 3;

    // Draw path header
    const path_style = Style{ .fg = Color.yellow, .attrs = .{ .bold = true } };
    _ = buf.writeStr(x, cy, " ", path_style);
    if (fb_path_len > 0) {
        const display_path = fb_current_path[0..fb_path_len];
        const max_path_width = if (width > 4) width - 4 else width;
        if (display_path.len > max_path_width) {
            // Show end of path with ellipsis
            _ = buf.writeStr(x + 2, cy, "...", Style{ .fg = Color.yellow });
            const start = display_path.len - (max_path_width - 3);
            _ = buf.writeTruncated(x + 5, cy, max_path_width - 3, display_path[start..], path_style);
        } else {
            _ = buf.writeTruncated(x + 2, cy, max_path_width, display_path, path_style);
        }
    }
    cy += 1;

    // Draw separator
    buf.hLine(x, cy, width, '─', Style{ .fg = Color.gray });
    cy += 1;

    // Calculate visible area
    const list_height = if (height > 6) height - 6 else 4;

    // Ensure scroll keeps selection visible
    if (fb_selected < fb_scroll) {
        fb_scroll = fb_selected;
    } else if (fb_selected >= fb_scroll + list_height) {
        fb_scroll = fb_selected - list_height + 1;
    }

    // Draw file entries
    var row: u16 = 0;
    while (row < list_height) : (row += 1) {
        const entry_idx = fb_scroll + row;
        if (entry_idx >= fb_entry_count) break;

        const entry = fb_entries[entry_idx];
        const is_selected = entry_idx == fb_selected;

        // Determine style based on entry type
        var style: Style = undefined;
        var icon: []const u8 = undefined;

        if (entry.name_len == 2 and entry.name[0] == '.' and entry.name[1] == '.') {
            icon = " ";
            style = Style{ .fg = Color.blue, .attrs = .{ .bold = true } };
        } else if (entry.is_dir) {
            icon = " ";
            style = Style{ .fg = Color.blue, .attrs = .{ .bold = true } };
        } else if (entry.is_hidden) {
            icon = " ";
            style = Style{ .fg = Color.gray };
        } else {
            icon = " ";
            style = Style{ .fg = Color.white };
        }

        if (is_selected) {
            style = Style{ .fg = Color.black, .bg = Color.cyan };
            // Fill background
            buf.fill(
                Rect{ .x = x, .y = cy + row, .width = width, .height = 1 },
                tui.Cell.styled(' ', style),
            );
        }

        // Draw icon and name
        _ = buf.writeStr(x, cy + row, icon, style);
        const name_slice = entry.name[0..entry.name_len];
        const name_width = if (width > 3) width - 3 else width;
        _ = buf.writeTruncated(x + 2, cy + row, name_width, name_slice, style);
    }

    // Draw scrollbar if needed
    if (fb_entry_count > list_height) {
        const scrollbar_x = x + width - 1;
        var sy: u16 = 0;
        while (sy < list_height) : (sy += 1) {
            buf.setChar(scrollbar_x, cy + sy, '│', Style{ .fg = Color.gray });
        }
        // Thumb position
        const thumb_pos: u16 = @intCast((fb_scroll * list_height) / fb_entry_count);
        buf.setChar(scrollbar_x, cy + thumb_pos, '┃', Style{ .fg = Color.white });
    }

    // Draw footer info
    const footer_y = y + height - 1;
    var count_buf: [32]u8 = undefined;
    const count_str = formatNumber(&count_buf, @as(u32, @intCast(fb_entry_count)));
    _ = buf.writeStr(x, footer_y, " ", Style{ .fg = Color.gray });
    _ = buf.writeStr(x + 2, footer_y, count_str, Style{ .fg = Color.bright_white });
    _ = buf.writeStr(x + 2 + @as(u16, @intCast(count_str.len)), footer_y, " items", Style{ .fg = Color.gray });

    // Show hidden toggle state
    const hidden_x = x + 15;
    _ = buf.writeStr(hidden_x, footer_y, "Hidden: ", Style{ .fg = Color.gray });
    if (fb_show_hidden) {
        _ = buf.writeStr(hidden_x + 8, footer_y, "ON", Style{ .fg = Color.green });
    } else {
        _ = buf.writeStr(hidden_x + 8, footer_y, "OFF", Style{ .fg = Color.red });
    }
}

fn renderCommandPaletteDemo(buf: *Buffer, x: u16, y: u16, width: u16, height: u16) void {
    _ = buf.writeTruncated(x, y, width, "Command Palette Demo", boldFg(Color.green));
    _ = buf.writeTruncated(x, y + 1, width, "Press Ctrl+P or Space to open | Type to search", Style{ .fg = Color.gray });

    // Initialize filter on first render
    if (cp_filtered_count == 0 and !cp_visible) {
        cpUpdateFilter();
    }

    var cy = y + 3;

    if (!cp_visible) {
        // Show instructions
        _ = buf.writeStr(x, cy, "Command Palette is hidden.", Style{ .fg = Color.white });
        cy += 2;
        _ = buf.writeStr(x, cy, "Press ", Style{ .fg = Color.gray });
        _ = buf.writeStr(x + 6, cy, "Space", Style{ .fg = Color.cyan, .attrs = .{ .bold = true } });
        _ = buf.writeStr(x + 11, cy, " or ", Style{ .fg = Color.gray });
        _ = buf.writeStr(x + 15, cy, "Ctrl+P", Style{ .fg = Color.cyan, .attrs = .{ .bold = true } });
        _ = buf.writeStr(x + 21, cy, " to open it.", Style{ .fg = Color.gray });

        cy += 3;
        if (cp_last_executed) |cmd_idx| {
            _ = buf.writeStr(x, cy, "Last executed: ", Style{ .fg = Color.yellow });
            const cmd = cp_commands[cmd_idx];
            _ = buf.writeStr(x + 15, cy, cmd.category, Style{ .fg = Color.gray });
            _ = buf.writeStr(x + 15 + @as(u16, @intCast(cmd.category.len)), cy, ": ", Style{ .fg = Color.gray });
            _ = buf.writeTruncated(x + 17 + @as(u16, @intCast(cmd.category.len)), cy, width - 17 - @as(u16, @intCast(cmd.category.len)), cmd.label, Style{ .fg = Color.bright_white });
        }
        return;
    }

    // Draw palette overlay
    const palette_width: u16 = @min(50, width);
    const palette_height: u16 = @min(12, height - 2);
    const palette_x = x + (width - palette_width) / 2;
    const palette_y = y + 2;

    // Draw background
    buf.fill(
        Rect{ .x = palette_x, .y = palette_y, .width = palette_width, .height = palette_height },
        tui.Cell.styled(' ', Style{ .bg = Color.bright_black }),
    );

    // Draw border
    buf.drawBorder(
        Rect{ .x = palette_x, .y = palette_y, .width = palette_width, .height = palette_height },
        .rounded,
        Style{ .fg = Color.cyan },
    );

    // Draw search icon and input
    const input_y = palette_y + 1;
    buf.setChar(palette_x + 2, input_y, '>', Style{ .fg = Color.cyan, .attrs = .{ .bold = true } });

    // Draw query or placeholder
    if (cp_query_len == 0) {
        _ = buf.writeTruncated(palette_x + 4, input_y, palette_width - 6, "Type to search commands...", Style{ .fg = Color.gray });
    } else {
        _ = buf.writeTruncated(palette_x + 4, input_y, palette_width - 6, cp_query[0..cp_query_len], Style{ .fg = Color.white });
    }

    // Draw cursor
    const cursor_x = palette_x + 4 + @as(u16, @intCast(cp_query_len));
    if (cursor_x < palette_x + palette_width - 2) {
        buf.setChar(cursor_x, input_y, '_', Style{ .fg = Color.white, .attrs = .{ .bold = true } });
    }

    // Draw separator
    buf.hLine(palette_x + 1, input_y + 1, palette_width - 2, '─', Style{ .fg = Color.cyan });

    // Draw results
    const results_y = input_y + 2;
    const max_results = palette_height - 4;

    var row: u16 = 0;
    while (row < max_results) : (row += 1) {
        if (row >= cp_filtered_count) break;

        const cmd_idx = cp_filtered[row];
        const cmd = cp_commands[cmd_idx];
        const is_selected = row == cp_selected;

        const row_y = results_y + row;
        const style = if (is_selected)
            Style{ .fg = Color.black, .bg = Color.cyan }
        else
            Style{ .fg = Color.white };

        // Fill row if selected
        if (is_selected) {
            buf.fill(
                Rect{ .x = palette_x + 1, .y = row_y, .width = palette_width - 2, .height = 1 },
                tui.Cell.styled(' ', style),
            );
        }

        var rx = palette_x + 2;

        // Draw category
        _ = buf.writeStr(rx, row_y, cmd.category, if (is_selected) style else Style{ .fg = Color.gray });
        rx += @intCast(cmd.category.len);
        _ = buf.writeStr(rx, row_y, ": ", if (is_selected) style else Style{ .fg = Color.gray });
        rx += 2;

        // Draw label
        const label_width = palette_width - (rx - palette_x) - 2;
        _ = buf.writeTruncated(rx, row_y, label_width, cmd.label, style);

        // Draw shortcut on right
        if (cmd.shortcut) |shortcut| {
            const shortcut_x = palette_x + palette_width - @as(u16, @intCast(shortcut.len)) - 3;
            if (shortcut_x > rx + cmd.label.len) {
                _ = buf.writeStr(shortcut_x, row_y, shortcut, if (is_selected) style else Style{ .fg = Color.gray });
            }
        }
    }

    // Draw result count
    const count_y = palette_y + palette_height - 1;
    var count_buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, " {d} commands ", .{cp_filtered_count}) catch " ? ";
    _ = buf.writeStr(palette_x + 2, count_y, count_str, Style{ .fg = Color.gray });
}

fn cpUpdateFilter() void {
    cp_filtered_count = 0;
    cp_selected = 0;

    const query = cp_query[0..cp_query_len];

    for (cp_commands, 0..) |cmd, i| {
        if (cp_filtered_count >= cp_filtered.len) break;

        if (query.len == 0) {
            // Show all commands
            cp_filtered[cp_filtered_count] = i;
            cp_filtered_count += 1;
        } else {
            // Fuzzy match on label or category
            if (cpFuzzyMatch(cmd.label, query) or cpFuzzyMatch(cmd.category, query)) {
                cp_filtered[cp_filtered_count] = i;
                cp_filtered_count += 1;
            }
        }
    }
}

fn cpFuzzyMatch(haystack: []const u8, needle: []const u8) bool {
    var needle_idx: usize = 0;
    for (haystack) |c| {
        if (needle_idx >= needle.len) break;
        const nc = needle[needle_idx];
        if (std.ascii.toLower(c) == std.ascii.toLower(nc)) {
            needle_idx += 1;
        }
    }
    return needle_idx == needle.len;
}

fn cpExecuteSelected() void {
    if (cp_selected < cp_filtered_count) {
        cp_last_executed = cp_filtered[cp_selected];
        cp_visible = false;
        cp_query_len = 0;
        @memset(&cp_query, 0);
    }
}

fn renderStatusBarDemo(buf: *Buffer, x: u16, y: u16, width: u16, height: u16) void {
    _ = height;
    _ = buf.writeTruncated(x, y, width, "Status Bar Demo", boldFg(Color.green));
    _ = buf.writeTruncated(x, y + 1, width, "Left/Right: Change values | Up/Down: Cycle options | Space: Toggle", Style{ .fg = Color.gray });

    var cy = y + 3;

    // Instructions panel
    _ = buf.writeStr(x, cy, "Interact with the status bar below:", Style{ .fg = Color.white });
    cy += 2;

    // Current settings
    _ = buf.writeStr(x, cy, "Mode: ", Style{ .fg = Color.yellow });
    const mode = sb_modes[sb_mode_idx];
    const mode_style = switch (sb_mode_idx) {
        0 => Style{ .fg = Color.black, .bg = Color.green, .attrs = .{ .bold = true } }, // NORMAL
        1 => Style{ .fg = Color.black, .bg = Color.blue, .attrs = .{ .bold = true } }, // INSERT
        2 => Style{ .fg = Color.black, .bg = Color.magenta, .attrs = .{ .bold = true } }, // VISUAL
        3 => Style{ .fg = Color.black, .bg = Color.yellow, .attrs = .{ .bold = true } }, // COMMAND
        4 => Style{ .fg = Color.black, .bg = Color.red, .attrs = .{ .bold = true } }, // REPLACE
        else => Style{ .fg = Color.black, .bg = Color.cyan },
    };
    buf.setChar(x + 6, cy, ' ', mode_style);
    _ = buf.writeStr(x + 7, cy, mode, mode_style);
    buf.setChar(x + 7 + @as(u16, @intCast(mode.len)), cy, ' ', mode_style);
    cy += 1;

    // Filename
    _ = buf.writeStr(x, cy, "File: ", Style{ .fg = Color.yellow });
    if (sb_filenames[sb_filename_idx]) |fname| {
        _ = buf.writeTruncated(x + 6, cy, width - 6, fname, Style{ .fg = Color.white });
    } else {
        _ = buf.writeStr(x + 6, cy, "(no file)", Style{ .fg = Color.gray });
    }
    cy += 1;

    // Flags
    _ = buf.writeStr(x, cy, "Modified: ", Style{ .fg = Color.yellow });
    if (sb_modified) {
        _ = buf.writeStr(x + 10, cy, "Yes", Style{ .fg = Color.red, .attrs = .{ .bold = true } });
    } else {
        _ = buf.writeStr(x + 10, cy, "No", Style{ .fg = Color.green });
    }
    _ = buf.writeStr(x + 16, cy, "  Readonly: ", Style{ .fg = Color.yellow });
    if (sb_readonly) {
        _ = buf.writeStr(x + 28, cy, "Yes", Style{ .fg = Color.yellow, .attrs = .{ .bold = true } });
    } else {
        _ = buf.writeStr(x + 28, cy, "No", Style{ .fg = Color.green });
    }
    cy += 1;

    // Position info
    var pos_buf: [32]u8 = undefined;
    const pos_str = std.fmt.bufPrint(&pos_buf, "Line: {d}  Column: {d}  Scroll: {d}%", .{ sb_line, sb_column, sb_percentage }) catch "?";
    _ = buf.writeStr(x, cy, pos_str, Style{ .fg = Color.cyan });
    cy += 2;

    // Controls help
    _ = buf.writeStr(x, cy, "Controls:", Style{ .fg = Color.yellow, .attrs = .{ .bold = true } });
    cy += 1;
    _ = buf.writeStr(x, cy, "  Up/Down    Cycle mode", Style{ .fg = Color.gray });
    cy += 1;
    _ = buf.writeStr(x, cy, "  Left/Right Change file", Style{ .fg = Color.gray });
    cy += 1;
    _ = buf.writeStr(x, cy, "  M          Toggle modified", Style{ .fg = Color.gray });
    cy += 1;
    _ = buf.writeStr(x, cy, "  R          Toggle readonly", Style{ .fg = Color.gray });
    cy += 1;
    _ = buf.writeStr(x, cy, "  +/-        Adjust line", Style{ .fg = Color.gray });
    cy += 1;
    _ = buf.writeStr(x, cy, "  Space      Show message", Style{ .fg = Color.gray });
    cy += 2;

    // Draw example status bars
    _ = buf.writeStr(x, cy, "Example Status Bars:", Style{ .fg = Color.white, .attrs = .{ .bold = true } });
    cy += 1;

    // Status bar style 1: Editor-like
    const bar_width = @min(width, 60);
    const bar_y = cy;

    // Background
    buf.fill(
        Rect{ .x = x, .y = bar_y, .width = bar_width, .height = 1 },
        tui.Cell.styled(' ', Style{ .fg = Color.black, .bg = Color.white }),
    );

    // Mode indicator
    var bar_x = x;
    buf.setChar(bar_x, bar_y, ' ', mode_style);
    bar_x += 1;
    _ = buf.writeStr(bar_x, bar_y, mode, mode_style);
    bar_x += @intCast(mode.len);
    buf.setChar(bar_x, bar_y, ' ', mode_style);
    bar_x += 1;

    // Separator
    _ = buf.writeStr(bar_x, bar_y, " | ", Style{ .fg = Color.gray, .bg = Color.white });
    bar_x += 3;

    // Filename
    if (sb_filenames[sb_filename_idx]) |fname| {
        const display_name = if (fname.len > 20) fname[fname.len - 20 ..] else fname;
        _ = buf.writeStr(bar_x, bar_y, display_name, Style{ .fg = Color.black, .bg = Color.white });
        bar_x += @intCast(display_name.len);

        if (sb_modified) {
            _ = buf.writeStr(bar_x, bar_y, " [+]", Style{ .fg = Color.red, .bg = Color.white, .attrs = .{ .bold = true } });
            bar_x += 4;
        }
        if (sb_readonly) {
            _ = buf.writeStr(bar_x, bar_y, " [RO]", Style{ .fg = Color.yellow, .bg = Color.white });
            bar_x += 5;
        }
    }

    // Right side: position and filetype
    var right_buf: [40]u8 = undefined;
    const right_str = std.fmt.bufPrint(&right_buf, "Ln {d}, Col {d} | {d}%", .{ sb_line, sb_column, sb_percentage }) catch "?";
    const right_x = x + bar_width - @as(u16, @intCast(right_str.len)) - 1;
    _ = buf.writeStr(right_x, bar_y, right_str, Style{ .fg = Color.black, .bg = Color.white });

    // Show message if active
    if (sb_show_message) {
        const msg = "File saved successfully!";
        const msg_x = x + (bar_width - @as(u16, @intCast(msg.len))) / 2;
        _ = buf.writeStr(msg_x, bar_y, msg, Style{ .fg = Color.green, .bg = Color.white, .attrs = .{ .bold = true } });
    }

    cy += 2;

    // Status bar style 2: Minimal
    buf.fill(
        Rect{ .x = x, .y = cy, .width = bar_width, .height = 1 },
        tui.Cell.styled(' ', Style{ .fg = Color.white, .bg = Color.bright_black }),
    );

    // Just filename and position
    bar_x = x + 1;
    if (sb_filenames[sb_filename_idx]) |fname| {
        _ = buf.writeStr(bar_x, cy, fname, Style{ .fg = Color.bright_white, .bg = Color.bright_black });
        bar_x += @intCast(fname.len);
        if (sb_modified) {
            _ = buf.writeStr(bar_x, cy, " *", Style{ .fg = Color.red, .bg = Color.bright_black });
        }
    }

    var min_buf: [20]u8 = undefined;
    const min_str = std.fmt.bufPrint(&min_buf, "{d}:{d}", .{ sb_line, sb_column }) catch "?";
    const min_x = x + bar_width - @as(u16, @intCast(min_str.len)) - 1;
    _ = buf.writeStr(min_x, cy, min_str, Style{ .fg = Color.cyan, .bg = Color.bright_black });
}

fn initFileBrowser() void {
    // Start at project directory
    const start_path = ".";
    @memcpy(fb_current_path[0..start_path.len], start_path);
    fb_path_len = start_path.len;
    refreshFileBrowser();
    fb_initialized = true;
}

// Linux dirent64 structure
const linux_dirent64 = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    // d_name follows (null-terminated)
};

fn refreshFileBrowser() void {
    fb_entry_count = 0;
    fb_selected = 0;
    fb_scroll = 0;

    // Add parent directory entry if not at root
    if (fb_path_len > 1) {
        var entry = &fb_entries[fb_entry_count];
        entry.name[0] = '.';
        entry.name[1] = '.';
        entry.name_len = 2;
        entry.is_dir = true;
        entry.is_hidden = false;
        fb_entry_count += 1;
    }

    // Open directory using posix API
    var path_z: [513]u8 = undefined;
    @memcpy(path_z[0..fb_path_len], fb_current_path[0..fb_path_len]);
    path_z[fb_path_len] = 0;

    const fd = std.posix.openat(std.posix.AT.FDCWD, path_z[0..fb_path_len :0], .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
    }, 0) catch {
        return;
    };
    defer _ = std.c.close(fd);

    // Read directory entries using getdents64 syscall
    var buf: [4096]u8 = undefined;
    var dir_count: usize = fb_entry_count;
    const file_start: usize = fb_entries.len / 2;
    var file_count: usize = 0;

    while (true) {
        const nread = std.os.linux.getdents64(fd, &buf, buf.len);
        if (nread == 0) break;
        if (nread > buf.len) break; // Error

        var bpos: usize = 0;
        while (bpos < nread) {
            const d: *align(1) const linux_dirent64 = @ptrCast(&buf[bpos]);
            const name_ptr: [*]const u8 = @ptrCast(&buf[bpos + 19]);
            const name_len = std.mem.indexOfScalar(u8, name_ptr[0 .. d.d_reclen - 19], 0) orelse (d.d_reclen - 19);

            if (name_len > 0 and name_len <= 255) {
                const name = name_ptr[0..name_len];

                // Skip . and ..
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
                    bpos += d.d_reclen;
                    continue;
                }

                const is_hidden = name[0] == '.';
                if (is_hidden and !fb_show_hidden) {
                    bpos += d.d_reclen;
                    continue;
                }

                const is_dir = d.d_type == 4; // DT_DIR

                if (is_dir) {
                    if (dir_count < file_start) {
                        var entry = &fb_entries[dir_count];
                        @memcpy(entry.name[0..name_len], name);
                        entry.name_len = name_len;
                        entry.is_dir = true;
                        entry.is_hidden = is_hidden;
                        dir_count += 1;
                    }
                } else {
                    if (file_start + file_count < fb_entries.len) {
                        var entry = &fb_entries[file_start + file_count];
                        @memcpy(entry.name[0..name_len], name);
                        entry.name_len = name_len;
                        entry.is_dir = false;
                        entry.is_hidden = is_hidden;
                        file_count += 1;
                    }
                }
            }
            bpos += d.d_reclen;
        }
    }

    // Sort directories (simple bubble sort for demo)
    sortEntries(fb_entries[fb_entry_count..dir_count]);
    sortEntries(fb_entries[file_start .. file_start + file_count]);

    // Move files after directories
    var final_count = dir_count;
    for (0..file_count) |i| {
        if (final_count >= fb_entries.len) break;
        fb_entries[final_count] = fb_entries[file_start + i];
        final_count += 1;
    }
    fb_entry_count = final_count;
}

fn sortEntries(entries: []FbEntry) void {
    if (entries.len < 2) return;

    var i: usize = 0;
    while (i < entries.len - 1) : (i += 1) {
        var j: usize = 0;
        while (j < entries.len - 1 - i) : (j += 1) {
            const a = entries[j].name[0..entries[j].name_len];
            const b = entries[j + 1].name[0..entries[j + 1].name_len];
            if (std.mem.order(u8, a, b) == .gt) {
                const tmp = entries[j];
                entries[j] = entries[j + 1];
                entries[j + 1] = tmp;
            }
        }
    }
}

fn fbNavigateUp() void {
    if (fb_path_len <= 1) return;

    // Find last separator
    var i = fb_path_len - 1;
    while (i > 0 and fb_current_path[i] != '/') : (i -= 1) {}

    fb_path_len = if (i == 0) 1 else i;
    refreshFileBrowser();
}

fn fbOpenSelected() void {
    if (fb_selected >= fb_entry_count) return;

    const entry = fb_entries[fb_selected];
    if (!entry.is_dir) return; // Only navigate into directories

    // Check for parent directory
    if (entry.name_len == 2 and entry.name[0] == '.' and entry.name[1] == '.') {
        fbNavigateUp();
        return;
    }

    // Build new path
    const name_slice = entry.name[0..entry.name_len];
    const new_len = fb_path_len + 1 + name_slice.len;
    if (new_len >= fb_current_path.len) return;

    // Add separator if not at root
    if (fb_path_len > 0 and fb_current_path[fb_path_len - 1] != '/') {
        fb_current_path[fb_path_len] = '/';
        fb_path_len += 1;
    }

    @memcpy(fb_current_path[fb_path_len..][0..name_slice.len], name_slice);
    fb_path_len += name_slice.len;

    refreshFileBrowser();
}

fn renderColorsTest(buf: *Buffer, x: u16, y: u16, width: u16) void {
    _ = buf.writeTruncated(x, y, width, "Colors Test", boldFg(Color.green));
    _ = buf.writeTruncated(x, y + 1, width, "Use Left/Right arrows to select", Style{ .fg = Color.gray });

    // 16 standard colors - interactive selection
    var cy = y + 3;
    const color_row_indicator = if (colors_row == 0) "> " else "  ";
    _ = buf.writeStr(x, cy, color_row_indicator, Style{ .fg = Color.bright_white });
    _ = buf.writeTruncated(x + 2, cy, if (width > 2) width - 2 else 0, "Standard colors:", Style{ .fg = Color.white });
    cy += 1;

    const colors = [_]Color{
        Color.black,         Color.red,           Color.green,        Color.yellow,
        Color.blue,          Color.magenta,       Color.cyan,         Color.white,
        Color.bright_black,  Color.bright_red,    Color.bright_green, Color.bright_yellow,
        Color.bright_blue,   Color.bright_magenta,Color.bright_cyan,  Color.bright_white,
    };

    const color_names = [_][]const u8{
        "Black", "Red", "Green", "Yellow",
        "Blue", "Magenta", "Cyan", "White",
        "BrightBlack", "BrightRed", "BrightGreen", "BrightYellow",
        "BrightBlue", "BrightMagenta", "BrightCyan", "BrightWhite",
    };

    var cx = x + 2; // Offset for row indicator
    for (colors, 0..) |color, i| {
        const is_selected = colors_row == 0 and i == color_selection;
        // Draw selection indicator
        if (is_selected) {
            buf.setChar(cx, cy, '[', Style{ .fg = Color.bright_white });
        }
        buf.setChar(cx + @as(u16, if (is_selected) @as(u16, 1) else @as(u16, 0)), cy, ' ', Style{ .bg = color });
        buf.setChar(cx + @as(u16, if (is_selected) @as(u16, 2) else @as(u16, 1)), cy, ' ', Style{ .bg = color });
        if (is_selected) {
            buf.setChar(cx + 3, cy, ']', Style{ .fg = Color.bright_white });
        }
        cx += 4;
        if ((i + 1) % 8 == 0) {
            cy += 1;
            cx = x + 2;
        }
    }

    // Show selected color name
    cy += 1;
    const selected_name = if (color_selection < color_names.len) color_names[color_selection] else "Unknown";
    _ = buf.writeStr(x, cy, "Selected: ", Style{ .fg = Color.yellow });
    const max_name_width = if (width > 12) width - 12 else width;
    _ = buf.writeTruncated(x + 10, cy, max_name_width, selected_name, Style{ .fg = colors[color_selection] });

    cy += 2;
    _ = buf.writeTruncated(x, cy, width, "RGB gradient:", Style{ .fg = Color.white });
    cy += 1;

    const gradient_width: u8 = @intCast(@min(width, 32));
    var i: u8 = 0;
    while (i < gradient_width) : (i += 1) {
        const r = if (gradient_width > 0) i * (255 / gradient_width) else 0;
        const g: u8 = 64;
        const b: u8 = if (gradient_width > 0) 255 - i * (255 / gradient_width) else 255;
        buf.setChar(x + i, cy, ' ', Style{ .bg = Color.fromRgb(r, g, b) });
    }

    cy += 2;
    const attr_row_indicator = if (colors_row == 1) "> " else "  ";
    _ = buf.writeStr(x, cy, attr_row_indicator, Style{ .fg = Color.bright_white });
    _ = buf.writeTruncated(x + 2, cy, if (width > 2) width - 2 else 0, "Attributes (Up/Down to switch):", Style{ .fg = Color.white });
    cy += 1;

    // Attribute options with selection
    const attr_names = [_][]const u8{ "Bold", "Dim", "Italic", "Underline", "Strikethrough", "Reverse" };
    const attr_styles = [_]Style{
        Style{ .fg = Color.white, .attrs = .{ .bold = true } },
        Style{ .fg = Color.white, .attrs = .{ .dim = true } },
        Style{ .fg = Color.white, .attrs = .{ .italic = true } },
        Style{ .fg = Color.white, .attrs = .{ .underline = true } },
        Style{ .fg = Color.white, .attrs = .{ .strikethrough = true } },
        Style{ .fg = Color.white, .attrs = .{ .reverse = true } },
    };

    var ax = x + 2; // Offset for row indicator
    for (attr_names, 0..) |name, ai| {
        const is_selected = colors_row == 1 and ai == attr_selection;
        if (is_selected) {
            buf.setChar(ax, cy, '[', Style{ .fg = Color.bright_cyan });
        }
        const offset: u16 = if (is_selected) 1 else 0;
        _ = buf.writeStr(ax + offset, cy, name, attr_styles[ai]);
        if (is_selected) {
            buf.setChar(ax + offset + @as(u16, @intCast(name.len)), cy, ']', Style{ .fg = Color.bright_cyan });
        }
        ax += @as(u16, @intCast(name.len)) + 2 + (if (is_selected) @as(u16, 2) else @as(u16, 0));
        if (ax > x + width - 10) {
            cy += 1;
            ax = x + 2;
        }
    }

    // Show current selection
    cy += 2;
    _ = buf.writeStr(x, cy, "Active: ", Style{ .fg = Color.yellow });
    if (attr_selection < attr_names.len) {
        _ = buf.writeStr(x + 8, cy, attr_names[attr_selection], attr_styles[attr_selection]);
    }
}

fn handleEvent(event: Event) bool {
    switch (event) {
        .key => |k| {
            // Global quit
            if (k.isCtrlC()) return false;

            switch (k.key) {
                .char => |c| {
                    if (c == 'q' or c == 'Q') {
                        return false;
                    }

                    // Counter increment with space (use 0x20 explicitly)
                    if (selected_item == 0 and c == 0x20) {
                        counter += 1;
                        return true;
                    }

                    // Checkbox toggle with space
                    if (selected_item == 4 and c == 0x20) {
                        // Toggle all checkboxes for demo
                        for (&checkbox_states) |*state| {
                            state.* = !state.*;
                        }
                        return true;
                    }

                    // Text input mode - handle printable characters
                    if (selected_item == 1) {
                        if (c >= 0x20 and c < 0x7F and input_len < input_text.len - 1) {
                            input_text[input_len] = @intCast(c);
                            input_len += 1;
                        }
                    }

                    // File browser - toggle hidden files with 'h'
                    if (selected_item == 7 and (c == 'h' or c == 'H')) {
                        fb_show_hidden = !fb_show_hidden;
                        refreshFileBrowser();
                        return true;
                    }

                    // Command palette handling
                    if (selected_item == 8) {
                        if (cp_visible) {
                            // Add character to query
                            if (c >= 0x20 and c < 0x7F and cp_query_len < cp_query.len - 1) {
                                cp_query[cp_query_len] = @intCast(c);
                                cp_query_len += 1;
                                cpUpdateFilter();
                            }
                            return true;
                        } else if (c == 0x20) {
                            // Space to open palette
                            cp_visible = true;
                            cpUpdateFilter();
                            return true;
                        }
                    }

                    // Status bar handling
                    if (selected_item == 9) {
                        if (c == 'm' or c == 'M') {
                            sb_modified = !sb_modified;
                            return true;
                        }
                        if (c == 'r' or c == 'R') {
                            sb_readonly = !sb_readonly;
                            return true;
                        }
                        if (c == '+' or c == '=') {
                            sb_line +|= 1;
                            return true;
                        }
                        if (c == '-' or c == '_') {
                            if (sb_line > 1) sb_line -= 1;
                            return true;
                        }
                        if (c == 0x20) {
                            // Space to show message
                            sb_show_message = !sb_show_message;
                            return true;
                        }
                    }
                },
                .special => |s| switch (s) {
                    .escape => {
                        // Command palette: close on escape
                        if (selected_item == 8 and cp_visible) {
                            cp_visible = false;
                            cp_query_len = 0;
                            @memset(&cp_query, 0);
                            return true;
                        }
                        return false;
                    },
                    .up => {
                        if (selected_item == 2) {
                            // List demo: navigate up
                            if (list_selected > 0) list_selected -= 1;
                        } else if (selected_item == 3) {
                            // Table demo: navigate up
                            if (table_selected > 0) table_selected -= 1;
                        } else if (selected_item == 4) {
                            // Checkbox demo: navigate radio options
                            if (radio_selected > 0) radio_selected -= 1;
                        } else if (selected_item == 5) {
                            // Progress demo: change style
                            if (progress_style_idx > 0) progress_style_idx -= 1;
                        } else if (selected_item == 6) {
                            // Tabs demo: change tab style
                            if (tabs_style_idx > 0) tabs_style_idx -= 1;
                        } else if (selected_item == 7) {
                            // File browser: navigate up
                            if (fb_selected > 0) fb_selected -= 1;
                        } else if (selected_item == 8) {
                            // Command palette: navigate up
                            if (cp_visible and cp_selected > 0) cp_selected -= 1;
                        } else if (selected_item == 9) {
                            // Status bar: cycle mode up
                            if (sb_mode_idx > 0) sb_mode_idx -= 1;
                        } else if (selected_item == 10) {
                            // Colors test: switch between color row and attribute row
                            if (colors_row > 0) colors_row -= 1;
                        } else {
                            if (selected_item > 0) selected_item -= 1;
                        }
                    },
                    .down => {
                        if (selected_item == 2) {
                            // List demo: navigate down
                            if (list_selected < list_items.len - 1) list_selected += 1;
                        } else if (selected_item == 3) {
                            // Table demo: navigate down
                            if (table_selected < table_data.len - 1) table_selected += 1;
                        } else if (selected_item == 4) {
                            // Checkbox demo: navigate radio options
                            if (radio_selected < 2) radio_selected += 1;
                        } else if (selected_item == 5) {
                            // Progress demo: change style
                            if (progress_style_idx < 3) progress_style_idx += 1;
                        } else if (selected_item == 6) {
                            // Tabs demo: change tab style
                            if (tabs_style_idx < 2) tabs_style_idx += 1;
                        } else if (selected_item == 7) {
                            // File browser: navigate down
                            if (fb_entry_count > 0 and fb_selected < fb_entry_count - 1) fb_selected += 1;
                        } else if (selected_item == 8) {
                            // Command palette: navigate down
                            if (cp_visible and cp_filtered_count > 0 and cp_selected < cp_filtered_count - 1) cp_selected += 1;
                        } else if (selected_item == 9) {
                            // Status bar: cycle mode down
                            if (sb_mode_idx < sb_modes.len - 1) sb_mode_idx += 1;
                        } else if (selected_item == 10) {
                            // Colors test: switch between color row and attribute row
                            if (colors_row < 1) colors_row += 1;
                        } else {
                            if (selected_item < menu_items.len - 1) selected_item += 1;
                        }
                    },
                    .left => {
                        if (selected_item == 5) {
                            // Progress demo: decrease value
                            progress_value = @max(0.0, progress_value - 0.05);
                        } else if (selected_item == 6) {
                            // Tabs demo: previous tab
                            if (tabs_selected > 0) tabs_selected -= 1;
                        } else if (selected_item == 9) {
                            // Status bar: previous file
                            if (sb_filename_idx > 0) sb_filename_idx -= 1;
                        } else if (selected_item == 10) {
                            // Colors test: navigate within current row
                            if (colors_row == 0) {
                                if (color_selection > 0) color_selection -= 1;
                            } else {
                                if (attr_selection > 0) attr_selection -= 1;
                            }
                        }
                    },
                    .right => {
                        if (selected_item == 5) {
                            // Progress demo: increase value
                            progress_value = @min(1.0, progress_value + 0.05);
                        } else if (selected_item == 6) {
                            // Tabs demo: next tab
                            if (tabs_selected < 3) tabs_selected += 1;
                        } else if (selected_item == 9) {
                            // Status bar: next file
                            if (sb_filename_idx < sb_filenames.len - 1) sb_filename_idx += 1;
                        } else if (selected_item == 10) {
                            // Colors test: navigate within current row
                            if (colors_row == 0) {
                                if (color_selection < 15) color_selection += 1;
                            } else {
                                if (attr_selection < 5) attr_selection += 1;
                            }
                        }
                    },
                    .enter => {
                        if (selected_item == 11) return false; // Exit
                        if (selected_item == 0) counter += 1;
                        if (selected_item == 7) fbOpenSelected(); // File browser: open dir
                        if (selected_item == 8 and cp_visible) {
                            // Command palette: execute command
                            cpExecuteSelected();
                            return true;
                        }
                    },
                    .backspace => {
                        if (selected_item == 1 and input_len > 0) {
                            input_len -= 1;
                        }
                        if (selected_item == 7) fbNavigateUp(); // File browser: go to parent
                        if (selected_item == 8 and cp_visible and cp_query_len > 0) {
                            // Command palette: delete character
                            cp_query_len -= 1;
                            cp_query[cp_query_len] = 0;
                            cpUpdateFilter();
                        }
                    },
                    .tab => {
                        // Tab to move between menu items even when in colors test
                        if (selected_item < menu_items.len - 1) {
                            selected_item += 1;
                            colors_row = 0; // Reset colors row
                        }
                    },
                    .backtab => {
                        // Shift+Tab to go back
                        if (selected_item > 0) {
                            selected_item -= 1;
                            colors_row = 0;
                        }
                    },
                    else => {},
                },
            }
        },
        .mouse => |m| {
            // Click on menu items
            if (m.kind == .press and m.button == .left) {
                if (m.x >= 4 and m.x < 28) {
                    const item_y = m.y -| 6;
                    if (item_y < menu_items.len) {
                        selected_item = item_y;
                    }
                }
            }
        },
        .resize => {
            // Handle resize
        },
        .tick => {
            // Advance spinner animation
            spinner_frame +%= 1;
        },
        else => {},
    }
    return true;
}

fn formatNumber(buf: []u8, n: u32) []const u8 {
    var val = n;
    var len: usize = 0;

    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    while (val > 0 and len < buf.len) {
        buf[len] = @intCast('0' + val % 10);
        val /= 10;
        len += 1;
    }

    // Reverse
    var i: usize = 0;
    while (i < len / 2) : (i += 1) {
        const tmp = buf[i];
        buf[i] = buf[len - 1 - i];
        buf[len - 1 - i] = tmp;
    }

    return buf[0..len];
}
