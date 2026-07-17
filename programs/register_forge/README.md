# register_forge

A command-line tool that parses ARM CMSIS-SVD (System View Description) files and generates type-safe Zig code — packed structs and MMIO accessors — for hardware register access on microcontrollers.

## What it does

SVD is an XML-based format standardized by ARM for describing a chip's peripherals, registers, and bitfields; most microcontroller vendors ship SVD files for their parts. `register_forge` reads an SVD file, extracts the device's peripherals/registers/fields, and emits Zig source in which each register is a `packed struct` and each peripheral exposes its base address and register offsets, so firmware can read and write hardware bits by name instead of by hand-computed masks.

The XML parser is a simplified, tag-scanning reader (not a full XML parser); it covers the common device/peripheral/register/field structure used by typical vendor SVD files.

## Usage

```sh
# Build the CLI tool
zig build

# Generate Zig code from an SVD file to stdout
zig build run -- STM32F401.svd

# Write the generated code to a file
zig build run -- STM32F401.svd --output stm32f401.zig

# Emit demo output without an input file
zig build run -- demo
```

Options:

- `-o, --output <file>` — output file (default: stdout)
- `-p, --peripheral <name>` — accepted on the command line but not yet applied; generation currently emits all peripherals
- `-h, --help` — show help

## Testing

```sh
zig build test
```

Built and tested with Zig 0.16.0.
