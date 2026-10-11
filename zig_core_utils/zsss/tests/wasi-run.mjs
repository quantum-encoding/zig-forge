// Run a wasm32-wasi test binary under node's WASI: a genuine 32-bit usize target, which is
// where `pos + len` on a file-supplied u32 wraps (crypto test campaign 2026-10-11, E-3).
// No 32-bit Android device or emulator is needed. From zig_core_utils/zsss:
//
//   zig test -target wasm32-wasi -lc src/lib.zig  --test-cmd node --test-cmd tests/wasi-run.mjs --test-cmd-bin
//   zig test -target wasm32-wasi -lc src/main.zig --test-cmd node --test-cmd tests/wasi-run.mjs --test-cmd-bin
//   zig test -target wasm32-wasi -lc --dep zlib_bomb --dep png_gradient -Mroot=src/stego_hostile_test.zig \
//       -Mzlib_bomb=tests/zlib-bomb-64mib.zlib -Mpng_gradient=tests/png-gradient-64x64-filtered.png \
//       --test-cmd node --test-cmd tests/wasi-run.mjs --test-cmd-bin
import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';
import { argv, env, exit } from 'node:process';
const bin = argv[2];
const wasi = new WASI({ version: 'preview1', args: [bin, ...argv.slice(3)], env, preopens: { '/': '/' }, returnOnExit: true });
const wasm = await WebAssembly.compile(await readFile(bin));
const inst = await WebAssembly.instantiate(wasm, wasi.getImportObject());
exit(wasi.start(inst));
