# Quantum Seed Vault - LCD HAT Technical Specification

## Hardware Overview

**Display:** Waveshare 1.3" LCD HAT
**Controller:** ST7789VW
**Resolution:** 240 x 240 pixels
**Color Depth:** RGB565 (16-bit, 65K colors)
**Interface:** 4-wire SPI
**Target Platform:** Raspberry Pi Zero 1.3 (air-gapped, no WiFi)

---

## GPIO Pin Assignments (BCM numbering)

### SPI Display Pins
| Function | BCM GPIO | Physical Pin | Description |
|----------|----------|--------------|-------------|
| SCLK | GPIO 11 | Pin 23 | SPI Clock |
| MOSI | GPIO 10 | Pin 19 | SPI Data Out (to display) |
| CS | GPIO 8 | Pin 24 | Chip Select (directly active low) |
| DC | GPIO 25 | Pin 22 | Data/Command (0=cmd, 1=data) |
| RST | GPIO 27 | Pin 13 | Reset (active low) |
| BL | GPIO 24 | Pin 18 | Backlight control |

### Joystick Pins (directly active low when pressed)
| Direction | BCM GPIO | Physical Pin |
|-----------|----------|--------------|
| UP | GPIO 6 | Pin 31 |
| DOWN | GPIO 19 | Pin 35 |
| LEFT | GPIO 5 | Pin 29 |
| RIGHT | GPIO 26 | Pin 37 |
| PRESS | GPIO 13 | Pin 33 |

### Button Pins (active low)
| Button | BCM GPIO | Physical Pin |
|--------|----------|--------------|
| KEY1 | GPIO 21 | Pin 40 |
| KEY2 | GPIO 20 | Pin 38 |
| KEY3 | GPIO 16 | Pin 36 |

---

## SPI Configuration

```
Mode: SPI Mode 0 (CPOL=0, CPHA=0)
Speed: Up to 62.5 MHz (recommend 40-50 MHz for stability)
Bit Order: MSB first
Word Size: 8 bits
```

### Linux SPI Device
```
Device: /dev/spidev0.0
CS: CE0 (GPIO 8)
```

---

## ST7789 Command Reference

### Essential Commands
| Command | Hex | Description |
|---------|-----|-------------|
| NOP | 0x00 | No operation |
| SWRESET | 0x01 | Software reset |
| SLPIN | 0x10 | Sleep in |
| SLPOUT | 0x11 | Sleep out |
| PTLON | 0x12 | Partial mode on |
| NORON | 0x13 | Normal display mode on |
| INVOFF | 0x20 | Display inversion off |
| INVON | 0x21 | Display inversion on |
| DISPOFF | 0x28 | Display off |
| DISPON | 0x29 | Display on |
| CASET | 0x2A | Column address set |
| RASET | 0x2B | Row address set |
| RAMWR | 0x2C | Memory write |
| RAMRD | 0x2E | Memory read |
| MADCTL | 0x36 | Memory data access control |
| COLMOD | 0x3A | Interface pixel format |

### MADCTL (0x36) Bit Definitions
```
Bit 7 (MY):  Row address order (0=top-to-bottom, 1=bottom-to-top)
Bit 6 (MX):  Column address order (0=left-to-right, 1=right-to-left)
Bit 5 (MV):  Row/Column exchange (0=normal, 1=swap)
Bit 4 (ML):  Vertical refresh order
Bit 3 (RGB): RGB/BGR order (0=RGB, 1=BGR)
Bit 2 (MH):  Horizontal refresh order
```

### COLMOD (0x3A) Values
```
0x55 = 16-bit/pixel (RGB565) - USE THIS
0x66 = 18-bit/pixel (RGB666)
0x53 = 12-bit/pixel (RGB444)
```

---

## Initialization Sequence

```zig
// Pseudo-code initialization sequence
fn init_st7789() void {
    // Hardware reset
    gpio_set(RST, LOW);
    delay_ms(10);
    gpio_set(RST, HIGH);
    delay_ms(120);
    
    // Software reset
    write_cmd(0x01);  // SWRESET
    delay_ms(150);
    
    // Sleep out
    write_cmd(0x11);  // SLPOUT
    delay_ms(120);
    
    // Memory data access control
    write_cmd(0x36);  // MADCTL
    write_data(0x00); // Normal orientation
    
    // Interface pixel format
    write_cmd(0x3A);  // COLMOD
    write_data(0x55); // 16-bit RGB565
    
    // Porch setting
    write_cmd(0xB2);
    write_data(0x0C);
    write_data(0x0C);
    write_data(0x00);
    write_data(0x33);
    write_data(0x33);
    
    // Gate control
    write_cmd(0xB7);
    write_data(0x35);
    
    // VCOM setting
    write_cmd(0xBB);
    write_data(0x19);
    
    // LCM control
    write_cmd(0xC0);
    write_data(0x2C);
    
    // VDV and VRH command enable
    write_cmd(0xC2);
    write_data(0x01);
    
    // VRH set
    write_cmd(0xC3);
    write_data(0x12);
    
    // VDV set
    write_cmd(0xC4);
    write_data(0x20);
    
    // Frame rate control
    write_cmd(0xC6);
    write_data(0x0F); // 60Hz
    
    // Power control 1
    write_cmd(0xD0);
    write_data(0xA4);
    write_data(0xA1);
    
    // Positive voltage gamma
    write_cmd(0xE0);
    write_data_array(&[_]u8{
        0xD0, 0x04, 0x0D, 0x11, 0x13, 0x2B, 0x3F,
        0x54, 0x4C, 0x18, 0x0D, 0x0B, 0x1F, 0x23
    });
    
    // Negative voltage gamma
    write_cmd(0xE1);
    write_data_array(&[_]u8{
        0xD0, 0x04, 0x0C, 0x11, 0x13, 0x2C, 0x3F,
        0x44, 0x51, 0x2F, 0x1F, 0x1F, 0x20, 0x23
    });
    
    // Display inversion on (required for this display)
    write_cmd(0x21);  // INVON
    
    // Normal display mode
    write_cmd(0x13);  // NORON
    delay_ms(10);
    
    // Display on
    write_cmd(0x29);  // DISPON
    delay_ms(10);
    
    // Backlight on
    gpio_set(BL, HIGH);
}
```

---

## Drawing to Display

### Set Window (before writing pixels)
```zig
fn set_window(x0: u16, y0: u16, x1: u16, y1: u16) void {
    // Column address set
    write_cmd(0x2A);  // CASET
    write_data(@truncate(x0 >> 8));
    write_data(@truncate(x0 & 0xFF));
    write_data(@truncate(x1 >> 8));
    write_data(@truncate(x1 & 0xFF));
    
    // Row address set
    write_cmd(0x2B);  // RASET
    write_data(@truncate(y0 >> 8));
    write_data(@truncate(y0 & 0xFF));
    write_data(@truncate(y1 >> 8));
    write_data(@truncate(y1 & 0xFF));
    
    // Memory write
    write_cmd(0x2C);  // RAMWR
}
```

### RGB565 Color Format
```zig
// RGB565: RRRRRGGGGGGBBBBB (16 bits)
fn rgb_to_565(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, r & 0xF8) << 8) |
           (@as(u16, g & 0xFC) << 3) |
           (@as(u16, b >> 3));
}

// Common colors
const BLACK:   u16 = 0x0000;
const WHITE:   u16 = 0xFFFF;
const RED:     u16 = 0xF800;
const GREEN:   u16 = 0x07E0;
const BLUE:    u16 = 0x001F;
const CYAN:    u16 = 0x07FF;
const MAGENTA: u16 = 0xF81F;
const YELLOW:  u16 = 0xFFE0;
```

### Full Screen Clear
```zig
fn clear_screen(color: u16) void {
    set_window(0, 0, 239, 239);
    
    const pixel_count = 240 * 240;
    var i: u32 = 0;
    while (i < pixel_count) : (i += 1) {
        write_data(@truncate(color >> 8));
        write_data(@truncate(color & 0xFF));
    }
}
```

---

## SPI Communication (Linux spidev)

### Zig Implementation Pattern
```zig
const std = @import("std");
const os = std.os;
const linux = os.linux;

const SPI_IOC_MAGIC = 'k';
const SPI_IOC_WR_MODE = 0x40016b01;
const SPI_IOC_WR_BITS_PER_WORD = 0x40016b03;
const SPI_IOC_WR_MAX_SPEED_HZ = 0x40046b04;

pub const ST7789 = struct {
    spi_fd: i32,
    dc_fd: i32,
    rst_fd: i32,
    bl_fd: i32,
    
    pub fn write_cmd(self: *ST7789, cmd: u8) void {
        // Set DC low for command
        gpio_write(self.dc_fd, 0);
        spi_write(self.spi_fd, &[_]u8{cmd});
    }
    
    pub fn write_data(self: *ST7789, data: u8) void {
        // Set DC high for data
        gpio_write(self.dc_fd, 1);
        spi_write(self.spi_fd, &[_]u8{data});
    }
    
    pub fn write_data_buffer(self: *ST7789, data: []const u8) void {
        gpio_write(self.dc_fd, 1);
        spi_write(self.spi_fd, data);
    }
};
```

---

## GPIO Input Handling

### Button/Joystick Reading
```zig
// All inputs are active LOW (pressed = 0)
const INPUT_PINS = struct {
    const JOY_UP    = 6;
    const JOY_DOWN  = 19;
    const JOY_LEFT  = 5;
    const JOY_RIGHT = 26;
    const JOY_PRESS = 13;
    const KEY1      = 21;
    const KEY2      = 20;
    const KEY3      = 16;
};

pub const InputState = packed struct {
    up: bool,
    down: bool,
    left: bool,
    right: bool,
    press: bool,
    key1: bool,
    key2: bool,
    key3: bool,
};

pub fn read_inputs() InputState {
    return InputState{
        .up    = gpio_read(INPUT_PINS.JOY_UP) == 0,
        .down  = gpio_read(INPUT_PINS.JOY_DOWN) == 0,
        .left  = gpio_read(INPUT_PINS.JOY_LEFT) == 0,
        .right = gpio_read(INPUT_PINS.JOY_RIGHT) == 0,
        .press = gpio_read(INPUT_PINS.JOY_PRESS) == 0,
        .key1  = gpio_read(INPUT_PINS.KEY1) == 0,
        .key2  = gpio_read(INPUT_PINS.KEY2) == 0,
        .key3  = gpio_read(INPUT_PINS.KEY3) == 0,
    };
}
```

---

## Cross-Compilation for Raspberry Pi Zero

### Build Command
```bash
# From development machine (Mac/Linux)
zig build-exe src/main.zig \
    -target arm-linux-gnueabihf \
    -mcpu=arm1176jzf_s \
    -O ReleaseSafe
```

### Target Architecture
```
CPU: ARM1176JZF-S (ARMv6)
ABI: gnueabihf (hardware float)
Endianness: Little endian
```

---

## File Structure Suggestion

```
quantum-seed-vault/
├── src/
│   ├── main.zig           # Entry point, main loop
│   ├── display/
│   │   ├── st7789.zig     # Display driver
│   │   ├── framebuffer.zig # 240x240 pixel buffer
│   │   └── fonts.zig      # Bitmap fonts
│   ├── input/
│   │   └── gpio.zig       # Button/joystick handling
│   ├── ui/
│   │   ├── menu.zig       # Menu navigation
│   │   ├── screens.zig    # Individual screens
│   │   └── widgets.zig    # Reusable UI components
│   ├── crypto/
│   │   ├── shamir.zig     # Existing ZSS implementation
│   │   └── stego.zig      # Steganography
│   └── storage/
│       └── usb.zig        # USB drive mounting/writing
├── assets/
│   └── fonts/             # Font bitmap data
├── build.zig
└── README.md
```

---

## References

- ST7789VW Datasheet: https://www.rhydolabz.com/documents/33/ST7789.pdf
- Waveshare Wiki: https://www.waveshare.com/wiki/1.3inch_LCD_HAT
- Waveshare Demo Code: https://github.com/waveshare/1.3inch-LCD-HAT-Code
- fbcp-ili9341 (reference): https://github.com/juj/fbcp-ili9341

---

## Notes for Implementation

1. **Reset sequence is critical** - Always delay 10ms+ after reset before sending commands
2. **INVON (0x21) is required** - This specific display needs inversion enabled
3. **Backlight must be enabled** - GPIO 24 HIGH to see anything
4. **Use DMA for framebuffer transfers** - Much faster than byte-by-byte
5. **Debounce inputs** - Physical buttons need ~50ms debounce
6. **RGB565 byte order** - Send high byte first, then low byte

---

*Document created for Quantum Seed Vault project - Air-gapped Shamir Secret Sharing device*
