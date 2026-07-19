# zdedupe

zdedupe finds duplicate files (by content hash) and compares two folders, and emits the result as text, JSON, or HTML — as a CLI, a Zig module, or a C-ABI static/shared library.

It is bidirectional in neither direction because it is not a codec: it *reads* a filesystem and *writes* a report. Nothing in this tree deletes a file on its own — `zdedupe_delete_file` / `zdedupe_move_file` exist for a consumer app to call after a user confirms.

## What it does

- **Duplicate finding** — walk paths → group by size → quick hash (first 4 KiB) → full hash → group by hash, sorted by reclaimable space. Hashing is BLAKE3 by default (`--sha256` switches), parallelised across a thread pool.
- **Folder comparison** — index two trees by relative path, then classify each path as identical / only-in-A / only-in-B / modified.
- **Reports** — `text` (default), `json`, `html`.

Hard links are detected by `(dev, ino)` and counted once: deleting one hard link reclaims nothing, so reporting the pair as duplicates would be a false saving.

## CLI

```
zdedupe [OPTIONS] <PATHS...>           Find duplicates in paths
zdedupe compare <FOLDER_A> <FOLDER_B>  Compare two folders
zdedupe scan <PATH>                    Fast scan (benchmark mode)

-f, --format FORMAT    text | json | html          (default: text)
-o, --output FILE      write report to file        (default: stdout)
-H, --hidden           include hidden files
-L, --follow-links     follow symlinks (targets are stat'd; cycles are guarded)
-m, --min-size SIZE    minimum file size, e.g. 1KB, 1MB
-M, --max-size SIZE    maximum file size (0 = unlimited)
-j, --threads N        thread count (0 = auto)
    --hashes           include file hashes in output
    --sha256           use SHA-256 instead of BLAKE3
```

## Library / FFI

`zig build` produces `libzdedupe.a`; `zig build shared` produces the dynamic library; `zig build header` installs `include/zdedupe.h`.

The C ABI is 14 symbols (`zdedupe_init` … `zdedupe_version`), all declared in `include/zdedupe.h`. **The JSON document returned by `zdedupe_run_sync` is part of the ABI**: the Tauri app (`src-tauri/src/ffi.rs`, serde) and the native Swift app (`ZDedupeEngine.swift`, `JSONDecoder`) decode it into typed models to decide which files to offer for deletion. Field names and types are documented in the header and asserted in `src/tier1_anchors.zig`; changing one without updating both consumers breaks them silently.

After rebuilding the static lib for the Xcode/Swift consumer, repack it: `zig-forge/scripts/repack-for-xcode.sh zig-out/lib/libzdedupe.a` (Zig 0.16 emits 2-byte-aligned Mach-O members; Apple's ld-prime needs 8).

## Correctness posture

Because a consumer deletes files based on this output, the failure mode that matters is a *wrong duplicate verdict*. Guards in place:

- **Read errors never become hashes.** `hasher.zig` breaks on `read() == 0` only; `EINTR` retries and any other failure returns `error.ReadFailed`. A partial-prefix hash used to be returned as valid, so two files that failed at the same offset hashed identically and were reported as duplicates. `parallel.zig` maps a hash failure to `null`, which excludes the file from grouping.
- **External anchors.** `src/tier1_anchors.zig` hashes on-disk fixtures and compares against the official BLAKE3 `test_vectors.json` (lengths 4096 and 102400 — the latter past the 64 KiB read buffer, so the multi-read loop is covered) and against `shasum -a 256` output for the same inputs. The emitted JSON is parsed back with `std.json`, and a filename containing `"`, `\` and `<script>` must survive encode → parse byte-exactly.
- **One stat implementation.** `src/pstat.zig` is the only place that stats. It routes through `std.c.fstatat` (which selects the `$INODE64` symbols) on Darwin and `statx` on Linux, replacing four hand-rolled `extern struct Stat` copies whose layout was wrong on x86_64 macOS and on aarch64 Linux.
- **Symlinks.** `-L` stats targets rather than links, and both walkers keep a visited-directory `(dev, ino)` set, so `ln -s .. loop` terminates. Without `-L`, symlinks are skipped entirely.

## Tests

`zig build test` runs every module's tests plus `src/tier1_anchors.zig`. Filesystem fixtures are created under `$TMPDIR` via `src/testing_scratch.zig` — never inside the repo, because the fixtures include hostile filenames, hard links and symlink cycles.
