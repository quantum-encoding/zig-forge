//! UI module for Quantum Seed Vault
//!
//! Provides widgets and menu system for the LCD interface.

pub const widgets = @import("ui/widgets.zig");
pub const menu = @import("ui/menu.zig");

// Re-export commonly used types
pub const Context = widgets.Context;
pub const Button = widgets.Button;
pub const List = widgets.List;
pub const ListItem = widgets.ListItem;
pub const ProgressBar = widgets.ProgressBar;
pub const TextInput = widgets.TextInput;
pub const Header = widgets.Header;
pub const Footer = widgets.Footer;
pub const MessageBox = widgets.MessageBox;

pub const MenuItem = menu.MenuItem;
pub const MenuAction = menu.MenuAction;
pub const MenuState = menu.MenuState;
pub const MenuRenderer = menu.MenuRenderer;
pub const ScreenId = menu.ScreenId;
pub const Menus = menu.Menus;
