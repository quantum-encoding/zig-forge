//! RP2040 Hardware Abstraction Layer
//!
//! Register definitions for the Raspberry Pi Pico (RP2040) microcontroller.
//! Dual ARM Cortex-M0+ cores at up to 133MHz.
//!
//! Memory Map:
//!   0x40000000 - APB Peripherals
//!   0x50000000 - AHB-Lite Peripherals (SIO, PIO)
//!   0xD0000000 - SIO (Single-cycle I/O)
//!
//! The RP2040 has a unique "atomic" register access pattern:
//!   base + 0x0000 = normal read/write
//!   base + 0x1000 = atomic XOR
//!   base + 0x2000 = atomic SET
//!   base + 0x3000 = atomic CLEAR

const mmio = @import("../mmio.zig");

// =============================================================================
// Base Addresses
// =============================================================================

pub const SYSINFO_BASE: u32 = 0x40000000;
pub const SYSCFG_BASE: u32 = 0x40004000;
pub const CLOCKS_BASE: u32 = 0x40008000;
pub const RESETS_BASE: u32 = 0x4000C000;
pub const PSM_BASE: u32 = 0x40010000;
pub const IO_BANK0_BASE: u32 = 0x40014000;
pub const PADS_BANK0_BASE: u32 = 0x4001C000;
pub const TIMER_BASE: u32 = 0x40054000;
pub const WATCHDOG_BASE: u32 = 0x40058000;

pub const SIO_BASE: u32 = 0xD0000000;

// Atomic access offsets
pub const ATOMIC_XOR: u32 = 0x1000;
pub const ATOMIC_SET: u32 = 0x2000;
pub const ATOMIC_CLR: u32 = 0x3000;

// =============================================================================
// Resets
// =============================================================================

pub const resets = struct {
    pub const RESET = mmio.Mmio(packed struct {
        adc: bool,
        busctrl: bool,
        dma: bool,
        i2c0: bool,
        i2c1: bool,
        io_bank0: bool,
        io_qspi: bool,
        jtag: bool,
        pads_bank0: bool,
        pads_qspi: bool,
        pio0: bool,
        pio1: bool,
        pll_sys: bool,
        pll_usb: bool,
        pwm: bool,
        rtc: bool,
        spi0: bool,
        spi1: bool,
        syscfg: bool,
        sysinfo: bool,
        tbman: bool,
        timer: bool,
        uart0: bool,
        uart1: bool,
        usbctrl: bool,
        reserved: u7,
    }, RESETS_BASE + 0x00);

    pub const RESET_DONE = mmio.Mmio(u32, RESETS_BASE + 0x08);

    /// Release a peripheral from reset
    pub fn unreset(mask: u32) void {
        // Clear the reset bit (active low)
        const clr_ptr: *volatile u32 = @ptrFromInt(RESETS_BASE + ATOMIC_CLR);
        clr_ptr.* = mask;

        // Wait for reset to complete
        while ((RESET_DONE.read() & mask) != mask) {}
    }

    /// Put a peripheral into reset
    pub fn reset(mask: u32) void {
        const set_ptr: *volatile u32 = @ptrFromInt(RESETS_BASE + ATOMIC_SET);
        set_ptr.* = mask;
    }

    // Reset bit masks
    pub const MASK_IO_BANK0: u32 = 1 << 5;
    pub const MASK_PADS_BANK0: u32 = 1 << 8;
    pub const MASK_TIMER: u32 = 1 << 21;
    pub const MASK_UART0: u32 = 1 << 22;
    pub const MASK_UART1: u32 = 1 << 23;
};

// =============================================================================
// SIO (Single-cycle I/O)
// =============================================================================

pub const sio = struct {
    pub const CPUID = mmio.Mmio(u32, SIO_BASE + 0x00);

    /// GPIO output value
    pub const GPIO_OUT = mmio.Mmio(u32, SIO_BASE + 0x10);
    pub const GPIO_OUT_SET = mmio.Mmio(u32, SIO_BASE + 0x14);
    pub const GPIO_OUT_CLR = mmio.Mmio(u32, SIO_BASE + 0x18);
    pub const GPIO_OUT_XOR = mmio.Mmio(u32, SIO_BASE + 0x1C);

    /// GPIO output enable
    pub const GPIO_OE = mmio.Mmio(u32, SIO_BASE + 0x20);
    pub const GPIO_OE_SET = mmio.Mmio(u32, SIO_BASE + 0x24);
    pub const GPIO_OE_CLR = mmio.Mmio(u32, SIO_BASE + 0x28);
    pub const GPIO_OE_XOR = mmio.Mmio(u32, SIO_BASE + 0x2C);

    /// GPIO input value
    pub const GPIO_IN = mmio.Mmio(u32, SIO_BASE + 0x04);

    // Hardware spinlocks (32 available)
    pub const SPINLOCK_BASE = SIO_BASE + 0x100;

    pub fn acquireSpinlock(lock_num: u5) void {
        const addr = SPINLOCK_BASE + @as(u32, lock_num) * 4;
        const ptr: *volatile u32 = @ptrFromInt(addr);
        while (ptr.* == 0) {}
    }

    pub fn releaseSpinlock(lock_num: u5) void {
        const addr = SPINLOCK_BASE + @as(u32, lock_num) * 4;
        const ptr: *volatile u32 = @ptrFromInt(addr);
        ptr.* = 1; // Write any value to release
    }
};

// =============================================================================
// GPIO
// =============================================================================

pub const gpio = struct {
    /// GPIO function select values
    pub const Function = enum(u5) {
        xip = 0,
        spi = 1,
        uart = 2,
        i2c = 3,
        pwm = 4,
        sio = 5,
        pio0 = 6,
        pio1 = 7,
        clock = 8,
        usb = 9,
        null = 31,
    };

    /// Configure a GPIO pin function
    pub fn setFunction(pin: u5, func: Function) void {
        const ctrl_addr = IO_BANK0_BASE + 0x04 + @as(u32, pin) * 8;
        const ptr: *volatile u32 = @ptrFromInt(ctrl_addr);
        ptr.* = @intFromEnum(func);
    }

    /// Configure pad (drive strength, pull-up/down, etc.)
    pub fn configurePad(pin: u5, config: PadConfig) void {
        const pad_addr = PADS_BANK0_BASE + 0x04 + @as(u32, pin) * 4;
        const ptr: *volatile u32 = @ptrFromInt(pad_addr);
        ptr.* = @bitCast(config);
    }

    pub const PadConfig = packed struct {
        slewfast: bool = false,
        schmitt: bool = true,
        pde: bool = false, // Pull-down enable
        pue: bool = false, // Pull-up enable
        drive: u2 = 1, // 0=2mA, 1=4mA, 2=8mA, 3=12mA
        ie: bool = true, // Input enable
        od: bool = false, // Output disable
        reserved: u24 = 0,
    };

    /// Initialize a pin as output
    pub fn initOutput(pin: u5) void {
        setFunction(pin, .sio);
        sio.GPIO_OE_SET.write(@as(u32, 1) << pin);
    }

    /// Initialize a pin as input
    pub fn initInput(pin: u5, pull_up: bool, pull_down: bool) void {
        setFunction(pin, .sio);
        configurePad(pin, .{
            .pue = pull_up,
            .pde = pull_down,
        });
        sio.GPIO_OE_CLR.write(@as(u32, 1) << pin);
    }

    /// Set output high
    pub fn setHigh(pin: u5) void {
        sio.GPIO_OUT_SET.write(@as(u32, 1) << pin);
    }

    /// Set output low
    pub fn setLow(pin: u5) void {
        sio.GPIO_OUT_CLR.write(@as(u32, 1) << pin);
    }

    /// Toggle output
    pub fn toggle(pin: u5) void {
        sio.GPIO_OUT_XOR.write(@as(u32, 1) << pin);
    }

    /// Read input
    pub fn read(pin: u5) bool {
        return ((sio.GPIO_IN.read() >> pin) & 1) == 1;
    }
};

// =============================================================================
// Timer
// =============================================================================

pub const timer = struct {
    pub const TIMEHW = mmio.Mmio(u32, TIMER_BASE + 0x00);
    pub const TIMELW = mmio.Mmio(u32, TIMER_BASE + 0x04);
    pub const TIMEHR = mmio.Mmio(u32, TIMER_BASE + 0x08);
    pub const TIMELR = mmio.Mmio(u32, TIMER_BASE + 0x0C);

    /// Get the current 64-bit timer value (microseconds since boot)
    pub fn getTimeUs() u64 {
        // Must read TIMELR first, which latches TIMEHR
        const lo = TIMELR.read();
        const hi = TIMEHR.read();
        return (@as(u64, hi) << 32) | lo;
    }

    /// Busy-wait for a number of microseconds
    pub fn delayUs(us: u32) void {
        const target = getTimeUs() + us;
        while (getTimeUs() < target) {}
    }

    /// Busy-wait for a number of milliseconds
    pub fn delayMs(ms: u32) void {
        delayUs(ms * 1000);
    }
};

// =============================================================================
// Initialization
// =============================================================================

/// Initialize the RP2040 to a known state
pub fn init() void {
    // Unreset common peripherals
    resets.unreset(resets.MASK_IO_BANK0 | resets.MASK_PADS_BANK0 | resets.MASK_TIMER);
}

/// Get current CPU core ID (0 or 1)
pub fn getCoreId() u1 {
    return @truncate(sio.CPUID.read());
}

test "rp2040 register sizes" {
    const std = @import("std");
    try std.testing.expectEqual(@sizeOf(gpio.PadConfig), 4);
}
