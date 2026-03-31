//! Blink LED Example for STM32F4
//!
//! This example blinks the built-in LED on pin PA5 (common on Nucleo-F401RE boards).
//!
//! At the transistor level, this program:
//! 1. Enables the clock gate for GPIOA peripheral
//! 2. Configures PA5 as a push-pull output
//! 3. Toggles the output register bit, which changes the voltage level
//!    on the GPIO pin through output driver transistors
//!
//! Build:
//!   zig build example-blink
//!
//! Flash:
//!   st-flash write zig-out/bin/examples/blink_stm32f4 0x08000000

const hal = @import("hal");
const stm32 = hal.stm32f4;

// LED on Nucleo-F401RE is PA5
const LED_PIN: u4 = 5;

/// Main entry point
pub fn main() noreturn {
    // Enable GPIOA clock
    // This opens the clock gate transistors, allowing the peripheral to operate
    stm32.rcc.AHB1ENR.modify(.{ .GPIOAEN = true });

    // Configure PA5 as output
    // Writing 0b01 to the mode bits connects the pin to the output driver
    stm32.GPIOA.MODER.modify(.{ .MODER5 = 0b01 });

    // Main loop - toggle LED forever
    while (true) {
        // Set PA5 high - drives transistor to pull pin to VDD
        stm32.GPIOA.setHigh(LED_PIN);
        delay();

        // Set PA5 low - drives transistor to pull pin to GND
        stm32.GPIOA.setLow(LED_PIN);
        delay();
    }
}

/// Simple delay loop (~500ms at 16MHz HSI)
fn delay() void {
    var i: u32 = 0;
    while (i < 1_000_000) : (i += 1) {
        // Prevent optimization from removing the loop
        asm volatile ("nop");
    }
}

// Minimal panic handler for bare-metal
pub fn panic(msg: []const u8, stack_trace: ?*@import("std").builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = stack_trace;
    _ = ret_addr;
    while (true) {
        asm volatile ("bkpt #0");
    }
}
