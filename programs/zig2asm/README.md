# zig2asm

A command-line wrapper around `zig build-obj` that emits assembly (`.s`), LLVM IR (`.ll`), or an object file (`.o`) from a single Zig source file.

This is a **CLI tool, not a library** — it exposes no importable module, no FFI, and no WASM target. It is a thin, shell-free subprocess wrapper: all codegen is delegated to the `zig` compiler found first in your `PATH`, so its trust model is identical to invoking `zig build-obj` by hand. Its job is to spare you from remembering the `-femit-asm=` / `-femit-llvm-ir=` / `-fno-emit-bin` flag spelling and to offer convenient target shortcuts.

## Building

```bash
cd programs/zig2asm
zig build                 # installs zig-out/bin/zig2asm
```

## Usage

```
zig2asm [options] <input.zig>
```

| Option | Description |
|---|---|
| `--emit <asm\|llvm-ir\|obj>` | Output format (default: `asm`) |
| `-o, --output <path>` | Write output to `<path>` (default: `<input stem>` + `.s`/`.ll`/`.o` in the CWD) |
| `--target <triple>` | Target triple (e.g. `x86_64-linux-gnu`). Omit to build for the native host |
| `-mcpu <cpu>` | Target CPU / feature set (e.g. `baseline`, `apple_m1`, `x86_64_v3`). Omit for native |
| `--strip` | Omit debug symbols from the output (`-fstrip`) |
| `-O <level>` | `Debug` \| `ReleaseSafe` \| `ReleaseFast` \| `ReleaseSmall` (default: `Debug`) |
| `-v, --verbose` | Print the executed `zig` command |
| `-h, --help` | Show help |

### Target shortcuts

| Shortcut | Expands to |
|---|---|
| `arm64`, `aarch64` | aarch64 on the **host** OS (`aarch64-macos-none` on macOS, `aarch64-linux-gnu` on Linux) |
| `x86`, `x64`, `x86_64` | x86_64 on the **host** OS |
| `macos-arm64` | `aarch64-macos-none` |
| `macos-x64` | `x86_64-macos-none` |
| `linux-arm64` | `aarch64-linux-gnu` |
| `linux-x64` | `x86_64-linux-gnu` |
| `wasm` | `wasm32-freestanding-none` |
| `arm` | `arm-linux-gnueabihf` |
| `riscv` | `riscv64-linux-gnu` |

Any value that is not a known shortcut is passed through to `zig` verbatim, so full triples like `x86_64-linux-musl` work directly.

## Examples

```bash
zig2asm hello.zig --emit asm -O ReleaseFast
zig2asm hello.zig --emit llvm-ir -o hello.ll
zig2asm hello.zig --emit obj --target arm64
zig2asm hello.zig -mcpu apple_m1 --strip
```

## Testing

```bash
zig build test        # unit tests: pin the exact zig CLI argv for every mode
zig build test-e2e    # end-to-end smoke test: compiles a fixture, asserts .s/.ll appear
```

The unit tests (`buildArgv`) pin the `zig build-obj` flag contract — a future Zig flag rename fails a test instead of silently breaking users. The end-to-end step (`test/e2e_runner.zig`) spawns the built `zig2asm` against `test/fixtures/hello.zig` and asserts real output files are produced; it is kept out of the default `test` step because it spawns `zig` and writes files.

## Requirements

`zig` must be installed and available in `PATH`. Built and tested against Zig 0.16.
