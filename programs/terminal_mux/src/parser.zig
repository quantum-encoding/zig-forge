//! ANSI/VT Escape Sequence Parser
//!
//! State machine parser for terminal escape sequences based on the
//! DEC VT100/VT220/xterm control sequence standards.
//!
//! Supports:
//! - CSI (Control Sequence Introducer) sequences: ESC [
//! - OSC (Operating System Command) sequences: ESC ]
//! - DCS (Device Control String) sequences: ESC P
//! - Single-character escape sequences: ESC M, ESC D, etc.
//! - UTF-8 character decoding

const std = @import("std");
const terminal = @import("terminal.zig");
const Terminal = terminal.Terminal;
const CellAttrs = terminal.CellAttrs;
const CellColor = terminal.CellColor;

/// Parser state machine states
pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    osc_string,
    sos_pm_apc_string,
    utf8,
};

/// Maximum number of CSI parameters
const MAX_PARAMS = 16;

/// Maximum OSC string length
const MAX_OSC_LEN = 2048;

/// Parser action to take after processing a byte
pub const Action = union(enum) {
    none: void,
    print: u21, // Print a character
    execute: u8, // Execute a C0 control
    csi_dispatch: CsiSequence,
    esc_dispatch: EscSequence,
    osc_dispatch: OscSequence,
    dcs_hook: DcsSequence,
    dcs_put: u8,
    dcs_unhook: void,
};

/// CSI sequence data
pub const CsiSequence = struct {
    params: [MAX_PARAMS]u16,
    param_count: u8,
    intermediates: [2]u8,
    intermediate_count: u8,
    final_byte: u8,

    pub fn getParam(self: *const CsiSequence, idx: usize, default: u16) u16 {
        if (idx < self.param_count) {
            const p = self.params[idx];
            if (p == 0) return default; // 0 means default
            return p;
        }
        return default;
    }
};

/// Escape sequence data
pub const EscSequence = struct {
    intermediates: [2]u8,
    intermediate_count: u8,
    final_byte: u8,
};

/// OSC sequence data
pub const OscSequence = struct {
    command: u16,
    data: []const u8,
};

/// DCS sequence data
pub const DcsSequence = struct {
    params: [MAX_PARAMS]u16,
    param_count: u8,
    intermediates: [2]u8,
    intermediate_count: u8,
    final_byte: u8,
};

/// ANSI escape sequence parser
pub const Parser = struct {
    state: State,

    // CSI state
    params: [MAX_PARAMS]u16,
    param_count: u8,
    intermediates: [2]u8,
    intermediate_count: u8,

    // OSC state
    osc_buffer: [MAX_OSC_LEN]u8,
    osc_len: usize,
    osc_command: u16,

    // UTF-8 state
    utf8_buffer: [4]u8,
    utf8_len: u8,
    utf8_expected: u8,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .state = .ground,
            .params = undefined,
            .param_count = 0,
            .intermediates = undefined,
            .intermediate_count = 0,
            .osc_buffer = undefined,
            .osc_len = 0,
            .osc_command = 0,
            .utf8_buffer = undefined,
            .utf8_len = 0,
            .utf8_expected = 0,
        };
    }

    pub fn reset(self: *Self) void {
        self.state = .ground;
        self.param_count = 0;
        self.intermediate_count = 0;
        self.osc_len = 0;
        self.utf8_len = 0;
    }

    /// Process a single byte and return an action
    pub fn feed(self: *Self, byte: u8) Action {
        // Handle C0 controls in any state (except when in string states)
        if (byte < 0x20 and self.state != .osc_string and self.state != .dcs_passthrough) {
            return self.handleC0(byte);
        }

        return switch (self.state) {
            .ground => self.handleGround(byte),
            .escape => self.handleEscape(byte),
            .escape_intermediate => self.handleEscapeIntermediate(byte),
            .csi_entry => self.handleCsiEntry(byte),
            .csi_param => self.handleCsiParam(byte),
            .csi_intermediate => self.handleCsiIntermediate(byte),
            .csi_ignore => self.handleCsiIgnore(byte),
            .osc_string => self.handleOscString(byte),
            .dcs_entry => self.handleDcsEntry(byte),
            .dcs_param => self.handleDcsParam(byte),
            .dcs_intermediate => self.handleDcsIntermediate(byte),
            .dcs_passthrough => self.handleDcsPassthrough(byte),
            .dcs_ignore => self.handleDcsIgnore(byte),
            .sos_pm_apc_string => self.handleSosPmApcString(byte),
            .utf8 => self.handleUtf8(byte),
        };
    }

    fn handleC0(self: *Self, byte: u8) Action {
        switch (byte) {
            0x1B => {
                // ESC - enter escape state
                self.state = .escape;
                return .{ .none = {} };
            },
            0x00...0x06, 0x08...0x0C, 0x0E...0x1A, 0x1C...0x1F => {
                // Execute C0 control
                return .{ .execute = byte };
            },
            0x07 => {
                // BEL
                return .{ .execute = byte };
            },
            0x0D => {
                // CR
                return .{ .execute = byte };
            },
            else => return .{ .none = {} },
        }
    }

    fn handleGround(self: *Self, byte: u8) Action {
        if (byte >= 0x20 and byte < 0x7F) {
            // Printable ASCII
            return .{ .print = byte };
        } else if (byte >= 0x80 and byte < 0xC0) {
            // Invalid UTF-8 lead byte, ignore
            return .{ .none = {} };
        } else if (byte >= 0xC0 and byte < 0xE0) {
            // 2-byte UTF-8
            self.utf8_buffer[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 2;
            self.state = .utf8;
            return .{ .none = {} };
        } else if (byte >= 0xE0 and byte < 0xF0) {
            // 3-byte UTF-8
            self.utf8_buffer[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 3;
            self.state = .utf8;
            return .{ .none = {} };
        } else if (byte >= 0xF0 and byte < 0xF8) {
            // 4-byte UTF-8
            self.utf8_buffer[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 4;
            self.state = .utf8;
            return .{ .none = {} };
        } else if (byte == 0x7F) {
            // DEL - ignore
            return .{ .none = {} };
        } else {
            return .{ .none = {} };
        }
    }

    fn handleUtf8(self: *Self, byte: u8) Action {
        if (byte >= 0x80 and byte < 0xC0) {
            // Valid continuation byte
            self.utf8_buffer[self.utf8_len] = byte;
            self.utf8_len += 1;

            if (self.utf8_len == self.utf8_expected) {
                // Complete UTF-8 sequence
                const codepoint = decodeUtf8(self.utf8_buffer[0..self.utf8_len]);
                self.state = .ground;
                self.utf8_len = 0;
                if (codepoint) |cp| {
                    return .{ .print = cp };
                }
            }
            return .{ .none = {} };
        } else {
            // Invalid sequence, reset and re-process byte
            self.state = .ground;
            self.utf8_len = 0;
            return self.feed(byte);
        }
    }

    fn handleEscape(self: *Self, byte: u8) Action {
        self.param_count = 0;
        self.intermediate_count = 0;

        switch (byte) {
            0x20...0x2F => {
                // Intermediate byte
                if (self.intermediate_count < 2) {
                    self.intermediates[self.intermediate_count] = byte;
                    self.intermediate_count += 1;
                }
                self.state = .escape_intermediate;
                return .{ .none = {} };
            },
            '[' => {
                // CSI
                self.state = .csi_entry;
                return .{ .none = {} };
            },
            ']' => {
                // OSC
                self.osc_len = 0;
                self.osc_command = 0;
                self.state = .osc_string;
                return .{ .none = {} };
            },
            'P' => {
                // DCS
                self.state = .dcs_entry;
                return .{ .none = {} };
            },
            'X', '^', '_' => {
                // SOS, PM, APC strings - ignore content
                self.state = .sos_pm_apc_string;
                return .{ .none = {} };
            },
            0x30...0x4F, 0x51...0x57, 0x59, 0x5A, 0x5C, 0x60...0x7E => {
                // Final byte for simple escape
                self.state = .ground;
                return .{ .esc_dispatch = .{
                    .intermediates = self.intermediates,
                    .intermediate_count = self.intermediate_count,
                    .final_byte = byte,
                } };
            },
            else => {
                self.state = .ground;
                return .{ .none = {} };
            },
        }
    }

    fn handleEscapeIntermediate(self: *Self, byte: u8) Action {
        switch (byte) {
            0x20...0x2F => {
                // More intermediate bytes
                if (self.intermediate_count < 2) {
                    self.intermediates[self.intermediate_count] = byte;
                    self.intermediate_count += 1;
                }
                return .{ .none = {} };
            },
            0x30...0x7E => {
                // Final byte
                self.state = .ground;
                return .{ .esc_dispatch = .{
                    .intermediates = self.intermediates,
                    .intermediate_count = self.intermediate_count,
                    .final_byte = byte,
                } };
            },
            else => {
                self.state = .ground;
                return .{ .none = {} };
            },
        }
    }

    fn handleCsiEntry(self: *Self, byte: u8) Action {
        @memset(&self.params, 0);
        self.param_count = 0;
        self.intermediate_count = 0;

        switch (byte) {
            0x30...0x39, ';' => {
                self.state = .csi_param;
                return self.handleCsiParam(byte);
            },
            '<', '=', '>', '?' => {
                // Private mode marker
                if (self.intermediate_count < 2) {
                    self.intermediates[self.intermediate_count] = byte;
                    self.intermediate_count += 1;
                }
                self.state = .csi_param;
                return .{ .none = {} };
            },
            0x40...0x7E => {
                // Final byte immediately
                self.state = .ground;
                return .{ .csi_dispatch = .{
                    .params = self.params,
                    .param_count = self.param_count,
                    .intermediates = self.intermediates,
                    .intermediate_count = self.intermediate_count,
                    .final_byte = byte,
                } };
            },
            else => {
                self.state = .csi_ignore;
                return .{ .none = {} };
            },
        }
    }

    fn handleCsiParam(self: *Self, byte: u8) Action {
        switch (byte) {
            0x30...0x39 => {
                // Digit - accumulate parameter
                if (self.param_count == 0) {
                    self.param_count = 1;
                }
                const idx = self.param_count - 1;
                if (idx < MAX_PARAMS) {
                    self.params[idx] = self.params[idx] *% 10 +% (byte - '0');
                }
                return .{ .none = {} };
            },
            ';' => {
                // Parameter separator
                if (self.param_count < MAX_PARAMS) {
                    self.param_count += 1;
                }
                return .{ .none = {} };
            },
            ':' => {
                // Sub-parameter separator (for SGR colon sequences)
                // Treat like semicolon for now
                if (self.param_count < MAX_PARAMS) {
                    self.param_count += 1;
                }
                return .{ .none = {} };
            },
            0x20...0x2F => {
                // Intermediate byte
                if (self.intermediate_count < 2) {
                    self.intermediates[self.intermediate_count] = byte;
                    self.intermediate_count += 1;
                }
                self.state = .csi_intermediate;
                return .{ .none = {} };
            },
            0x40...0x7E => {
                // Final byte
                self.state = .ground;
                return .{ .csi_dispatch = .{
                    .params = self.params,
                    .param_count = self.param_count,
                    .intermediates = self.intermediates,
                    .intermediate_count = self.intermediate_count,
                    .final_byte = byte,
                } };
            },
            else => {
                self.state = .csi_ignore;
                return .{ .none = {} };
            },
        }
    }

    fn handleCsiIntermediate(self: *Self, byte: u8) Action {
        switch (byte) {
            0x20...0x2F => {
                // More intermediates
                if (self.intermediate_count < 2) {
                    self.intermediates[self.intermediate_count] = byte;
                    self.intermediate_count += 1;
                }
                return .{ .none = {} };
            },
            0x40...0x7E => {
                // Final byte
                self.state = .ground;
                return .{ .csi_dispatch = .{
                    .params = self.params,
                    .param_count = self.param_count,
                    .intermediates = self.intermediates,
                    .intermediate_count = self.intermediate_count,
                    .final_byte = byte,
                } };
            },
            else => {
                self.state = .csi_ignore;
                return .{ .none = {} };
            },
        }
    }

    fn handleCsiIgnore(self: *Self, byte: u8) Action {
        if (byte >= 0x40 and byte <= 0x7E) {
            self.state = .ground;
        }
        return .{ .none = {} };
    }

    fn handleOscString(self: *Self, byte: u8) Action {
        switch (byte) {
            0x07 => {
                // BEL - string terminator
                self.state = .ground;
                return .{ .osc_dispatch = .{
                    .command = self.osc_command,
                    .data = self.osc_buffer[0..self.osc_len],
                } };
            },
            0x1B => {
                // Possible ST (ESC \)
                // For simplicity, treat ESC as terminator
                self.state = .ground;
                return .{ .osc_dispatch = .{
                    .command = self.osc_command,
                    .data = self.osc_buffer[0..self.osc_len],
                } };
            },
            0x30...0x39 => {
                // Digit - part of command number
                if (self.osc_len == 0) {
                    self.osc_command = self.osc_command *% 10 +% (byte - '0');
                    return .{ .none = {} };
                }
                // Fall through to collect as data
                if (self.osc_len < MAX_OSC_LEN) {
                    self.osc_buffer[self.osc_len] = byte;
                    self.osc_len += 1;
                }
                return .{ .none = {} };
            },
            ';' => {
                // Separator between command and data
                if (self.osc_len == 0) {
                    // First semicolon marks end of command number
                    return .{ .none = {} };
                }
                if (self.osc_len < MAX_OSC_LEN) {
                    self.osc_buffer[self.osc_len] = byte;
                    self.osc_len += 1;
                }
                return .{ .none = {} };
            },
            else => {
                if (self.osc_len < MAX_OSC_LEN) {
                    self.osc_buffer[self.osc_len] = byte;
                    self.osc_len += 1;
                }
                return .{ .none = {} };
            },
        }
    }

    fn handleDcsEntry(self: *Self, byte: u8) Action {
        @memset(&self.params, 0);
        self.param_count = 0;
        self.intermediate_count = 0;

        switch (byte) {
            0x30...0x39, ';' => {
                self.state = .dcs_param;
                return self.handleDcsParam(byte);
            },
            0x20...0x2F => {
                if (self.intermediate_count < 2) {
                    self.intermediates[self.intermediate_count] = byte;
                    self.intermediate_count += 1;
                }
                self.state = .dcs_intermediate;
                return .{ .none = {} };
            },
            0x40...0x7E => {
                self.state = .dcs_passthrough;
                return .{ .dcs_hook = .{
                    .params = self.params,
                    .param_count = self.param_count,
                    .intermediates = self.intermediates,
                    .intermediate_count = self.intermediate_count,
                    .final_byte = byte,
                } };
            },
            else => {
                self.state = .dcs_ignore;
                return .{ .none = {} };
            },
        }
    }

    fn handleDcsParam(self: *Self, byte: u8) Action {
        switch (byte) {
            0x30...0x39 => {
                if (self.param_count == 0) self.param_count = 1;
                const idx = self.param_count - 1;
                if (idx < MAX_PARAMS) {
                    self.params[idx] = self.params[idx] *% 10 +% (byte - '0');
                }
                return .{ .none = {} };
            },
            ';' => {
                if (self.param_count < MAX_PARAMS) {
                    self.param_count += 1;
                }
                return .{ .none = {} };
            },
            0x20...0x2F => {
                if (self.intermediate_count < 2) {
                    self.intermediates[self.intermediate_count] = byte;
                    self.intermediate_count += 1;
                }
                self.state = .dcs_intermediate;
                return .{ .none = {} };
            },
            0x40...0x7E => {
                self.state = .dcs_passthrough;
                return .{ .dcs_hook = .{
                    .params = self.params,
                    .param_count = self.param_count,
                    .intermediates = self.intermediates,
                    .intermediate_count = self.intermediate_count,
                    .final_byte = byte,
                } };
            },
            else => {
                self.state = .dcs_ignore;
                return .{ .none = {} };
            },
        }
    }

    fn handleDcsIntermediate(self: *Self, byte: u8) Action {
        switch (byte) {
            0x20...0x2F => {
                if (self.intermediate_count < 2) {
                    self.intermediates[self.intermediate_count] = byte;
                    self.intermediate_count += 1;
                }
                return .{ .none = {} };
            },
            0x40...0x7E => {
                self.state = .dcs_passthrough;
                return .{ .dcs_hook = .{
                    .params = self.params,
                    .param_count = self.param_count,
                    .intermediates = self.intermediates,
                    .intermediate_count = self.intermediate_count,
                    .final_byte = byte,
                } };
            },
            else => {
                self.state = .dcs_ignore;
                return .{ .none = {} };
            },
        }
    }

    fn handleDcsPassthrough(self: *Self, byte: u8) Action {
        switch (byte) {
            0x1B => {
                // Possible ST
                self.state = .ground;
                return .{ .dcs_unhook = {} };
            },
            else => {
                return .{ .dcs_put = byte };
            },
        }
    }

    fn handleDcsIgnore(self: *Self, byte: u8) Action {
        if (byte == 0x1B) {
            self.state = .ground;
        }
        return .{ .none = {} };
    }

    fn handleSosPmApcString(self: *Self, byte: u8) Action {
        if (byte == 0x1B) {
            // Possible ST
            self.state = .ground;
        }
        return .{ .none = {} };
    }
};

/// Decode UTF-8 byte sequence to codepoint
fn decodeUtf8(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;

    const b0 = bytes[0];
    if (bytes.len == 1) {
        if (b0 < 0x80) return b0;
        return null;
    }

    if (bytes.len == 2) {
        if (b0 >= 0xC0 and b0 < 0xE0) {
            const cp = (@as(u21, b0 & 0x1F) << 6) | @as(u21, bytes[1] & 0x3F);
            if (cp >= 0x80) return cp;
        }
        return null;
    }

    if (bytes.len == 3) {
        if (b0 >= 0xE0 and b0 < 0xF0) {
            const cp = (@as(u21, b0 & 0x0F) << 12) |
                (@as(u21, bytes[1] & 0x3F) << 6) |
                @as(u21, bytes[2] & 0x3F);
            if (cp >= 0x800 and (cp < 0xD800 or cp > 0xDFFF)) return cp;
        }
        return null;
    }

    if (bytes.len == 4) {
        if (b0 >= 0xF0 and b0 < 0xF8) {
            const cp = (@as(u21, b0 & 0x07) << 18) |
                (@as(u21, bytes[1] & 0x3F) << 12) |
                (@as(u21, bytes[2] & 0x3F) << 6) |
                @as(u21, bytes[3] & 0x3F);
            if (cp >= 0x10000 and cp <= 0x10FFFF) return cp;
        }
        return null;
    }

    return null;
}

// =============================================================================
// Terminal Handler - applies parser actions to terminal
// =============================================================================

/// Applies parser actions to a terminal
pub fn applyAction(term: *Terminal, action: Action) void {
    switch (action) {
        .none => {},
        .print => |char| {
            term.putChar(char);
        },
        .execute => |byte| {
            executeC0(term, byte);
        },
        .csi_dispatch => |seq| {
            handleCsi(term, seq);
        },
        .esc_dispatch => |seq| {
            handleEscape(term, seq);
        },
        .osc_dispatch => |seq| {
            handleOsc(term, seq);
        },
        .dcs_hook => {
            // DCS strings not fully implemented
        },
        .dcs_put => {
            // DCS data
        },
        .dcs_unhook => {
            // DCS end
        },
    }
}

fn executeC0(term: *Terminal, byte: u8) void {
    switch (byte) {
        0x07 => {
            // BEL - bell
        },
        0x08 => {
            // BS - backspace
            term.backspace();
        },
        0x09 => {
            // HT - horizontal tab
            term.tab();
        },
        0x0A, 0x0B, 0x0C => {
            // LF, VT, FF - newline
            term.newline();
        },
        0x0D => {
            // CR - carriage return
            term.carriageReturn();
        },
        0x0E => {
            // SO - shift out (switch to G1)
            term.gl = .g1;
        },
        0x0F => {
            // SI - shift in (switch to G0)
            term.gl = .g0;
        },
        else => {},
    }
}

fn handleCsi(term: *Terminal, seq: CsiSequence) void {
    // Check for private mode (starts with ?)
    const is_private = seq.intermediate_count > 0 and seq.intermediates[0] == '?';

    switch (seq.final_byte) {
        '@' => {
            // ICH - Insert Character
            const n = seq.getParam(0, 1);
            term.insertChar(n);
        },
        'A' => {
            // CUU - Cursor Up
            term.cursorUp(seq.getParam(0, 1));
        },
        'B' => {
            // CUD - Cursor Down
            term.cursorDown(seq.getParam(0, 1));
        },
        'C' => {
            // CUF - Cursor Forward
            term.cursorForward(seq.getParam(0, 1));
        },
        'D' => {
            // CUB - Cursor Backward
            term.cursorBackward(seq.getParam(0, 1));
        },
        'E' => {
            // CNL - Cursor Next Line
            term.cursorDown(seq.getParam(0, 1));
            term.cursor.col = 0;
        },
        'F' => {
            // CPL - Cursor Previous Line
            term.cursorUp(seq.getParam(0, 1));
            term.cursor.col = 0;
        },
        'G' => {
            // CHA - Cursor Horizontal Absolute
            const col = seq.getParam(0, 1);
            term.cursor.col = if (col > 0) col - 1 else 0;
            if (term.cursor.col >= term.grid.cols) {
                term.cursor.col = term.grid.cols - 1;
            }
        },
        'H', 'f' => {
            // CUP - Cursor Position
            const row = seq.getParam(0, 1);
            const col = seq.getParam(1, 1);
            term.setCursorPos(if (row > 0) row - 1 else 0, if (col > 0) col - 1 else 0);
        },
        'J' => {
            // ED - Erase Display
            term.eraseDisplay(@intCast(seq.getParam(0, 0)));
        },
        'K' => {
            // EL - Erase Line
            term.eraseLine(@intCast(seq.getParam(0, 0)));
        },
        'L' => {
            // IL - Insert Line
            const n = seq.getParam(0, 1);
            term.scrollDown(n);
        },
        'M' => {
            // DL - Delete Line
            const n = seq.getParam(0, 1);
            term.scrollUp(n);
        },
        'S' => {
            // SU - Scroll Up
            const n = seq.getParam(0, 1);
            term.scrollUp(n);
        },
        'T' => {
            // SD - Scroll Down
            const n = seq.getParam(0, 1);
            term.scrollDown(n);
        },
        'd' => {
            // VPA - Vertical Position Absolute
            const row = seq.getParam(0, 1);
            term.cursor.row = if (row > 0) row - 1 else 0;
            if (term.cursor.row >= term.grid.rows) {
                term.cursor.row = term.grid.rows - 1;
            }
        },
        'h' => {
            // SM - Set Mode
            if (is_private) {
                handleDecPrivateMode(term, seq, true);
            }
        },
        'l' => {
            // RM - Reset Mode
            if (is_private) {
                handleDecPrivateMode(term, seq, false);
            }
        },
        'm' => {
            // SGR - Select Graphic Rendition
            handleSgr(term, seq);
        },
        'r' => {
            // DECSTBM - Set Scrolling Region
            const top = seq.getParam(0, 1);
            const bottom = seq.getParam(1, term.grid.rows);
            if (top < bottom and top >= 1 and bottom <= term.grid.rows) {
                term.scroll_region.top = top - 1;
                term.scroll_region.bottom = bottom - 1;
                term.setCursorPos(0, 0);
            }
        },
        's' => {
            // DECSC or Save Cursor
            term.saveCursor();
        },
        'u' => {
            // DECRC or Restore Cursor
            term.restoreCursor();
        },
        else => {},
    }
}

fn handleDecPrivateMode(term: *Terminal, seq: CsiSequence, enable: bool) void {
    var i: u8 = 0;
    while (i < seq.param_count) : (i += 1) {
        const mode = seq.params[i];
        switch (mode) {
            1 => term.modes.app_cursor = enable,
            3 => {
                // DECCOLM - 132 column mode (ignore)
            },
            6 => term.modes.origin = enable,
            7 => term.modes.autowrap = enable,
            12 => {
                // Cursor blink (ignore)
            },
            25 => term.modes.cursor_visible = enable,
            1000 => term.modes.mouse_tracking = if (enable) .normal else .none,
            1002 => term.modes.mouse_tracking = if (enable) .button else .none,
            1003 => term.modes.mouse_tracking = if (enable) .any else .none,
            1004 => term.modes.focus_events = enable,
            1049 => {
                // Alternate screen buffer with cursor save
                if (enable) {
                    term.saveCursor();
                    term.enterAltScreen() catch {};
                } else {
                    term.exitAltScreen();
                    term.restoreCursor();
                }
            },
            2004 => term.modes.bracketed_paste = enable,
            else => {},
        }
    }
}

fn handleSgr(term: *Terminal, seq: CsiSequence) void {
    if (seq.param_count == 0) {
        // Reset all
        term.current_attrs = .{};
        term.current_fg = .{ .default = {} };
        term.current_bg = .{ .default = {} };
        return;
    }

    var i: u8 = 0;
    while (i < seq.param_count) : (i += 1) {
        const param = seq.params[i];
        switch (param) {
            0 => {
                term.current_attrs = .{};
                term.current_fg = .{ .default = {} };
                term.current_bg = .{ .default = {} };
            },
            1 => term.current_attrs.bold = true,
            2 => term.current_attrs.dim = true,
            3 => term.current_attrs.italic = true,
            4 => term.current_attrs.underline = true,
            5 => term.current_attrs.blink = true,
            7 => term.current_attrs.inverse = true,
            8 => term.current_attrs.invisible = true,
            9 => term.current_attrs.strikethrough = true,
            21 => term.current_attrs.bold = false,
            22 => {
                term.current_attrs.bold = false;
                term.current_attrs.dim = false;
            },
            23 => term.current_attrs.italic = false,
            24 => term.current_attrs.underline = false,
            25 => term.current_attrs.blink = false,
            27 => term.current_attrs.inverse = false,
            28 => term.current_attrs.invisible = false,
            29 => term.current_attrs.strikethrough = false,
            30...37 => term.current_fg = .{ .indexed = @intCast(param - 30) },
            38 => {
                // Extended foreground color
                if (i + 1 < seq.param_count and seq.params[i + 1] == 5) {
                    // 256 color mode: 38;5;n
                    if (i + 2 < seq.param_count) {
                        term.current_fg = .{ .indexed = @intCast(seq.params[i + 2]) };
                        i += 2;
                    }
                } else if (i + 1 < seq.param_count and seq.params[i + 1] == 2) {
                    // RGB mode: 38;2;r;g;b
                    if (i + 4 < seq.param_count) {
                        term.current_fg = .{ .rgb = .{
                            .r = @intCast(seq.params[i + 2]),
                            .g = @intCast(seq.params[i + 3]),
                            .b = @intCast(seq.params[i + 4]),
                        } };
                        i += 4;
                    }
                }
            },
            39 => term.current_fg = .{ .default = {} },
            40...47 => term.current_bg = .{ .indexed = @intCast(param - 40) },
            48 => {
                // Extended background color
                if (i + 1 < seq.param_count and seq.params[i + 1] == 5) {
                    if (i + 2 < seq.param_count) {
                        term.current_bg = .{ .indexed = @intCast(seq.params[i + 2]) };
                        i += 2;
                    }
                } else if (i + 1 < seq.param_count and seq.params[i + 1] == 2) {
                    if (i + 4 < seq.param_count) {
                        term.current_bg = .{ .rgb = .{
                            .r = @intCast(seq.params[i + 2]),
                            .g = @intCast(seq.params[i + 3]),
                            .b = @intCast(seq.params[i + 4]),
                        } };
                        i += 4;
                    }
                }
            },
            49 => term.current_bg = .{ .default = {} },
            90...97 => term.current_fg = .{ .indexed = @intCast(param - 90 + 8) },
            100...107 => term.current_bg = .{ .indexed = @intCast(param - 100 + 8) },
            else => {},
        }
    }
}

fn handleEscape(term: *Terminal, seq: EscSequence) void {
    switch (seq.final_byte) {
        '7' => term.saveCursor(),
        '8' => term.restoreCursor(),
        'D' => {
            // IND - Index (move down, scroll if at bottom)
            if (term.cursor.row == term.scroll_region.bottom) {
                term.scrollUp(1);
            } else if (term.cursor.row < term.grid.rows - 1) {
                term.cursor.row += 1;
            }
        },
        'E' => {
            // NEL - Next Line
            term.newline();
            term.cursor.col = 0;
        },
        'M' => {
            // RI - Reverse Index
            if (term.cursor.row == term.scroll_region.top) {
                term.scrollDown(1);
            } else if (term.cursor.row > 0) {
                term.cursor.row -= 1;
            }
        },
        'c' => {
            // RIS - Full Reset
            term.reset();
        },
        else => {},
    }
}

fn handleOsc(term: *Terminal, seq: OscSequence) void {
    switch (seq.command) {
        0, 2 => {
            // Set window title
            const len = @min(seq.data.len, term.title.len);
            @memcpy(term.title[0..len], seq.data[0..len]);
            term.title_len = len;
        },
        1 => {
            // Set icon name (ignore)
        },
        else => {},
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parser init" {
    const parser = Parser.init();
    try std.testing.expectEqual(State.ground, parser.state);
}

test "parser simple text" {
    var parser = Parser.init();

    const action = parser.feed('A');
    try std.testing.expectEqual(Action{ .print = 'A' }, action);
}

test "parser csi cursor move" {
    var parser = Parser.init();

    // ESC [ 5 A
    _ = parser.feed(0x1B);
    _ = parser.feed('[');
    _ = parser.feed('5');
    const action = parser.feed('A');

    switch (action) {
        .csi_dispatch => |seq| {
            try std.testing.expectEqual(@as(u8, 'A'), seq.final_byte);
            try std.testing.expectEqual(@as(u16, 5), seq.getParam(0, 1));
        },
        else => return error.UnexpectedAction,
    }
}

test "utf8 decode" {
    // 2-byte: é (U+00E9)
    try std.testing.expectEqual(@as(?u21, 0xE9), decodeUtf8(&[_]u8{ 0xC3, 0xA9 }));

    // 3-byte: 日 (U+65E5)
    try std.testing.expectEqual(@as(?u21, 0x65E5), decodeUtf8(&[_]u8{ 0xE6, 0x97, 0xA5 }));

    // 4-byte: 😀 (U+1F600)
    try std.testing.expectEqual(@as(?u21, 0x1F600), decodeUtf8(&[_]u8{ 0xF0, 0x9F, 0x98, 0x80 }));
}
