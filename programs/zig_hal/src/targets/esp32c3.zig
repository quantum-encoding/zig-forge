//! ESP32-C3 Hardware Abstraction Layer
//!
//! Register definitions for the ESP32-C3 RISC-V microcontroller.
//! Single-core RISC-V at up to 160MHz with WiFi and Bluetooth LE.
//!
//! Memory Map:
//!   0x60000000 - Peripheral registers
//!   0x600C0000 - GPIO registers
//!   0x60008000 - UART registers

const mmio = @import("../mmio.zig");

// =============================================================================
// Base Addresses
// =============================================================================

pub const DR_REG_GPIO_BASE: u32 = 0x60004000;
pub const DR_REG_IO_MUX_BASE: u32 = 0x60009000;
pub const DR_REG_UART_BASE: u32 = 0x60000000;
pub const DR_REG_SYSTEM_BASE: u32 = 0x600C0000;
pub const DR_REG_TIMG0_BASE: u32 = 0x6001F000;
pub const DR_REG_RTC_CNTL_BASE: u32 = 0x60008000;

// =============================================================================
// GPIO
// =============================================================================

pub const gpio = struct {
    /// GPIO output register
    pub const GPIO_OUT_REG = mmio.Mmio(u32, DR_REG_GPIO_BASE + 0x04);
    pub const GPIO_OUT_W1TS_REG = mmio.Mmio(u32, DR_REG_GPIO_BASE + 0x08);
    pub const GPIO_OUT_W1TC_REG = mmio.Mmio(u32, DR_REG_GPIO_BASE + 0x0C);

    /// GPIO output enable register
    pub const GPIO_ENABLE_REG = mmio.Mmio(u32, DR_REG_GPIO_BASE + 0x20);
    pub const GPIO_ENABLE_W1TS_REG = mmio.Mmio(u32, DR_REG_GPIO_BASE + 0x24);
    pub const GPIO_ENABLE_W1TC_REG = mmio.Mmio(u32, DR_REG_GPIO_BASE + 0x28);

    /// GPIO input register
    pub const GPIO_IN_REG = mmio.Mmio(u32, DR_REG_GPIO_BASE + 0x3C);

    /// GPIO pin configuration (one per pin)
    pub fn pinReg(pin: u5) *volatile u32 {
        return @ptrFromInt(DR_REG_GPIO_BASE + 0x74 + @as(u32, pin) * 4);
    }

    /// IO MUX configuration (one per pin)
    pub fn ioMuxReg(pin: u5) *volatile u32 {
        return @ptrFromInt(DR_REG_IO_MUX_BASE + 0x04 + @as(u32, pin) * 4);
    }

    /// GPIO function values
    pub const Func = enum(u3) {
        gpio = 1,
        // Other functions are peripheral-specific
    };

    /// Initialize a pin as GPIO output
    pub fn initOutput(pin: u5) void {
        // Set IO MUX to GPIO function
        const mux = ioMuxReg(pin);
        mux.* = (mux.* & ~@as(u32, 0x7 << 12)) | (@as(u32, 1) << 12); // FUN_SEL = 1

        // Enable output
        GPIO_ENABLE_W1TS_REG.write(@as(u32, 1) << pin);
    }

    /// Initialize a pin as GPIO input
    pub fn initInput(pin: u5, pull_up: bool, pull_down: bool) void {
        // Set IO MUX to GPIO function with pull configuration
        const mux = ioMuxReg(pin);
        var val = mux.*;
        val = (val & ~@as(u32, 0x7 << 12)) | (@as(u32, 1) << 12); // FUN_SEL = 1
        val = (val & ~@as(u32, 1 << 8)) | (@as(u32, @intFromBool(pull_up)) << 8); // FUN_WPU
        val = (val & ~@as(u32, 1 << 7)) | (@as(u32, @intFromBool(pull_down)) << 7); // FUN_WPD
        val |= (1 << 9); // FUN_IE (input enable)
        mux.* = val;

        // Disable output
        GPIO_ENABLE_W1TC_REG.write(@as(u32, 1) << pin);
    }

    /// Set output high
    pub fn setHigh(pin: u5) void {
        GPIO_OUT_W1TS_REG.write(@as(u32, 1) << pin);
    }

    /// Set output low
    pub fn setLow(pin: u5) void {
        GPIO_OUT_W1TC_REG.write(@as(u32, 1) << pin);
    }

    /// Toggle output
    pub fn toggle(pin: u5) void {
        const current = GPIO_OUT_REG.read();
        if ((current >> pin) & 1 == 1) {
            setLow(pin);
        } else {
            setHigh(pin);
        }
    }

    /// Read input
    pub fn read(pin: u5) bool {
        return ((GPIO_IN_REG.read() >> pin) & 1) == 1;
    }
};

// =============================================================================
// Timer
// =============================================================================

pub const timer = struct {
    const TIMG0_T0CONFIG_REG = mmio.Mmio(u32, DR_REG_TIMG0_BASE + 0x00);
    const TIMG0_T0LO_REG = mmio.Mmio(u32, DR_REG_TIMG0_BASE + 0x04);
    const TIMG0_T0HI_REG = mmio.Mmio(u32, DR_REG_TIMG0_BASE + 0x08);
    const TIMG0_T0UPDATE_REG = mmio.Mmio(u32, DR_REG_TIMG0_BASE + 0x0C);

    /// Initialize timer for microsecond counting (assuming 40MHz APB clock)
    pub fn init() void {
        // Configure timer: enable, count up, divider = 40 (1MHz tick)
        TIMG0_T0CONFIG_REG.write(
            (1 << 31) | // Enable
                (1 << 30) | // Auto-reload
                (40 << 13), // Divider
        );
    }

    /// Get current timer value
    pub fn getTimeUs() u64 {
        // Trigger update
        TIMG0_T0UPDATE_REG.write(1);
        const lo = TIMG0_T0LO_REG.read();
        const hi = TIMG0_T0HI_REG.read();
        return (@as(u64, hi) << 32) | lo;
    }

    /// Delay in microseconds
    pub fn delayUs(us: u32) void {
        const target = getTimeUs() + us;
        while (getTimeUs() < target) {}
    }

    /// Delay in milliseconds
    pub fn delayMs(ms: u32) void {
        delayUs(ms * 1000);
    }
};

// =============================================================================
// System
// =============================================================================

pub const system = struct {
    /// Enable peripheral clock
    pub fn enablePeripheralClock(peripheral: u32) void {
        const reg: *volatile u32 = @ptrFromInt(DR_REG_SYSTEM_BASE + 0x18);
        reg.* |= peripheral;
    }

    /// Reset peripheral
    pub fn resetPeripheral(peripheral: u32) void {
        const reg: *volatile u32 = @ptrFromInt(DR_REG_SYSTEM_BASE + 0x20);
        reg.* |= peripheral;
        reg.* &= ~peripheral;
    }
};

test "esp32c3 module compiles" {
    _ = gpio;
    _ = timer;
}
