//! STM32F4 Hardware Abstraction Layer
//!
//! Register definitions for STM32F4xx series microcontrollers (ARM Cortex-M4).
//! Based on STM32F4xx Reference Manual (RM0090).
//!
//! Memory Map:
//!   0x40000000 - APB1 Peripherals
//!   0x40010000 - APB2 Peripherals
//!   0x40020000 - AHB1 Peripherals (GPIO, DMA, etc.)
//!   0x40023800 - RCC (Reset and Clock Control)
//!
//! Example - Blink LED on PA5 (Nucleo-F401RE):
//! ```zig
//! const stm32 = @import("targets/stm32f4.zig");
//! stm32.rcc.AHB1ENR.modify(.{ .GPIOAEN = 1 });  // Enable GPIOA clock
//! stm32.gpio.GPIOA.MODER.modify(.{ .MODER5 = 0b01 });  // Output mode
//! stm32.gpio.GPIOA.ODR.modify(.{ .ODR5 = 1 });  // Set high
//! ```

const mmio = @import("../mmio.zig");
const bitfield = @import("../bitfield.zig");

// =============================================================================
// Base Addresses
// =============================================================================

pub const PERIPH_BASE: u32 = 0x40000000;
pub const APB1_BASE: u32 = PERIPH_BASE;
pub const APB2_BASE: u32 = PERIPH_BASE + 0x10000;
pub const AHB1_BASE: u32 = PERIPH_BASE + 0x20000;
pub const AHB2_BASE: u32 = PERIPH_BASE + 0x10000000;

// GPIO base addresses
pub const GPIOA_BASE: u32 = AHB1_BASE + 0x0000;
pub const GPIOB_BASE: u32 = AHB1_BASE + 0x0400;
pub const GPIOC_BASE: u32 = AHB1_BASE + 0x0800;
pub const GPIOD_BASE: u32 = AHB1_BASE + 0x0C00;
pub const GPIOE_BASE: u32 = AHB1_BASE + 0x1000;

// RCC base address
pub const RCC_BASE: u32 = AHB1_BASE + 0x3800;

// =============================================================================
// RCC (Reset and Clock Control)
// =============================================================================

pub const rcc = struct {
    /// RCC Clock Control Register
    pub const CR = mmio.Mmio(packed struct {
        HSION: bool,
        HSIRDY: bool,
        reserved1: u1,
        HSITRIM: u5,
        HSICAL: u8,
        HSEON: bool,
        HSERDY: bool,
        HSEBYP: bool,
        CSSON: bool,
        reserved2: u4,
        PLLON: bool,
        PLLRDY: bool,
        PLLI2SON: bool,
        PLLI2SRDY: bool,
        reserved3: u4,
    }, RCC_BASE + 0x00);

    /// RCC PLL Configuration Register
    pub const PLLCFGR = mmio.Mmio(packed struct {
        PLLM: u6,
        PLLN: u9,
        reserved1: u1,
        PLLP: u2,
        reserved2: u4,
        PLLSRC: u1,
        reserved3: u1,
        PLLQ: u4,
        reserved4: u4,
    }, RCC_BASE + 0x04);

    /// RCC Clock Configuration Register
    pub const CFGR = mmio.Mmio(packed struct {
        SW: u2,
        SWS: u2,
        HPRE: u4,
        reserved1: u2,
        PPRE1: u3,
        PPRE2: u3,
        RTCPRE: u5,
        MCO1: u2,
        I2SSCR: u1,
        MCO1PRE: u3,
        MCO2PRE: u3,
        MCO2: u2,
    }, RCC_BASE + 0x08);

    /// RCC AHB1 Peripheral Clock Enable Register
    pub const AHB1ENR = mmio.Mmio(packed struct {
        GPIOAEN: bool,
        GPIOBEN: bool,
        GPIOCEN: bool,
        GPIODEN: bool,
        GPIOEEN: bool,
        reserved1: u2,
        GPIOHEN: bool,
        reserved2: u4,
        CRCEN: bool,
        reserved3: u5,
        BKPSRAMEN: bool,
        reserved4: u1,
        CCMDATARAMEN: bool,
        DMA1EN: bool,
        DMA2EN: bool,
        reserved5: u9,
    }, RCC_BASE + 0x30);

    /// RCC APB1 Peripheral Clock Enable Register
    pub const APB1ENR = mmio.Mmio(packed struct {
        TIM2EN: bool,
        TIM3EN: bool,
        TIM4EN: bool,
        TIM5EN: bool,
        reserved1: u7,
        WWDGEN: bool,
        reserved2: u2,
        SPI2EN: bool,
        SPI3EN: bool,
        reserved3: u1,
        USART2EN: bool,
        reserved4: u3,
        I2C1EN: bool,
        I2C2EN: bool,
        I2C3EN: bool,
        reserved5: u4,
        PWREN: bool,
        reserved6: u3,
    }, RCC_BASE + 0x40);

    /// RCC APB2 Peripheral Clock Enable Register
    pub const APB2ENR = mmio.Mmio(packed struct {
        TIM1EN: bool,
        reserved1: u3,
        USART1EN: bool,
        USART6EN: bool,
        reserved2: u2,
        ADC1EN: bool,
        reserved3: u2,
        SDIOEN: bool,
        SPI1EN: bool,
        SPI4EN: bool,
        SYSCFGEN: bool,
        reserved4: u1,
        TIM9EN: bool,
        TIM10EN: bool,
        TIM11EN: bool,
        reserved5: u13,
    }, RCC_BASE + 0x44);
};

// =============================================================================
// GPIO (General Purpose I/O)
// =============================================================================

/// GPIO Register Block
pub fn GpioPort(comptime base: u32) type {
    return struct {
        /// GPIO Mode Register - 2 bits per pin (input/output/alt/analog)
        pub const MODER = mmio.Mmio(packed struct {
            MODER0: u2, MODER1: u2, MODER2: u2, MODER3: u2,
            MODER4: u2, MODER5: u2, MODER6: u2, MODER7: u2,
            MODER8: u2, MODER9: u2, MODER10: u2, MODER11: u2,
            MODER12: u2, MODER13: u2, MODER14: u2, MODER15: u2,
        }, base + 0x00);

        /// GPIO Output Type Register - 1 bit per pin (push-pull/open-drain)
        pub const OTYPER = mmio.Mmio(packed struct {
            OT0: u1, OT1: u1, OT2: u1, OT3: u1,
            OT4: u1, OT5: u1, OT6: u1, OT7: u1,
            OT8: u1, OT9: u1, OT10: u1, OT11: u1,
            OT12: u1, OT13: u1, OT14: u1, OT15: u1,
            reserved: u16,
        }, base + 0x04);

        /// GPIO Output Speed Register - 2 bits per pin
        pub const OSPEEDR = mmio.Mmio(packed struct {
            OSPEEDR0: u2, OSPEEDR1: u2, OSPEEDR2: u2, OSPEEDR3: u2,
            OSPEEDR4: u2, OSPEEDR5: u2, OSPEEDR6: u2, OSPEEDR7: u2,
            OSPEEDR8: u2, OSPEEDR9: u2, OSPEEDR10: u2, OSPEEDR11: u2,
            OSPEEDR12: u2, OSPEEDR13: u2, OSPEEDR14: u2, OSPEEDR15: u2,
        }, base + 0x08);

        /// GPIO Pull-up/Pull-down Register - 2 bits per pin
        pub const PUPDR = mmio.Mmio(packed struct {
            PUPDR0: u2, PUPDR1: u2, PUPDR2: u2, PUPDR3: u2,
            PUPDR4: u2, PUPDR5: u2, PUPDR6: u2, PUPDR7: u2,
            PUPDR8: u2, PUPDR9: u2, PUPDR10: u2, PUPDR11: u2,
            PUPDR12: u2, PUPDR13: u2, PUPDR14: u2, PUPDR15: u2,
        }, base + 0x0C);

        /// GPIO Input Data Register (read-only)
        pub const IDR = mmio.Mmio(packed struct {
            IDR0: u1, IDR1: u1, IDR2: u1, IDR3: u1,
            IDR4: u1, IDR5: u1, IDR6: u1, IDR7: u1,
            IDR8: u1, IDR9: u1, IDR10: u1, IDR11: u1,
            IDR12: u1, IDR13: u1, IDR14: u1, IDR15: u1,
            reserved: u16,
        }, base + 0x10);

        /// GPIO Output Data Register
        pub const ODR = mmio.Mmio(packed struct {
            ODR0: u1, ODR1: u1, ODR2: u1, ODR3: u1,
            ODR4: u1, ODR5: u1, ODR6: u1, ODR7: u1,
            ODR8: u1, ODR9: u1, ODR10: u1, ODR11: u1,
            ODR12: u1, ODR13: u1, ODR14: u1, ODR15: u1,
            reserved: u16,
        }, base + 0x14);

        /// GPIO Bit Set/Reset Register (write-only)
        /// Lower 16 bits set pins, upper 16 bits reset pins
        pub const BSRR = mmio.Mmio(u32, base + 0x18);

        /// GPIO Alternate Function Low Register (pins 0-7)
        pub const AFRL = mmio.Mmio(packed struct {
            AFRL0: u4, AFRL1: u4, AFRL2: u4, AFRL3: u4,
            AFRL4: u4, AFRL5: u4, AFRL6: u4, AFRL7: u4,
        }, base + 0x20);

        /// GPIO Alternate Function High Register (pins 8-15)
        pub const AFRH = mmio.Mmio(packed struct {
            AFRH8: u4, AFRH9: u4, AFRH10: u4, AFRH11: u4,
            AFRH12: u4, AFRH13: u4, AFRH14: u4, AFRH15: u4,
        }, base + 0x24);

        // Convenience functions

        /// Set pin as output
        pub fn setOutput(pin: u4) void {
            const moder = MODER.read();
            const shift: u5 = @as(u5, pin) * 2;
            const mask: u32 = ~(@as(u32, 0b11) << shift);
            const val: u32 = @as(u32, 0b01) << shift;
            MODER.write(@bitCast((@as(u32, @bitCast(moder)) & mask) | val));
        }

        /// Set pin as input
        pub fn setInput(pin: u4) void {
            const moder = MODER.read();
            const shift: u5 = @as(u5, pin) * 2;
            const mask: u32 = ~(@as(u32, 0b11) << shift);
            MODER.write(@bitCast(@as(u32, @bitCast(moder)) & mask));
        }

        /// Set pin high
        pub fn setHigh(pin: u4) void {
            BSRR.write(@as(u32, 1) << pin);
        }

        /// Set pin low
        pub fn setLow(pin: u4) void {
            BSRR.write(@as(u32, 1) << (@as(u5, pin) + 16));
        }

        /// Toggle pin
        pub fn toggle(pin: u4) void {
            const odr = ODR.read();
            const bit = (@as(u32, @bitCast(odr)) >> pin) & 1;
            if (bit == 1) {
                setLow(pin);
            } else {
                setHigh(pin);
            }
        }

        /// Read pin state
        pub fn read_pin(pin: u4) bool {
            const idr = IDR.read();
            return ((@as(u32, @bitCast(idr)) >> pin) & 1) == 1;
        }
    };
}

// GPIO Port instances
pub const GPIOA = GpioPort(GPIOA_BASE);
pub const GPIOB = GpioPort(GPIOB_BASE);
pub const GPIOC = GpioPort(GPIOC_BASE);
pub const GPIOD = GpioPort(GPIOD_BASE);
pub const GPIOE = GpioPort(GPIOE_BASE);

// Convenience re-export
pub const gpio = struct {
    pub const A = GPIOA;
    pub const B = GPIOB;
    pub const C = GPIOC;
    pub const D = GPIOD;
    pub const E = GPIOE;
};

// =============================================================================
// System Configuration
// =============================================================================

/// Initialize system clocks to 84MHz using HSI and PLL
pub fn initClock84MHz() void {
    // Enable HSI
    rcc.CR.modify(.{ .HSION = true });
    while (!rcc.CR.read().HSIRDY) {}

    // Configure PLL: HSI (16MHz) / 16 * 336 / 4 = 84MHz
    rcc.PLLCFGR.modify(.{
        .PLLM = 16,
        .PLLN = 336,
        .PLLP = 0b01, // /4
        .PLLSRC = 0, // HSI
        .PLLQ = 7,
    });

    // Enable PLL
    rcc.CR.modify(.{ .PLLON = true });
    while (!rcc.CR.read().PLLRDY) {}

    // Set flash latency for 84MHz
    const FLASH_ACR: *volatile u32 = @ptrFromInt(0x40023C00);
    FLASH_ACR.* = (FLASH_ACR.* & ~@as(u32, 0xF)) | 2; // 2 wait states

    // Switch to PLL
    rcc.CFGR.modify(.{ .SW = 0b10 });
    while (rcc.CFGR.read().SWS != 0b10) {}
}

test "stm32f4 register sizes" {
    const std = @import("std");
    // Verify packed structs are correct size
    try std.testing.expectEqual(@sizeOf(@TypeOf(rcc.CR.read())), 4);
    try std.testing.expectEqual(@sizeOf(@TypeOf(GPIOA.MODER.read())), 4);
}
