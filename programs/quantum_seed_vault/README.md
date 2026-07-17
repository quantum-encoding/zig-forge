# Quantum Seed Vault

A menu-driven terminal/LCD application for managing cryptographic seed material on a Raspberry Pi Zero with a 1.3" ST7789 LCD HAT, built around a Shamir Secret Sharing module that splits and reconstructs a secret over GF(256).

## What it actually is

- **Front end.** A small framebuffer UI with a navigable menu (Create Seed, Recover Seed, Split Seed, Combine Shares, Settings, About). It renders either to the ST7789 hardware display on a Pi, or to an ANSI/ASCII terminal mock for development on a host machine (`--terminal` / `--ascii`). Hardware is auto-detected; the terminal mock is used when no hardware is present. The on-device seed-management screens are currently informational placeholder renders — they describe each operation and draw button widgets, but do not yet wire live keyboard entry through to the crypto module.

- **Crypto core (`src/crypto/shamir.zig`).** The implemented and tested part. It provides:
  - `SSS.split` / `SSS.combine` — Shamir Secret Sharing over GF(256), splitting a byte secret into `n` shares recoverable from any `threshold` of them.
  - `GF256` — finite-field multiply/divide used by the sharing math.
  - `Share` serialization / deserialization.
  - A `SLIP39` helper that maps share bytes to mnemonic words. **This is not SLIP-39.** It uses a custom **256-word** list for a deterministic 1-byte-per-word encoding; it is not compatible with the standard 1024-word SLIP-39 scheme.
  - `SecureMem` helpers (`secureZero`, constant-time-style compare).

  Randomness comes from the OS CSPRNG (`getrandom` on Linux, `arc4random_buf` on macOS/BSD).

## "Quantum"

The name is a brand, not a cryptographic claim. The cryptography here is classical Shamir Secret Sharing over GF(256) — there is no post-quantum / lattice cryptography in this program.

## Building

The only supported toolchain is Zig 0.16.0.

```sh
zig build            # native host build (installs quantum-seed-vault)
zig build run        # build and run on the host (terminal mock)
zig build pi         # cross-compile for Raspberry Pi Zero (ARMv6, ReleaseSafe) -> zig-out/arm
```

## Tests

```sh
zig build test-crypto   # runs the Shamir / GF(256) tests (recommended)
```

`test-crypto` roots the test binary at the crypto module only, so it has no terminal I/O. The
crypto suite includes an external FIPS-197 GF(256) worked-example vector, a fixed-line `combine`
hand-check, and a `split` → `combine` roundtrip regression.

> The full `zig build test` step also compiles the application UI, whose tests write ANSI escapes
> straight to stdout; under the build runner's stdout-based result protocol that corrupts the IPC
> channel and stalls the runner. Prefer `zig build test-crypto` for the crypto coverage.

## Layout

| Path | Purpose |
|---|---|
| `src/main.zig` | App entry point, config parsing, main loop |
| `src/crypto/shamir.zig` | Shamir Secret Sharing over GF(256) — the tested core |
| `src/crypto.zig` | Crypto module facade / re-exports |
| `src/display.zig`, `src/display/` | Framebuffer, ST7789 driver, terminal mock |
| `src/ui.zig`, `src/ui/` | Menu state and framebuffer widgets |
| `src/input.zig`, `src/input/` | Input handling |
