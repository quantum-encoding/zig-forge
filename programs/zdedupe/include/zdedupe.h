/**
 * zdedupe - Cross-platform duplicate finder and folder comparator
 *
 * C FFI header for Tauri/Rust integration
 *
 * Basic usage:
 *   zdedupe_ctx* ctx = zdedupe_init();
 *   zdedupe_add_path(ctx, "/path/to/scan");
 *   const char* json = zdedupe_run_sync(ctx);
 *   // Use JSON result...
 *   zdedupe_free(ctx);
 */

#ifndef ZDEDUPE_H
#define ZDEDUPE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Opaque context handle
 */
typedef struct zdedupe_ctx zdedupe_ctx;

/**
 * Operation modes
 */
typedef enum {
    ZDEDUPE_MODE_FIND_DUPLICATES = 0,
    ZDEDUPE_MODE_COMPARE_FOLDERS = 1,
    /* Where the disk went: walk and size every folder, hash nothing. Result
     * store only (zdedupe_run_to_file); see "Disk space" below. */
    ZDEDUPE_MODE_DISK_SPACE = 2
} zdedupe_mode;

/* === Context Management === */

/**
 * Initialize a new zdedupe context
 *
 * @return Context handle, or NULL on failure
 */
zdedupe_ctx* zdedupe_init(void);

/**
 * Free a zdedupe context and all associated resources
 *
 * @param ctx Context to free (safe to pass NULL)
 */
void zdedupe_free(zdedupe_ctx* ctx);

/* === Configuration === */

/**
 * Add a path to scan
 *
 * For find_duplicates mode: Add multiple paths to search
 * For compare_folders mode: Add exactly two paths to compare
 *
 * @param ctx  Context handle
 * @param path Absolute path to add
 * @return 0 on success, -1 on failure
 */
int zdedupe_add_path(zdedupe_ctx* ctx, const char* path);

/**
 * Set operation mode
 *
 * @param ctx  Context handle
 * @param mode ZDEDUPE_MODE_FIND_DUPLICATES, ZDEDUPE_MODE_COMPARE_FOLDERS or
 *             ZDEDUPE_MODE_DISK_SPACE. Any other value leaves the mode as it was.
 */
void zdedupe_set_mode(zdedupe_ctx* ctx, zdedupe_mode mode);

/**
 * Set minimum file size to consider
 *
 * @param ctx   Context handle
 * @param bytes Minimum size in bytes (default: 1)
 */
void zdedupe_set_min_size(zdedupe_ctx* ctx, uint64_t bytes);

/**
 * Set maximum file size to consider
 *
 * @param ctx   Context handle
 * @param bytes Maximum size in bytes (0 = unlimited, default: 0)
 */
void zdedupe_set_max_size(zdedupe_ctx* ctx, uint64_t bytes);

/**
 * Set whether to include hidden files (dotfiles)
 *
 * @param ctx     Context handle
 * @param include true to include hidden files (default: true)
 */
void zdedupe_set_include_hidden(zdedupe_ctx* ctx, bool include);

/**
 * Set whether to follow symbolic links
 *
 * @param ctx    Context handle
 * @param follow true to follow symlinks (default: false)
 */
void zdedupe_set_follow_symlinks(zdedupe_ctx* ctx, bool follow);

/**
 * Set number of threads (0 = auto)
 *
 * @param ctx   Context handle
 * @param count Number of threads (default: 0 = auto-detect)
 */
void zdedupe_set_threads(zdedupe_ctx* ctx, uint32_t count);

/**
 * Set hash algorithm
 *
 * @param ctx       Context handle
 * @param use_sha256 true for SHA256, false for BLAKE3 (default: false/BLAKE3)
 */
void zdedupe_use_sha256(zdedupe_ctx* ctx, bool use_sha256);

/**
 * Also report identical and overlapping directories (the "directories"
 * section of the find_duplicates JSON, see zdedupe_run_sync).
 *
 * While enabled, min/max size filter the reported file groups only - the walk
 * sees every file, since a directory must not pass for a copy of another
 * because the file that differs was outside the size window - and symlinks are
 * compared by target rather than followed (follow_symlinks is ignored).
 *
 * @param ctx     Context handle
 * @param analyze true to enable (default: false)
 */
void zdedupe_set_analyze_dirs(zdedupe_ctx* ctx, bool analyze);

/**
 * Stay on the volumes the scan roots live on (default: true). A directory on
 * another device inside a root - a mounted disk, a network share, a
 * connected phone's DeviceFS - is not entered: such a mount can block a read
 * indefinitely. A root on another volume is still scanned; it was named.
 */
void zdedupe_set_one_filesystem(zdedupe_ctx* ctx, bool one);

/**
 * Skip library packages another app owns, by extension (default: true):
 * .photoslibrary, .migratedphotolibrary, .photolibrary, .aplibrary,
 * .musiclibrary, .tvlibrary. Their contents are the app's database, and
 * opening a Photos library makes macOS ask for photo-library access.
 * The same switch skips Steam: every `steamapps` library folder, and the
 * client's own install (~/.local/share/Steam, ~/.steam, the Flatpak's
 * ~/.var/app/com.valvesoftware.Steam, ~/Library/Application Support/Steam).
 * Steam checks game files against its manifests, so deleting a "duplicate"
 * there re-downloads or breaks a game. A scan root is never skipped. Applies
 * to duplicate scans; a folder comparison compares everything it is given.
 */
void zdedupe_set_skip_app_libraries(zdedupe_ctx* ctx, bool skip);

/**
 * Ignore regenerable output: node_modules, __pycache__, .zig-cache,
 * .svelte-kit, .DS_Store, ... (Config.default_excludes in src/types.zig) and
 * any directory carrying a valid CACHEDIR.TAG, e.g. cargo's target/.
 * .git is never part of the defaults. Scan roots are never excluded.
 *
 * @param ctx          Context handle
 * @param use_defaults true to enable (default: false)
 */
void zdedupe_use_default_excludes(zdedupe_ctx* ctx, bool use_defaults);

/**
 * Never open key stores or credential files: .ssh, .gnupg, Keychains,
 * .password-store, .vault-token, .aws, .azure, gcloud, .kube, .docker,
 * .terraform.d, .netrc, .git-credentials, .npmrc, .pypirc, .pgpass, .my.cnf,
 * .boto, .s3cfg, .env, .envrc (Config.credential_excludes in src/types.zig).
 *
 * A scan only ever compares content and reports nothing about what it read,
 * but a security tool watching file access cannot know that: a duplicate
 * finder walking ~/.ssh looks exactly like one exfiltrating it. Skipping these
 * costs a user nothing - nobody reclaims space by deduplicating a private key.
 *
 * Additive, and independent of zdedupe_use_default_excludes.
 *
 * @param ctx Context handle
 * @param use true to enable (default: false)
 */
void zdedupe_use_credential_excludes(zdedupe_ctx* ctx, bool use);

/**
 * Ignore every entry (file or directory) with exactly this name. Additive,
 * and independent of zdedupe_use_default_excludes. No globs.
 *
 * @param ctx  Context handle
 * @param name A single path component; empty or containing '/' is rejected
 * @return 0 on success, -1 on failure
 */
int zdedupe_add_exclude(zdedupe_ctx* ctx, const char* name);

/**
 * Never scan this absolute path: a folder is skipped with everything beneath
 * it, a file just itself. For the user's own "do not look here" rules, beside
 * zdedupe_add_exclude's names. A scan root is never skipped. Applies to
 * duplicate scans.
 *
 * @return 0 on success, -1 if the path is empty or not absolute
 */
int zdedupe_add_exclude_path(zdedupe_ctx* ctx, const char* path);

/* === Progress & cancellation === */

/**
 * Snapshot of a running scan. `phase` values:
 *   0 idle, 1 scanning (walking), 2 size grouping, 3 quick hashing,
 *   4 full hashing, 5 analyzing, 6 writing results, 7 done
 * `done`/`total` count work items of the current phase (meaningful for the
 * hashing phases); `files_found` grows during the walk.
 */
typedef struct {
    uint32_t phase;
    uint32_t _pad;
    uint64_t files_found;
    uint64_t done;
    uint64_t total;
} zdedupe_progress;

/**
 * Read the progress of the run currently executing on `ctx`.
 *
 * THREAD-SAFE: this, zdedupe_get_current_path() and zdedupe_cancel() are the
 * only functions that may be called from another thread while
 * zdedupe_run_sync()/zdedupe_run_to_file() is running on the same context. They touch nothing but atomics, so a host
 * can poll from a UI timer - no callback re-enters the host.
 */
void zdedupe_get_progress(const zdedupe_ctx* ctx, zdedupe_progress* out);

/**
 * Copy the path the running scan has been working on LONGEST - of the
 * directories being read (walk) or files being read (hashing) right now -
 * into `buf` (not NUL-terminated). While a scan flows it changes constantly;
 * when one directory or file holds the scan up, it is the one shown, so a
 * path that stays put names what is slow.
 * A path longer than `cap` (or than the core's 1024-byte slot) is given as
 * its TAIL, with *truncated set. Returns bytes written; 0 when there is no
 * current path (between phases, idle) or the slot was busy - poll again.
 * Bytes are the raw path spelling; decode lossily.
 *
 * THREAD-SAFE: same contract as zdedupe_get_progress().
 */
size_t zdedupe_get_current_path(const zdedupe_ctx* ctx, char* buf, size_t cap, bool* truncated);

/**
 * Ask the run on `ctx` to stop. The walk stops at the next directory, hashing
 * at the next file - and inside a large file, at the next 64 KiB read. The run
 * then FAILS (NULL / status 2): results are never built from a partial scan,
 * because a file that was not hashed is indistinguishable from a unique one.
 * A cancel requested before the run starts cancels that run; afterwards the
 * context is reusable.
 */
void zdedupe_cancel(zdedupe_ctx* ctx);

/* === Execution === */

/**
 * Run a duplicate scan and write the BINARY RESULT STORE to `path` instead of
 * returning JSON. This is the interface for GUI hosts: the file holds
 * fixed-size records in flat sections, so a host memory-maps it and reads
 * exactly the rows it is about to draw - no parsing, no copy of the results
 * in memory, and a finished scan can be reopened later. The format is
 * specified in src/store.zig. Readers MUST bounds-check every offset.
 *
 * The file is created with mode 0600, written to "<path>.partial" and renamed
 * into place, so an existing store at `path` survives any failure.
 *
 * In ZDEDUPE_MODE_DISK_SPACE the store holds the scanned folder tree instead
 * of duplicate groups (read it with the zdedupe_results_space_* calls). The
 * walk keeps the duplicate scan's scoping - same volume, app libraries and
 * Steam skipped, credential excludes and added excludes honoured, hidden
 * files as set - but ignores zdedupe_use_default_excludes: build output and
 * dependency folders are exactly what a disk-space view has to show. It opens
 * no file, never follows a symlink, and on macOS never makes the system
 * download an iCloud placeholder (a folder that is only in the cloud is
 * reported unreadable). Scanning "/" on macOS also covers the Data volume
 * behind the firmlinks (/Users, /Applications, ...), counted once. Progress
 * phases: scanning, analyzing (building the tree), writing, done.
 *
 * @return 0 ok, 1 failed, 2 cancelled, 3 unsupported (compare-folders mode)
 */
int zdedupe_run_to_file(zdedupe_ctx* ctx, const char* path);

/**
 * Run the scan/compare operation synchronously
 *
 * The returned JSON string is owned by the context and remains valid
 * until the next call to zdedupe_run_sync() or zdedupe_free().
 *
 * For find_duplicates mode, returns JSON of exactly this shape (this block is
 * kept in sync with src/report.zig writeDuplicateJson and is asserted by
 * src/tier1_anchors.zig -- the Swift JSONDecoder models and the Tauri serde
 * structs decode these exact field names):
 * {
 *   "report_type": "duplicates",
 *   "generated_at": "2026-07-19T17:50:52Z",
 *   "scan_duration_ms": 23,
 *   "summary": {
 *     "files_scanned": 1000,
 *     "bytes_scanned": 1073741824,
 *     "bytes_scanned_human": "1.0 GB",
 *     "duplicate_groups": 10,
 *     "duplicate_files": 25,
 *     "space_savings": 524288000,
 *     "space_savings_human": "500.0 MB",
 *     "excluded_entries": 12,
 *     "overlapping_roots": 0
 *   },
 *   "groups": [
 *     {
 *       "hash": "abc123...",
 *       "size": 1048576,
 *       "size_human": "1.0 MB",
 *       "count": 3,
 *       "savings": 2097152,
 *       "savings_human": "2.0 MB",
 *       "files": [
 *         { "path": "/path/a.txt", "mtime": "2026-07-19T17:50:51Z" },
 *         { "path": "/path/b.txt", "mtime": "2026-07-19T17:50:51Z" }
 *       ]
 *     }
 *   ]
 * }
 *
 * "overlapping_roots" counts scan roots dropped because another root already
 * covers them (nested, repeated, or a symlinked spelling of the same place).
 *
 * With zdedupe_set_analyze_dirs(ctx, true) the document gains one more
 * top-level key (absent otherwise, so existing decoders are unaffected):
 *
 *   "directories": {
 *     "analyzed": 2836,
 *     "incomplete": 0,
 *     "identical_sets": [
 *       {
 *         "digest": "7e75cf42...",
 *         "count": 2,
 *         "file_count": 261,
 *         "bytes": 2086912,
 *         "bytes_human": "1.99 MB",
 *         "reclaimable": 2086912,
 *         "reclaimable_human": "1.99 MB",
 *         "dirs": [
 *           { "path": "/a/proj", "newest_mtime": "2026-07-19T17:50:51Z", "skipped_entries": 1 },
 *           { "path": "/a/proj copy", "newest_mtime": "2026-07-19T17:50:51Z", "skipped_entries": 0 }
 *         ]
 *       }
 *     ],
 *     "overlaps": [
 *       {
 *         "relation": "a_in_b",
 *         "a": {
 *           "path": "/backup/proj",
 *           "files": 258, "bytes": 2000000, "bytes_human": "1.91 MB",
 *           "newest_mtime": "2025-03-01T10:00:00Z",
 *           "skipped_entries": 0,
 *           "complete": true,
 *           "identical_copies": 1,
 *           "shared_files": 258, "shared_bytes": 2000000,
 *           "only_count": 0,
 *           "only": []
 *         },
 *         "b": { ...same fields... }
 *       }
 *     ]
 *   }
 *
 * identical_sets: directories whose entire subtree matches - names, file
 * content, symlink targets. Largest "reclaimable" first; only the top-most
 * directory of each copied tree is listed. "reclaimable" is bytes * (count-1),
 * an upper bound when the copies are hard links of one another.
 *
 * overlaps: directory pairs sharing at least half of one side's files, largest
 * shared size first. "relation" is one of:
 *   "same_content"  both hold exactly the same file content (names/layout differ)
 *   "a_in_b"        every file in a also exists in b - a adds nothing
 *   "b_in_a"        every file in b also exists in a - b adds nothing
 *   "overlap"       each side has content the other lacks, OR the side that
 *                   looks contained is not "complete"
 * "only" lists (sorted, at most 100; "only_count" is exact) the files whose
 * content exists nowhere on the other side: what deleting that side would
 * lose. "complete": false means something beneath could not be read; such a
 * directory is never in an identical set and never the contained side.
 * "skipped_entries" counts entries ignored on purpose beneath it (excludes,
 * cache dirs, hidden files when off, sockets/FIFOs); a consumer should surface
 * a non-zero value next to any "identical"/"contained" claim.
 * "identical_copies" > 1 means that side is the first path of an identical
 * set and the pair stands for every member of it.
 *
 * Within a group, "files" is ordered oldest first (mtime, then path), so the
 * first entry is the natural one to keep.
 *
 * Note: "files" is an array of OBJECTS, not of strings, and "mtime" /
 * "generated_at" are ISO-8601 UTC strings. Paths are JSON-escaped by
 * std.json.Stringify, so a filename containing a quote or backslash round-trips
 * intact rather than corrupting the document.
 *
 * For compare_folders mode, returns JSON like:
 * {
 *   "folder_a": "/path/a",
 *   "folder_b": "/path/b",
 *   "is_identical": false,
 *   "summary": {
 *     "identical_count": 100,
 *     "only_in_a_count": 5,
 *     "only_in_b_count": 3,
 *     "modified_count": 2
 *   },
 *   "identical": ["file1.txt", "file2.txt"],
 *   "only_in_a": ["extra.txt"],
 *   "only_in_b": ["new.txt"],
 *   "modified": ["changed.txt"]
 * }
 *
 * @param ctx Context handle
 * @return JSON string, or NULL on failure
 */
const char* zdedupe_run_sync(zdedupe_ctx* ctx);

/* =========================================================================
 * === Results session ===
 * =========================================================================
 *
 * Everything that happens AFTER a scan, done here instead of in each
 * frontend: paging the groups with a sort and filters, summarising the
 * "select all duplicates" rule, deleting verified copies with progress and
 * cancellation, remembering what went so a delete does not force a rescan,
 * and export. A host does: zdedupe_run_to_file -> zdedupe_results_open ->
 * page / summarise / delete / export -> zdedupe_results_close.
 *
 * CONVENTIONS
 *
 *  - Queries in and answers out are UTF-8 JSON, NUL-terminated. A returned
 *    string is owned by the session and valid ONLY until the next call on
 *    that session; copy anything you need to keep.
 *  - Every call on a session happens on one thread at a time, EXCEPT
 *    zdedupe_results_delete_progress and zdedupe_results_cancel_delete,
 *    which touch nothing but atomics and may be called from another thread
 *    while a delete runs (same contract as zdedupe_get_progress/_cancel).
 *  - A failed call returns NULL (pointer-returning) or non-zero
 *    (int-returning); zdedupe_results_last_error then gives the message.
 *  - Paths inside JSON are the LOSSY UTF-8 spelling of the stored bytes -
 *    invalid sequences become U+FFFD, the same spelling Rust's
 *    String::from_utf8_lossy and Swift's String(decoding:as:) produce.
 *    Paths sent back in (unticked, hand-picked) are matched against that
 *    same spelling; everything touching the disk uses the exact bytes.
 *  - Byte counts and timestamps are JSON integers. Timestamps are epoch
 *    MILLISECONDS (the store holds seconds).
 *  - Two sidecars sit beside the store file <dir>/<name>.zds and are owned
 *    by the session: <name>.roots.json (["/root/a", ...], the scan roots,
 *    which the store format does not record) and <name>.removed.json
 *    ({"overflowed": bool, "paths_b64": [...]} - exact path bytes, base64,
 *    because a name that is not UTF-8 must still match after a restart).
 *
 * FILTERS, shared by the group list and the bulk rule:
 *
 *   { "text": "", "min_bytes": 0, "redundant_only": false,
 *     "under": null, "name": null, "ext": null }
 *
 * All fields optional. "text" is an ASCII-case-insensitive substring of any
 * member's path (trimmed; non-ASCII bytes match exactly). "min_bytes" is the
 * size of one file in the group. "under"/"name"/"ext" must hold for the SAME
 * member - "a file called x under /a", not "something under /a and, some-
 * where else, something called x"; "under" matches whole path components
 * (/a/proj-backup is not under /a/proj) and "ext" is lower-case with the dot
 * (".png"), "" meaning no extension. "redundant_only" applies to folder
 * overlaps only. The whole value is the cache key for the row order.
 */

typedef struct zdedupe_results zdedupe_results;

/**
 * Map a finished result store.
 *
 * @param store_path the .zds file zdedupe_run_to_file wrote
 * @param roots_json a JSON array of the scan's root paths, or NULL. When
 *        given (a fresh scan) it is written to the roots sidecar and the
 *        removed sidecar is discarded. When NULL (reopening) both sidecars
 *        are loaded, and roots absent from the sidecar fall back to the
 *        deepest directory containing every path in the results.
 * @return a session, or NULL if the store fails validation, cannot be read,
 *         or roots_json is not a JSON array of strings
 */
zdedupe_results* zdedupe_results_open(const char* store_path, const char* roots_json);

/** Release a session and unmap the store. Safe to pass NULL. */
void zdedupe_results_close(zdedupe_results* r);

/** Why the last call on `r` failed, or NULL. Owned by the session. */
const char* zdedupe_results_last_error(const zdedupe_results* r);

/**
 * The scan's own counters, plus what the folder sections add up to:
 * { "roots": ["/a"], "generated_at": 1758530000000,
 *   "files_scanned": 0, "bytes_scanned": 0, "duplicate_groups": 0,
 *   "duplicate_files": 0, "space_savings": 0, "scan_time_ns": 0,
 *   "excluded_entries": 0, "overlapping_roots": 0, "failed_paths": 0,
 *   "has_directories": false, "dirs_analyzed": 0, "dirs_incomplete": 0,
 *   "identical_sets": 0, "overlaps": 0, "redundant_pairs": 0,
 *   "reclaimable": 0 }
 *
 * These counters are the SCAN's and do not change with deletes; say so
 * beside them. "reclaimable" is the sum of bytes * (copies - 1) over
 * identical folder sets; "redundant_pairs" counts overlap pairs where at
 * least one side has nothing unique.
 */
const char* zdedupe_results_overview(zdedupe_results* r);

/**
 * One page of duplicate groups.
 *
 * Query: { "offset": 0, "limit": 50, "sort": "savings"|"size"|"count",
 *          "filters": {...}, "bulk": {...} | null, "keep": KeepSpec }
 * "limit" is clamped to 200. "bulk" is the select-all rule's filters: the
 * rows it covers come back marked, so a UI shows them selected without ever
 * holding the selection as a list. "keep" decides which copy of each group
 * stays (see KeepSpec below); omitted, the oldest does.
 *
 * Page: { "rows": [GroupRow], "total": N, "offset": 0 }, where a GroupRow is
 * { "hash": "64 hex", "count": 3, "size": 1048576, "savings": 2097152,
 *   "files": ["/oldest", ...], "mtimes": [ms, ...], "keeper": "/path",
 *   "locked": [bool, ...], "targets": [bool, ...], "bulk": false }
 *
 * "count" and "savings" are over the copies that are still ALIVE (the
 * removed overlay applied), "files" lists at most 50 of them oldest first,
 * and "bulk" is (alive >= 2 && the rule matches). "keeper" is the copy
 * "keep" leaves in place, which may lie past the listed 50. "locked" and
 * "targets" run parallel to "files": a locked copy is in a protected
 * location and is never deleted; a target is one the rule would delete.
 *
 * KeepSpec (every field optional):
 *   { "prefer_under": ["/dir", ...],   kept: first copy under the earliest
 *     "avoid_under": ["/dir", ...],    kept only if nothing else is left
 *     "fallback": "oldest"|"newest"|"shortest_path",
 *     "by_type": [{ "ext": ".jpg", "prefer_under": [...],
 *                   "avoid_under": [...], "fallback": "..." }],
 *     "pins": [{ "hash": "64 hex", "path": "/the/copy/to/keep" }],
 *     "delete_only_under": ["/dir", ...] }
 * Per group: a pinned copy is kept; else the first copy under the earliest
 * prefer_under; else, with delete_only_under set, a copy outside those
 * folders survives and every copy inside them is a target; else one
 * unprotected copy is kept by fallback, outside avoid_under while possible.
 * "by_type" replaces prefer_under/avoid_under/fallback for groups whose
 * oldest copy has that extension. Protected copies are always kept; only
 * under delete_only_under do they stand in for the survivor.
 * A group with fewer than two alive copies is not a row at all. Order:
 * "savings" is the store's own order until something has been deleted and
 * live savings after that; "size" and "count" descending. The sort is
 * stable, so ties keep largest-savings-first.
 */
const char* zdedupe_results_groups(zdedupe_results* r, const char* query_json);

/**
 * What the select-all rule covers, as three numbers:
 * { "groups": N, "files": M, "bytes": B } - every copy but the oldest of
 * each matching group. This never sees the unticked list; subtract it in the
 * UI. Takes a bare filters object. Protected copies are not counted.
 */
const char* zdedupe_results_bulk_summary(zdedupe_results* r, const char* filters_json);

/**
 * What a delete carrying this rule would do, for review before it runs.
 *
 * Query: { "filters": {...}, "excluded": ["/unticked", ...],
 *          "keep": KeepSpec, "under": "/dir" | null, "limit": 20 }
 * "filters" is required. "under" is where the location breakdown starts;
 * null starts at the scan root (or the roots, when there are several).
 *
 * Answer: { "groups": N, "files": M, "bytes": B, "locked": L,
 *           "untouched": U, "from": FacetPage }
 * "groups" lose at least one copy; "untouched" match but lose nothing;
 * "locked" counts protected copies in the matching groups, all of which
 * stay; "from" buckets the deleted copies by location, as
 * zdedupe_results_facets does ("count" is copies, "bytes" their size).
 */
const char* zdedupe_results_bulk_plan(zdedupe_results* r, const char* query_json);

/**
 * Protected locations: nothing in them is deleted - not by a rule, not by a
 * hand-ticked path, not as part of a folder. Built in, and not optional:
 * operating-system roots (/System, /Applications, /usr, /etc, ...), per-user
 * application data (~/Library, flatpak), repository stores (.git and the
 * like, anywhere in a path), packages (.app, .framework, photo libraries -
 * any directory so named above a file) and game launcher libraries.
 *
 * set_protected replaces the host's own additions with a JSON array of
 * absolute folders; 0 ok, -1 invalid (see last_error). A folder delete is
 * also refused when the folder holds a protected root.
 *
 * protected returns { "system": [...], "home": [...], "stores": [...],
 * "packages": [...], "user": [...] } for a UI to show.
 */
int zdedupe_results_set_protected(zdedupe_results* r, const char* paths_json);

/**
 * The home directory whose Library (and other per-user roots) is protected.
 * Defaults to the user database's entry, not $HOME: inside the macOS App
 * Sandbox $HOME is the app's container. For a host that knows better, such
 * as a test harness whose temporary files live in that container; the system
 * roots, stores and packages stay protected whatever it says. 0 ok, -1 not
 * an absolute path.
 */
int zdedupe_results_set_home(zdedupe_results* r, const char* path);
const char* zdedupe_results_protected(zdedupe_results* r);

/** Snapshot of a running delete. */
typedef struct {
    bool running;
    uint64_t done;
    uint64_t total;
} zdedupe_delete_progress;

/**
 * Host-provided Trash - the one piece the core cannot do, because there is
 * no portable API for it (trash::delete_all on Linux/Rust,
 * NSWorkspace.recycle on macOS).
 *
 * Called with a batch of at most 200 exact path bytes, each NUL-terminated.
 * Return 0 when EVERY path went; any other value and the session retries the
 * batch one path at a time, so a failure can be attributed to a file. On a
 * single-path call, write a NUL-terminated reason into err_out (at most
 * err_cap bytes) and it is reported against that path.
 *
 * It runs inside the delete that called it, so the only entry points it may
 * use are zdedupe_results_delete_progress and zdedupe_results_cancel_delete.
 */
typedef int (*zdedupe_trash_fn)(void* user, const char* const* paths, size_t count,
                                char* err_out, size_t err_cap);

/**
 * Delete duplicates: what a rule covers, plus what was ticked by hand.
 * BLOCKS until done; poll zdedupe_results_delete_progress from another
 * thread and stop it with zdedupe_results_cancel_delete.
 *
 * selection_json:
 *   { "rule": { "filters": {...}, "excluded": ["/path", ...],
 *               "keep": KeepSpec } | null,
 *     "extra": ["/hand/picked", ...] }
 *
 * use_trash = false deletes PERMANENTLY (unlink) and verifies by content;
 * use_trash = true calls trash_fn (required, or the call fails) and verifies
 * by metadata.
 *
 * NOTHING IS DELETED ON THE STRENGTH OF A STALE HASH. Results describe the
 * disk as it was, which may be hours ago, and a rule deletes files nobody
 * looked at one by one. Every target is lstat'ed on its exact bytes and must
 * still be a REGULAR file (a symlink standing where a file was is not a
 * copy) of the group's recorded size; then its modification time must match
 * (Trash) or its content must re-hash to the group's hash (permanent). A
 * group only loses copies while some file OUTSIDE the targets verifies
 * first, so ticking every copy of a group - the easiest mistake to make -
 * deletes none of them. Whatever fails is skipped and counted.
 *
 * Plan: for each group in the rule's order, the targets are the alive copies
 * its KeepSpec does not keep (see zdedupe_results_groups; omitted, every
 * copy but the oldest), minus "excluded"; hand-picks merge into the same
 * group's targets before any judgement. A hand-picked path that is in no
 * group of these results fails with "not a duplicate in the current
 * results" and is never touched. A target in a protected location (see
 * zdedupe_results_set_protected) fails with "is in a protected location",
 * whether a rule or a hand put it there.
 *
 * Report: { "deleted": N, "freed_bytes": B, "skipped_changed": N,
 *           "failed_count": N, "failed": [["/path","reason"], ...] (<= 20),
 *           "cancelled": bool, "needs_rescan": bool }
 *
 * What went is recorded in the removed overlay and persisted, so the rows
 * correct themselves without a rescan. Past 100,000 tracked paths the
 * overlay overflows, clears, persists "overflowed": true, and needs_rescan
 * stays true from then on, a reopen included: a bulk delete of a million
 * files is cheaper to rescan than to remember.
 *
 * A second delete while one runs fails with "A delete is already running".
 */
const char* zdedupe_results_delete(zdedupe_results* r, const char* selection_json,
                                   bool use_trash, zdedupe_trash_fn trash_fn, void* user);

/**
 * THREAD-SAFE, like zdedupe_get_progress: this and
 * zdedupe_results_cancel_delete touch nothing but atomics, so a UI can poll
 * from a timer. "total" is the whole plan and is set before anything is
 * deleted; "done" advances per group.
 */
void zdedupe_results_delete_progress(const zdedupe_results* r, zdedupe_delete_progress* out);

/**
 * Ask the running delete to stop. It stops before the next group, so what
 * was already deleted stays deleted and the report says "cancelled": true.
 * A cancel asked for before a delete begins cancels that delete; afterwards
 * the session is reusable (as with zdedupe_cancel).
 */
void zdedupe_results_cancel_delete(zdedupe_results* r);

/**
 * How much has been deleted since the results were scanned, and whether they
 * can still be corrected in place: { "count": N, "needs_rescan": bool }.
 *
 * The overlay covers a path itself or any ancestor, so a deleted folder
 * takes everything the results list inside it - and /a/old-backup is not
 * under /a/old.
 */
const char* zdedupe_results_removed_status(zdedupe_results* r);

/* --- Folders -------------------------------------------------------------
 *
 * Present only when the scan ran with zdedupe_set_analyze_dirs(ctx, true);
 * without it the folder counts in the overview are zero and these page empty.
 *
 * Two kinds of finding. An IDENTICAL SET is a group of folders whose entire
 * subtrees match - names, file content, symlink targets - and only the
 * top-most folder of each copied tree is listed. An OVERLAP is a pair of
 * folders sharing at least half of one side's files, which is what catches
 * "this backup is last year's copy of that project, plus three files".
 */

/**
 * One page of identical sets, largest reclaimable first.
 *
 * Query: { "offset": 0, "limit": 50, "filters": {...},
 *          "sort": "reclaim"|"size"|"count" } - descending and stable;
 * "reclaim" (the default) is the store's own order until something is
 * deleted, and live after that. "limit" is clamped to 200. For a set,
 * filters' "min_bytes" is the size of ONE copy.
 *
 * Page: { "rows": [SetRow], "total": N, "offset": 0 }, where a SetRow is
 * { "index": 0, "digest": "64 hex", "count": 3, "common_parent": "/a",
 *   "file_count": 261, "bytes": 2086912, "reclaimable": 4173824,
 *   "dirs": [{ "path": "/a/proj", "newest_mtime": ms,
 *              "skipped_entries": 0, "locked": false }, ...] }
 * ("locked": the folder is, or holds, a protected location.)
 *
 * "count" is the copies still ALIVE and "reclaimable" is bytes * (count - 1)
 * over those - an upper bound, since copies that are hard links of one
 * another take no extra space to begin with. A set with fewer than two alive
 * copies is not a row. "dirs" carries at most 8 of them, because a set can
 * have hundreds (879 in one real scan); the rest come from
 * zdedupe_results_set_members, keyed by "index". "common_parent" is the
 * deepest folder holding every alive copy. "skipped_entries" counts entries
 * ignored on purpose beneath that folder (excludes, cache dirs, hidden files
 * when off); surface a non-zero value next to any "identical" claim.
 */
const char* zdedupe_results_identical_sets(zdedupe_results* r, const char* query_json);

/**
 * Every alive member folder of one set, as a bare JSON array of the same
 * objects a row's "dirs" holds. The one unpaged call in the API, and bounded
 * by a single set. `index` is a SetRow's "index".
 */
const char* zdedupe_results_set_members(zdedupe_results* r, size_t index);

/**
 * One page of overlapping folder pairs, largest shared size first. Same query
 * shape as the sets; for an overlap "min_bytes" is the SHARED size, and
 * "redundant_only": true hides pairs where each side still has something
 * unique - keeping only the ones where deleting a side loses nothing.
 *
 * Page: { "rows": [OverlapRow], "total": N, "offset": 0 }, where an
 * OverlapRow is { "relation": ..., "a": SideRow, "b": SideRow } and a SideRow
 * is { "path": "/backup/proj", "files": 258, "bytes": 2000000,
 *      "newest_mtime": ms, "skipped_entries": 0, "complete": true,
 *      "identical_copies": 1, "shared_files": 258, "shared_bytes": 2000000,
 *      "only_count": 0, "only": [] }
 *
 * "relation" is one of:
 *   "same_content"  both hold exactly the same content (names/layout differ)
 *   "a_in_b"        every file in a also exists in b - a adds nothing
 *   "b_in_a"        every file in b also exists in a - b adds nothing
 *   "overlap"       each side has content the other lacks, OR the side that
 *                   looks contained is not "complete"
 *
 * "only" lists the files whose content exists nowhere on the other side -
 * what deleting that side would lose - sorted, at most 100, while
 * "only_count" is exact. "complete": false means something beneath could not
 * be read; such a folder is never in an identical set and never the contained
 * side. "identical_copies" above 1 means that side is the first path of an
 * identical set and the pair stands for every member of it, reported once
 * rather than per copy. A pair with either side deleted is not a row: it says
 * nothing once one of the two folders is gone.
 */
const char* zdedupe_results_overlaps(zdedupe_results* r, const char* query_json);

/**
 * Findings counted by where they are, what they are called, or what type they
 * are - the "group by" of the UI, and what makes a whole-disk scan reviewable
 * (one real scan: 13,370 identical sets, of which 602 held 96 of the 98 GB
 * that could be reclaimed).
 *
 * Query: { "kind": "groups"|"sets"|"overlaps", "by": "location"|"name"|"type",
 *          "filters": {...}, "limit": 50 } - "limit" clamped to 100.
 *
 * Page: { "base": "/home/u" | null, "facets": [{ "key": "/home/u/sdk",
 *         "count": 2, "bytes": 1100 }, ...], "total": N }
 *
 * "key" is the value to put in filters' under / name / ext to select that
 * facet, so a location facet drills down one level at a time: "base" is the
 * folder being drilled into (filters.under, or the single scan root when
 * nothing is chosen yet, else null) and the keys are its children. A finding
 * contributes once to each DISTINCT facet it touches, however many of its
 * members share that facet, so counts can add up to more than the total.
 * Largest "bytes" first, then count, then key, so the same scan always lists
 * its facets the same way. "total" is the distinct facets before the cut.
 */
const char* zdedupe_results_facets(zdedupe_results* r, const char* query_json);

/**
 * Remove whole folders. Blocks, with the same progress and cancellation as
 * zdedupe_results_delete, and the same report shape.
 *
 * items_json: [{ "path": "/a/copy", "keepers": ["/a/orig"], "bytes": 0 }, ...]
 * where "keepers" are folders holding the same content that are NOT being
 * removed, and "bytes" is the size the UI showed, for "freed_bytes".
 *
 * use_trash = true moves each one with trash_fn (required). That is
 * recoverable, so the selection rules in the UI are the safeguard and no
 * comparison is made - but a symlink or a file is still refused, because
 * removing "it" is not what the user picked.
 *
 * use_trash = false removes it FOR GOOD, and only after the folder has been
 * compared with a surviving copy byte for byte, right then: the same relative
 * paths, the same content, nothing extra on either side, hidden and empty
 * files included. That comparison ignores the scan's size window entirely, so
 * a folder can never pass for a copy of another because the file that differs
 * was too small to have been scanned. A keeper that is itself in this list -
 * or that contains, or sits inside, something in it - vouches for nothing.
 * Refused outright: a relative path, "/" itself, a symlink, a file, a folder
 * that cannot be read, and a folder with no keeper named.
 *
 * Whatever went is recorded in the removed overlay, and a removed folder
 * covers everything the results list inside it, so the sets, overlaps, groups
 * and facets all correct themselves without a rescan.
 */
const char* zdedupe_results_delete_folders(zdedupe_results* r, const char* items_json,
                                           bool use_trash, zdedupe_trash_fn trash_fn, void* user);

/**
 * Write every alive group, in store order, to `path`. Streams group by
 * group, so a scan with millions of duplicates never exists as one document
 * in memory. The file is created 0600 and truncated.
 *
 * @param format "json", "csv" or "html"
 * @return 0 on success, -1 on failure
 *
 * CSV carries the header
 * "Group Hash,File Path,File Size (bytes),Group Savings (bytes),Modified"
 * and one line per file. JSON is
 * {report_type, generated_at, summary{...},
 *  groups:[{hash,size,count,savings,files:[{path,mtime}]}]}, with the scan's
 * own summary counters. HTML is a table banner-rowed by group. Timestamps
 * here are ISO-8601 UTC strings, not milliseconds - these are documents for
 * a person, not answers for a UI.
 */
int zdedupe_results_export(zdedupe_results* r, const char* format, const char* path);

/* === Disk space ===
 *
 * Over a store written in ZDEDUPE_MODE_DISK_SPACE. Every folder carries what
 * its whole subtree adds up to; a host asks for one level at a time and gets
 * the top N of it plus one "everything else" remainder, so a folder holding a
 * million files costs the UI a few hundred rows. Shapes are in
 * schema/results-session.schema.json ($defs/Space*); the calls fail (NULL, with
 * last_error "these results are not a disk-space scan") on a duplicate store.
 *
 * Sizes: "bytes" is space on disk (allocated blocks) - a cloud placeholder
 * counts ~0, a sparse file what it occupies; "logical" is the apparent size.
 * Every inode counts once (of several hard links, the lexicographically
 * smallest path holds the bytes). APFS clones are counted in full.
 *
 * Types: media, documents, code, archives, applications, system, other. The
 * extension decides, except inside a folder that decides for everything it
 * holds: an app bundle is applications, node_modules/.git/DerivedData and the
 * like are code, OS trees and ~/Library/Caches|Logs are system.
 *
 * Folder and file ids are stable for the life of the store. Everything the
 * removed overlay holds (see zdedupe_results_space_trash) is left out of every
 * answer, and folder totals are corrected for it.
 */

/**
 * The scan as a whole -> SpaceOverview: roots, volume (mount, total, free,
 * available - as scanned; on macOS the APFS container's figures), totals
 * (files, dirs, bytes, logical, cloud-only files, hard links, excluded
 * entries, errors, unreadable folders), bytes and files per type.
 */
const char* zdedupe_results_space_overview(zdedupe_results* r);

/**
 * One folder's contents -> SpaceChildren. Query (SpaceChildrenQuery):
 *   { "node": id | null, "path": "/abs" | null,
 *     "by": "folder" | "type" | "size", "limit": 150, "per_group": 40,
 *     "depth": 1, "nested_limit": 16 }
 * No node and no path means the scan root (every root, as a node of kind
 * "all", when there were several). "folder": one group, the folder's
 * subfolders and files merged largest first, `limit` of them (<= 500).
 * "type": every file below the folder grouped by type, largest group first;
 * "size": grouped by size band (over_1g, 100m_1g, 10m_100m, 1m_10m,
 * under_1m); each group lists its `per_group` (<= 200) largest files. With
 * "depth" 2 or 3 (folder view), each folder item also carries "children" -
 * its own `nested_limit` (<= 60) largest items - and "children_rest", nesting
 * again while depth remains, for a map that draws folders inside folders; at
 * most 3000 nested items per answer. Every
 * group carries a "rest" {count, bytes} for what it did not list. "trail"
 * leads from the root to the folder, for a breadcrumb. Fails when the folder
 * is not in these results or was removed.
 */
const char* zdedupe_results_space_children(zdedupe_results* r, const char* query_json);

/**
 * Largest items below a folder -> SpaceLargest. Query (SpaceLargestQuery):
 *   { "node"|"path" as above, "kind": "files" | "folders",
 *     "type": "media" ... | null, "limit": 100 (<= 200) }
 * Folders rank by their whole size and leave out wrappers: a folder whose
 * largest subfolder holds 90% or more of it is represented by that subfolder.
 */
const char* zdedupe_results_space_largest(zdedupe_results* r, const char* query_json);

/**
 * Record this scan in its volume's history, kept as one JSON file per volume
 * in `history_dir` (a folder the host owns; created files are 0600), and
 * describe that history -> SpaceHistory: every recorded scan's totals, oldest
 * first (at most 30), and - against the latest earlier scan of the same roots
 * - the folders (down to three levels below a root) that grew most and
 * shrank most. Idempotent: a scan is recorded once however often this is
 * called. Uses the figures as scanned, not corrected for later removals.
 */
const char* zdedupe_results_space_history(zdedupe_results* r, const char* history_dir);

/**
 * Move folders and files to the Trash through `trash_fn` (the same host
 * callback zdedupe_results_delete uses). There is no permanent delete here.
 * items_json (SpaceTrashItems): { "items": [{"kind":"dir"|"file","id":N}, ...] }
 * (at most 10,000). Each is checked first: a file must still be a regular
 * file with the scanned size and modification time (else skipped_changed); a
 * folder must still be a folder, not a link; nothing that is, or holds, a
 * protected location goes (zdedupe_results_protected), and a scan root never
 * goes whole. Anything inside a folder that goes is left to it. Blocks until
 * done; progress and cancel as for zdedupe_results_delete. Returns a
 * DeleteReport; freed_bytes counts space on disk, and 0 for a file with other
 * hard links (they keep its blocks). What went joins the removed overlay, so
 * every space answer corrects itself without a rescan.
 */
const char* zdedupe_results_space_trash(zdedupe_results* r, const char* items_json,
                                        zdedupe_trash_fn trash_fn, void* user);

/* === Utilities === */

/**
 * Delete a file
 *
 * @param path Absolute path to file
 * @return 0 on success, -1 on failure
 */
int zdedupe_delete_file(const char* path);

/**
 * Move/rename a file
 *
 * @param src Source path
 * @param dst Destination path
 * @return 0 on success, -1 on failure
 */
int zdedupe_move_file(const char* src, const char* dst);

/**
 * Hash one file with the algorithm a scan uses, into out[32].
 *
 * For hosts about to delete a duplicate PERMANENTLY: scan results describe
 * the disk as it was. Re-hash the file and the copy being kept and compare
 * both with the group's recorded hash before unlinking. Non-regular files are
 * refused and a read error is a failure, exactly as during a scan.
 *
 * @param use_sha256 must match the scan (result store flag bit 1)
 * @return 0 on success, -1 on failure
 */
int zdedupe_hash_file(const char* path, bool use_sha256, uint8_t out[32]);

/**
 * Get library version string
 *
 * @return Version string (e.g., "0.1.0")
 */
const char* zdedupe_version(void);

/**
 * The names zdedupe_use_credential_excludes skips, as a JSON array of
 * strings, for a settings screen to show. Static; never freed. The list
 * exists only here, so what the UI shows is what the engine does.
 */
const char* zdedupe_credential_excludes_json(void);

#ifdef __cplusplus
}
#endif

#endif /* ZDEDUPE_H */
