/*
 * zig_lens.h — C interface for zig-lens source code analysis library
 *
 * Link against libzig_lens.a (static library built with `zig build`).
 *
 * Memory ownership:
 *   Functions returning buffers via out_buf/out_len allocate internally.
 *   You MUST call zig_lens_free_buffer(ptr, len) when done.
 *   zig_lens_count_lines and zig_lens_get_error use caller-owned storage.
 *   zig_lens_version returns a static string — do NOT free it.
 *
 * Example usage:
 *
 *   char* buf = NULL;
 *   size_t len = 0;
 *   int rc = zig_lens_analyze_path("/path/to/project", ZIG_LENS_FORMAT_JSON, NULL, &buf, &len);
 *   if (rc == ZIG_LENS_OK) {
 *       printf("%.*s\n", (int)len, buf);
 *       zig_lens_free_buffer(buf, len);
 *   } else {
 *       char err[256];
 *       zig_lens_get_error(err, sizeof(err));
 *       fprintf(stderr, "Error: %s\n", err);
 *   }
 */

#ifndef ZIG_LENS_H
#define ZIG_LENS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Result Codes
 * ========================================================================= */

#define ZIG_LENS_OK             0   /* Success */
#define ZIG_LENS_ERR_NULL_PTR  -1   /* Null pointer argument */
#define ZIG_LENS_ERR_INVALID   -2   /* Invalid argument (bad format, language, empty path) */
#define ZIG_LENS_ERR_ANALYSIS  -3   /* Analysis or serialization failed */
#define ZIG_LENS_ERR_IO        -4   /* File I/O error */
#define ZIG_LENS_ERR_OOM       -5   /* Out of memory */

/* =========================================================================
 * Output Format Codes (for zig_lens_analyze_path)
 * ========================================================================= */

#define ZIG_LENS_FORMAT_JSON      0  /* Full JSON with per-file details */
#define ZIG_LENS_FORMAT_COMPACT   1  /* Compact AI-optimized JSON */
#define ZIG_LENS_FORMAT_TERMINAL  2  /* Colored terminal summary */
#define ZIG_LENS_FORMAT_MARKDOWN  3  /* GitHub-compatible Markdown report */
#define ZIG_LENS_FORMAT_DOT       4  /* Graphviz DOT dependency graph */

/* =========================================================================
 * Language Codes (for zig_lens_analyze_source)
 * ========================================================================= */

#define ZIG_LENS_LANG_ZIG         0
#define ZIG_LENS_LANG_RUST        1
#define ZIG_LENS_LANG_C           2
#define ZIG_LENS_LANG_PYTHON      3
#define ZIG_LENS_LANG_JAVASCRIPT  4

/* =========================================================================
 * Progress Callback
 * ========================================================================= */

/*
 * Optional callback invoked during long-running operations.
 *   percent  — 0..100 progress estimate
 *   message  — null-terminated status description (e.g. "Scanning files")
 * Pass NULL to disable progress reporting.
 */
typedef void (*ZigLensProgressCallback)(int percent, const char* message);

/* =========================================================================
 * Functions
 * ========================================================================= */

/*
 * zig_lens_version — Get library version string.
 *
 * Returns a pointer to a static null-terminated string (e.g. "0.1.0").
 * Do NOT free the returned pointer.
 */
const char* zig_lens_version(void);

/*
 * zig_lens_get_error — Retrieve the last error message for this thread.
 *
 * Copies the error message into buf (null-terminated).
 * Returns the number of bytes written (excluding null terminator).
 * If buf is NULL or buf_size is 0, returns the required buffer size.
 *
 * Caller owns buf — no free needed.
 */
size_t zig_lens_get_error(char* buf, size_t buf_size);

/*
 * zig_lens_analyze_path — Analyze a file or directory.
 *
 * Runs the full analysis pipeline (scan, parse, analyze) and returns
 * the result in the requested output format.
 *
 * Parameters:
 *   path        — Null-terminated path to file or directory
 *   format      — Output format (ZIG_LENS_FORMAT_*)
 *   progress_cb — Progress callback, or NULL
 *   out_buf     — [out] Receives pointer to result buffer
 *   out_len     — [out] Receives byte length of result
 *
 * Returns ZIG_LENS_OK on success. Caller MUST free *out_buf with
 * zig_lens_free_buffer(*out_buf, *out_len).
 */
int zig_lens_analyze_path(
    const char*              path,
    int                      format,
    ZigLensProgressCallback  progress_cb,
    char**                   out_buf,
    size_t*                  out_len
);

/*
 * zig_lens_compile_codebase — Compile codebase into a single Markdown document.
 *
 * Walks the directory tree, collects all text files, and produces a
 * Markdown document with directory tree and complete file contents.
 *
 * Parameters:
 *   path        — Null-terminated path to directory
 *   progress_cb — Progress callback, or NULL
 *   out_buf     — [out] Receives pointer to result buffer
 *   out_len     — [out] Receives byte length of result
 *
 * Returns ZIG_LENS_OK on success. Caller MUST free *out_buf.
 */
int zig_lens_compile_codebase(
    const char*              path,
    ZigLensProgressCallback  progress_cb,
    char**                   out_buf,
    size_t*                  out_len
);

/*
 * zig_lens_generate_reports — Generate all report formats into a directory.
 *
 * Creates: ai-context.json, full-analysis.json, summary.md,
 * dependencies.dot, OVERVIEW.md
 *
 * Parameters:
 *   path        — Null-terminated path to file or directory to analyze
 *   output_dir  — Null-terminated path to output directory (created if needed)
 *   progress_cb — Progress callback, or NULL
 *
 * Returns ZIG_LENS_OK on success. No buffer returned — files written to disk.
 */
int zig_lens_generate_reports(
    const char*              path,
    const char*              output_dir,
    ZigLensProgressCallback  progress_cb
);

/*
 * zig_lens_analyze_source — Analyze in-memory source code.
 *
 * Analyzes a source buffer without file I/O. Returns JSON analysis.
 * For Zig: uses compiler AST parser. Others: line-based scanner.
 *
 * Parameters:
 *   source      — Pointer to source code bytes (not required to be null-terminated)
 *   source_len  — Byte length of source
 *   language    — Language code (ZIG_LENS_LANG_*)
 *   out_buf     — [out] Receives pointer to JSON result
 *   out_len     — [out] Receives byte length of result
 *
 * Returns ZIG_LENS_OK on success. Caller MUST free *out_buf.
 */
int zig_lens_analyze_source(
    const char*  source,
    size_t       source_len,
    int          language,
    char**       out_buf,
    size_t*      out_len
);

/*
 * zig_lens_count_lines — Count lines, blanks, and comments in source code.
 *
 * Pure function — no allocation, no I/O. Results written to caller-provided
 * pointers. No free needed.
 *
 * Parameters:
 *   source       — Pointer to source code bytes
 *   source_len   — Byte length of source
 *   out_loc      — [out] Receives total line count
 *   out_blank    — [out] Receives blank line count
 *   out_comments — [out] Receives comment line count
 *
 * Returns ZIG_LENS_OK on success.
 */
int zig_lens_count_lines(
    const char*  source,
    size_t       source_len,
    uint32_t*    out_loc,
    uint32_t*    out_blank,
    uint32_t*    out_comments
);

/*
 * zig_lens_free_buffer — Free a buffer allocated by zig-lens.
 *
 * MUST be called on every buffer returned via out_buf/out_len from:
 *   - zig_lens_analyze_path
 *   - zig_lens_compile_codebase
 *   - zig_lens_analyze_source
 *
 * Parameters:
 *   ptr — Pointer from out_buf
 *   len — Length from out_len
 *
 * Safe to call with NULL/0.
 */
void zig_lens_free_buffer(char* ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* ZIG_LENS_H */
