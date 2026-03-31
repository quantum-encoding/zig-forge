//! Input handling for Quantum Seed Vault
//!
//! Supports both hardware GPIO (joystick + buttons) and keyboard for testing.

const std = @import("std");
const linux = std.os.linux;

/// Input events that the UI responds to
pub const InputEvent = enum {
    none,
    up,
    down,
    left,
    right,
    select, // Joystick press or Enter
    key1, // Physical button 1
    key2, // Physical button 2
    key3, // Physical button 3
    back, // Escape or back navigation
    quit, // Request to exit application
};

/// Input state for current frame
pub const InputState = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    select: bool = false,
    key1: bool = false,
    key2: bool = false,
    key3: bool = false,
    back: bool = false,
    quit: bool = false,

    /// Get the primary event (first pressed button)
    pub fn getEvent(self: InputState) InputEvent {
        if (self.quit) return .quit;
        if (self.back) return .back;
        if (self.up) return .up;
        if (self.down) return .down;
        if (self.left) return .left;
        if (self.right) return .right;
        if (self.select) return .select;
        if (self.key1) return .key1;
        if (self.key2) return .key2;
        if (self.key3) return .key3;
        return .none;
    }
};

/// GPIO pin assignments (BCM numbering) for hardware
const GPIO_PINS = struct {
    const JOY_UP: u8 = 6;
    const JOY_DOWN: u8 = 19;
    const JOY_LEFT: u8 = 5;
    const JOY_RIGHT: u8 = 26;
    const JOY_PRESS: u8 = 13;
    const KEY1: u8 = 21;
    const KEY2: u8 = 20;
    const KEY3: u8 = 16;
};

/// Input handler - abstracts hardware/keyboard input
pub const InputHandler = struct {
    backend: Backend,
    last_state: InputState,
    debounce_time: i64,
    last_input_time: i64,

    const Self = @This();
    const DEBOUNCE_MS: i64 = 50;

    const Backend = union(enum) {
        gpio: GpioBackend,
        keyboard: KeyboardBackend,
    };

    /// Initialize with automatic backend detection
    pub fn init() Self {
        var backend: Backend = undefined;
        if (GpioBackend.isAvailable()) {
            if (GpioBackend.init()) |gpio| {
                backend = .{ .gpio = gpio };
            } else |_| {
                backend = .{ .keyboard = KeyboardBackend.init() };
            }
        } else {
            backend = .{ .keyboard = KeyboardBackend.init() };
        }

        return Self{
            .backend = backend,
            .last_state = .{},
            .debounce_time = DEBOUNCE_MS,
            .last_input_time = 0,
        };
    }

    /// Force keyboard backend (for testing)
    pub fn initKeyboard() Self {
        return Self{
            .backend = .{ .keyboard = KeyboardBackend.init() },
            .last_state = .{},
            .debounce_time = DEBOUNCE_MS,
            .last_input_time = 0,
        };
    }

    /// Get current time in milliseconds (using clock_gettime)
    fn getTimeMs() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        // Convert timespec to milliseconds
        const sec_ms: i64 = @as(i64, @intCast(ts.sec)) * 1000;
        const nsec_ms: i64 = @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
        return sec_ms + nsec_ms;
    }

    /// Poll for input events
    pub fn poll(self: *Self) InputState {
        const now = getTimeMs();

        // Apply debouncing
        if (now - self.last_input_time < self.debounce_time) {
            return .{};
        }

        const state = switch (self.backend) {
            .gpio => |*gpio| gpio.read(),
            .keyboard => |*kb| kb.read(),
        };

        // Only report on state change (edge detection)
        var result = InputState{};
        if (state.up and !self.last_state.up) result.up = true;
        if (state.down and !self.last_state.down) result.down = true;
        if (state.left and !self.last_state.left) result.left = true;
        if (state.right and !self.last_state.right) result.right = true;
        if (state.select and !self.last_state.select) result.select = true;
        if (state.key1 and !self.last_state.key1) result.key1 = true;
        if (state.key2 and !self.last_state.key2) result.key2 = true;
        if (state.key3 and !self.last_state.key3) result.key3 = true;
        if (state.back and !self.last_state.back) result.back = true;
        if (state.quit and !self.last_state.quit) result.quit = true;

        self.last_state = state;

        // Update debounce timer if any input
        if (result.getEvent() != .none) {
            self.last_input_time = now;
        }

        return result;
    }

    /// Deinitialize
    pub fn deinit(self: *Self) void {
        switch (self.backend) {
            .gpio => |*gpio| gpio.deinit(),
            .keyboard => |*kb| kb.deinit(),
        }
    }

    /// Get backend name for display
    pub fn getBackendName(self: *const Self) []const u8 {
        return switch (self.backend) {
            .gpio => "GPIO (Hardware)",
            .keyboard => "Keyboard (Terminal)",
        };
    }
};

/// GPIO backend for Raspberry Pi hardware
const GpioBackend = struct {
    pin_fds: [8]std.posix.fd_t,

    const Self = @This();

    pub fn isAvailable() bool {
        // Check if path exists by trying to open it
        const fd = std.posix.openatZ(std.c.AT.FDCWD, "/sys/class/gpio", .{ .ACCMODE = .RDONLY }, 0) catch return false;
        _ = std.c.close(fd);
        return true;
    }

    pub fn init() !Self {
        var self = Self{
            .pin_fds = .{ -1, -1, -1, -1, -1, -1, -1, -1 },
        };

        // Export all input pins
        const pins = [_]u8{
            GPIO_PINS.JOY_UP,
            GPIO_PINS.JOY_DOWN,
            GPIO_PINS.JOY_LEFT,
            GPIO_PINS.JOY_RIGHT,
            GPIO_PINS.JOY_PRESS,
            GPIO_PINS.KEY1,
            GPIO_PINS.KEY2,
            GPIO_PINS.KEY3,
        };

        for (pins, 0..) |pin, i| {
            self.pin_fds[i] = try exportGpioInput(pin);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.pin_fds) |fd| {
            if (fd >= 0) _ = std.c.close(fd);
        }
    }

    pub fn read(self: *Self) InputState {
        return InputState{
            .up = self.readPin(0),
            .down = self.readPin(1),
            .left = self.readPin(2),
            .right = self.readPin(3),
            .select = self.readPin(4),
            .key1 = self.readPin(5),
            .key2 = self.readPin(6),
            .key3 = self.readPin(7),
            .back = false,
            .quit = false,
        };
    }

    fn readPin(self: *Self, idx: usize) bool {
        const fd = self.pin_fds[idx];
        if (fd < 0) return false;

        // For sysfs GPIO files, we can read without seeking
        // (the file is always short)
        var buf: [2]u8 = undefined;
        const result = std.c.read(fd, &buf, buf.len);
        if (result <= 0) return false;

        // Active low: '0' means pressed
        return buf[0] == '0';
    }
};

/// Keyboard backend for terminal testing
const KeyboardBackend = struct {
    orig_termios: ?std.posix.termios,
    stdin_fd: std.posix.fd_t,

    const Self = @This();

    pub fn init() Self {
        var self = Self{
            .orig_termios = null,
            .stdin_fd = std.posix.STDIN_FILENO,
        };

        // Set terminal to raw mode for immediate key reading
        if (std.posix.tcgetattr(self.stdin_fd)) |termios| {
            self.orig_termios = termios;

            var raw = termios;
            // Disable canonical mode and echo
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            // Minimum 0 characters, no timeout (non-blocking)
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

            _ = std.posix.tcsetattr(self.stdin_fd, .NOW, raw) catch {};
        } else |_| {}

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Restore original terminal settings
        if (self.orig_termios) |termios| {
            _ = std.posix.tcsetattr(self.stdin_fd, .NOW, termios) catch {};
        }
    }

    pub fn read(self: *Self) InputState {
        var state = InputState{};
        var buf: [8]u8 = undefined;

        // Non-blocking read
        const result = std.c.read(self.stdin_fd, &buf, buf.len);
        if (result <= 0) return state;
        const n: usize = @intCast(result);

        // Parse input
        if (n >= 1) {
            switch (buf[0]) {
                'q', 'Q' => state.quit = true,
                27 => { // Escape sequence
                    if (n == 1) {
                        state.back = true;
                    } else if (n >= 3 and buf[1] == '[') {
                        switch (buf[2]) {
                            'A' => state.up = true, // Up arrow
                            'B' => state.down = true, // Down arrow
                            'C' => state.right = true, // Right arrow
                            'D' => state.left = true, // Left arrow
                            else => {},
                        }
                    }
                },
                '\n', '\r' => state.select = true,
                ' ' => state.select = true,
                '1' => state.key1 = true,
                '2' => state.key2 = true,
                '3' => state.key3 = true,
                'w', 'W', 'k', 'K' => state.up = true,
                's', 'S', 'j', 'J' => state.down = true,
                'a', 'A', 'h', 'H' => state.left = true,
                'd', 'D', 'l', 'L' => state.right = true,
                else => {},
            }
        }

        return state;
    }
};

/// Export a GPIO pin as input with pull-up
fn exportGpioInput(pin: u8) !std.posix.fd_t {
    // Export the GPIO
    const export_fd = try std.posix.openatZ(std.c.AT.FDCWD, "/sys/class/gpio/export", .{ .ACCMODE = .WRONLY }, 0);
    defer _ = std.c.close(export_fd);

    // Convert pin to string manually
    var buf: [4]u8 = undefined;
    var len: usize = 0;
    if (pin >= 100) {
        buf[len] = '0' + pin / 100;
        len += 1;
    }
    if (pin >= 10) {
        buf[len] = '0' + (pin / 10) % 10;
        len += 1;
    }
    buf[len] = '0' + pin % 10;
    len += 1;
    _ = std.c.write(export_fd, &buf, len); // May already be exported

    // Wait for sysfs
    var ts = linux.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = linux.nanosleep(&ts, null);

    // Set direction to input
    var dir_path_buf: [64]u8 = undefined;
    const dir_path_len = (std.fmt.bufPrint(&dir_path_buf, "/sys/class/gpio/gpio{d}/direction", .{pin}) catch unreachable).len;
    dir_path_buf[dir_path_len] = 0;

    const dir_fd = try std.posix.openatZ(std.c.AT.FDCWD, dir_path_buf[0..dir_path_len :0], .{ .ACCMODE = .WRONLY }, 0);
    defer _ = std.c.close(dir_fd);
    const in_str = "in";
    const write_result = std.c.write(dir_fd, in_str.ptr, in_str.len);
    if (write_result < 0) return error.WriteError;

    // Open value file for reading
    var val_path_buf: [64]u8 = undefined;
    const val_path_len = (std.fmt.bufPrint(&val_path_buf, "/sys/class/gpio/gpio{d}/value", .{pin}) catch unreachable).len;
    val_path_buf[val_path_len] = 0;

    return try std.posix.openatZ(std.c.AT.FDCWD, val_path_buf[0..val_path_len :0], .{ .ACCMODE = .RDONLY }, 0);
}
