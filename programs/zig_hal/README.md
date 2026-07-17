# zig_hal

A bare-metal Zig hardware-abstraction toolkit for direct, type-safe access to
memory-mapped hardware registers on microcontrollers. It provides volatile MMIO
helpers, `packed struct` register wrappers, interrupt-vector and startup
scaffolding, and target-specific register definitions.

## What's in the box

- `mmio` — volatile read / write / read-modify-write and bit set/clear helpers
  (`Mmio(T, addr)`), so register accesses are never optimized away or reordered.
- `bitfield` — `Register(T, addr)` wraps a `packed struct` to give field-level
  read/modify access with exact bit layout.
- `interrupts` — interrupt/exception vector helpers.
- `startup` — reset/startup scaffolding for freestanding targets.
- `targets/` — register maps for three supported chips:
  - **STM32F4** (ARM Cortex-M4)
  - **RP2040** (Raspberry Pi Pico, ARM Cortex-M0+)
  - **ESP32-C3** (RISC-V, generic rv32)

## Usage

```zig
const hal = @import("zig_hal");
const gpio = hal.stm32f4.gpio;

// Set PA5 as output (LED on a Nucleo board) and drive it high.
gpio.GPIOA.MODER.modify(.{ .MODER5 = 0b01 });
gpio.GPIOA.ODR.modify(.{ .ODR5 = 1 });
```

The library is exposed as a consumable module named `zig_hal` via
`b.addModule` in `build.zig`.

## Building

```sh
zig build            # build the host static library and register the module
zig build test       # run the unit tests (src/hal.zig)
zig build stm32f4    # cross-build the static lib for STM32F4 (Cortex-M4)
zig build rp2040     # cross-build for RP2040 (Cortex-M0+)
zig build esp32c3    # cross-build for ESP32-C3 (RISC-V)
zig build example-blink  # build the STM32F4 blink example
```

Requires Zig 0.16.0.

## Scope

This is an unaudited developer toolkit for embedded register access. The target
register maps cover a subset of each chip's peripherals (the parts exercised by
the examples and tests), not the full datasheet. It does not touch money, keys,
or auth and is not on the canonical promoted-library list.
