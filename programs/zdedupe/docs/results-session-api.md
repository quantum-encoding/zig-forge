# Results session — the C API that makes the frontends thin

## Why

zdedupe has one engine (this library) and two desktop frontends: a Tauri/Rust
app (`~/work/tauri_apps/zdedupe`, branch `v2-dual-pane`, `src-tauri/src/`) and
a SwiftUI app (same repo, branch `v3-swiftui`, `zdedupe-app/zdedupe/Services/`).
The engine is shared, but everything that happens *after* a scan is written
twice — once in Rust (`store.rs`, `commands/results.rs`, `commands/bulk.rs`,
`removed.rs`, `filters.rs`, ~4,000 lines) and once in Swift (`ResultStore.swift`,
`ScanResults.swift`, ~1,100 lines):

- reading the binary result store (`src/store.zig`, `ZDSTORE1`)
- paging groups with sort and filters, one cached order per (sort, filters)
- "select all duplicates" as a rule (filters + unticked paths), summarised
  as three numbers, never enumerated
- verified deletion: every target checked against what the scan saw (size +
  mtime for the Trash, content re-hash for a permanent delete); a group only
  loses copies if a verified copy outside the targets survives; progress and
  cancel; batch trash with per-file fallback
- the removed overlay: what was deleted since the scan, applied to every row
  query so a delete does not force a rescan; persisted beside the store
- export (JSON, CSV, HTML) streamed group by group
- the credential and build-output exclude lists

Two implementations drift (a claim audit on 2026-09-22 found the same bugs
in both, and the credential list "must agree" with nothing enforcing it).
This API moves that layer into the core. After it, a frontend does:
scan → `zdedupe_results_open` → page/summarise/delete/export through the
session → close. The only platform work left in a frontend is the Trash
(no portable API) and, on macOS, security-scoped bookmarks.

The Rust files above are the **reference implementation**: the semantics
below are theirs, and their tests (`cargo test` in `src-tauri`) are the spec
for edge cases. Port behaviour, not structure.

## Conventions

- **`schema/results-session.schema.json` is the machine-readable form of this
  document, and the authority when the two disagree.** This file explains why
  the shapes are what they are; the schema is what a host validates against.
  Every `$defs` entry is one document the session sends or receives, so a
  caller points at the entry it means — `#/$defs/GroupPage`, `#/$defs/Filters`.
  A host should test its own serialised queries against it too, not only the
  answers: `zdedupe-app` does both in `src-tauri/src/commands/conformance.rs`,
  which is how the macOS app shipping without `under`/`name`/`ext`/
  `redundant_only` stops being a silent failure.
- Every call on a session happens on one thread at a time, except
  `zdedupe_results_delete_progress` and `zdedupe_results_cancel_delete`,
  which touch only atomics and may be called from any thread while a delete
  runs (same contract as `zdedupe_get_progress` / `zdedupe_cancel`).
- Strings the session returns are UTF-8 JSON, NUL-terminated, owned by the
  session, valid until the next call on the same session. Paths inside JSON
  are the lossy UTF-8 spelling of the stored bytes (what a UI can show);
  paths sent back in (unticked, hand-picked) are matched against that same
  spelling. The session acts on the store's exact bytes.
- Errors: a call that fails returns NULL (pointer-returning) or non-zero
  (int-returning); `zdedupe_results_last_error` gives the message.
- Numbers in JSON: byte counts and timestamps as integers. Timestamps are
  epoch **milliseconds** in JSON (the store holds seconds).
- Sidecars, owned by the session, beside the store file `<dir>/<name>.zds`:
  `<name>.roots.json` (`["/root/a", ...]`, the scan roots, which the store
  does not record) and `<name>.removed.json` (`{"overflowed": bool,
  "paths_b64": ["...", ...]}` — exact path bytes, base64).

## Lifecycle

```c
typedef struct zdedupe_results zdedupe_results;

/* Map a finished store. roots_json (nullable): a JSON array of the scan's
 * root paths; when given it is written to the roots sidecar and the removed
 * sidecar is discarded (a fresh scan). When NULL, both sidecars are loaded
 * (reopening). A store that fails validation returns NULL. */
zdedupe_results* zdedupe_results_open(const char* store_path, const char* roots_json);
void zdedupe_results_close(zdedupe_results* r);
const char* zdedupe_results_last_error(const zdedupe_results* r);
```

## Overview

```c
const char* zdedupe_results_overview(zdedupe_results* r);
```
```json
{ "roots": ["/a"], "generated_at": 1758530000000,
  "files_scanned": 0, "bytes_scanned": 0, "duplicate_groups": 0,
  "duplicate_files": 0, "space_savings": 0, "scan_time_ns": 0,
  "excluded_entries": 0, "overlapping_roots": 0, "failed_paths": 0,
  "has_directories": false, "dirs_analyzed": 0, "dirs_incomplete": 0,
  "identical_sets": 0, "overlaps": 0, "redundant_pairs": 0, "reclaimable": 0 }
```
Counters are the scan's own; they do not change with deletes (the UIs say
so beside them). `reclaimable` = Σ bytes·(copies−1) over identical sets;
`redundant_pairs` = overlap pairs where at least one side has nothing unique.
Roots come from the sidecar, else the deepest directory containing every
path in the results (`results.rs common_root`).

## Filters (shared by groups, bulk rule, sets, overlaps, facets)

```json
{ "text": "", "min_bytes": 0, "redundant_only": false,
  "under": null, "name": null, "ext": null }
```
Semantics from `filters.rs`: `text` is an ASCII-case-insensitive substring
of any member's path; `min_bytes` is per kind (a file's size, a set's bytes
per copy, an overlap's shared bytes); `under`/`name`/`ext` must hold for the
**same** member (`under` by whole path components; `ext` lower-case with the
dot, `""` = no extension, `.gitignore` → none, `a.tar.gz` → `.gz`);
`redundant_only` applies to overlaps only. All fields optional; missing =
default. `Filters` is the cache key for the group order.

## Groups

```c
const char* zdedupe_results_groups(zdedupe_results* r, const char* query_json);
```
Query: `{ "offset": 0, "limit": 50, "sort": "savings"|"size"|"count",
"filters": {...}, "bulk": {...} | null }`. `limit` is clamped to 200.
`bulk` is the rule in force: rows it covers come back marked.

Page: `{ "rows": [GroupRow], "total": N, "offset": 0 }` where
```json
{ "hash": "64 hex", "count": 3, "size": 1048576, "savings": 2097152,
  "files": ["/oldest", "/next", ...], "mtimes": [ms, ms, ...], "bulk": false }
```
`count`/`savings` are over **alive** copies (removed overlay applied);
`files` lists at most 50, oldest first (index 0 is the keeper); `bulk` is
`alive ≥ 2 && rule matches`. Order: `savings` is the store's own order
until anything has been deleted, then live savings desc; `size` and
`count` desc; stable, so ties keep largest-savings-first. Groups with fewer
than two alive copies are not rows. The order for a (sort, filters, removed
generation) is computed once and cached (four bytes per matching group).

```c
const char* zdedupe_results_bulk_summary(zdedupe_results* r, const char* filters_json);
```
→ `{ "groups": N, "files": M, "bytes": B }` — every copy but the oldest in
the matching groups. Never sees the unticked list; the UI subtracts it.
Reads no paths when nothing has been deleted and no text/facet filter is set.

## Delete

```c
typedef struct { bool running; uint64_t done; uint64_t total; } zdedupe_delete_progress;

/* Host-provided Trash. Called with a batch (<= 200) of exact path bytes,
 * NUL-terminated. Return 0 when every path went; any other value and the
 * session retries the batch one path at a time, so a failure can be
 * attributed to a file. err_out/err_cap: a message for a single-path failure. */
typedef int (*zdedupe_trash_fn)(void* user, const char* const* paths, size_t count,
                                char* err_out, size_t err_cap);

/* Blocks until done. selection_json:
 *   { "rule": { "filters": {...}, "excluded": ["/path", ...] } | null,
 *     "extra": ["/hand/picked", ...] }
 * use_trash=false deletes permanently (std.fs) and verifies by content;
 * use_trash=true calls trash_fn and verifies by metadata. */
const char* zdedupe_results_delete(zdedupe_results* r, const char* selection_json,
                                   bool use_trash, zdedupe_trash_fn trash_fn, void* user);
void zdedupe_results_delete_progress(const zdedupe_results* r, zdedupe_delete_progress* out);
void zdedupe_results_cancel_delete(zdedupe_results* r);
```
Semantics (`bulk.rs run_delete`, `still_a_copy`, `deletable`):
- Plan: for each group in the rule's order, targets = every alive copy
  after the oldest alive one, minus `excluded` (matched on the lossy
  spelling). `extra` paths are located in the store; one not found fails
  with `"not a duplicate in the current results"`. Hand-picks merge into
  the same group's targets before any judgement.
- `total` = planned targets, set before anything is deleted; `done`
  advances per group; cancel is checked per group.
- Verify: `lstat` on the exact bytes; must be a regular file (a symlink
  standing where a file was is not a copy) of the group's size; then
  metadata (mtime seconds equal) or content (`hash_file` equals the group's
  hash, sha256 per the store flag).
- Survivor: some file **outside** the targets and not removed must verify
  first, or every target in the group is `skipped_changed`. Then each
  target verifies individually or is `skipped_changed`.
- Report: `{ "deleted": N, "freed_bytes": B, "skipped_changed": N,
  "failed_count": N, "failed": [["/path","reason"], ...] (≤ 20),
  "cancelled": bool, "needs_rescan": bool }`.
- What went is recorded in the removed overlay and persisted; past 100,000
  tracked paths the overlay overflows, clears, persists `overflowed: true`,
  and `needs_rescan` is true from then on (also after a reopen).
- A second delete while one runs fails with `"A delete is already running"`.

```c
const char* zdedupe_results_removed_status(zdedupe_results* r);
```
→ `{ "count": N, "needs_rescan": bool }`.

The removed overlay (`removed.rs`): `covers(path)` is the path itself or
any ancestor (a deleted folder covers its contents; `/a/old-backup` is not
under `/a/old`). Applied in every row query, the bulk summary, set and
overlap rows, and facets. Bumps a generation that invalidates the cached
order.

## Folders (stage B)

```c
const char* zdedupe_results_identical_sets(zdedupe_results* r, const char* query_json); /* {offset,limit,filters} -> Page<SetRow> */
const char* zdedupe_results_set_members(zdedupe_results* r, size_t index);             /* every alive member */
const char* zdedupe_results_overlaps(zdedupe_results* r, const char* query_json);      /* Page<OverlapRow> */
const char* zdedupe_results_facets(zdedupe_results* r, const char* query_json);        /* {kind,by,filters,limit} -> FacetPage */
const char* zdedupe_results_delete_folders(zdedupe_results* r, const char* items_json,
                                           bool use_trash, zdedupe_trash_fn trash_fn, void* user);
```
Row shapes and semantics exactly as `results.rs` (`SetRow`, `SetDirRow`,
`OverlapRow`, `SideRow`, `Facet`, `FacetPage`) and `bulk.rs`
(`delete_folders_permanently`, `trash_folders`, `folder_refusal`,
`folders_identical` with `min_size 0`). Page-of semantics: rows before the
page are never materialised; sets list 8 dirs, sides list ≤ 100 only-paths.

## Export

```c
int zdedupe_results_export(zdedupe_results* r, const char* format /* "json"|"csv"|"html" */, const char* path);
```
Streams every alive group in store order. Shapes as
`ExportService.swift DuplicateWriter` (Swift) — CSV header
`Group Hash,File Path,File Size (bytes),Group Savings (bytes),Modified`;
JSON `{report_type, generated_at, summary{...}, groups:[{hash,size,count,savings,files:[{path,mtime}]}]}`;
HTML a table grouped by first row.

## Excludes as presets

```c
/* Never open key stores or credential files. The scan only compares content,
 * but a security tool watching file access cannot know that. */
void zdedupe_use_credential_excludes(zdedupe_ctx* ctx, bool use);
```
Names (exact path components, same list the two apps carry today):
`.ssh .gnupg Keychains .password-store .vault-token .aws .azure gcloud .kube
.docker .terraform.d .netrc .git-credentials .npmrc .pypirc .pgpass .my.cnf
.boto .s3cfg .env .envrc`. Lives in `types.zig` beside `default_excludes`;
documented in the header. Both apps then flip a flag and delete their lists.

## Staging

- **Stage A** (this branch, first commit): open/close/last_error, overview,
  groups, bulk_summary, delete + progress + cancel, removed_status, export,
  credential excludes, header docs, tests.
- **Stage B**: identical_sets, set_members, overlaps, facets, delete_folders.

Tests (`zig build test`): run the real engine on a temp tree, then through
the session: paging order and sort; every filter field; bulk summary with
and without deletions; delete — survivor rule, an unticked copy, a changed
copy skipped, hand-picks incl. an unknown path, both copies of a pair
refused, metadata vs content verification, cancel, progress totals; removed
overlay — ancestor cover, persistence, overflow persistence, a non-UTF-8
name round trip; export line counts; a store that fails validation returns
NULL. The Rust tests in `src-tauri/src/commands/bulk.rs` and `removed.rs`
list the cases to match.

## Frontends after stage A

Rust: `results.rs`/`bulk.rs`/`removed.rs`/`store.rs`/`filters.rs` collapse to
FFI pass-through; the Tauri commands keep their names and JSON shapes (the
webview does not change). The `trash` crate becomes the `trash_fn`.
Swift: `ScanResults`/`ResultStore` are deleted; `ScopedRoots` stays;
`NSWorkspace.recycle` becomes the `trash_fn`. The Rust-side switch is done
by the session working on `v2-dual-pane`; the Swift switch by the macOS
session.
