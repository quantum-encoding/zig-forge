# zig_tui

`zig_tui` is a terminal UI framework for Zig, providing a cell buffer, an
input parser, a double-buffered renderer, an application event loop, box
layouts, a theme system, and a set of ready-made widgets.

## What it does

- **Core** — a `Buffer` of `Cell`s with `Style`/`Attrs`/`Color`, `Rect`/`Size`/
  `Position` geometry, Unicode width helpers (`charWidth`, `stringWidth`),
  and a theme system (`Theme`, `Palette`, `ThemeManager`, plus `dark_theme`,
  `light_theme`, `high_contrast_theme`).
- **Input** — an escape-sequence `Parser` producing `Event`s (`KeyEvent`,
  `MouseEvent`) with modifier tracking, plus a `Keybindings` map.
- **Render** — a `Renderer` with terminal-mode control and diff-based redraw.
- **App** — an `Application` event loop driven by user-supplied render and
  event callbacks (see the example below).
- **Layout** — `BoxLayout` with `hbox`/`vbox` helpers and `Constraint`s.
- **Widgets** — `Label`, `Button`, `TextInput`, `TextArea`, `List`, `Table`,
  `Checkbox`, `RadioGroup`, `ProgressBar`, `Spinner`, `Tabs`, `Tree`, `Modal`,
  `Toast`, `FileBrowser`, `CommandPalette`, `StatusBar`, plus a `Widget`
  interface and a `FocusManager`.

## Quick start

```zig
const tui = @import("zig_tui");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var app = try tui.Application.init(allocator, .{});
    defer app.deinit();

    app.setRenderCallback(render);
    app.setEventCallback(handleEvent);

    try app.run();
}

fn render(buf: *tui.Buffer, size: tui.Size) void {
    _ = size;
    _ = buf.writeStr(0, 0, "Hello, TUI!", tui.Style.default);
}

fn handleEvent(event: tui.Event) bool {
    if (event.isKey(.escape)) return false; // Quit
    return true;
}
```

## Build

```sh
zig build          # build the library module + tui-demo executable
zig build run      # run the bundled demo (src/demo.zig)
zig build test     # run the unit tests
```

The library is exposed as a consumable module named `zig_tui` via
`b.addModule` in `build.zig`.

## Status

Requires Zig 0.16.0. Developed and exercised on macOS/Linux terminals; it links
libc for terminal I/O.
