# zigix_desktop

A terminal (TUI) desktop environment and window manager written in Zig, with a
compile-time platform split: it builds either as a hosted Linux/macOS program
(with libc, PTY-backed terminal windows via `terminal_mux`, and `/proc` stats)
or as a Zigix freestanding binary (no libc, pure syscalls, UART I/O).

## What it does

- Composites a desktop scene from pure-Zig layers: wallpaper → windows → panel →
  launcher (`compositor.zig`, `theme.zig` — a PC-98 amber palette).
- Manages terminal windows with layouts (single, tiled, horizontal/vertical
  split) and Ctrl+Alt window-manager keybindings (new/close/focus/launcher).
- On Linux, drives a full `zig_tui` `Application` event loop (raw termios, mouse,
  16 ms tick) and spawns real PTYs through `terminal_mux`.
- On Zigix freestanding, runs a simple read → tick → render → sleep loop, forwards
  input to the focused window, and flushes the cell buffer to a UART.

## Layout

```
platform.zig → { platform/linux.zig | platform/zigix.zig }
main.zig     → event loop (platform-aware)
compositor.zig → wallpaper → windows → panel → launcher
desktop.zig / window.zig / panel.zig / launcher.zig → window management + UI
tui_pure.zig → minimal TUI primitives for the freestanding build
theme.zig    → PC-98 amber palette
```

## Build

Requires Zig 0.16.0.

```sh
# Hosted (Linux/macOS): full zig_tui + terminal_mux, libc
zig build
zig build run

# Zigix freestanding (no libc, syscall-based):
zig build -Dtarget=riscv64-freestanding
zig build -Dtarget=aarch64-freestanding
zig build -Dtarget=x86_64-freestanding
```

The freestanding build links against the Zigix userspace syscall library
(`../../zigix/userspace/lib/sys.zig`) and an architecture-appropriate linker
script; the hosted build pulls in the in-tree `zig_tui` and `terminal_mux`
modules.

## Keybindings (Ctrl+Alt)

| Key | Action |
|-----|--------|
| `q` | Quit |
| `n` | New window |
| `w` | Close focused window |
| `l` | Toggle launcher |
| `h` / `v` / `t` / `f` | Layout: split-h / split-v / tiled / single |
| `1`–`9` | Focus window by number |
| Tab / →, ← | Focus next / previous window |
