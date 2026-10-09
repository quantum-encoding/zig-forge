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
const config = @import("config.zig");

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
    /// OSC 52 (clipboard) after its command number: the payload streams to
    /// the emulator's bounded heap accumulator (clipboard_put), since it
    /// outgrows the OSC buffer; BEL or ST emits clipboard_end.
    osc_clipboard,
    sos_pm_apc_string,
    /// APC (ESC _) string — Kitty graphics protocol. Distinct from SOS/PM,
    /// whose content is still ignored. Payload is streamed to the emulator's
    /// heap-backed graphics accumulator via apc_put; ST emits apc_end.
    apc_string,
    utf8,
};

/// Maximum number of CSI parameters
const MAX_PARAMS = 16;

/// Most ':' sub-parameters kept per CSI parameter: enough for the longest
/// SGR colour form, `38:2:Pi:Pr:Pg:Pb` (ITU T.416). Further ones are dropped.
pub const MAX_SUBPARAMS = 6;

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
    /// APC (Kitty graphics) — begin capture (reset the payload accumulator).
    apc_start: void,
    /// APC payload byte (streamed to the graphics accumulator).
    apc_put: u8,
    /// APC string terminated (ST) — dispatch the accumulated payload.
    apc_end: void,
    /// OSC 52 — begin a clipboard payload ("Pc;Pd").
    clipboard_start: void,
    /// OSC 52 payload byte.
    clipboard_put: u8,
    /// OSC 52 terminated — publish (or drop) the payload.
    clipboard_end: void,
};

/// CSI sequence data
pub const CsiSequence = struct {
    params: [MAX_PARAMS]u16,
    param_count: u8,
    /// `subparams[i][0..sub_counts[i]]` are the ':'-separated sub-parameters
    /// written after `params[i]` (ECMA-48 §5.4.2). An empty one reads 0.
    subparams: [MAX_PARAMS][MAX_SUBPARAMS]u16 = undefined,
    sub_counts: [MAX_PARAMS]u8 = @splat(0),
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

    /// The sub-parameters of parameter `idx`: `38:2::10:20:30` gives
    /// 2, 0, 10, 20, 30 for the 38. Empty when it has none.
    pub fn subParams(self: *const CsiSequence, idx: usize) []const u16 {
        if (idx >= self.param_count or idx >= MAX_PARAMS) return &.{};
        return self.subparams[idx][0..self.sub_counts[idx]];
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
    /// The string outgrew the OSC buffer and `data` is only its start.
    truncated: bool = false,
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
    /// Inside a ':' sub-parameter chain (SGR 4:3, 38:2::r:g:b). Its digits
    /// belong to the current parameter's sub-parameters, never to a
    /// top-level parameter (ECMA-48 §5.4.2 colon separators).
    in_subparam: bool,
    /// Sub-parameters of each parameter; see `CsiSequence.subparams`.
    subparams: [MAX_PARAMS][MAX_SUBPARAMS]u16,
    sub_counts: [MAX_PARAMS]u8,
    /// The sub-parameter being written has a slot (false past
    /// MAX_SUBPARAMS: its digits are dropped).
    sub_open: bool,

    // OSC state
    osc_buffer: [MAX_OSC_LEN]u8,
    osc_len: usize,
    osc_command: u16,
    /// The command number has ended (at the first non-digit): digits after
    /// it are data, so `OSC 0;2024 BEL` titles the window "2024".
    osc_cmd_done: bool,
    /// Bytes past MAX_OSC_LEN were dropped from the current string.
    osc_overflow: bool,

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
            .in_subparam = false,
            .subparams = undefined,
            .sub_counts = @splat(0),
            .sub_open = false,
            .osc_buffer = undefined,
            .osc_len = 0,
            .osc_command = 0,
            .osc_cmd_done = false,
            .osc_overflow = false,
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
        // Handle C0 controls in any state (except when in string states).
        // apc_string joins osc_string / dcs_passthrough here so ESC (0x1B)
        // reaches the string handler and is recognized as ST, rather than being
        // swallowed by handleC0 (which would never emit apc_end).
        if (byte < 0x20 and self.state != .osc_string and self.state != .osc_clipboard and
            self.state != .dcs_passthrough and self.state != .apc_string)
        {
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
            .osc_clipboard => self.handleOscClipboard(byte),
            .dcs_entry => self.handleDcsEntry(byte),
            .dcs_param => self.handleDcsParam(byte),
            .dcs_intermediate => self.handleDcsIntermediate(byte),
            .dcs_passthrough => self.handleDcsPassthrough(byte),
            .dcs_ignore => self.handleDcsIgnore(byte),
            .sos_pm_apc_string => self.handleSosPmApcString(byte),
            .apc_string => self.handleApcString(byte),
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
                self.osc_cmd_done = false;
                self.osc_overflow = false;
                self.state = .osc_string;
                return .{ .none = {} };
            },
            'P' => {
                // DCS
                self.state = .dcs_entry;
                return .{ .none = {} };
            },
            'X', '^' => {
                // SOS, PM strings - ignore content
                self.state = .sos_pm_apc_string;
                return .{ .none = {} };
            },
            '_' => {
                // APC string - Kitty graphics protocol. Begin payload capture.
                self.state = .apc_string;
                return .{ .apc_start = {} };
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
        self.in_subparam = false;
        @memset(&self.sub_counts, 0);
        self.sub_open = false;

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
                return self.csiDispatch(byte);
            },
            else => {
                self.state = .csi_ignore;
                return .{ .none = {} };
            },
        }
    }

    /// The finished CSI sequence ending in `final`; back to ground.
    fn csiDispatch(self: *Self, final: u8) Action {
        self.state = .ground;
        return .{ .csi_dispatch = .{
            .params = self.params,
            .param_count = self.param_count,
            .subparams = self.subparams,
            .sub_counts = self.sub_counts,
            .intermediates = self.intermediates,
            .intermediate_count = self.intermediate_count,
            .final_byte = final,
        } };
    }

    fn handleCsiParam(self: *Self, byte: u8) Action {
        switch (byte) {
            0x30...0x39 => {
                // Digit: accumulates into the current parameter, or into its
                // current sub-parameter after a ':'. Saturating, so a huge
                // number cannot wrap around to a small, valid one.
                if (self.param_count == 0) {
                    self.param_count = 1;
                }
                const idx = self.param_count - 1;
                if (idx >= MAX_PARAMS) return .{ .none = {} };
                const d: u16 = byte - '0';
                if (self.in_subparam) {
                    if (self.sub_open) {
                        const sp = &self.subparams[idx][self.sub_counts[idx] - 1];
                        sp.* = sp.* *| 10 +| d;
                    }
                } else {
                    self.params[idx] = self.params[idx] *| 10 +| d;
                }
                return .{ .none = {} };
            },
            ';' => {
                // Parameter separator. A LEADING ';' means an empty (default)
                // first parameter: ESC[;5H is row-default col-5 — the old code
                // collapsed it so 5 landed in params[0] (wrong row).
                self.in_subparam = false;
                self.sub_open = false;
                if (self.param_count == 0) {
                    self.param_count = 2; // empty first + open second
                } else if (self.param_count < MAX_PARAMS) {
                    self.param_count += 1;
                }
                return .{ .none = {} };
            },
            ':' => {
                // Colon opens a SUB-parameter of the current param (SGR 4:3,
                // 38:2::r:g:b). It never becomes a top-level param, which
                // would shift every parameter after it.
                if (self.param_count == 0) self.param_count = 1;
                self.in_subparam = true;
                const idx = self.param_count - 1;
                self.sub_open = idx < MAX_PARAMS and self.sub_counts[idx] < MAX_SUBPARAMS;
                if (self.sub_open) {
                    self.subparams[idx][self.sub_counts[idx]] = 0;
                    self.sub_counts[idx] += 1;
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
                return self.csiDispatch(byte);
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
                return self.csiDispatch(byte);
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
                return self.oscDispatch();
            },
            0x1B => {
                // ST is ESC \ — dispatch now, but land in ESCAPE state so the
                // trailing '\' is consumed as the ST final byte. Landing in
                // ground printed a literal backslash into the grid after every
                // ST-terminated OSC (tmux, iTerm2 shell integration, systemd).
                self.state = .escape;
                self.intermediate_count = 0;
                return self.oscDispatch();
            },
            else => {},
        }
        if (!self.osc_cmd_done) {
            if (byte >= '0' and byte <= '9') {
                self.osc_command = self.osc_command *| 10 +| (byte - '0');
                return .{ .none = {} };
            }
            self.osc_cmd_done = true;
            if (byte == ';') {
                // The separator between command and data is not data.
                if (self.osc_command == 52) {
                    self.state = .osc_clipboard;
                    return .{ .clipboard_start = {} };
                }
                return .{ .none = {} };
            }
        }
        if (self.osc_len < MAX_OSC_LEN) {
            self.osc_buffer[self.osc_len] = byte;
            self.osc_len += 1;
        } else {
            self.osc_overflow = true;
        }
        return .{ .none = {} };
    }

    fn oscDispatch(self: *Self) Action {
        return .{ .osc_dispatch = .{
            .command = self.osc_command,
            .data = self.osc_buffer[0..self.osc_len],
            .truncated = self.osc_overflow,
        } };
    }

    /// OSC 52 payload: every byte goes to the emulator until BEL or ST.
    fn handleOscClipboard(self: *Self, byte: u8) Action {
        switch (byte) {
            0x07 => {
                self.state = .ground;
                return .{ .clipboard_end = {} };
            },
            0x1B => {
                // ST: consume the trailing '\' in ESCAPE state (see above).
                self.state = .escape;
                self.intermediate_count = 0;
                return .{ .clipboard_end = {} };
            },
            else => return .{ .clipboard_put = byte },
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
                // ST is ESC \ — consume the trailing '\' in ESCAPE state
                // (ground would print it; see handleOscString).
                self.state = .escape;
                self.intermediate_count = 0;
                return .{ .dcs_unhook = {} };
            },
            else => {
                return .{ .dcs_put = byte };
            },
        }
    }

    fn handleDcsIgnore(self: *Self, byte: u8) Action {
        if (byte == 0x1B) {
            self.state = .escape; // ST's '\' consumed as the escape final
            self.intermediate_count = 0;
        }
        return .{ .none = {} };
    }

    fn handleSosPmApcString(self: *Self, byte: u8) Action {
        if (byte == 0x1B) {
            // ST's '\' must not print — finish in ESCAPE state.
            self.state = .escape;
            self.intermediate_count = 0;
        }
        return .{ .none = {} };
    }

    /// APC (Kitty graphics) payload capture. Terminated by ST (ESC \) or BEL.
    /// Every other byte is streamed to the emulator's graphics accumulator.
    fn handleApcString(self: *Self, byte: u8) Action {
        switch (byte) {
            0x1B => {
                // ST is ESC \ — consume the trailing '\' in ESCAPE state
                // (ground would print it; see handleOscString).
                self.state = .escape;
                self.intermediate_count = 0;
                return .{ .apc_end = {} };
            },
            0x07 => {
                // Some emitters terminate with BEL instead of ST.
                self.state = .ground;
                return .{ .apc_end = {} };
            },
            else => return .{ .apc_put = byte },
        }
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
        .apc_start => {
            term.graphicsApcStart();
        },
        .apc_put => |byte| {
            term.graphicsApcPut(byte);
        },
        .apc_end => {
            term.graphicsApcEnd();
        },
        .clipboard_start => term.clipboardStart(),
        .clipboard_put => |byte| term.clipboardPut(byte),
        .clipboard_end => term.clipboardEnd(),
    }
}

fn executeC0(term: *Terminal, byte: u8) void {
    switch (byte) {
        0x07 => {
            // BEL - bell: queue a stroke for the host (audio/visual is its call).
            term.bell_pending +%= 1;
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
            // ED - Erase Display. A mode past u8 names no erase at all.
            if (std.math.cast(u8, seq.getParam(0, 0))) |mode| term.eraseDisplay(mode);
        },
        'K' => {
            // EL - Erase Line
            if (std.math.cast(u8, seq.getParam(0, 0))) |mode| term.eraseLine(mode);
        },
        'P' => {
            // DCH - Delete Character (was silently ignored — zsh/fzf in-place
            // line redraws depend on it; caught by the tier-1 VT anchors)
            term.deleteChar(seq.getParam(0, 1));
        },
        'X' => {
            // ECH - Erase Character (same story as DCH)
            term.eraseChars(seq.getParam(0, 1));
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
            // SGR - Select Graphic Rendition — but ONLY without a private
            // parameter marker. `CSI > Pp;Pv m` is XTMODKEYS (modifyOtherKeys)
            // and other 0x3C-0x3F-prefixed m-finals are private too. Claude
            // Code emits ESC[>4;2m in its boot handshake; dispatching that
            // into handleSgr read param 4 as "underline on" — and with nothing
            // ever emitting a reset, EVERY cell for the rest of the session
            // rendered underlined (aiconductor goal 556D61CB's "pervasive
            // underlines" defect; proved against a real script-captured
            // claude boot stream, which contains no underline SGR at all).
            const is_private_m = seq.intermediate_count > 0 and switch (seq.intermediates[0]) {
                '<', '=', '>', '?' => true,
                else => false,
            };
            if (!is_private_m) handleSgr(term, seq);
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
            // DECRC / Restore Cursor — but ONLY the bare `CSI u`. Kitty
            // keyboard-protocol pushes are u-finals with a private marker
            // (`CSI > 1 u` push, `CSI < u` pop, `CSI ? u` query, `CSI = 1;1 u`
            // set) — Claude Code sends ESC[>1u in its boot handshake, and
            // dispatching that into restoreCursor teleported the cursor to a
            // stale saved position. Same defect class as the 'm' case above;
            // we don't implement the kitty protocol, so swallow those.
            const is_private_u = seq.intermediate_count > 0 and switch (seq.intermediates[0]) {
                '<', '=', '>', '?' => true,
                else => false,
            };
            if (!is_private_u) term.restoreCursor();
        },
        'q' => {
            // DECSCUSR - cursor style (only with the space intermediate).
            if (seq.intermediate_count == 1 and seq.intermediates[0] == ' ') {
                term.setCursorStyle(seq.getParam(0, 1));
            }
        },
        'c' => {
            // DA - Device Attributes. The app BLOCKS on this answer: vim, fzf
            // and an inner tmux send it and wait, so silence costs them a
            // read timeout or drops them into a degraded-capability mode.
            const marker: u8 = if (seq.intermediate_count > 0) seq.intermediates[0] else 0;
            switch (marker) {
                // DA1 (`CSI c` / `CSI 0 c`) — VT220 with 132 columns (22).
                // Any other Ps is not a request, per xterm.
                0 => if (seq.getParam(0, 0) == 0) term.queueResponse("\x1b[?62;22c"),
                // DA2 (`CSI > c`) — terminal id 0, firmware 277, cartridge 0.
                '>' => term.queueResponse("\x1b[>0;277;0c"),
                // DA3 (`CSI = c`) reports a unit id we do not have; stay silent.
                else => {},
            }
        },
        'n' => {
            // DSR - Device Status Report. Same blocking-caller story as DA;
            // `CSI 6 n` (CPR) is what readline and every TUI uses to find the
            // cursor after a resize or a partial redraw.
            const marker: u8 = if (seq.intermediate_count > 0) seq.intermediates[0] else 0;
            const ps = seq.getParam(0, 0);
            if (marker == 0) {
                switch (ps) {
                    5 => term.queueResponse("\x1b[0n"), // "terminal ready, no fault"
                    6 => reportCursorPosition(term, false),
                    else => {},
                }
            } else if (marker == '?' and ps == 6) {
                reportCursorPosition(term, true); // DECXCPR
            }
        },
        else => {},
    }
}

/// Answer CPR (`CSI 6 n`) or DECXCPR (`CSI ? 6 n`).
///
/// Under DECOM (origin mode) the reported row is RELATIVE to the scrolling
/// region, because that is the coordinate space the app's own CUP calls use.
/// Reporting an absolute row there sends the app back to the wrong line the
/// next time it seeks to the position it just read.
fn reportCursorPosition(term: *Terminal, extended: bool) void {
    const top: u16 = if (term.modes.origin) term.scroll_region.top else 0;
    const bottom: u16 = if (term.modes.origin) term.scroll_region.bottom else term.grid.rows - 1;

    const clamped_row = std.math.clamp(term.cursor.row, top, bottom);
    const row = clamped_row - top + 1;
    const col = @min(term.cursor.col, term.grid.cols - 1) + 1;

    var buf: [32]u8 = undefined;
    const reply = if (extended)
        std.fmt.bufPrint(&buf, "\x1b[?{d};{d};1R", .{ row, col }) catch return
    else
        std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ row, col }) catch return;
    term.queueResponse(reply);
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
            1006 => term.modes.mouse_sgr = enable,
            // Alternate screen buffer (xterm ctlseqs, DECSET/DECRST):
            //   47    plain switch, no cursor save; the alternate buffer
            //         keeps its contents across switches.
            //   1047  set: switch; reset: clear the alternate buffer, then
            //         switch back to the normal one.
            //   1049  set: save the cursor (DECSC), switch, clearing the
            //         alternate buffer first; reset: as 1047, then restore
            //         the cursor (DECRC).
            47 => if (enable) {
                term.enterAltScreen(.keep) catch {};
            } else {
                term.exitAltScreen(.keep);
            },
            1047 => if (enable) {
                term.enterAltScreen(.keep) catch {};
            } else {
                term.exitAltScreen(.clear);
            },
            1049 => {
                if (enable) {
                    term.saveCursor();
                    term.enterAltScreen(.clear) catch {};
                } else {
                    term.exitAltScreen(.clear);
                    term.restoreCursor();
                }
            },
            2004 => term.modes.bracketed_paste = enable,
            2026 => {
                // Synchronized output: claude Code wraps every TUI repaint in
                // `?2026h … ?2026l`. The grid keeps updating normally; only
                // the HOST's presentation is gated (zterm_sync_suppressed), so
                // a replayed stream's final grid is identical with or without
                // this mode — but a live renderer no longer paints the
                // half-applied repaint states between the pair.
                term.modes.synchronized = enable;
                if (enable) term.sync_began_ms = @import("terminal.zig").monotonicMs();
            },
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
            4 => {
                // `4:n` picks an underline style (kitty / ITU T.416): 0 none,
                // 1 single, 2 double, 3 curly, 4 dotted, 5 dashed. A cell has
                // one underline bit, so every style but 0 draws as single.
                const sub = seq.subParams(i);
                term.current_attrs.underline = sub.len == 0 or sub[0] != 0;
            },
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
            // Extended colours: foreground, background, underline. The
            // underline colour is not drawn, but its arguments must still be
            // consumed or `58;2;255;0;0` would apply 2 (dim) and 0 (reset).
            38, 48, 58 => if (extendedColor(&seq, &i)) |col| switch (param) {
                38 => term.current_fg = col,
                48 => term.current_bg = col,
                else => {},
            },
            39 => term.current_fg = .{ .default = {} },
            40...47 => term.current_bg = .{ .indexed = @intCast(param - 40) },
            49 => term.current_bg = .{ .default = {} },
            90...97 => term.current_fg = .{ .indexed = @intCast(param - 90 + 8) },
            100...107 => term.current_bg = .{ .indexed = @intCast(param - 100 + 8) },
            else => {},
        }
    }
}

/// The colour an SGR 38/48/58 at parameter `i.*` selects, or null when it
/// names none or a component is out of range (an out-of-range colour is
/// ignored, as xterm does). Two spellings (xterm ctlseqs, "SGR"):
///   colon (ITU T.416): `38:5:n`, `38:2:Pi:r:g:b` (Pi, the colour-space id,
///     is usually empty and is ignored), and the common `38:2:r:g:b`;
///     its arguments are sub-parameters, so `i` stays put.
///   semicolon (konsole's legacy form): `38;5;n`, `38;2;r;g;b`; its
///     arguments are the following parameters, and `i` moves past them.
fn extendedColor(seq: *const CsiSequence, i: *u8) ?CellColor {
    const sub = seq.subParams(i.*);
    if (sub.len > 0) {
        switch (sub[0]) {
            5 => return if (sub.len >= 2) indexedColor(sub[1]) else null,
            2 => {
                const rgb = if (sub.len >= 5) sub[2..5] else if (sub.len == 4) sub[1..4] else return null;
                return rgbColor(rgb[0], rgb[1], rgb[2]);
            },
            else => return null,
        }
    }
    const rest = seq.params[i.* + 1 .. seq.param_count];
    if (rest.len >= 2 and rest[0] == 5) {
        i.* += 2;
        return indexedColor(rest[1]);
    }
    if (rest.len >= 4 and rest[0] == 2) {
        i.* += 4;
        return rgbColor(rest[1], rest[2], rest[3]);
    }
    return null;
}

fn indexedColor(n: u16) ?CellColor {
    return .{ .indexed = std.math.cast(u8, n) orelse return null };
}

fn rgbColor(r: u16, g: u16, b: u16) ?CellColor {
    return .{ .rgb = .{
        .r = std.math.cast(u8, r) orelse return null,
        .g = std.math.cast(u8, g) orelse return null,
        .b = std.math.cast(u8, b) orelse return null,
    } };
}

fn handleEscape(term: *Terminal, seq: EscSequence) void {
    // Character set designation: ESC ( F → G0, ESC ) F → G1, ESC * F → G2,
    // ESC + F → G3 (94-character sets; the final byte names the set).
    if (seq.intermediate_count == 1) {
        const slot: ?terminal.CharsetSlot = switch (seq.intermediates[0]) {
            '(' => .g0,
            ')' => .g1,
            '*' => .g2,
            '+' => .g3,
            else => null,
        };
        if (slot) |sl| {
            if (terminal.Charset.fromFinal(seq.final_byte)) |set| term.designate(sl, set);
            return;
        }
    }
    if (seq.intermediate_count != 0) return;
    switch (seq.final_byte) {
        // SS2 / SS3: the next character only, from G2 / G3.
        'N' => term.single_shift = .g2,
        'O' => term.single_shift = .g3,
        // LS2 / LS3: G2 / G3 into GL until shifted again.
        'n' => term.gl = .g2,
        'o' => term.gl = .g3,
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

/// The mark an OSC 133 payload names, or null for one this emulator does not
/// record (an unknown letter, or kitty's "P" prompt-kind extension). `D`'s
/// exit status is the field after the letter; absent or not a number, the
/// mark carries none.
pub fn parseMark(data: []const u8) ?struct { kind: terminal.Mark.Kind, exit: ?i32 } {
    if (data.len == 0) return null;
    if (data.len > 1 and data[1] != ';') return null;
    const kind: terminal.Mark.Kind = switch (data[0]) {
        'A' => .prompt,
        'B' => .input,
        'C' => .output,
        'D' => .done,
        else => return null,
    };
    var exit: ?i32 = null;
    if (kind == .done and data.len > 2) {
        const rest = data[2..];
        const field = rest[0 .. std.mem.indexOfScalar(u8, rest, ';') orelse rest.len];
        exit = std.fmt.parseInt(i32, field, 10) catch null;
    }
    return .{ .kind = kind, .exit = exit };
}

/// The directory an OSC 7 payload reports: `file://host/path`, with the path
/// percent-decoded (RFC 3986 §2.1) into `buf`. Null for anything else: another
/// scheme, no absolute path, a malformed %-escape, a path longer than `buf`,
/// or a control character once decoded (NUL included — a C consumer would cut
/// the path there — and newline, which would turn a pasted path into a
/// command). The host part is not checked: it is whatever the shell calls
/// its machine, and a shell over ssh reports a path on the remote one.
pub fn parseOsc7(data: []const u8, buf: []u8) ?[]const u8 {
    const scheme = "file://";
    if (data.len < scheme.len or !std.ascii.eqlIgnoreCase(data[0..scheme.len], scheme)) return null;
    const rest = data[scheme.len..];
    const enc = rest[std.mem.indexOfScalar(u8, rest, '/') orelse return null ..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < enc.len) : (n += 1) {
        if (n == buf.len) return null;
        var b = enc[i];
        if (b == '%') {
            if (i + 2 >= enc.len) return null;
            const hi = std.fmt.charToDigit(enc[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(enc[i + 2], 16) catch return null;
            b = hi * 16 + lo;
            i += 3;
        } else {
            i += 1;
        }
        if (b < 0x20 or b == 0x7F) return null;
        buf[n] = b;
    }
    return buf[0..n];
}

fn handleOsc(term: *Terminal, seq: OscSequence) void {
    switch (seq.command) {
        7 => {
            // Current directory (shell integration: zsh/fish/vte.sh emit
            // `OSC 7 ; file://host/path` at each prompt). A truncated
            // string would be a different, shorter path: ignore it.
            var buf: [terminal.CWD_CAP]u8 = undefined;
            if (!seq.truncated) {
                if (parseOsc7(seq.data, &buf)) |path| term.setCwd(path);
            }
        },
        0, 2 => {
            // Set window title
            const len = @min(seq.data.len, term.title.len);
            @memcpy(term.title[0..len], seq.data[0..len]);
            term.title_len = len;
        },
        1 => {
            // Set icon name (ignore)
        },
        10, 11 => {
            // OSC 10/11 with "?" asks for the default foreground/background.
            // Apps read it to pick a light-vs-dark scheme; unanswered they
            // either wait or guess, and guess wrong on a dark theme.
            if (std.mem.eql(u8, seq.data, "?")) {
                const th = &config.active_theme;
                const c = if (seq.command == 10) th.fg else th.bg;
                var buf: [48]u8 = undefined;
                // xterm answers in 16-bit-per-channel rgb:; repeating each
                // byte is the standard 8-to-16-bit widening (0xAB -> 0xABAB).
                const reply = std.fmt.bufPrint(
                    &buf,
                    "\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\",
                    .{ seq.command, c.r, c.r, c.g, c.g, c.b, c.b },
                ) catch return;
                term.queueResponse(reply);
            }
        },
        133 => {
            // Semantic prompt (shell integration, FinalTerm/iTerm2/kitty):
            // "A" prompt, "B" command line, "C" output, "D[;exit]" done.
            // Options after the letter (";aid=…", ";cl=…") are ignored.
            if (parseMark(seq.data)) |m| term.recordMark(m.kind, m.exit);
        },
        // 52 (clipboard) never arrives here with a payload: it streams to the
        // emulator as clipboard_start/put/end (see State.osc_clipboard).
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

test "OSC 7 payloads: file:// URL, percent-decoded path, refusals" {
    // RFC 8089 file URI (`file://host/path`) with RFC 3986 §2.1 escapes, as
    // vte.sh / zsh / fish emit it.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/Users/me/my dir", parseOsc7("file://mac.local/Users/me/my%20dir", &buf).?);
    try std.testing.expectEqualStrings("/tmp", parseOsc7("file:///tmp", &buf).?); // empty host
    try std.testing.expectEqualStrings("/a%b", parseOsc7("FILE://h/a%25b", &buf).?); // scheme is case-blind
    try std.testing.expectEqualStrings("/caf\xc3\xa9", parseOsc7("file://h/caf%C3%A9", &buf).?);
    try std.testing.expectEqualStrings("/", parseOsc7("file://h/", &buf).?);
    try std.testing.expect(parseOsc7("http://h/tmp", &buf) == null); // another scheme
    try std.testing.expect(parseOsc7("file://host", &buf) == null); // no path
    try std.testing.expect(parseOsc7("/tmp", &buf) == null);
    try std.testing.expect(parseOsc7("file://h/a%2", &buf) == null); // escape cut short
    try std.testing.expect(parseOsc7("file://h/a%zz", &buf) == null); // not hex
    try std.testing.expect(parseOsc7("file://h/a%+9", &buf) == null);
    try std.testing.expect(parseOsc7("file://h/x%0Arm%20-rf%20~", &buf) == null); // newline
    try std.testing.expect(parseOsc7("file://h/a%00b", &buf) == null); // NUL
    try std.testing.expect(parseOsc7("file://h/a\x1bb", &buf) == null);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(parseOsc7("file://h/abcd", &tiny) == null); // longer than the buffer
    try std.testing.expectEqualStrings("/abc", parseOsc7("file://h/abc", &tiny).?);
}

test "OSC 7 through the parser sets the cwd; a bad or truncated one leaves it" {
    var t = try Terminal.init(std.testing.allocator, 3, 20, 10);
    defer t.deinit();
    var p = Parser.init();
    const feed = struct {
        fn f(pp: *Parser, tt: *Terminal, bytes: []const u8) void {
            for (bytes) |b| applyAction(tt, pp.feed(b));
        }
    }.f;
    feed(&p, &t, "\x1b]7;file://h/srv/app\x07");
    try std.testing.expectEqualStrings("/srv/app", t.reportedCwd());
    feed(&p, &t, "\x1b]7;file://h/x%0Aecho\x07"); // refused
    try std.testing.expectEqualStrings("/srv/app", t.reportedCwd());
    // Longer than the OSC buffer: the parser keeps only its start, and the
    // start of a path is another directory. The escapes make the kept start
    // a well-formed, short path ("/s/" + 679 'a'), so only the truncation
    // flag can refuse it.
    const prefix = "file://h/s/";
    comptime std.debug.assert((MAX_OSC_LEN - prefix.len) % 3 == 0);
    feed(&p, &t, "\x1b]7;" ++ prefix);
    for (0..1000) |_| feed(&p, &t, "%61");
    feed(&p, &t, "\x1b\\");
    try std.testing.expectEqualStrings("/srv/app", t.reportedCwd());
    feed(&p, &t, "\x1b]7;file://h/home\x1b\\");
    try std.testing.expectEqualStrings("/home", t.reportedCwd());
}

test "OSC 133 payloads: letter, options and D's exit status" {
    const a = parseMark("A").?;
    try std.testing.expectEqual(terminal.Mark.Kind.prompt, a.kind);
    try std.testing.expectEqual(terminal.Mark.Kind.prompt, parseMark("A;cl=m;aid=3").?.kind);
    try std.testing.expectEqual(terminal.Mark.Kind.input, parseMark("B").?.kind);
    try std.testing.expectEqual(terminal.Mark.Kind.output, parseMark("C").?.kind);
    try std.testing.expectEqual(@as(?i32, 130), parseMark("D;130").?.exit);
    try std.testing.expectEqual(@as(?i32, -1), parseMark("D;-1;aid=2").?.exit);
    try std.testing.expectEqual(@as(?i32, null), parseMark("D").?.exit);
    try std.testing.expectEqual(@as(?i32, null), parseMark("D;x").?.exit);
    try std.testing.expect(parseMark("") == null);
    try std.testing.expect(parseMark("P;k=i") == null);
    try std.testing.expect(parseMark("AB") == null);
}
