# zdedupe

zdedupe finds duplicate files and duplicate directories (by content hash) and compares two folders, and emits the result as text, JSON, or HTML — as a CLI, a Zig module, or a C-ABI static/shared library.

It is bidirectional in neither direction because it is not a codec: it *reads* a filesystem and *writes* a report. Nothing in this tree deletes a file on its own — `zdedupe_delete_file` / `zdedupe_move_file` exist for a consumer app to call after a user confirms.

## What it does

- **Duplicate finding** — walk paths → group by size → quick hash (first 4 KiB) → full hash → group by hash, sorted by reclaimable space. Hashing is BLAKE3 by default (`--sha256` switches), parallelised across a thread pool.
- **Directory analysis** (`--dirs`) — rolls the file hashes up into directory identities, with no further I/O:
  - *identical sets*: directories whose whole subtree matches (names, content, symlink targets), found with a Merkle digest so any number of copies lands in one set, and only the top of each copied tree is reported;
  - *overlaps*: directory pairs sharing most of their content — the working folder versus its stale backup — each side listing the files that exist nowhere in the other, i.e. exactly what deleting it would lose. Relations: `same_content`, `a_in_b`, `b_in_a`, `overlap`.
- **Excludes** — entries are pruned by exact basename (`-x NAME`). The CLI ignores regenerable output by default (`node_modules`, `__pycache__`, `.zig-cache`, `.svelte-kit`, `.DS_Store`, … and any directory carrying a valid `CACHEDIR.TAG`, which is how cargo's `target/` is caught without excluding the generic name). `.git` is never excluded by default: a stale copy can hold the only copy of a branch or stash. Over the FFI excludes are opt-in.
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
-d, --dirs             also report identical and overlapping directories
-x, --exclude NAME     ignore entries with this exact name (repeatable)
    --no-default-excludes   scan everything
```

With `--dirs`, `--min-size`/`--max-size` filter the reported file groups only (the walk must see every file, or a directory could pass for a copy because the file that differs was outside the window), and symlinks are compared by target rather than followed.

## Library / FFI

`zig build` produces `libzdedupe.a`; `zig build shared` produces the dynamic library; `zig build header` installs `include/zdedupe.h`.

The C ABI is 20 symbols (`zdedupe_init` … `zdedupe_version`), all declared in `include/zdedupe.h`. **The JSON document returned by `zdedupe_run_sync` is part of the ABI**: the Tauri app (`src-tauri/src/ffi.rs`, serde) and the native Swift app (`ZDedupeEngine.swift`, `JSONDecoder`) decode it into typed models to decide which files to offer for deletion. Field names and types are documented in the header and asserted in `src/tier1_anchors.zig`; changing one without updating both consumers breaks them silently.

### Result store, progress, cancel

`zdedupe_run_to_file` writes a **binary result store** instead of returning JSON (CLI: `--store FILE`). The JSON report is one document — to draw row 40,000 a host must receive, copy and parse everything before it; measured on 642k files that is 106 MB of JSON and a further 570 MB once parsed by the host. The store is fixed-size records in flat, 8-byte-aligned sections with paths referenced as `(offset, len)` into one string section, so a host memory-maps it and reads exactly the rows on screen. The writer streams (offsets are running sums over a fixed iteration order, so records go out before the strings they point at and nothing is buffered), creates the file `0600`, and renames it into place from `<path>.partial` so an existing store survives a failed write. Format spec: the module doc of `src/store.zig`; the desktop app's Rust reader is an independent implementation of it.

`zdedupe_get_progress` / `zdedupe_cancel` are the only calls allowed from another thread during a run; they touch atomics only (`types.Monitor`), so a GUI polls from a timer and no callback re-enters the host. A cancelled run **fails** rather than returning what it has: a file that was never hashed is indistinguishable from a unique one, so results built from a partial scan would silently under-report duplicates.

Duplicate groups list their files oldest first (mtime, then path) in every output.

After rebuilding the static lib for the Xcode/Swift consumer, repack it: `zig-forge/scripts/repack-for-xcode.sh zig-out/lib/libzdedupe.a` (Zig 0.16 emits 2-byte-aligned Mach-O members; Apple's ld-prime needs 8).

## Correctness posture

Because a consumer deletes files based on this output, the failure mode that matters is a *wrong duplicate verdict*. Guards in place:

- **Read errors never become hashes.** `hasher.zig` breaks on `read() == 0` only; `EINTR` retries and any other failure returns `error.ReadFailed`. A partial-prefix hash used to be returned as valid, so two files that failed at the same offset hashed identically and were reported as duplicates. `parallel.zig` maps a hash failure to `null`, which excludes the file from grouping.
- **External anchors.** `src/tier1_anchors.zig` hashes on-disk fixtures and compares against the official BLAKE3 `test_vectors.json` (lengths 4096 and 102400 — the latter past the 64 KiB read buffer, so the multi-read loop is covered) and against `shasum -a 256` output for the same inputs. The emitted JSON is parsed back with `std.json`, and a filename containing `"`, `\` and `<script>` must survive encode → parse byte-exactly.
- **Overlapping roots are reconciled.** Roots are compared by `realpath`; one that another already covers (nested, repeated, or a symlinked spelling) is dropped and counted in `summary.overlapping_roots`. Previously each root got its own walker and inode table, so `zdedupe ~/docs ~/docs/old` listed every file under `old/` twice and reported it as a duplicate *of itself* — "keep one, delete the rest" then deletes the only copy.
- **Directory verdicts are conservative.** A directory with anything unreadable beneath it is `incomplete`: never a member of an identical set, never the contained side of `a_in_b` / `b_in_a`. A file the pipeline could not hash is treated as unique. Entries ignored on purpose (excludes, cache dirs, hidden-when-off, special files) do not block a verdict but are counted per directory (`skipped_entries`) so a consumer can say "identical, ignoring N entries". Hard-linked snapshot trees (`cp -al`, `rsync --link-dest`) compare identical by inode, while the file-level groups still never report a hard link as a duplicate.
- **Cancel and store guards, mutation-tested.** Removing the post-hash cancel check, writing the string section in a different order than offsets were assigned, leaving groups in walk order, writing the store in place instead of via rename, or letting a cancel stick to the context each turn the suite red. The store is cross-checked field by field against the JSON report of the same scan.
- **No advice about VCS metadata.** No finding points at or inside `.git` / `.hg` / `.svn`: there a file's location is its meaning (`.git/refs/heads` can equal `.git/refs/remotes/origin` byte for byte, and deleting the "redundant" one deletes the local branches). The metadata still counts toward the identity of the project around it, so copies whose histories differ are never identical.
- **Directory digest anchored independently.** The digest format is specified in the `src/dirs.zig` module doc; `tools/dirdigest_reference.py` implements it from that text with `os` + `hashlib`, and its output for the fixture tree is the expected value in `src/tier1_anchors.zig`. Eleven mutations of the guards above (dropping the name, symlink target or content hash from the digest; ignoring `incomplete`; honouring the size window during the walk; accepting an unsigned `CACHEDIR.TAG`; not reconciling roots; grouping or dropping extra hard links; reporting inside `.git`) each turn the suite red.
- **One stat implementation.** `src/pstat.zig` is the only place that stats. It routes through `std.c.fstatat` (which selects the `$INODE64` symbols) on Darwin and `statx` on Linux, replacing four hand-rolled `extern struct Stat` copies whose layout was wrong on x86_64 macOS and on aarch64 Linux.
- **Symlinks.** `-L` stats targets rather than links, and both walkers keep a visited-directory `(dev, ino)` set, so `ln -s .. loop` terminates. Without `-L`, symlinks are skipped by the file-level scan (directory analysis records them, with their target, as part of what a directory contains).

## Tests

`zig build test` runs every module's tests plus `src/tier1_anchors.zig`. Filesystem fixtures are created under `$TMPDIR` via `src/testing_scratch.zig` — never inside the repo, because the fixtures include hostile filenames, hard links and symlink cycles.
