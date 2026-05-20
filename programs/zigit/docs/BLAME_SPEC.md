# zigit blame

Spec for `zigit blame`. Self-contained.

> **Status: shipped in v1.0.** Every section below is implemented and
> covered by `tests/parity.sh §28` (7 byte-for-byte parity checks
> against `git blame --porcelain`) + unit tests in
> `src/blame/{region,blame,format}.zig`.
>
> Revision history:
> * 2026-05-19 v1 — original draft (handed off).
> * 2026-05-19 v2 — corrected merge-commit handling (trace through *all*
>   parents, not just first parent; attribute to the merge commit only
>   when content doesn't match any parent's blob).
> * 2026-05-20 v3 — marked shipped sections. Out-of-scope items (rename
>   detection, `--reverse`, `--ignore-revs-file`, `-w`, incremental
>   output) remain deferred per the original spec.

---

## Current state

- `zigit blame` does not exist.
- All the primitives blame needs are already in tree: Myers diff
  (`src/diff/myers.zig`), commit graph walker (`src/object/walker.zig`),
  tree reader (`src/object/tree.zig`), pack reader, loose store.
- `git blame --porcelain` is the canonical reference for output format;
  `tests/parity.sh` already shells out to real git so a new section
  drops cleanly into the existing harness.

## Scope

1. **Core library** — `src/blame/blame.zig` exposing
   `blameFile(repo, ref, path) → BlameResult` and
   `blameRange(repo, ref, path, range) → BlameResult`. Pure Zig, no CLI
   concerns.
2. **CLI command** — `src/cli/blame.zig` wiring the library to
   `zigit blame [-L N,M] [--porcelain] PATH`.
3. **Output formatters** — human (matches `git blame` default),
   porcelain (matches `git blame --porcelain` byte-for-byte where
   mechanically possible).
4. **Performance instrumentation** — per-phase timings
   (`tree_walks_ms`, `diffs_ms`, `io_ms`, `total_ms`) emitted under
   `--verbose`, exposed structurally through the library so jesternet's
   port can surface them on `/status`.
5. **Parity tests** — a new section in `tests/parity.sh` covering at
   least: single-author file, multi-author file, file created
   mid-history, file unchanged across many commits (tree-OID
   short-circuit must trigger), merge commit attribution, deleted
   lines, `-L` range, `--porcelain` byte-identity.
6. **Unit tests** — algorithm correctness on synthetic histories where
   the expected attribution is mechanically derivable.

## Out of scope

- Rename detection (`--follow`, `-M`, `-C`). Defer; rename detection
  roughly doubles algorithm complexity and the parity surface.
- `--reverse` (walk forward from a commit to see when lines disappear).
  Niche; defer.
- `--ignore-revs-file`. Useful but additive.
- `-w` / `--ignore-all-space` whitespace-insensitive diffing. Defer.
- `--date=<format>` variants. Default to `iso`
  (`YYYY-MM-DD HH:MM:SS ±ZZZZ`).
- Incremental output (`git blame --incremental`). Defer.

---

## Architecture

### Data model

```zig
// src/blame/blame.zig

pub const BlameLine = struct {
    /// 1-based line number in the target file at the target ref.
    line_no: u32,
    /// The commit that last touched this line.
    commit_oid: Oid,
    /// Author identity at that commit (not committer).
    author_name: []const u8,
    author_email: []const u8,
    /// Seconds since epoch + tz offset minutes, as recorded in the commit.
    author_time: i64,
    author_tz_offset_minutes: i16,
    /// The line content as it appears in the target file. Caller-owned slice
    /// into the target blob; lifetime matches the BlameResult.
    content: []const u8,
};

pub const BlameMetrics = struct {
    tree_walks_ms: u64,
    diffs_ms: u64,
    io_ms: u64,
    total_ms: u64,
    commits_examined: u32,
    /// How many times the tree-OID short-circuit fired
    /// (file unchanged between commit and parent).
    short_circuit_hits: u32,
    /// Set when max_commits was hit before every line was attributed;
    /// the residue is pinned to the target ref's commit.
    partial: bool,
};

pub const BlameResult = struct {
    lines: []BlameLine,
    metrics: BlameMetrics,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *BlameResult) void { /* free arena */ }
};

pub const BlameError = error{
    PathNotFoundAtRef,
    PathIsNotFile,
    RefNotFound,
    UnreadableBlob,
    OutOfMemory,
};

pub const BlameOptions = struct {
    line_range: ?struct { start: u32, end: u32 } = null,
    max_commits: ?u32 = null,
};

pub fn blameFile(
    allocator: std.mem.Allocator,
    repo: *Repo,
    ref_oid: Oid,
    path: []const u8,
    opts: BlameOptions,
) BlameError!BlameResult;
```

### Algorithm: incremental backward walk with region tracking

The core abstraction is a **region**: a contiguous range of lines that
are currently being traced together because they all need attribution
and all live in the same blob at the current point in the walk.

```
Region = {
  current_commit: Oid,           // which commit's blob frame these lines live in
  blob_line_start: u32,          // 1-based, inclusive, in current_commit's blob
  blob_line_end: u32,            // 1-based, inclusive
  target_line_start: u32,        // 1-based line range in the TARGET file
  target_line_end: u32,          // (so we can write attributions back to the right slots)
}
```

Initial state: one region covering the requested range (whole file or
`-L`) in the target file at the target ref.

```
work_queue: priority queue of (commit_time, commit_oid, regions_at_this_commit)
            ordered newest-first by author_time. Topological correctness
            comes for free because a commit is more recent than its parents
            in git's commit DAG (modulo committer clock skew, which we
            tolerate via the priority queue ordering).

attributions: array of (target_line_no → ?Oid), initially all null

push (head_commit, [initial_region]) onto work_queue

while work_queue is non-empty:
    (commit_oid, regions) = pop highest-time entry

    if max_commits hit:
        attribute every still-pending target line to the target ref's commit
        metrics.partial = true
        break

    commit = readCommit(commit_oid)

    if commit.parents is empty:
        # Root commit. Whatever's still in flight originated here.
        attributeRemaining(regions, commit_oid)
        continue

    blob_oid_in_commit = lookupPathInTree(commit.tree, path)
    if blob_oid_in_commit is null:
        # Bug — we shouldn't be looking at a commit where the path doesn't
        # exist; the previous step's diff would have attributed those lines.
        attributeRemaining(regions, commit_oid)
        continue

    if commit.parents.len == 1:
        handleSingleParent(regions, commit_oid, commit.parents[0])
    else:
        handleMergeCommit(regions, commit_oid, commit.parents)

# At the end, build BlameResult.lines from attributions[] + content from
# the target blob's lines.
```

#### Single-parent step

```
function handleSingleParent(regions, commit_oid, parent_oid):
    blob_oid_in_commit = blob at path in commit_oid.tree
    blob_oid_in_parent = blob at path in parent_oid.tree

    if blob_oid_in_parent is null:
        # File created in `commit_oid`. Attribute remaining lines and stop.
        attributeRemaining(regions, commit_oid)
        return

    if blob_oid_in_parent == blob_oid_in_commit:
        # SHORT-CIRCUIT: file unchanged. Carry regions to parent's frame
        # unchanged (the blob-line range is still valid because the blob
        # didn't change).
        metrics.short_circuit_hits += 1
        push (parent_oid, regions) onto work_queue
        return

    # File changed: compute Myers diff between parent and commit blobs.
    diff_edits = myers(blob_in_parent, blob_in_commit)
    metrics.diffs_ms += elapsed

    # For each region, split:
    #   - Lines in this commit added vs parent → attribute to commit
    #   - Lines unchanged from parent → carry back to parent's frame
    #     with line numbers re-expressed in parent's coordinate system
    new_regions_for_parent = []
    for region in regions:
        split = splitRegionAgainstDiff(region, diff_edits, parent_oid)
        for attributed in split.attributed_to_commit:
            attribute(attributed.target_lines, commit_oid)
        new_regions_for_parent.extend(split.carry_to_parent)

    new_regions_for_parent = coalesceContiguous(new_regions_for_parent)
    if new_regions_for_parent is non-empty:
        push (parent_oid, new_regions_for_parent) onto work_queue
```

#### Multi-parent (merge) step — the corrected handling

Git's blame does **not** treat a merge commit as "attribute everything
not in the first parent." It walks every parent. A line is attributed
to the merge commit *only* if its content cannot be matched against
*any* parent — i.e. content that exists in the merge's blob but in
none of the parents' blobs, meaning it was introduced during the merge
resolution itself.

```
function handleMergeCommit(regions, commit_oid, parents):
    blob_in_commit = blob at path in commit_oid.tree
    if blob_in_commit is null:
        # File created at the merge — rare but legal. Attribute and stop.
        attributeRemaining(regions, commit_oid)
        return

    # We split regions iteratively across parents. Each pass takes whatever
    # is left and tries to route it to the next parent.
    pending = regions   // a list of regions, all in commit_oid's frame
    routed_to_parent: map<parent_oid, list<Region>> = {}

    for parent_oid in parents:                           // order matters for tie-breaking
        blob_in_parent = blob at path in parent_oid.tree
        if blob_in_parent is null:
            # Path missing in this parent; nothing to match against.
            continue
        if blob_in_parent == blob_in_commit:
            # SHORT-CIRCUIT: identical blob. ALL remaining pending lines
            # match this parent unchanged — route everything there. This
            # is a common case for merges where only one branch touched
            # the file.
            metrics.short_circuit_hits += 1
            for region in pending:
                routed_to_parent[parent_oid].append(
                    region with current_commit ← parent_oid
                )
            pending = []
            break

        # Compute diff. Lines that appear unchanged in parent route to
        # parent's frame; lines added vs parent stay in `pending` for
        # the next parent to potentially claim.
        diff_edits = myers(blob_in_parent, blob_in_commit)
        next_pending = []
        for region in pending:
            split = splitRegionAgainstDiff(region, diff_edits, parent_oid)
            # Lines that match this parent → route to that parent's frame
            routed_to_parent[parent_oid].extend(split.carry_to_parent)
            # Lines that don't match → carry forward to try the next parent
            next_pending.extend(split.attributed_to_commit_as_regions)
            # NOTE: split.attributed_to_commit_as_regions are regions whose
            # blob lines are "added vs THIS parent". They might still match
            # another parent; we don't attribute them to commit_oid yet.
        pending = next_pending

    # Whatever is still in `pending` after trying every parent did not
    # appear unchanged in ANY parent's blob. That content was introduced
    # by the merge resolution itself — attribute it to commit_oid.
    for region in pending:
        attribute(region.target_lines, commit_oid)

    # Push each parent's collected regions onto the work queue.
    for (parent_oid, parent_regions) in routed_to_parent:
        if parent_regions is non-empty:
            push (parent_oid, coalesceContiguous(parent_regions))
                onto work_queue
```

The first-parent default git uses is just **tie-breaking**: if a line
matches both parent 1 and parent 2 unchanged, git routes it to parent
1 first. Our loop achieves the same by iterating parents in order and
routing matches as we find them — once a line has been routed to
parent 1, it's out of `pending` and parent 2 doesn't see it. So a
non-trunk parent only "wins" a line when the trunk parent doesn't have
that line. That matches git's default behavior (no flags like
`--first-parent`).

#### splitRegionAgainstDiff

Given a region in `commit`'s frame and the diff from `parent` to
`commit`, produce two sets of sub-regions:

```
splitRegionAgainstDiff(region, diff_edits, parent_oid):
    # diff_edits is an array of {op, a_idx, b_idx} where a = parent's blob
    # lines (0-indexed), b = commit's blob lines (0-indexed). For each
    # 1-based blob line L in [region.blob_line_start .. region.blob_line_end]:
    #   - Find the Edit with b_idx == L-1.
    #   - If op == .equal → this line existed unchanged in parent at
    #                       a_idx+1. Carry to parent.
    #   - If op == .insert → this line was added in commit. Mark as
    #                        attributed_to_commit (i.e. did not match
    #                        this parent).
    #   - .delete ops have no b_idx and don't appear in this scan.
    #
    # Group consecutive lines with the same disposition into contiguous
    # sub-regions, mapping target line numbers through.
    #
    # Returns:
    #   carry_to_parent: list<Region>      (in parent's frame)
    #   attributed_to_commit_as_regions: list<Region>  (still in commit's frame)
```

Edge cases to think about during implementation:

- A region might straddle a hunk boundary: the first half is "equal"
  in the diff and the second half is "insert". The split function must
  produce two sub-regions, not lose either half.
- An empty region (start > end) is a bug; assert and skip.
- Blob lines past the end of `commit`'s blob shouldn't appear in the
  initial region; assert at construction time.

### Tree-OID short-circuit

The single biggest perf win. Computing the tree path lookup is cheap;
computing a Myers diff is expensive. If the path's blob OID is
identical between commit and parent, the file is identical, and we
don't need to diff.

For a long-lived file in a repo with many commits that don't touch it,
this is the difference between O(commits_total × diff_cost) and
O(commits_touching_file × diff_cost).

Make the short-circuit unconditional and required, not an optimization
that can be disabled. It applies to both the single-parent and
multi-parent paths.

### Caching within a blame call

A single blame call walks N commits and reads:
- N commit objects (for `parents`, `author`, `tree`)
- N tree paths (to resolve `tree[path] → blob_oid`)
- M blob objects, where M ≤ N (often M ≪ N thanks to the short-circuit)
- K author identities (K ≤ N, usually K ≪ N)

All four caches live in an arena scoped to the blame call:
- `commits: HashMap<Oid, ParsedCommit>`
- `path_blob_at_commit: HashMap<Oid, ?Oid>` — keyed by commit OID,
  value is blob OID at `path` (or null if path doesn't exist)
- `blobs: HashMap<Oid, []const u8>` — borrows from a single shared
  buffer per call
- `authors: HashMap<Oid, AuthorIdent>` — keyed by commit OID

The arena is freed on `BlameResult.deinit()`.

### Path-blob resolution

`lookupPathInTree(tree_oid, "src/foo/bar.zig")`:

1. Read tree object at `tree_oid`.
2. Find entry `src` — if missing, return null.
3. If `src` is a tree, recurse with that subtree OID and the remaining
   path.
4. At the leaf, return the blob OID if the leaf is a blob (mode 100644
   or 100755). For mode 120000 (symlink): out of scope —
   `error.PathIsNotFile`. For mode 160000 (submodule):
   `error.PathIsNotFile`.

Cache aggressively. A blame walk visits the same intermediate trees
repeatedly; without caching, the tree walk dominates.

---

## CLI surface

```
zigit blame [OPTIONS] PATH

OPTIONS:
    -L <N>[,<M>]        Restrict blame to lines N through M (1-based, inclusive).
                        With only N: blame from line N to end of file.
    --porcelain         Machine-readable output matching git blame --porcelain.
    --verbose           Emit per-phase timing summary to stderr after the result.
    --max-commits <N>   Stop walking after N commits and attribute residue to the
                        target ref's commit. metrics.partial = true.

PATH is relative to the working tree.
The implicit ref is HEAD; an explicit ref form is a follow-up.
```

Exit codes:
- `0` — blame produced for all lines.
- `1` — partial result (max_commits hit).
- `128` — file not found, ref invalid, or other fatal error.

### Output: human (default)

```
<short_oid> (<author_padded> <iso_date> <iso_time> <tz>  <line_no>) <line_content>
```

Padding rules match git:
- short_oid: 8 chars.
- author: padded to the width of the longest author name in the result.
- line_no: right-aligned to the width of the largest line number.

### Output: `--porcelain`

Matches `git blame --porcelain` line-by-line. When consecutive lines
share a commit, only the first emits the full header block; subsequent
lines emit only the OID line and the `\t<content>` line. `tests/parity.sh`
will compare byte-for-byte.

For now `filename` always equals the input path (no rename detection).
`previous` is the first-parent commit's OID and the same path.

### Output: `--verbose` (stderr after the result)

```
zigit blame: examined 1247 commits, 8923 ms total
  tree walks: 3120 ms (1247 path lookups, 1108 short-circuited)
  diffs:      4805 ms (139 Myers calls)
  io:         998 ms
```

Numbers illustrative. Programmatic callers read `result.metrics`.

---

## Library API contract

```zig
const blame = @import("zigit").blame;
var result = try blame.blameFile(allocator, repo, ref_oid, "src/foo.zig", .{});
defer result.deinit();

for (result.lines) |line| {
    // ...
}

std.log.info("blame took {}ms", .{result.metrics.total_ms});
```

Two blame calls in flight don't share state beyond `Repository`'s own
caches.

---

## Test surface

### Unit tests (`zig build test`)

In `src/blame/blame.zig` test block:

- **Single-commit file.** All lines → that commit.
- **Two commits, second appends.** Original lines → A; new lines → B.
- **Two commits, second modifies middle.** Unchanged lines → A;
  changed lines → B.
- **Three commits, middle deletes lines.** Verify deleted lines don't
  appear in blame output; surviving lines trace back through the
  delete to A.
- **Merge commit, both branches modified the file.** A creates F. B
  modifies line 3. C modifies line 5. M merges B and C taking both
  changes. Blame at M:
    * lines 1,2,4 → A
    * line 3 → B
    * line 5 → C
    * M itself does NOT appear.
- **Merge commit introduces conflict-resolution content.** Same setup
  as above, plus M itself inserts a new line that exists in neither
  B's nor C's blob. That line → M.
- **Tree-OID short-circuit verified.** Create F at A, make 20 commits
  that don't touch F, then commit C modifies one line. Assert
  `metrics.short_circuit_hits == 20` and the algorithm only ran 2
  Myers calls (one for C, one terminal at A).
- **`-L` range.** Same fixture as above; blame with
  `line_range = .{1, 3}` returns only those lines.
- **Empty file.** Result `lines.len == 0`, no error.
- **Path not found at ref.** `BlameError.PathNotFoundAtRef`.
- **Path is a directory.** `BlameError.PathIsNotFile`.
- **Path is a submodule entry.** `BlameError.PathIsNotFile`.
- **`max_commits` cap hit.** `metrics.partial == true` and
  unattributed lines fall back to the target ref's commit.

### Parity tests (new section in `tests/parity.sh`)

Section name: §28 Blame. For each fixture, run
`git blame --porcelain PATH` and `zigit blame --porcelain PATH`,
then `diff -u`. Byte-identical output expected.

- §28.1: single-author file (5 commits).
- §28.2: multi-author file (10 commits, 3 identities).
- §28.3: file unchanged across 50 commits sandwiched between two that
  change it.
- §28.4: merge commit on the history. Verify content from the
  non-trunk branch is attributed to its originating commit, not the
  merge.
- §28.5: file created mid-history.
- §28.6: `-L 5,10` range on §28.2's fixture.
- §28.7: deleted lines.

### Performance smoke

§28.9. Take a known-large repo (vendor a copy of zigit's own history
into `tests/fixtures/large-repo/`) and run blame on a long-lived file.
Assert total wall time < a calibrated threshold. The point is
regression detection, not a strict perf gate.

---

## File inventory — all shipped

New (commit `5b39074` — core; `25a6d06` — CLI + formatters + parity):

- `src/blame/blame.zig` — algorithm, types, caches. **Shipped.**
- `src/blame/region.zig` — `Region` struct, coalescing,
  blob-line→parent-line mapping. Pure functions, separately testable.
  **Shipped.**
- `src/blame/mod.zig` — re-exports. **Shipped.**
- `src/blame/format.zig` — human + porcelain formatters. **Shipped.**
- `src/cli/blame.zig` — CLI wiring (`-L N[,M]`, `--porcelain`,
  `--verbose`, `--max-commits N`). **Shipped.**
- Synthetic histories for parity built inline in `tests/parity.sh §28`
  via real git commits in a temp dir; no static fixtures directory
  was needed.

Modified:

- `src/main.zig` — `blame` registered in CLI dispatch + usage block.
  **Shipped.**
- `src/lib.zig` — `blame` re-exported. **Shipped.**
- `tests/parity.sh` — §28 added, 7 byte-for-byte porcelain checks.
  **Shipped.**

---

## Performance: what to publish

Once blame works, populate `/status` on jesternet with three concrete
numbers per blame request:

1. Wall time to compute blame for a representative file (e.g. blame on
   `src/repo.zig` in zigit's own history, locally vs jesternet's
   R2-backed implementation).
2. Short-circuit hit ratio — `short_circuit_hits / commits_examined`.
   High ratios are the marketing point.
3. Comparison with `git blame` on the same file, same revision, same
   machine. Two-column table.

---

## Forward-looking

- **Rename detection (`--follow`).** Defer.
- **Move/copy detection (`-M`, `-C`).** Defer further.
- **`--reverse`.** Defer.
- **`--ignore-revs-file`.** Defer.
- **Incremental output (`--incremental`).** Defer.
- **jesternet TS port.** Library API contract above is the reference;
  the parity tests built for zigit are reusable.

---

End of spec.
