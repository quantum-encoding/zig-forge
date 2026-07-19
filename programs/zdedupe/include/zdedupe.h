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
 *     "space_savings_human": "500.0 MB"
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
