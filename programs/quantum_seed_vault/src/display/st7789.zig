//! ST7789VW Display Driver for Raspberry Pi
//!
//! Controls the Waveshare 1.3" LCD HAT via SPI.
//! This is the hardware driver - use TerminalDisplay for testing.

const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");
const Framebuffer = @import("framebuffer.zig").Framebuffer;

const Color = types.Color;
const WIDTH = types.WIDTH;
const HEIGHT = types.HEIGHT;

/// GPIO pin assignments (BCM numbering)
const GPIO = struct {
    const DC: u8 = 25; // Data/Command
    const RST: u8 = 27; // Reset
    const BL: u8 = 24; // Backlight
    const CS: u8 = 8; // Chip Select (directly handled by SPI)
};

/// ST7789 Commands
const CMD = struct {
    const NOP: u8 = 0x00;
    const SWRESET: u8 = 0x01;
    const SLPIN: u8 = 0x10;
    const SLPOUT: u8 = 0x11;
    const NORON: u8 = 0x13;
    const INVOFF: u8 = 0x20;
    const INVON: u8 = 0x21;
    const DISPOFF: u8 = 0x28;
    const DISPON: u8 = 0x29;
    const CASET: u8 = 0x2A;
    const RASET: u8 = 0x2B;
    const RAMWR: u8 = 0x2C;
    const MADCTL: u8 = 0x36;
    const COLMOD: u8 = 0x3A;
};

/// ST7789 Display Driver
pub const ST7789 = struct {
    spi_fd: std.posix.fd_t,
    dc_fd: std.posix.fd_t,
    rst_fd: std.posix.fd_t,
    bl_fd: std.posix.fd_t,
    initialized: bool,

    const Self = @This();
    const SPI_DEVICE = "/dev/spidev0.0";
    const SPI_SPEED_HZ: u32 = 40_000_000; // 40 MHz

    /// Initialize the display driver
    pub fn init() !Self {
        var self = Self{
            .spi_fd = -1,
            .dc_fd = -1,
            .rst_fd = -1,
            .bl_fd = -1,
            .initialized = false,
        };

        // Open SPI device
        self.spi_fd = try std.posix.openatZ(std.c.AT.FDCWD, SPI_DEVICE, .{ .ACCMODE = .RDWR }, 0);
        errdefer _ = std.c.close(self.spi_fd);

        // Configure SPI (would use ioctl in real implementation)
        try self.configureSpi();

        // Export and configure GPIO pins
        self.dc_fd = try self.exportGpio(GPIO.DC, .out);
        errdefer self.unexportGpio(GPIO.DC);

        self.rst_fd = try self.exportGpio(GPIO.RST, .out);
        errdefer self.unexportGpio(GPIO.RST);

        self.bl_fd = try self.exportGpio(GPIO.BL, .out);
        errdefer self.unexportGpio(GPIO.BL);

        // Hardware reset and initialization
        try self.hardwareReset();
        try self.initSequence();

        self.initialized = true;
        return self;
    }

    /// Deinitialize and cleanup
    pub fn deinit(self: *Self) void {
        if (!self.initialized) return;

        // Turn off backlight
        self.gpioWrite(self.bl_fd, 0);

        // Close file descriptors
        if (self.spi_fd >= 0) _ = std.c.close(self.spi_fd);
        if (self.dc_fd >= 0) _ = std.c.close(self.dc_fd);
        if (self.rst_fd >= 0) _ = std.c.close(self.rst_fd);
        if (self.bl_fd >= 0) _ = std.c.close(self.bl_fd);

        // Unexport GPIOs
        self.unexportGpio(GPIO.DC);
        self.unexportGpio(GPIO.RST);
        self.unexportGpio(GPIO.BL);

        self.initialized = false;
    }

    /// Update display with framebuffer contents
    pub fn update(self: *Self, fb: *const Framebuffer) !void {
        if (!self.initialized) return error.NotInitialized;

        // Set window to full screen
        try self.setWindow(0, 0, WIDTH - 1, HEIGHT - 1);

        // Write pixel data
        try self.writeData(fb.getBufferBytes());
    }

    /// Set backlight brightness (0 = off, 1 = on)
    pub fn setBacklight(self: *Self, on: bool) void {
        self.gpioWrite(self.bl_fd, if (on) 1 else 0);
    }

    // Private methods

    fn configureSpi(self: *Self) !void {
        // In real implementation, use ioctl to set:
        // - SPI mode 0
        // - 8 bits per word
        // - Speed to SPI_SPEED_HZ
        _ = self;
    }

    fn hardwareReset(self: *Self) !void {
        // RST low for 10ms
        self.gpioWrite(self.rst_fd, 0);
        var ts1 = linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts1, null);

        // RST high, wait 120ms
        self.gpioWrite(self.rst_fd, 1);
        var ts2 = linux.timespec{ .sec = 0, .nsec = 120 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts2, null);
    }

    fn initSequence(self: *Self) !void {
        // Software reset
        try self.writeCommand(CMD.SWRESET);
        var ts_init1 = linux.timespec{ .sec = 0, .nsec = 150 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts_init1, null);

        // Sleep out
        try self.writeCommand(CMD.SLPOUT);
        var ts_init2 = linux.timespec{ .sec = 0, .nsec = 120 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts_init2, null);

        // Memory data access control
        try self.writeCommand(CMD.MADCTL);
        try self.writeData(&[_]u8{0x00});

        // Interface pixel format (RGB565)
        try self.writeCommand(CMD.COLMOD);
        try self.writeData(&[_]u8{0x55});

        // Porch setting
        try self.writeCommand(0xB2);
        try self.writeData(&[_]u8{ 0x0C, 0x0C, 0x00, 0x33, 0x33 });

        // Gate control
        try self.writeCommand(0xB7);
        try self.writeData(&[_]u8{0x35});

        // VCOM setting
        try self.writeCommand(0xBB);
        try self.writeData(&[_]u8{0x19});

        // LCM control
        try self.writeCommand(0xC0);
        try self.writeData(&[_]u8{0x2C});

        // VDV and VRH command enable
        try self.writeCommand(0xC2);
        try self.writeData(&[_]u8{0x01});

        // VRH set
        try self.writeCommand(0xC3);
        try self.writeData(&[_]u8{0x12});

        // VDV set
        try self.writeCommand(0xC4);
        try self.writeData(&[_]u8{0x20});

        // Frame rate control (60Hz)
        try self.writeCommand(0xC6);
        try self.writeData(&[_]u8{0x0F});

        // Power control 1
        try self.writeCommand(0xD0);
        try self.writeData(&[_]u8{ 0xA4, 0xA1 });

        // Positive voltage gamma
        try self.writeCommand(0xE0);
        try self.writeData(&[_]u8{
            0xD0, 0x04, 0x0D, 0x11, 0x13, 0x2B, 0x3F,
            0x54, 0x4C, 0x18, 0x0D, 0x0B, 0x1F, 0x23,
        });

        // Negative voltage gamma
        try self.writeCommand(0xE1);
        try self.writeData(&[_]u8{
            0xD0, 0x04, 0x0C, 0x11, 0x13, 0x2C, 0x3F,
            0x44, 0x51, 0x2F, 0x1F, 0x1F, 0x20, 0x23,
        });

        // Display inversion on (required for this display)
        try self.writeCommand(CMD.INVON);

        // Normal display mode
        try self.writeCommand(CMD.NORON);
        var ts_noron = linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts_noron, null);

        // Display on
        try self.writeCommand(CMD.DISPON);
        var ts_dispon = linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts_dispon, null);

        // Backlight on
        self.gpioWrite(self.bl_fd, 1);
    }

    fn setWindow(self: *Self, x0: u16, y0: u16, x1: u16, y1: u16) !void {
        // Column address set
        try self.writeCommand(CMD.CASET);
        try self.writeData(&[_]u8{
            @truncate(x0 >> 8),
            @truncate(x0 & 0xFF),
            @truncate(x1 >> 8),
            @truncate(x1 & 0xFF),
        });

        // Row address set
        try self.writeCommand(CMD.RASET);
        try self.writeData(&[_]u8{
            @truncate(y0 >> 8),
            @truncate(y0 & 0xFF),
            @truncate(y1 >> 8),
            @truncate(y1 & 0xFF),
        });

        // Memory write
        try self.writeCommand(CMD.RAMWR);
    }

    fn writeCommand(self: *Self, cmd: u8) !void {
        self.gpioWrite(self.dc_fd, 0); // DC low = command
        const cmd_buf = [_]u8{cmd};
        const result = std.c.write(self.spi_fd, &cmd_buf, 1);
        if (result < 0) return error.WriteError;
    }

    fn writeData(self: *Self, data: []const u8) !void {
        self.gpioWrite(self.dc_fd, 1); // DC high = data
        const result = std.c.write(self.spi_fd, data.ptr, data.len);
        if (result < 0) return error.WriteError;
    }

    fn exportGpio(self: *Self, pin: u8, direction: enum { in, out }) !std.posix.fd_t {
        _ = self;

        // Export the GPIO
        const export_fd = std.posix.openatZ(std.c.AT.FDCWD, "/sys/class/gpio/export", .{ .ACCMODE = .WRONLY }, 0) catch |err| {
            // May already be exported
            if (err == error.FileNotFound) return error.GpioNotAvailable;
            return err;
        };
        defer _ = std.c.close(export_fd);

        var buf: [4]u8 = undefined;
        const len = std.fmt.formatIntBuf(&buf, pin, 10, .lower, .{});
        _ = std.c.write(export_fd, &buf, len);

        // Small delay for sysfs to create the files
        var ts_export = linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts_export, null);

        // Set direction
        var dir_path_buf: [64]u8 = undefined;
        const dir_path_len = (std.fmt.bufPrint(&dir_path_buf, "/sys/class/gpio/gpio{d}/direction", .{pin}) catch unreachable).len;
        dir_path_buf[dir_path_len] = 0;

        const dir_fd = try std.posix.openatZ(std.c.AT.FDCWD, dir_path_buf[0..dir_path_len :0], .{ .ACCMODE = .WRONLY }, 0);
        defer _ = std.c.close(dir_fd);

        const dir_str = if (direction == .out) "out" else "in";
        const write_result = std.c.write(dir_fd, dir_str.ptr, dir_str.len);
        if (write_result < 0) return error.WriteError;

        // Open value file
        var val_path_buf: [64]u8 = undefined;
        const val_path_len = (std.fmt.bufPrint(&val_path_buf, "/sys/class/gpio/gpio{d}/value", .{pin}) catch unreachable).len;
        val_path_buf[val_path_len] = 0;

        return try std.posix.openatZ(std.c.AT.FDCWD, val_path_buf[0..val_path_len :0], .{ .ACCMODE = .RDWR }, 0);
    }

    fn unexportGpio(self: *Self, pin: u8) void {
        _ = self;

        const unexport_fd = std.posix.openatZ(std.c.AT.FDCWD, "/sys/class/gpio/unexport", .{ .ACCMODE = .WRONLY }, 0) catch return;
        defer _ = std.c.close(unexport_fd);

        var buf: [4]u8 = undefined;
        const len = std.fmt.formatIntBuf(&buf, pin, 10, .lower, .{});
        _ = std.c.write(unexport_fd, &buf, len);
    }

    fn gpioWrite(self: *Self, fd: std.posix.fd_t, value: u1) void {
        _ = self;
        if (fd < 0) return;
        const val_str = if (value == 1) "1" else "0";
        _ = std.c.write(fd, val_str.ptr, val_str.len);
    }
};

/// Check if running on Raspberry Pi with GPIO available
pub fn isHardwareAvailable() bool {
    // Check if path exists by trying to open it
    const dir = std.posix.openatZ(std.c.AT.FDCWD, "/sys/class/gpio", .{ .ACCMODE = .RDONLY }, 0) catch return false;
    _ = std.c.close(dir);
    return true;
}
