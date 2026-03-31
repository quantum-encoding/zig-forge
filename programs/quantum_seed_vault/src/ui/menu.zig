//! Menu System for Quantum Seed Vault
//!
//! Hierarchical menu navigation with state machine.

const std = @import("std");
const display = @import("../display.zig");
const input = @import("../input.zig");
const widgets = @import("widgets.zig");

const Framebuffer = display.Framebuffer;
const Theme = display.Theme;
const Colors = display.Colors;
const InputEvent = input.InputEvent;

/// Menu item action
pub const MenuAction = union(enum) {
    /// Navigate to another screen
    navigate: ScreenId,
    /// Execute a callback
    callback: *const fn () void,
    /// Submenu
    submenu: []const MenuItem,
    /// No action (informational item)
    none,
};

/// Menu item definition
pub const MenuItem = struct {
    label: []const u8,
    description: ?[]const u8,
    action: MenuAction,
    enabled: bool,
    icon: ?u8, // Character code for icon

    pub fn init(label: []const u8, action: MenuAction) MenuItem {
        return .{
            .label = label,
            .description = null,
            .action = action,
            .enabled = true,
            .icon = null,
        };
    }

    pub fn withDescription(self: MenuItem, desc: []const u8) MenuItem {
        var copy = self;
        copy.description = desc;
        return copy;
    }

    pub fn withIcon(self: MenuItem, icon: u8) MenuItem {
        var copy = self;
        copy.icon = icon;
        return copy;
    }

    pub fn disabled(self: MenuItem) MenuItem {
        var copy = self;
        copy.enabled = false;
        return copy;
    }
};

/// Screen identifiers
pub const ScreenId = enum {
    main_menu,
    create_seed,
    recover_seed,
    split_seed,
    combine_shares,
    view_shares,
    settings,
    about,
    confirm_exit,
    seed_display,
    share_input,
    share_output,
};

/// Dynamic submenu navigation context
pub const SubmenuContext = struct {
    items: []const MenuItem,
    parent_screen: ScreenId,
    depth: usize,
};

/// Menu state
pub const MenuState = struct {
    current_screen: ScreenId,
    selected_index: usize,
    scroll_offset: usize,
    history: [8]ScreenId,
    history_depth: usize,
    submenu: ?SubmenuContext,
    submenu_stack: [4]SubmenuContext,
    submenu_depth: usize,

    const Self = @This();
    const MAX_VISIBLE_ITEMS: usize = 8;

    pub fn init() Self {
        return .{
            .current_screen = .main_menu,
            .selected_index = 0,
            .scroll_offset = 0,
            .history = [_]ScreenId{.main_menu} ** 8,
            .history_depth = 0,
            .submenu = null,
            .submenu_stack = undefined,
            .submenu_depth = 0,
        };
    }

    pub fn navigateTo(self: *Self, screen: ScreenId) void {
        // Push current to history
        if (self.history_depth < self.history.len) {
            self.history[self.history_depth] = self.current_screen;
            self.history_depth += 1;
        }
        self.current_screen = screen;
        self.selected_index = 0;
        self.scroll_offset = 0;
        self.submenu = null;
    }

    /// Navigate to a submenu
    pub fn navigateToSubmenu(self: *Self, items: []const MenuItem) bool {
        if (self.submenu_depth >= self.submenu_stack.len) {
            return false; // Stack overflow
        }

        // Save current submenu on stack before navigating
        if (self.submenu) |current_submenu| {
            self.submenu_stack[self.submenu_depth] = current_submenu;
            self.submenu_depth += 1;
        }

        self.submenu = SubmenuContext{
            .items = items,
            .parent_screen = self.current_screen,
            .depth = self.submenu_depth,
        };

        self.selected_index = 0;
        self.scroll_offset = 0;
        return true;
    }

    /// Go back from submenu
    pub fn goBackFromSubmenu(self: *Self) bool {
        if (self.submenu_depth > 0) {
            self.submenu_depth -= 1;
            self.submenu = self.submenu_stack[self.submenu_depth];
            self.selected_index = 0;
            self.scroll_offset = 0;
            return true;
        }

        // No more submenus, clear submenu context
        self.submenu = null;
        self.selected_index = 0;
        self.scroll_offset = 0;
        return false;
    }

    pub fn goBack(self: *Self) bool {
        // First check if we're in a submenu
        if (self.submenu != null) {
            return self.goBackFromSubmenu();
        }

        // Then check regular navigation history
        if (self.history_depth > 0) {
            self.history_depth -= 1;
            self.current_screen = self.history[self.history_depth];
            self.selected_index = 0;
            self.scroll_offset = 0;
            return true;
        }
        return false;
    }

    pub fn moveUp(self: *Self, item_count: usize) void {
        if (item_count == 0) return;
        if (self.selected_index > 0) {
            self.selected_index -= 1;
            if (self.selected_index < self.scroll_offset) {
                self.scroll_offset = self.selected_index;
            }
        }
    }

    pub fn moveDown(self: *Self, item_count: usize) void {
        if (item_count == 0) return;
        if (self.selected_index < item_count - 1) {
            self.selected_index += 1;
            if (self.selected_index >= self.scroll_offset + MAX_VISIBLE_ITEMS) {
                self.scroll_offset = self.selected_index - MAX_VISIBLE_ITEMS + 1;
            }
        }
    }
};

/// Menu definitions for the application
pub const Menus = struct {
    pub const main_menu = [_]MenuItem{
        MenuItem.init("Create New Seed", .{ .navigate = .create_seed })
            .withDescription("Generate a new seed phrase")
            .withIcon('N'),
        MenuItem.init("Recover Seed", .{ .navigate = .recover_seed })
            .withDescription("Restore from mnemonic words")
            .withIcon('R'),
        MenuItem.init("Split Seed", .{ .navigate = .split_seed })
            .withDescription("Shamir Secret Sharing")
            .withIcon('S'),
        MenuItem.init("Combine Shares", .{ .navigate = .combine_shares })
            .withDescription("Recover from shares")
            .withIcon('C'),
        MenuItem.init("View Shares", .{ .navigate = .view_shares })
            .withDescription("Display stored shares")
            .withIcon('V'),
        MenuItem.init("Settings", .{ .navigate = .settings })
            .withDescription("Configure device")
            .withIcon('*'),
        MenuItem.init("About", .{ .navigate = .about })
            .withDescription("Version and info")
            .withIcon('?'),
    };

    pub const settings_menu = [_]MenuItem{
        MenuItem.init("Display Brightness", .none),
        MenuItem.init("Auto-Lock Timeout", .none),
        MenuItem.init("Wipe Device", .none).disabled(),
        MenuItem.init("Back", .{ .navigate = .main_menu }),
    };

    pub fn getMenuItems(screen: ScreenId) []const MenuItem {
        return switch (screen) {
            .main_menu => &main_menu,
            .settings => &settings_menu,
            else => &[_]MenuItem{},
        };
    }

    pub fn getMenuItemsFromSubmenu(state: *const MenuState) []const MenuItem {
        if (state.submenu) |submenu| {
            return submenu.items;
        }
        return &[_]MenuItem{};
    }
};

/// Menu renderer
pub const MenuRenderer = struct {
    ctx: widgets.Context,
    state: *MenuState,
    header: widgets.Header,
    footer: widgets.Footer,

    const Self = @This();
    const CONTENT_Y: i16 = 28;
    const CONTENT_HEIGHT: u16 = display.HEIGHT - 28 - 20;
    const ITEM_HEIGHT: u16 = 24;

    pub fn init(fb: *Framebuffer, state: *MenuState) Self {
        return .{
            .ctx = widgets.Context.init(fb),
            .state = state,
            .header = widgets.Header.init("Quantum Seed Vault"),
            .footer = widgets.Footer.init(),
        };
    }

    pub fn render(self: *Self) void {
        // Clear framebuffer
        self.ctx.fb.clear(self.ctx.theme.background);

        // Update header title based on screen
        self.header.title = self.getScreenTitle();
        self.header.draw(&self.ctx);

        // If in submenu, render submenu instead of normal screen
        if (self.state.submenu != null) {
            self.renderMenu();
        } else {
            // Render content based on current screen
            switch (self.state.current_screen) {
                .main_menu, .settings => self.renderMenu(),
                .about => self.renderAbout(),
                .create_seed => self.renderCreateSeed(),
                .recover_seed => self.renderRecoverSeed(),
                .split_seed => self.renderSplitSeed(),
                .combine_shares => self.renderCombineShares(),
                .view_shares => self.renderViewShares(),
                else => self.renderPlaceholder(),
            }
        }

        // Update footer
        self.updateFooter();
        self.footer.draw(&self.ctx);
    }

    fn getScreenTitle(self: *const Self) []const u8 {
        return switch (self.state.current_screen) {
            .main_menu => "Quantum Seed Vault",
            .create_seed => "Create New Seed",
            .recover_seed => "Recover Seed",
            .split_seed => "Split Seed",
            .combine_shares => "Combine Shares",
            .view_shares => "View Shares",
            .settings => "Settings",
            .about => "About",
            else => "Quantum Seed Vault",
        };
    }

    fn updateFooter(self: *Self) void {
        switch (self.state.current_screen) {
            .main_menu => self.footer.setButtons("K1", "Select", "K3"),
            .settings => self.footer.setButtons("Back", "Select", null),
            .about => self.footer.setButtons("Back", null, null),
            else => self.footer.setButtons("Back", "OK", null),
        }
    }

    fn renderMenu(self: *Self) void {
        // Use submenu items if in submenu, otherwise use regular menu items
        const items = if (self.state.submenu != null)
            Menus.getMenuItemsFromSubmenu(self.state)
        else
            Menus.getMenuItems(self.state.current_screen);

        if (items.len == 0) return;

        var y: i16 = CONTENT_Y;
        const visible_start = self.state.scroll_offset;
        const visible_end = @min(visible_start + MenuState.MAX_VISIBLE_ITEMS, items.len);

        for (items[visible_start..visible_end], visible_start..) |item, idx| {
            const is_selected = idx == self.state.selected_index;

            // Background
            const bg = if (is_selected) self.ctx.theme.highlight else self.ctx.theme.background;
            self.ctx.fb.fillRect(0, y, display.WIDTH, ITEM_HEIGHT, bg);

            // Selection indicator
            if (is_selected) {
                self.ctx.fb.fillRect(0, y, 4, ITEM_HEIGHT, self.ctx.theme.accent);
            }

            // Icon
            if (item.icon) |icon| {
                const icon_buf = [_]u8{icon};
                self.ctx.fb.drawText(8, y + 4, &icon_buf, .small, self.ctx.theme.accent, null);
            }

            // Label
            const fg = if (item.enabled) self.ctx.theme.text else Colors.GRAY;
            self.ctx.fb.drawText(24, y + 4, item.label, .small, fg, null);

            // Description (if selected and has one)
            if (is_selected) {
                if (item.description) |desc| {
                    self.ctx.fb.drawText(24, y + 14, desc, .small, Colors.GRAY, null);
                }
            }

            y += @intCast(ITEM_HEIGHT);
        }

        // Scroll indicators
        if (visible_start > 0) {
            self.ctx.fb.drawText(display.WIDTH - 12, CONTENT_Y, "^", .small, self.ctx.theme.text, null);
        }
        if (visible_end < items.len) {
            const arrow_y: i16 = CONTENT_Y + @as(i16, @intCast(CONTENT_HEIGHT)) - 10;
            self.ctx.fb.drawText(display.WIDTH - 12, arrow_y, "v", .small, self.ctx.theme.text, null);
        }
    }

    fn renderAbout(self: *Self) void {
        var y: i16 = CONTENT_Y + 20;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Quantum Seed Vault", .small, .center, self.ctx.theme.text, null);
        y += 16;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Version 1.0.0", .small, .center, Colors.GRAY, null);
        y += 24;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Secure Seed Management", .small, .center, self.ctx.theme.text, null);
        y += 12;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "with Shamir Secret Sharing", .small, .center, self.ctx.theme.text, null);
        y += 24;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Hardware: Raspberry Pi Zero", .small, .center, Colors.GRAY, null);
        y += 12;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Display: ST7789 1.3\" LCD", .small, .center, Colors.GRAY, null);
    }

    fn renderCreateSeed(self: *Self) void {
        var y: i16 = CONTENT_Y + 20;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Generate New Seed", .small, .center, self.ctx.theme.text, null);
        y += 24;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "A new 24-word seed phrase", .small, .center, Colors.GRAY, null);
        y += 12;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "will be generated using", .small, .center, Colors.GRAY, null);
        y += 12;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "hardware random entropy.", .small, .center, Colors.GRAY, null);
        y += 32;

        // Generate button placeholder
        var btn = widgets.Button.init(60, y, 120, 30, "Generate");
        btn.selected = true;
        btn.draw(&self.ctx);
    }

    fn renderRecoverSeed(self: *Self) void {
        var y: i16 = CONTENT_Y + 20;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Enter Seed Words", .small, .center, self.ctx.theme.text, null);
        y += 24;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Enter your 12 or 24 word", .small, .center, Colors.GRAY, null);
        y += 12;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "mnemonic phrase to recover", .small, .center, Colors.GRAY, null);
        y += 12;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "your seed.", .small, .center, Colors.GRAY, null);
        y += 32;

        // Word input would go here
        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Word 1 of 24: _______", .small, .center, self.ctx.theme.text, null);
    }

    fn renderSplitSeed(self: *Self) void {
        var y: i16 = CONTENT_Y + 20;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Split Seed (SSS)", .small, .center, self.ctx.theme.text, null);
        y += 24;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Split your seed into", .small, .center, Colors.GRAY, null);
        y += 12;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "multiple shares using", .small, .center, Colors.GRAY, null);
        y += 12;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Shamir Secret Sharing.", .small, .center, Colors.GRAY, null);
        y += 32;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Threshold: 3 of 5", .small, .center, self.ctx.theme.accent, null);
    }

    fn renderCombineShares(self: *Self) void {
        var y: i16 = CONTENT_Y + 20;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Combine Shares", .small, .center, self.ctx.theme.text, null);
        y += 24;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Enter your shares to", .small, .center, Colors.GRAY, null);
        y += 12;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "recover the original seed.", .small, .center, Colors.GRAY, null);
        y += 32;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Shares entered: 0/3", .small, .center, self.ctx.theme.accent, null);
    }

    fn renderViewShares(self: *Self) void {
        var y: i16 = CONTENT_Y + 20;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Stored Shares", .small, .center, self.ctx.theme.text, null);
        y += 24;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "No shares stored yet.", .small, .center, Colors.GRAY, null);
        y += 24;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "Split a seed to create", .small, .center, Colors.GRAY, null);
        y += 12;

        self.ctx.fb.drawTextAligned(0, y, display.WIDTH, "shares.", .small, .center, Colors.GRAY, null);
    }

    fn renderPlaceholder(self: *Self) void {
        self.ctx.fb.drawTextAligned(
            0,
            display.HEIGHT / 2 - 4,
            display.WIDTH,
            "Coming Soon",
            .small,
            .center,
            self.ctx.theme.text,
            null,
        );
    }

    /// Handle input events
    pub fn handleInput(self: *Self, event: InputEvent) bool {
        // Determine which items to use based on submenu context
        const items = if (self.state.submenu != null)
            Menus.getMenuItemsFromSubmenu(self.state)
        else
            Menus.getMenuItems(self.state.current_screen);

        switch (event) {
            .up => {
                self.state.moveUp(items.len);
                return true;
            },
            .down => {
                self.state.moveDown(items.len);
                return true;
            },
            .select, .key2 => {
                return self.handleSelect();
            },
            .back, .key1 => {
                return self.state.goBack();
            },
            .quit => return false,
            else => {},
        }
        return true;
    }

    fn handleSelect(self: *Self) bool {
        // Determine which items to use based on submenu context
        const items = if (self.state.submenu != null)
            Menus.getMenuItemsFromSubmenu(self.state)
        else
            Menus.getMenuItems(self.state.current_screen);

        if (items.len == 0) return true;
        if (self.state.selected_index >= items.len) return true;

        const item = items[self.state.selected_index];
        if (!item.enabled) return true;

        switch (item.action) {
            .navigate => |screen| self.state.navigateTo(screen),
            .callback => |cb| cb(),
            .submenu => |submenu_items| {
                // Navigate to submenu
                _ = self.state.navigateToSubmenu(submenu_items);
            },
            .none => {},
        }
        return true;
    }
};
