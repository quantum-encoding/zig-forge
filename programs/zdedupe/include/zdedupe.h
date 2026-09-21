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
    ZDEDUPE_MODE_COMPARE_FOLDERS = 1
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
 * @param mode ZDEDUPE_MODE_FIND_DUPLICATES or ZDEDUPE_MODE_COMPARE_FOLDERS
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
 * Ignore every entry (file or directory) with exactly this name. Additive,
 * and independent of zdedupe_use_default_excludes. No globs.
 *
 * @param ctx  Context handle
 * @param name A single path component; empty or containing '/' is rejected
 * @return 0 on success, -1 on failure
 */
int zdedupe_add_exclude(zdedupe_ctx* ctx, const char* name);

/* === Execution === */

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
 * Get library version string
 *
 * @return Version string (e.g., "0.1.0")
 */
const char* zdedupe_version(void);

#ifdef __cplusplus
}
#endif

#endif /* ZDEDUPE_H */
