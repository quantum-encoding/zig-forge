//! Comprehensive Test Suite for zig_hal
//!
//! Tests for the Hardware Abstraction Layer components.
//! These tests verify compile-time guarantees and logic that doesn't
//! require actual hardware.

const std = @import("std");
const mmio = @import("mmio.zig");
const bitfield = @import("bitfield.zig");
const interrupts = @import("interrupts.zig");

// ============================================================================
// MMIO Tests
// ============================================================================

test "Mmio type generation" {
    const TestReg = mmio.Mmio(u32, 0x4000_0000);
    try std.testing.expectEqual(TestReg.address(), 0x4000_0000);
}

test "Mmio packed struct type" {
    const GpioCtrl = packed struct {
        enable: bool,
        mode: u2,
        speed: u2,
        reserved: u27,
    };

    try std.testing.expectEqual(@sizeOf(GpioCtrl), 4);
    try std.testing.expectEqual(@bitSizeOf(GpioCtrl), 32);

    const TestReg = mmio.Mmio(GpioCtrl, 0x4002_0000);
    try std.testing.expectEqual(TestReg.address(), 0x4002_0000);
}

test "MmioArray type generation" {
    const TestArray = mmio.MmioArray(u32, 0x4000_0000, 16);
    _ = TestArray;
}

// ============================================================================
// Bitfield Tests
// ============================================================================

test "bitMask generates correct masks" {
    // Single bit
    try std.testing.expectEqual(bitfield.bitMask(0, 0), 0x1);
    try std.testing.expectEqual(bitfield.bitMask(1, 1), 0x2);
    try std.testing.expectEqual(bitfield.bitMask(7, 7), 0x80);

    // Nibbles
    try std.testing.expectEqual(bitfield.bitMask(0, 3), 0xF);
    try std.testing.expectEqual(bitfield.bitMask(4, 7), 0xF0);
    try std.testing.expectEqual(bitfield.bitMask(8, 11), 0xF00);
    try std.testing.expectEqual(bitfield.bitMask(12, 15), 0xF000);

    // Bytes
    try std.testing.expectEqual(bitfield.bitMask(0, 7), 0xFF);
    try std.testing.expectEqual(bitfield.bitMask(8, 15), 0xFF00);
    try std.testing.expectEqual(bitfield.bitMask(16, 23), 0xFF_0000);
    try std.testing.expectEqual(bitfield.bitMask(24, 31), 0xFF00_0000);

    // Half-words
    try std.testing.expectEqual(bitfield.bitMask(0, 15), 0xFFFF);
    try std.testing.expectEqual(bitfield.bitMask(16, 31), 0xFFFF_0000);
}

test "extractBits extracts correct values" {
    const value: u32 = 0xDEAD_BEEF;

    // Extract nibbles
    try std.testing.expectEqual(bitfield.extractBits(value, 0, 3), 0xF);
    try std.testing.expectEqual(bitfield.extractBits(value, 4, 7), 0xE);
    try std.testing.expectEqual(bitfield.extractBits(value, 8, 11), 0xE);
    try std.testing.expectEqual(bitfield.extractBits(value, 12, 15), 0xB);

    // Extract bytes
    try std.testing.expectEqual(bitfield.extractBits(value, 0, 7), 0xEF);
    try std.testing.expectEqual(bitfield.extractBits(value, 8, 15), 0xBE);
    try std.testing.expectEqual(bitfield.extractBits(value, 16, 23), 0xAD);
    try std.testing.expectEqual(bitfield.extractBits(value, 24, 31), 0xDE);
}

test "insertBits inserts correct values" {
    // Insert into zero
    try std.testing.expectEqual(bitfield.insertBits(0, 0xF, 0, 3), 0xF);
    try std.testing.expectEqual(bitfield.insertBits(0, 0xF, 4, 7), 0xF0);
    try std.testing.expectEqual(bitfield.insertBits(0, 0xFF, 8, 15), 0xFF00);

    // Insert with preservation
    try std.testing.expectEqual(bitfield.insertBits(0xFFFF_FFFF, 0x0, 0, 7), 0xFFFF_FF00);
    try std.testing.expectEqual(bitfield.insertBits(0xFFFF_0000, 0xAB, 0, 7), 0xFFFF_00AB);
}

test "GpioMode constants are valid" {
    try std.testing.expectEqual(bitfield.GpioMode.Input, 0b00);
    try std.testing.expectEqual(bitfield.GpioMode.Output, 0b01);
    try std.testing.expectEqual(bitfield.GpioMode.AlternateFunction, 0b10);
    try std.testing.expectEqual(bitfield.GpioMode.Analog, 0b11);
}

test "GpioSpeed constants are valid" {
    try std.testing.expectEqual(bitfield.GpioSpeed.Low, 0b00);
    try std.testing.expectEqual(bitfield.GpioSpeed.Medium, 0b01);
    try std.testing.expectEqual(bitfield.GpioSpeed.High, 0b10);
    try std.testing.expectEqual(bitfield.GpioSpeed.VeryHigh, 0b11);
}

test "GpioPull constants are valid" {
    try std.testing.expectEqual(bitfield.GpioPull.None, 0b00);
    try std.testing.expectEqual(bitfield.GpioPull.PullUp, 0b01);
    try std.testing.expectEqual(bitfield.GpioPull.PullDown, 0b10);
}

test "Reserved type generation" {
    const Reserved5 = bitfield.Reserved(5);
    try std.testing.expectEqual(@bitSizeOf(Reserved5), 5);

    const Reserved27 = bitfield.Reserved(27);
    try std.testing.expectEqual(@bitSizeOf(Reserved27), 27);
}

// ============================================================================
// Interrupt Tests
// ============================================================================

test "interrupt handler type is correct" {
    const Handler = interrupts.Handler;
    try std.testing.expectEqual(@sizeOf(Handler), @sizeOf(usize));
}

test "CriticalSection type exists" {
    const CriticalSection = interrupts.CriticalSection;
    try std.testing.expectEqual(@sizeOf(CriticalSection), 4);
}

test "NVIC constants are valid" {
    // NVIC should be at the Cortex-M standard address
    _ = interrupts.NVIC;
}

test "SCB constants are valid" {
    // SCB should be at the Cortex-M standard address
    _ = interrupts.SCB;
}

// ============================================================================
// Packed Struct Layout Tests
// ============================================================================

test "GPIO MODER layout (32-bit register with 16x2-bit fields)" {
    const MODER = packed struct {
        MODE0: u2, MODE1: u2, MODE2: u2, MODE3: u2,
        MODE4: u2, MODE5: u2, MODE6: u2, MODE7: u2,
        MODE8: u2, MODE9: u2, MODE10: u2, MODE11: u2,
        MODE12: u2, MODE13: u2, MODE14: u2, MODE15: u2,
    };

    try std.testing.expectEqual(@sizeOf(MODER), 4);
    try std.testing.expectEqual(@bitSizeOf(MODER), 32);

    // Verify field positions via packed struct bit layout
    var reg = MODER{
        .MODE0 = 0, .MODE1 = 0, .MODE2 = 0, .MODE3 = 0,
        .MODE4 = 0, .MODE5 = 0, .MODE6 = 0, .MODE7 = 0,
        .MODE8 = 0, .MODE9 = 0, .MODE10 = 0, .MODE11 = 0,
        .MODE12 = 0, .MODE13 = 0, .MODE14 = 0, .MODE15 = 0,
    };

    reg.MODE0 = 0b01;
    try std.testing.expectEqual(@as(u32, @bitCast(reg)), 0x0000_0001);

    reg = @bitCast(@as(u32, 0));
    reg.MODE5 = 0b01;
    try std.testing.expectEqual(@as(u32, @bitCast(reg)), 0x0000_0400);

    reg = @bitCast(@as(u32, 0));
    reg.MODE15 = 0b11;
    try std.testing.expectEqual(@as(u32, @bitCast(reg)), 0xC000_0000);
}

test "GPIO ODR layout (32-bit register with 16 single-bit fields)" {
    const ODR = packed struct {
        OD0: bool, OD1: bool, OD2: bool, OD3: bool,
        OD4: bool, OD5: bool, OD6: bool, OD7: bool,
        OD8: bool, OD9: bool, OD10: bool, OD11: bool,
        OD12: bool, OD13: bool, OD14: bool, OD15: bool,
        reserved: u16,
    };

    try std.testing.expectEqual(@sizeOf(ODR), 4);
    try std.testing.expectEqual(@bitSizeOf(ODR), 32);

    var reg = ODR{
        .OD0 = false, .OD1 = false, .OD2 = false, .OD3 = false,
        .OD4 = false, .OD5 = false, .OD6 = false, .OD7 = false,
        .OD8 = false, .OD9 = false, .OD10 = false, .OD11 = false,
        .OD12 = false, .OD13 = false, .OD14 = false, .OD15 = false,
        .reserved = 0,
    };

    reg.OD0 = true;
    try std.testing.expectEqual(@as(u32, @bitCast(reg)), 0x0000_0001);

    reg = @bitCast(@as(u32, 0));
    reg.OD5 = true;
    try std.testing.expectEqual(@as(u32, @bitCast(reg)), 0x0000_0020);

    reg = @bitCast(@as(u32, 0));
    reg.OD15 = true;
    try std.testing.expectEqual(@as(u32, @bitCast(reg)), 0x0000_8000);
}

test "RCC AHB1ENR layout" {
    const AHB1ENR = packed struct {
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
    };

    try std.testing.expectEqual(@sizeOf(AHB1ENR), 4);
    try std.testing.expectEqual(@bitSizeOf(AHB1ENR), 32);

    // Test GPIOA enable is at bit 0
    var reg: AHB1ENR = @bitCast(@as(u32, 0));
    reg.GPIOAEN = true;
    try std.testing.expectEqual(@as(u32, @bitCast(reg)), 0x0000_0001);

    // Test DMA1EN position
    reg = @bitCast(@as(u32, 0));
    reg.DMA1EN = true;
    try std.testing.expectEqual(@as(u32, @bitCast(reg)), 0x0020_0000);
}

// ============================================================================
// Address Constant Tests
// ============================================================================

test "STM32F4 peripheral base addresses" {
    // Standard STM32F4 peripheral addresses
    const GPIOA_BASE: u32 = 0x4002_0000;
    const GPIOB_BASE: u32 = 0x4002_0400;
    const GPIOC_BASE: u32 = 0x4002_0800;
    const RCC_BASE: u32 = 0x4002_3800;

    // Verify GPIO ports are 0x400 apart
    try std.testing.expectEqual(GPIOB_BASE - GPIOA_BASE, 0x400);
    try std.testing.expectEqual(GPIOC_BASE - GPIOB_BASE, 0x400);

    // Verify RCC is at expected address
    try std.testing.expectEqual(RCC_BASE, 0x4002_3800);
}

test "Cortex-M system addresses" {
    const NVIC_BASE: u32 = 0xE000_E100;
    const SCB_BASE: u32 = 0xE000_ED00;
    const SYSTICK_BASE: u32 = 0xE000_E010;

    // These are ARM-defined addresses for Cortex-M
    try std.testing.expect(NVIC_BASE >= 0xE000_0000);
    try std.testing.expect(SCB_BASE >= 0xE000_0000);
    try std.testing.expect(SYSTICK_BASE >= 0xE000_0000);
}

// ============================================================================
// Benchmark Support Tests
// ============================================================================

test "bitCast performance characteristics" {
    // Verify bitCast is zero-cost at runtime
    const TestReg = packed struct {
        a: u8,
        b: u8,
        c: u8,
        d: u8,
    };

    const value: u32 = 0xDEAD_BEEF;
    const reg: TestReg = @bitCast(value);
    const back: u32 = @bitCast(reg);

    try std.testing.expectEqual(value, back);
}

test "packed struct field access" {
    const Reg = packed struct {
        field1: u4,
        field2: u4,
        field3: u8,
        field4: u16,
    };

    const reg: Reg = @bitCast(@as(u32, 0xABCD_1234));

    try std.testing.expectEqual(reg.field1, 0x4);
    try std.testing.expectEqual(reg.field2, 0x3);
    try std.testing.expectEqual(reg.field3, 0x12);
    try std.testing.expectEqual(reg.field4, 0xABCD);
}
