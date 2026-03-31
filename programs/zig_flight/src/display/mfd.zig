//! Multi-Function Display controller — page switching, input dispatch, render dispatch.
//! Owns the AlertSystem and AircraftLimits. Evaluates alerts each frame before page dispatch.
//! Optionally dispatches keyboard commands to X-Plane via WebSocket.

const std = @import("std");
const tui = @import("tui_backend.zig");
const renderer_mod = @import("renderer.zig");
const FlightData = @import("../flight_data.zig").FlightData;
const DatarefRegistry = @import("../dataref_registry.zig").DatarefRegistry;
const AlertSystem = @import("../alerts.zig").AlertSystem;
const AlertPriority = @import("../alerts.zig").AlertPriority;
const limits = @import("../limits.zig");
const AircraftLimits = limits.AircraftLimits;
const commands = @import("../commands.zig");
const XPlaneClient = @import("../xplane_client.zig").XPlaneClient;
const pfd = @import("pfd.zig");
const eicas = @import("eicas.zig");
const nd = @import("nd.zig");
const fms = @import("fms.zig");

pub const MfdPage = enum(u8) {
    pfd = 1,
    nd = 2,
    eicas = 3,
    fms = 4,
    status = 5,
};

pub const Mfd = struct {
    current_page: MfdPage = .pfd,
    renderer: renderer_mod.Renderer = .{},
    quit_requested: bool = false,
    alert_system: AlertSystem = AlertSystem.init(),
    aircraft_limits: AircraftLimits = limits.GENERIC_JET,
    client: ?*XPlaneClient = null,
    registry: ?*const DatarefRegistry = null,
    demo_mode: bool = false,

    pub fn init() Mfd {
        var self = Mfd{};
        const size = tui.getTermSize();
        self.renderer.fb.width = @min(size.cols, renderer_mod.MAX_WIDTH);
        self.renderer.fb.height = @min(size.rows, renderer_mod.MAX_HEIGHT);
        return self;
    }

    /// Handle a keypress. Returns true if consumed.
    pub fn handleInput(self: *Mfd, key: u8, fd: *const FlightData) bool {
        switch (key) {
            '1' => {
                self.current_page = .pfd;
                return true;
            },
            '2' => {
                self.current_page = .nd;
                return true;
            },
            '3' => {
                self.current_page = .eicas;
                return true;
            },
            '4' => {
                self.current_page = .fms;
                return true;
            },
            '5' => {
                self.current_page = .status;
                return true;
            },
            'q', 'Q' => {
                self.quit_requested = true;
                return true;
            },
            else => {
                // Try command dispatch
                if (commands.keyToCommand(key)) |cmd| {
                    if (self.client) |c| {
                        if (self.registry) |reg| {
                            commands.execute(c, cmd, fd, reg);
                        }
                    }
                    return true;
                }
                return false;
            },
        }
    }

    /// Render the current page.
    pub fn render(self: *Mfd, fd: *const FlightData, reg: *const DatarefRegistry) void {
        // Evaluate alerts before rendering
        self.alert_system.evaluate(fd, &self.aircraft_limits);

        self.renderer.beginFrame();

        switch (self.current_page) {
            .pfd => pfd.render(&self.renderer.fb, fd),
            .nd => nd.render(&self.renderer.fb, fd),
            .eicas => eicas.render(&self.renderer.fb, fd, &self.alert_system),
            .fms => fms.render(&self.renderer.fb, fd),
            .status => self.renderStatus(fd, reg),
        }

        // Warning banner overlay — shown on ALL pages when any warning is active
        if (self.alert_system.hasWarning()) {
            self.renderWarningBanner();
        }

        self.renderPageBar();
        self.renderer.endFrame();
        self.renderer.flush();
    }

    fn renderWarningBanner(self: *Mfd) void {
        const fb = &self.renderer.fb;
        const alerts = self.alert_system.activeAlerts();
        if (alerts.len == 0) return;

        // Find first warning message
        var msg: []const u8 = "WARNING";
        for (alerts) |a| {
            if (a.priority == .warning) {
                msg = a.message;
                break;
            }
        }

        // Red banner across full width
        var col: u16 = 0;
        while (col < fb.width) : (col += 1) {
            fb.setCell(0, col, ' ', .bright_white, .red, true);
        }

        // Center the warning text
        const text_col = if (fb.width > msg.len) (fb.width - @as(u16, @intCast(msg.len))) / 2 else 0;
        fb.putStr(0, text_col, msg, .bright_white, .red, true);
    }

    fn renderPageBar(self: *Mfd) void {
        const fb = &self.renderer.fb;
        const row = fb.height -| 2;
        const cmd_row = fb.height -| 1;

        // Page selector row
        fb.putStr(row, 0, " 1:PFD  2:NAV  3:EICAS  4:FMS  5:STATUS          q:QUIT ", .dim, .black, false);

        // Highlight current page
        const info = pageBarInfo(self.current_page);
        var i: u16 = 0;
        while (i < info.len) : (i += 1) {
            if (info.col + i < fb.width) {
                fb.cells[row][info.col + i].fg = .bright_green;
                fb.cells[row][info.col + i].bold = true;
            }
        }

        // Command hints row
        if (self.demo_mode) {
            fb.putStr(cmd_row, 0, " DEMO PLAYBACK                                           ", .bright_yellow, .black, true);
        } else if (self.client != null) {
            fb.putStr(cmd_row, 0, " a:AP  h/H:HDG  v/V:ALT  s/S:SPD  w/W:VS               ", .dim, .black, false);
        } else {
            fb.putStr(cmd_row, 0, "                                                         ", .dim, .black, false);
        }
    }

    const PageBarInfo = struct { col: u16, len: u16 };
    fn pageBarInfo(page: MfdPage) PageBarInfo {
        return switch (page) {
            .pfd => .{ .col = 1, .len = 5 },
            .nd => .{ .col = 8, .len = 5 },
            .eicas => .{ .col = 15, .len = 7 },
            .fms => .{ .col = 24, .len = 5 },
            .status => .{ .col = 31, .len = 8 },
        };
    }

    fn renderStatus(self: *Mfd, fd: *const FlightData, reg: *const DatarefRegistry) void {
        const fb = &self.renderer.fb;
        const w = fb.width;
        fb.drawBox(0, 0, w, 18, .dim);
        fb.putStr(0, 3, " STATUS ", .bright_green, .black, true);

        fb.putStr(2, 3, "zig_flight MFD v0.5.0", .cyan, .black, true);
        fb.putStr(3, 3, "X-Plane 12 Avionics Toolkit", .dim, .black, false);
        fb.putStr(4, 3, "Phase 5: Demo + Commands", .dim, .black, false);

        fb.drawHLine(6, 3, 40, .dim);

        fb.putFmt(7, 3, "Update tick:     {d}", .{fd.update_tick}, .green, .black, false);
        fb.putFmt(8, 3, "Updates recv:    {d}", .{fd.updates_received}, .green, .black, false);
        fb.putFmt(9, 3, "Datarefs:        {d} resolved", .{reg.count}, .green, .black, false);
        fb.putFmt(10, 3, "Terminal:        {d}x{d}", .{ fb.width, fb.height }, .green, .black, false);
        fb.putFmt(11, 3, "Active alerts:   {d}", .{self.alert_system.active_count}, .green, .black, false);
        fb.putFmt(12, 3, "Aircraft:        Vmo={d:.0} bank={d:.0}", .{
            self.aircraft_limits.vmo,
            self.aircraft_limits.max_bank_deg,
        }, .green, .black, false);

        const mode: []const u8 = if (self.demo_mode) "DEMO" else if (self.client != null) "LIVE" else "OFFLINE";
        fb.putFmt(13, 3, "Mode:            {s}", .{mode}, .green, .black, false);

        fb.drawHLine(15, 3, 40, .dim);
        fb.putStr(16, 3, "Zero heap allocation in hot path", .bright_green, .black, true);
        fb.putStr(17, 3, "JSF AV C++ compliance via Zig 0.16", .dim, .black, false);
    }
};
