//! Terminal Multiplexer Library
//!
//! A modern terminal multiplexer written in Zig, designed as a tmux alternative.
//!
//! Features:
//! - PTY management for shell processes
//! - Session/window/pane hierarchy
//! - Full VT100/ANSI terminal emulation
//! - Zig-native configuration (no config file parsing)
//! - Unix socket IPC for attach/detach
//!
//! Architecture:
//!   ┌─────────────────────────────────────────────────┐
//!   │                    Server                        │
//!   │  ┌──────────────────────────────────────────┐   │
//!   │  │            Session Manager                │   │
//!   │  │   Session1 ─┬─ Window1 ─┬─ Pane1        │   │
//!   │  │             │           └─ Pane2        │   │
//!   │  │             └─ Window2 ─── Pane3        │   │
//!   │  └──────────────────────────────────────────┘   │
//!   │                      │                          │
//!   │  ┌─────────┐  ┌─────────┐  ┌────────────────┐  │
//!   │  │   PTY   │  │ Parser  │  │    Renderer    │  │
//!   │  │ Manager │  │  (VT)   │  │    (ANSI)      │  │
//!   │  └─────────┘  └─────────┘  └────────────────┘  │
//!   └─────────────────────────────────────────────────┘
//!               │                   ▲
//!               ▼                   │
//!   ┌─────────────────────────────────────────────────┐
//!   │              Unix Socket IPC                     │
//!   └─────────────────────────────────────────────────┘
//!               ▲                   │
//!               │                   ▼
//!   ┌─────────────────────────────────────────────────┐
//!   │                    Client                        │
//!   │      (User Terminal: stdin/stdout/sigwinch)     │
//!   └─────────────────────────────────────────────────┘

const std = @import("std");

// Re-export modules
pub const pty = @import("pty.zig");
pub const terminal = @import("terminal.zig");
pub const parser = @import("parser.zig");
pub const session = @import("session.zig");
pub const render = @import("render.zig");
pub const ipc = @import("ipc.zig");
pub const config = @import("config.zig");

// Re-export key types
pub const Pty = pty.Pty;
pub const RawMode = pty.RawMode;
pub const Winsize = pty.Winsize;

pub const Terminal = terminal.Terminal;
pub const Cell = terminal.Cell;
pub const CellAttrs = terminal.CellAttrs;
pub const CellColor = terminal.CellColor;
pub const Grid = terminal.Grid;
pub const Cursor = terminal.Cursor;

pub const Parser = parser.Parser;
pub const ParserAction = parser.Action;

pub const Session = session.Session;
pub const Window = session.Window;
pub const Pane = session.Pane;
pub const SessionManager = session.SessionManager;
pub const Rect = session.Rect;
pub const SplitDirection = session.SplitDirection;

pub const Renderer = render.Renderer;

pub const IpcServer = ipc.Server;
pub const IpcClient = ipc.IpcClient;
pub const MessageType = ipc.MessageType;

pub const Config = config.Config;
pub const RuntimeConfig = config.RuntimeConfig;
pub const Color = config.Color;
pub const Key = config.Key;
pub const Action = config.Action;

// =============================================================================
// Tests
// =============================================================================

test "library imports" {
    _ = pty;
    _ = terminal;
    _ = parser;
    _ = session;
    _ = render;
    _ = ipc;
    _ = config;
}

test "pty module" {
    _ = pty;
}

test "terminal module" {
    _ = terminal;
}

test "parser module" {
    _ = parser;
}

test "session module" {
    _ = session;
}

test "render module" {
    _ = render;
}

test "ipc module" {
    _ = ipc;
}

test "config module" {
    _ = config;
}
