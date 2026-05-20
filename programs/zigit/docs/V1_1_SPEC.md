# zigit v1.1

Spec for the next release. Self-contained.

> Status: planned. v1.0 shipped at commit `f1621f1`.

## Goals

Two pain points block zigit from being usable on complex real-world
repositories. v1.1 closes both.

1. **`.gitignore` support.** Today `zigit status` lists every
   `node_modules/`, `dist/`, `.zig-cache/`, and editor swap file as
   untracked. `zigit add .` doesn't exist yet, but when it does it
   needs to skip the same files. Users on any non-trivial repo can't
   read status output without piping through `grep -v`.

2. **Symlink materialization (mode 120000).** Today `zigit clone` /
   `checkout` / `restore` write symlink blobs as **regular files
   containing the link target path**. That breaks every config-driven
   workflow that depends on `latest → v1.2.3/` style links — common
   in CI, deployment, and tooling like nvm / pyenv.

Out of scope for v1.1 (defer to v1.2):

- `.gitattributes` (line-ending normalisation, `binary` markers,
  export filters).
- Sparse-checkout, partial-clone, shallow-clone.
- Stat-cache fast path for `status`.
- `add .` directory recursion is in scope because it depends on
  `.gitignore`, but globbed pathspecs (`add 'src/**/*.zig'`) are
  v1.2.

---

## Part 1 — `.gitignore`

### Scope

Match git's documented `.gitignore` semantics for the subset that
covers ≥99 % of real-world ignore files. Specifically:

- **Pattern syntax** (per `gitignore(5)`):
  - Plain literals: `foo.txt`, `secrets.json`
  - Anchored to repo root: `/build`
  - Directory-only: trailing `/` (`node_modules/`, `dist/`)
  - Globs: `*.log`, `*.tmp`, `~$*`
  - `**` for arbitrary path depth: `**/node_modules/`, `vendor/**/test`
  - Negation: `!important.log` to un-ignore something an earlier
    pattern excluded
  - Comments: `#`-prefixed lines
  - Blank lines: skipped
- **Cascade**: a `.gitignore` in any directory applies to that
  directory and its descendants. Patterns in a deeper file override
  patterns in shallower files via standard last-match-wins semantics.
- **Global ignore**: `core.excludesFile` from `~/.gitconfig`, default
  `~/.config/git/ignore` per git's docs. Applied with lowest
  precedence (below any in-repo `.gitignore`).
- **`.git/info/exclude`**: per-repo equivalent of the global file.
  Applied between the global file and in-repo `.gitignore` files.
- **Always-tracked files**: a path that's already in the index
  bypasses `.gitignore` entirely. `status` shows it; `add` re-stages
  it. Matches git.

Explicitly **not** in scope:

- `.gitignore`-pattern character classes (`[abc]`, `[!a-z]`). They're
  rare in practice. We'll error on them with a clear message if
  encountered, then add support in a follow-up.
- Glob escapes (`\!literal-bang`). Same — clear error, follow-up.
- `[attr] pattern` (gitattributes-style attribute lines that some
  tools embed). v1.2.

### Architecture

```
src/ignore/
├── mod.zig         re-exports
├── pattern.zig     pure pattern compilation + matching
└── ruleset.zig     cascading-file ruleset, query interface
```

`pattern.zig` is the heart. A compiled pattern is:

```zig
pub const Pattern = struct {
    /// The compiled glob segments — each is either a literal byte
    /// run or a wildcard token.
    segments: []const Segment,
    /// Patterns starting with `/` only match relative to the
    /// .gitignore's containing directory.
    anchored: bool,
    /// Patterns ending with `/` only match directories.
    dir_only: bool,
    /// `!`-prefixed patterns un-ignore on match.
    negated: bool,
    /// Pre-computed double-star presence — lets the matcher pick a
    /// fast path for common simple-glob patterns.
    has_doublestar: bool,
};

pub const Segment = union(enum) {
    literal: []const u8,
    star: void,         // matches anything except '/'
    doublestar: void,   // matches arbitrary depth
    question: void,     // matches one byte except '/'
};

pub fn compile(allocator, raw_pattern) !Pattern;
pub fn matches(pattern, path, is_dir) bool;
```

`ruleset.zig` wraps multiple cascading files:

```zig
pub const RuleSource = enum {
    global,        // ~/.config/git/ignore or core.excludesFile
    info_exclude,  // .git/info/exclude
    in_repo,       // a .gitignore at some depth
};

pub const Rule = struct {
    pattern: Pattern,
    /// The directory the pattern is relative to. For global +
    /// info/exclude this is the repo root. For in-repo files it's
    /// the directory containing the .gitignore.
    base_dir: []const u8,
    source: RuleSource,
};

pub const Ruleset = struct {
    /// Sorted: lower-precedence rules first (global → info/exclude →
    /// in-repo from shallowest to deepest). Last match wins, with
    /// !-rules un-ignoring.
    rules: []Rule,

    pub fn loadForRepo(allocator, io, environ, repo, cfg) !Ruleset;
    pub fn isIgnored(self, path, is_dir) bool;
    pub fn deinit(self, allocator) void;
};
```

`Ruleset.loadForRepo` walks the work tree once at construction time,
finding every `.gitignore`. We do NOT discover them lazily during
walks because the cascade rules require us to know the full set
before evaluating any single path.

### Integration

- **`workdir.walk`** (`src/workdir.zig`) — currently returns every
  file under the work tree except `.git/`. Add a `?*const Ruleset`
  parameter; when non-null, skip directories and files matching
  it (with the dir-only / negation semantics applied). The early-exit
  for matched directories is important: skipping `node_modules/`
  before recursing into it is the whole perf payoff.

- **`zigit status`** — load the ruleset once at the top of `run`,
  pass to `workdir.walk`. The "untracked files" section then only
  shows non-ignored paths. Existing parity tests (§10) hold; new
  parity checks cover the cascade + negation behaviour.

- **`zigit add`** — extend to support directory args and `.`:
  - `zigit add foo.txt` (existing) — explicit, ignores `.gitignore`.
  - `zigit add path/to/dir/` — recurse, honour the ruleset, stage
    every non-ignored file.
  - `zigit add .` — same as the current working directory.
  - **Always-tracked override**: if a path is already in the index,
    re-staging via an explicit argument works even when it matches
    the ruleset. Matches `git add -f` behaviour, except we don't
    need a flag because explicit single-file args already imply
    intent.

- **`zigit diff`** — exact-match pathspec only today, no recursion.
  No `.gitignore` integration needed for the existing surface.
  v1.2 work.

### Data flow

```
zigit status
    └─→ Ruleset.loadForRepo(...)
            ├─ read ~/.config/git/ignore (or core.excludesFile)
            ├─ read .git/info/exclude
            └─ for each dir under work tree:
                 ├─ read .gitignore if present
                 └─ recurse
        └─→ workdir.walk(work_root, ruleset)
                └─ for each entry:
                     ├─ if .git → skip
                     ├─ if ruleset.isIgnored(rel_path, is_dir) → skip
                     └─ emit
        └─→ existing index / head comparison logic
        └─→ render
```

### Test surface

**Unit tests** (`src/ignore/pattern.zig` test block):

- Literal matches: `pattern("foo.txt").matches("foo.txt", false) == true`
- Literal misses: `pattern("foo.txt").matches("bar.txt", false) == false`
- Anchored `/build`: matches `build` at root, NOT `src/build`.
- Directory-only `node_modules/`: matches `node_modules` when is_dir,
  doesn't match `node_modules` when it's a file (the file path itself,
  not its containing dir).
- Star: `*.log` matches `foo.log`, doesn't match `dir/foo.log`.
- Doublestar: `**/node_modules` matches at any depth.
- Negation: `*.log` then `!important.log` — `important.log` survives.
- Comments + blank lines: don't produce rules.
- Unsupported character class `[abc]`: returns
  `error.UnsupportedPatternCharClass` with a clear name.

**Ruleset tests** — synthetic file tree, assert isIgnored returns
the right value for each path:

- Global ignore from a fixture `~/.config/git/ignore` overlaid by
  `.git/info/exclude` overlaid by a nested `.gitignore`.
- Last-match-wins: top-level `*.log` plus a deeper `!debug.log`
  un-ignores `debug.log` only under that subtree.
- A path matching `node_modules/` short-circuits the recursive walk
  (verified by counting `read` calls against a mock store).

**Parity tests** (`tests/parity.sh §32`):

- §32.1 — `zigit status` matches `git status --porcelain` on a repo
  with a typical Node.js `.gitignore` (`node_modules/`, `dist/`,
  `*.log`, `!important.log`).
- §32.2 — `zigit status` matches git on a Zig project layout
  (`zig-cache/`, `zig-out/`, plus a nested `.gitignore`).
- §32.3 — `zigit add .` stages exactly the files git stages, no
  more no less.
- §32.4 — A file already tracked but newly matching `.gitignore`
  still shows in status (modified) and re-stages via add.
- §32.5 — A `core.excludesFile` set in `~/.gitconfig` (synthesised
  via `HOME=<tmp>`) applies.

---

## Part 2 — Symlink materialization

### Scope

When a tree entry has mode `120000`, the blob's payload is the link
target as plain bytes (e.g. `../bin/zigit`). Today we write it as a
regular file. v1.1 creates an actual OS-level symlink instead.

Covered:

- **`clone`** — work-tree materialisation when fetching a fresh repo.
- **`checkout`** / **`switch`** — when moving between branches that
  differ on symlink content.
- **`restore`** — when restoring a path from index or HEAD.
- **`gc`** — symlink blobs still pack-deltify like any other blob.
  No change here; they were already correct on the storage side.
- **`hash-object`** of a symlink — Zig's `lstat` plus a manual read
  of the link target. Already mostly correct in `workdir.zig`
  (Mode.symlink is detected); just isn't reaching the index at the
  right mode.
- **Index**: index entries for symlinks store mode `120000` and the
  link-target blob's oid. Already on the read side; the write side
  needs the same Mode handling.
- **`status`** — already detects link mode from lstat; needs to
  hash the link-target bytes (NOT readlink + treat as regular file)
  to compare against the index.

Not covered (v1.2):

- **Windows symlinks** — they require admin or developer-mode
  privileges. v1.1 targets POSIX systems (macOS + Linux). On
  Windows, fall back to writing a regular file containing the
  target path (current behaviour) with a stderr warning.
- **Hard links** — git doesn't model them; we don't either.
- **Cycle detection** when walking via symlinks. Out of scope.

### Architecture

No new modules. Touch the existing materialisation + walk surface:

```
src/worktree.zig          applyTree: when entry.mode == 120000,
                          read the blob payload, std.Io.Dir.symlink
                          instead of writeFile.
src/workdir.zig           walk: when lstat reports symlink, emit
                          with Mode.symlink and DO NOT recurse into
                          it (already correct; verify).
src/cli/status.zig        For Mode.symlink workdir entries, hash the
                          link target via readLink instead of
                          readFile. Compare against the index entry's
                          oid (already a blob oid of the link target).
src/cli/{checkout,restore,switch,clone}.zig
                          Already delegate to worktree.applyTree;
                          inherit the fix transparently.
src/index/entry.zig       Verify the symlink mode (120000) round-trips
                          through write / read. Likely already correct
                          since we tested git-written indexes; verify.
src/object/tree.zig       Verify symlink entries serialise correctly.
                          (No change expected; we use the mode byte
                          from the entry.)
```

### The materialisation primitive

`std.Io.Dir` exposes a `symlink` operation. Verify the API
signature before coding:

```zig
// In src/worktree.zig applyTree:
.symlink => |target_bytes| {
    // The blob payload IS the link target — no trailing newline
    // normalisation. git stores the raw target bytes.
    try work_root.symlink(io, target_bytes, dest_path);
    // Symlinks have no executable bit, no content hashing beyond
    // their target; nothing further to do.
},
```

Pre-existing files at `dest_path` must be removed first (the existing
`applyTree` does this for regular files via `deleteFile`; extend the
same handling to symlinks via `deleteSymlink` or `lstat`-then-delete).

### Cross-platform fallback

On Windows (`builtin.os.tag == .windows`):

```zig
.symlink => |target_bytes| {
    work_root.symlink(io, target_bytes, dest_path) catch |err| switch (err) {
        error.AccessDenied => {
            // Windows requires SeCreateSymbolicLinkPrivilege or
            // developer mode. Fall back to a regular file so the
            // checkout doesn't fail outright.
            try work_root.writeFile(io, .{ .sub_path = dest_path, .data = target_bytes });
            try writeWarning(io, "wrote symlink as regular file (Windows perms): {s}\n", .{dest_path});
        },
        else => return err,
    };
},
```

We don't currently test on Windows in CI; the fallback is
correctness insurance.

### Test surface

**Unit tests** — `src/worktree.zig` test block:

- Apply a tree containing a symlink → verify `readLink` on the
  resulting path returns the target bytes. Skip the test cleanly on
  Windows.
- Apply a tree where a path changes from regular file to symlink
  between calls. The first applyTree writes a file; the second must
  delete the file and create a symlink.
- Apply a tree where a symlink changes target. The second applyTree
  must replace the link, not create a new file.

**Parity tests** (`tests/parity.sh §33`):

- §33.1 — A test repo where `latest` is a symlink to `v1.2.3/`. After
  `zigit clone`, `readlink latest` returns `v1.2.3/`.
- §33.2 — `git status` on the cloned repo is clean (no spurious
  "modified" line for the symlink).
- §33.3 — `zigit checkout main` after editing a symlink restores
  the original target.
- §33.4 — A repo where a path was a file in commit A and a symlink
  in commit B. `zigit switch B` correctly replaces the file with a
  symlink.

---

## File inventory

New:

- `src/ignore/mod.zig` — re-exports.
- `src/ignore/pattern.zig` — pattern compiler + matcher + unit
  tests for every supported pattern shape.
- `src/ignore/ruleset.zig` — multi-file cascading ruleset + tests.
- `docs/V1_1_SPEC.md` — this document.

Modified:

- `src/workdir.zig` — `walk` accepts an optional `*const Ruleset`,
  applies dir-only / negation semantics, short-circuits matched
  directories.
- `src/lib.zig` — re-export `ignore`.
- `src/cli/status.zig` — load ruleset before walking the work tree.
- `src/cli/add.zig` — implement directory + `.` recursion.
- `src/worktree.zig` — symlink branch in `applyTree`.
- `src/cli/status.zig` — for `Mode.symlink` entries, hash the link
  target via `readLink` instead of `readFile`.
- `tests/parity.sh` — append §32 (gitignore) + §33 (symlinks).

## Acceptance criteria

v1.1 ships when:

- `zig build test` passes (extends from 132 → ~150 tests).
- `tests/parity.sh` passes (extends from 184 → ~200 checks).
- A representative real-world repo (suggest: this repo, or the user's
  `zig-forge` monorepo) gives the same `zigit status` output as
  `git status` modulo cosmetic colour codes.
- `zigit clone` of a repo with symlinks produces a work tree where
  every link is a real OS symlink (verified via `readlink`).

## Notes for the implementer

- **Order**: write `pattern.zig` first with its unit tests. The
  ruleset layer is mechanical on top of a correct matcher; the
  CLI integration is mechanical on top of the ruleset.
- **Performance**: don't optimise pattern matching prematurely. The
  early-exit-on-matched-directory in `workdir.walk` is the real perf
  win — even a naive linear scan of patterns per path is fast
  compared to the I/O it saves. If a profile shows pattern matching
  in the hot path later, we can pre-compile a trie or short-circuit
  on common literal prefixes.
- **Memory**: the ruleset lives for the duration of a single
  command. An arena per command keeps lifetimes simple — same shape
  as blame's per-call arena.

End of spec.
