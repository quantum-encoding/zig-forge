# zig_silicon

A small CLI tool that renders hardware register bitfields as SVG diagrams, to help visualize how packed layouts (e.g. an STM32 `GPIO_MODER` or `RCC_AHB1ENR` register) divide a 32-bit word into named fields.

## Commands

```
zig-silicon bitfield <name> <field:bits>...   Print a bitfield SVG to stdout
zig-silicon demo                              Write gpio_moder.svg and rcc_ahb1enr.svg to the cwd
zig-silicon help                              Show usage
```

`field:bits` pairs describe each field left-to-right; a missing `:bits` defaults to 1 bit.

## Example

```
zig-silicon bitfield GPIO_MODER MODE0:2 MODE1:2 MODE2:2 MODE3:2 > moder.svg
```

## Build

```
zig build             # build the CLI (installs zig-silicon)
zig build run -- demo # run it
zig build test        # run unit tests
```

## Scope

This is an educational visualization helper. It only generates bitfield SVG diagrams from field/width specs — it does not disassemble machine code, emit register-map HTML, or model read-modify-write sequences.
