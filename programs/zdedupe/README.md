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

Hard links are detected by `(dev, ino)` and counted once: deleting one hard link reclaims nothing, so reporting the pair as duplicates would be a false saving. Of several paths to one inode the lexicographically smallest is reported, so the choice does not depend on the order the disk returned entries in.

The walk is parallel (`src/fast_walker.zig`): a pool of workers pulls directories from a shared stack, each with its own string arena and result lists, and every file is stat'ed relative to its open directory (`statx(dirfd, name)`) instead of by absolute path. Measured on 642k files with a warm cache: 1.07 s single-threaded with absolute-path stats → 0.90 s with relative stats → 0.16 s on 16 threads. Results arrive in no fixed order, so nothing downstream depends on walk order (`dirs.zig` ranks the tree itself) and every report ordering has a total tie-break; five runs over a frozen tree produce byte-identical stores.

## CLI

```
zdedupe [OPTIONS] <PATHS...>           Find duplicates in paths
zdedupe compare <FOLDER_A> <FOLDER_B>  Compare two folders
zdedupe scan <PATH>                    Fast scan (benchmark mode)
zdedupe clean [OPTIONS] <ROOTS...>     Build leftovers (see "zdedupe clean" below)

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

## zdedupe clean

Build output piles up wherever agents and people build: scratch copies of a
project, worktrees, `/tmp`. `zdedupe clean` finds it, says whose it is and
whether that project's work is safe elsewhere, and on request moves the stale
build output to the Trash.

```
zdedupe clean [--json] [--trash] [--older AGE] [--main-roots DIR]... [-j N] <ROOTS...>

--json             the JSON document below instead of the text report
--trash            move eligible build folders to the Trash (never a permanent delete)
--older AGE        how long nothing in a folder may have changed: 30m, 24h, 3d, 2w
                   (default 24h, at least 10m)
--main-roots DIR   where main checkouts live (repeatable, or DIR:DIR; default ~/work)
-j, --threads N    walk and hash threads (0 = auto)
```

Without `--trash` nothing on disk changes, and the report says what `--trash`
would move. Exit status 1 means no root could be scanned.

**Build output** is the core's own definition (`src/buildrule.zig`), the one
Disk Space suggests from and protection's temp-area exception asks: a folder
named `node_modules`, `bower_components`, `.zig-cache`, `zig-cache`,
`zig-out`, `DerivedData`, `__pycache__`, `.next`, `.nuxt`, `.svelte-kit`,
`.turbo`, `.parcel-cache`, `.tox`, `.mypy_cache`, `.pytest_cache` or
`.ruff_cache`; `target` beside `Cargo.toml` or `pom.xml`; `.build` beside
`Package.swift`; whatever it is called, a Zig cache (folders `h/`, `o/`,
`tmp/` and `z/`) or an Xcode derived-data folder (`info.plist`, `Build/`,
`Logs/`, and `Index.noindex/` or `ModuleCache.noindex/`); and any folder
carrying a valid CACHEDIR.TAG, except a Python virtual environment
(`pyvenv.cfg` directly inside: uv tags them, but people install into them by
hand). The walk enters tagged folders, so build output inside a virtual
environment is still found. A layout is judged from the folder's own
entries, a few stats and nothing read, and asks for names no project uses
together.
Roots are resolved to their real path. The walk stays on the roots'
filesystems, never follows a link, never enters `.git` / `.hg` / `.svn` /
`.bzr` or a credential store (`Config.credential_excludes`), and does not look
for build output inside build output. A root is the scope, never a finding.

**Identical copies** are found by content with the directory analysis
(`src/dirs.zig`) over the build folders: names, bytes and links all match, and
a folder with anything unreadable in it is never a copy.

**Projects.** A build folder's project is the nearest folder above it, up to
its root, holding `.git` or a manifest (`package.json`, `Cargo.toml`,
`build.zig`, `Package.swift`, `pyproject.toml`, `setup.py`, `go.mod`,
`pom.xml`, `build.gradle(.kts)`, `Gemfile`, `composer.json`, `deno.json`,
`CMakeLists.txt`, `meson.build`, `mix.exs`, `pubspec.yaml`). Every checkout
under a root, and every outermost project, is reported too, build output or
not; a checkout inside build output (a package manager's) is part of that
output. For each, git (run read-only: `--no-optional-locks`,
`core.fsmonitor=false`, nothing fetched) says the checkout's toplevel, origin
(credentials removed), branch, HEAD, whether it is a linked worktree and of
which repository, the main checkouts of the same origin under the main roots
(4 levels deep; `git@host:a/b.git`, `ssh://` and `https://` spellings are one
origin), uncommitted entries (untracked included) and commits on no
remote-tracking ref. The verdict:

- `main_has_everything`: nothing uncommitted, no stash, and every commit on
  its branches is on a remote-tracking ref or in a main checkout's current
  branch. A linked worktree is judged by its HEAD alone (its other branches
  live in the main repository).
- `has_unique_work`, with the reasons. Also every folder git cannot vouch
  for: not in a repository, ignored by the repository around it, or a
  worktree whose repository is gone.

With no `git` the report says so and gives no verdicts.

**What `--trash` moves**: only build folders, only to the Trash, and only
those that lie below a root (never a root), are not and do not hold a
protected location (`src/protect.zig`, applied to the real path; build output
in a temp area such as `/private/tmp` or `$TMPDIR` is not protected by where
it is, everything else there is), are not inside a
version-control store, were read completely, and in which nothing, folders
included, was modified *or had its status changed* for `--older`. The status
change time is set by the system, so a tool that restores old modification
times while unpacking still counts as fresh. Immediately before each move the
folder is checked again: the same folder (device and inode, not a link), still
build output by the same rule (manifest or tag still there), still old enough,
nothing in it on another filesystem. The Trash is NSFileManager's on macOS
(`src/trash.zig`, through the Objective-C runtime) and the freedesktop Trash
on Linux (`files/` + `info/*.trashinfo` on the item's own filesystem, never a
copy across filesystems); Windows reports it as unsupported. Whole project
copies are never moved: they are reported with their verdict.

### JSON (`--json`, schema `zdedupe-clean/1`)

Times are seconds since the epoch; sizes are bytes; `bytes` is space on disk
(allocated blocks, each inode once), `logical_bytes` the apparent size. Paths
are UTF-8 (an invalid byte sequence becomes U+FFFD). Arrays are ordered as
stated. A new field may appear in any object; a field changing meaning or
going away changes `schema`.

```
{
  "schema": "zdedupe-clean/1",
  "generated_at": 1792226400,
  "older_than_s": 86400,
  "git": { "available": true, "version": "git version 2.55.0" },
  "main_roots": ["/Users/me/work"],
  "roots": [{
    "path": "/private/tmp/scratch",      // real path
    "given": "/tmp/scratch",
    "error": null,                       // or why it was not scanned
    "build_dirs": 4, "bytes": 3800000000, "files": 9900,
    "unreadable": 0,                     // entries the walk could not read
    "left_out": 2                        // credential stores, app libraries, other volumes
  }],
  "build_dirs": [{                       // largest first
    "path": "/private/tmp/scratch/app/node_modules",
    "kind": "node_modules",              // the folder's name
    "rule": "name",                      // "name" | "beside_manifest" | "cachedir_tag" |
                                         // "zig_cache" | "xcode_derived_data"
    "root": "/private/tmp/scratch",
    "project": "/private/tmp/scratch/app",   // or null
    "bytes": 210000000, "logical_bytes": 190000000, "files": 3377,
    "hardlinked_bytes": 0,               // freed only if every other link goes too
    "newest_mtime": 1792160000,          // newest file modification, or null (no files)
    "complete": true,                    // false: something inside could not be read
    "duplicate_set": 0,                  // index into duplicate_sets, or null
    "trash": {
      "eligible": false,                 // what --trash would do now
      "refusal": "is, or holds, a protected location",   // or null
      "newest_change": 1792160587        // newest mtime or ctime of anything inside, the folder included
    }
  }],
  "duplicate_sets": [{                   // most reclaimable first
    "kind": "node_modules",              // or "mixed"
    "copies": 3, "bytes_each": 210000000, "files_each": 3377,
    "reclaimable": 420000000,            // freed by keeping only the largest copy (an upper
                                         // bound: APFS clones share blocks unreported)
    "paths": ["...", "...", "..."]       // sorted
  }],
  "projects": [{                         // most build output first
    "path": "/private/tmp/scratch/app",
    "root": "/private/tmp/scratch",
    "markers": [".git", "package.json"],
    "build_dirs": 1, "build_bytes": 210000000,
    "verdict": "has_unique_work",        // "main_has_everything" | "has_unique_work" | null (no git)
    "reasons": ["2 uncommitted changes (modified, staged or untracked)"],
    "ignored_by": null,                  // the repository that ignores this folder, if one does
    "git": {                             // null when not in a checkout
      "toplevel": "/private/tmp/scratch/app",
      "origin": "git@github.com:acme/app.git",   // credentials removed
      "origin_key": "github.com/acme/app",
      "branch": "main",                  // null when detached
      "head": "4f1c...",                 // null with no commits
      "linked_worktree": false,
      "main_repository": null,           // a linked worktree's repository
      "main_checkouts": ["/Users/me/work/app"],
      "is_main_checkout": false,
      "remotes": 1,
      "uncommitted": 2,
      "unpushed_commits": 0,             // on its branches (a worktree: its HEAD), on no remote-tracking ref
      "stashes": 0,                      // null for a linked worktree (they are its repository's)
      "head_on_remote": true,
      "head_in_main": true,              // null with no main checkout
      "unique_branches": [{ "name": "feature", "commits": 3 }]   // on no remote and in no main checkout
    }
  }],
  "totals": { "build_dirs": 4, "bytes": 3800000000, "files": 9900,
              "duplicate_reclaimable": 420000000, "eligible": 0, "eligible_bytes": 0 },
  "trash": null                          // with --trash:
  // { "moved":   [{ "path": "...", "bytes": 1, "trashed_as": "/Users/me/.Trash/node_modules" }],
  //   "skipped": [{ "path": "...", "bytes": 1, "reason": "changed too recently (see newest_change)" }],
  //   "bytes_moved": 1 }
}
```

## Library / FFI

`zig build` produces a Debug `zig-out/lib/dev/libzdedupe.a`; `zig build lib -Doptimize=ReleaseFast` produces `zig-out/lib/libzdedupe.a`, the archive libs.toml stamps (only `zig build lib`, only in a release mode, writes it); `zig build shared` produces the dynamic library; `zig build header` installs `include/zdedupe.h`.

The C ABI is 21 symbols (`zdedupe_init` … `zdedupe_version`), all declared in `include/zdedupe.h`. **The JSON document returned by `zdedupe_run_sync` is part of the ABI**: the Tauri app (`src-tauri/src/ffi.rs`, serde) and the native Swift app (`ZDedupeEngine.swift`, `JSONDecoder`) decode it into typed models to decide which files to offer for deletion. Field names and types are documented in the header and asserted in `src/tier1_anchors.zig`; changing one without updating both consumers breaks them silently.

### Result store, progress, cancel

`zdedupe_run_to_file` writes a **binary result store** instead of returning JSON (CLI: `--store FILE`). The JSON report is one document — to draw row 40,000 a host must receive, copy and parse everything before it; measured on 642k files that is 106 MB of JSON and a further 570 MB once parsed by the host. The store is fixed-size records in flat, 8-byte-aligned sections with paths referenced as `(offset, len)` into one string section, so a host memory-maps it and reads exactly the rows on screen. The writer streams (offsets are running sums over a fixed iteration order, so records go out before the strings they point at and nothing is buffered), creates the file `0600`, and renames it into place from `<path>.partial` so an existing store survives a failed write. Format spec: the module doc of `src/store.zig`; the desktop app's Rust reader is an independent implementation of it.

`zdedupe_get_progress` / `zdedupe_cancel` are the only calls allowed from another thread during a run; they touch atomics only (`types.Monitor`), so a GUI polls from a timer and no callback re-enters the host. A cancelled run **fails** rather than returning what it has: a file that was never hashed is indistinguishable from a unique one, so results built from a partial scan would silently under-report duplicates.

Duplicate groups list their files oldest first (mtime, then path) in every output.

For the Xcode/Swift consumer, build it with `scripts/build-macos-lib.sh programs/zdedupe ReleaseFast` from the repo root: that runs `zig build lib`, repacks `zig-out/lib/libzdedupe.a` (Zig 0.16 emits 2-byte-aligned Mach-O members; Apple's ld-prime needs 8) and stamps its source identity.

## Correctness posture

Because a consumer deletes files based on this output, the failure mode that matters is a *wrong duplicate verdict*. Guards in place:

- **Read errors never become hashes.** `hasher.zig` breaks on `read() == 0` only; `EINTR` retries and any other failure returns `error.ReadFailed`. A partial-prefix hash used to be returned as valid, so two files that failed at the same offset hashed identically and were reported as duplicates. `parallel.zig` maps a hash failure to `null`, which excludes the file from grouping.
- **External anchors.** `src/tier1_anchors.zig` hashes on-disk fixtures and compares against the official BLAKE3 `test_vectors.json` (lengths 4096 and 102400 — the latter past the 64 KiB read buffer, so the multi-read loop is covered) and against `shasum -a 256` output for the same inputs. The emitted JSON is parsed back with `std.json`, and a filename containing `"`, `\` and `<script>` must survive encode → parse byte-exactly.
- **Overlapping roots are reconciled.** Roots are compared by `realpath`; one that another already covers (nested, repeated, or a symlinked spelling) is dropped and counted in `summary.overlapping_roots`. Previously each root got its own walker and inode table, so `zdedupe ~/docs ~/docs/old` listed every file under `old/` twice and reported it as a duplicate *of itself* — "keep one, delete the rest" then deletes the only copy.
- **Roots are walked by their real paths.** Protection, excludes and keep rules match paths as spelled, and the walker follows a root that is a link, so a root given through one (macOS `/tmp` or `/var`, a link to `/System`) would have been walked under a spelling no rule recognises. Every scan (duplicates, folders, Disk Space, compare, `clean`) resolves its roots and exclude paths first (`src/realpath.zig`: `realpath`, or the final path by handle on Windows), and results and stores carry real paths; the session resolves the roots, home folder and protected roots a host names the same way.
- **Directory verdicts are conservative.** A directory with anything unreadable beneath it is `incomplete`: never a member of an identical set, never the contained side of `a_in_b` / `b_in_a`. A file the pipeline could not hash is treated as unique. Entries ignored on purpose (excludes, cache dirs, hidden-when-off, special files) do not block a verdict but are counted per directory (`skipped_entries`) so a consumer can say "identical, ignoring N entries". A directory directly holding another app's library (Photos, Steam) or another volume's mount point is `incomplete` all the same: neither was read, and deleting the directory would take it along. Hard-linked snapshot trees (`cp -al`, `rsync --link-dest`) compare identical by inode, while the file-level groups still never report a hard link as a duplicate.
- **Cancel and store guards, mutation-tested.** Removing the post-hash cancel check, writing the string section in a different order than offsets were assigned, leaving groups in walk order, writing the store in place instead of via rename, or letting a cancel stick to the context each turn the suite red. The store is cross-checked field by field against the JSON report of the same scan.
- **No advice about VCS metadata.** No finding points at or inside `.git` / `.hg` / `.svn`: there a file's location is its meaning (`.git/refs/heads` can equal `.git/refs/remotes/origin` byte for byte, and deleting the "redundant" one deletes the local branches). The metadata still counts toward the identity of the project around it, so copies whose histories differ are never identical.
- **Directory digest anchored independently.** The digest format is specified in the `src/dirs.zig` module doc; `tools/dirdigest_reference.py` implements it from that text with `os` + `hashlib`, and its output for the fixture tree is the expected value in `src/tier1_anchors.zig`. Eleven mutations of the guards above (dropping the name, symlink target or content hash from the digest; ignoring `incomplete`; honouring the size window during the walk; accepting an unsigned `CACHEDIR.TAG`; not reconciling roots; grouping or dropping extra hard links; reporting inside `.git`) each turn the suite red.
- **One stat implementation.** `src/pstat.zig` is the only place that stats. It routes through `std.c.fstatat` (which selects the `$INODE64` symbols) on Darwin and `statx` on Linux, replacing four hand-rolled `extern struct Stat` copies whose layout was wrong on x86_64 macOS and on aarch64 Linux.
- **Symlinks.** `-L` stats targets rather than links, and both walkers keep a visited-directory `(dev, ino)` set, so `ln -s .. loop` terminates. Without `-L`, symlinks are skipped by the file-level scan (directory analysis records them, with their target, as part of what a directory contains).

## Tests

`zig build test` runs every module's tests plus `src/tier1_anchors.zig`. Filesystem fixtures are created under `$TMPDIR` via `src/testing_scratch.zig` — never inside the repo, because the fixtures include hostile filenames, hard links and symlink cycles.
